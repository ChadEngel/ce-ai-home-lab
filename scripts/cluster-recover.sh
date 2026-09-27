#!/bin/bash
# cluster-recover.sh — bring k3s back after power-on OR a network outage,
# WITHOUT the manual stale-NFS-mount rescue.
#
# THE PROBLEM THIS SOLVES
#   The UDM Pro is the LAN router/DNS/DHCP. Whenever it drops, the NAS (NFS) at
#   192.168.30.121 becomes unreachable. Kubelet's hard NFS mounts then hang, the
#   worker nodes go NotReady, and pods wedge (ContainerCreating / Error) — and
#   they do NOT recover on their own once the network returns, because the stale
#   mounts stay stuck in the kernel. Fixing it by hand = find the hung mounts,
#   `umount -l` each, restart k3s-agent. This script does all that.
#
# WHAT IT DOES (idempotent; only touches a node when something is wrong)
#   1. waits for the NAS/NFS to answer,
#   2. ensures k3s is running (control plane first) and the API is up,
#   3. on any node that is NotReady or has a hung kubelet NFS mount:
#        lazily unmount the stale mounts, restart k3s-agent (or k3s),
#   4. waits for nodes Ready and pods Running,
#   5. clears pods stuck in non-self-healing states (Error/Unknown/CreateContainerError),
#   6. reports anything still not healthy.
#
# NAS (.121) and aiserver (.10) are NOT managed here — they just come back.
#
# Usage (from the repo root, workstation with kubectl + SSH to the nodes):
#   ./scripts/cluster-recover.sh
#
# Env overrides:  SSH_USER, SSH_KEY, NFS_SERVER, RECOVER_ROUNDS, NODE_WAIT
set -uo pipefail   # NOTE: no -e; this is a best-effort recovery tool

SSH_USER="${SSH_USER:-cengel}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/homelab-agent-util-server}"
SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8"
NFS_SERVER="${NFS_SERVER:-192.168.30.121}"
CONTROL_NAME="util-server"; CONTROL_IP="192.168.30.217"; CONTROL_SVC="k3s"
WORKERS=("caelx002=192.168.30.60" "caelx003=192.168.30.251")
RECOVER_ROUNDS="${RECOVER_ROUNDS:-4}"
NODE_WAIT="${NODE_WAIT:-300}"     # seconds to wait for all nodes Ready

log()  { printf '\033[1;34m[recover]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[✅]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[⚠️]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[✖]\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$SSH_KEY" ] || die "SSH key not found: $SSH_KEY (set SSH_KEY=...)"

ssh_ok() { ssh $SSH_OPTS "$SSH_USER@$1" true 2>/dev/null; }

# Run a script on a node via base64 (avoids nested-quoting hell), as root.
run_remote_root() { # <ip> <script>
  local ip="$1" b64; b64="$(printf '%s' "$2" | base64 | tr -d '\n')"
  ssh $SSH_OPTS "$SSH_USER@$ip" "echo $b64 | base64 -d | sudo sh"
}

# ---- 1. NFS reachable? -------------------------------------------------------
log "checking NFS server $NFS_SERVER:2049 ..."
nfs_ok=0
for i in $(seq 1 24); do
  if ssh_ok "$CONTROL_IP" && \
     ssh $SSH_OPTS "$SSH_USER@$CONTROL_IP" \
        "timeout 4 bash -c 'cat < /dev/null > /dev/tcp/$NFS_SERVER/2049'" 2>/dev/null; then
    nfs_ok=1; break
  fi
  [ "$i" = 1 ] && log "  NFS not answering — waiting (bring the NAS up if it's off) ..."
  sleep 5
done
[ "$nfs_ok" = 1 ] && ok "NFS reachable" || die "NFS $NFS_SERVER:2049 unreachable after 120s — power on / check the NAS first"

# ---- 2. control plane + API --------------------------------------------------
ssh_ok "$CONTROL_IP" || die "$CONTROL_NAME ($CONTROL_IP) not reachable — power it on (physical host) and re-run"
if ssh $SSH_OPTS "$SSH_USER@$CONTROL_IP" "systemctl is-active --quiet $CONTROL_SVC"; then
  log "$CONTROL_NAME: $CONTROL_SVC already active"
else
  log "$CONTROL_NAME: starting $CONTROL_SVC ..."
fi
ssh $SSH_OPTS "$SSH_USER@$CONTROL_IP" "sudo systemctl start $CONTROL_SVC" >/dev/null 2>&1

log "waiting for the Kubernetes API (https://$CONTROL_IP:6443) ..."
api_ok=0
for i in $(seq 1 60); do
  if kubectl get --raw='/readyz' >/dev/null 2>&1; then api_ok=1; break; fi
  sleep 5
done
[ "$api_ok" = 1 ] && ok "API ready" || die "API not ready after 300s — check: ssh $SSH_USER@$CONTROL_IP 'journalctl -u $CONTROL_SVC -n 50'"

# ---- 3. workers up? ----------------------------------------------------------
# (no associative arrays — macOS /bin/bash is 3.2)
for entry in "${WORKERS[@]}"; do
  n="${entry%%=*}"; ip="${entry##*=}"
  if ! ssh_ok "$ip"; then warn "$n ($ip) not reachable — power it on (Proxmox) and re-run"; continue; fi
  ssh $SSH_OPTS "$SSH_USER@$ip" "sudo systemctl start k3s-agent" >/dev/null 2>&1
done

# ---- 3b. re-assert the Tailscale subnet route --------------------------------
# k3s-killall.sh used to wipe `--advertise-routes`, which silently breaks
# tailnet access to the whole LAN (grafana./ai./secrets. etc all resolve to
# 192.168.30.217). Re-assert it; harmless on nodes without tailscale.
TS_ROUTES="${TS_ROUTES:-192.168.30.0/24}"
log "ensuring Tailscale subnet route ($TS_ROUTES) is advertised ..."
for entry in "$CONTROL_NAME=$CONTROL_IP" "${WORKERS[@]}"; do
  n="${entry%%=*}"; ip="${entry##*=}"
  ssh_ok "$ip" || continue
  if ssh $SSH_OPTS "$SSH_USER@$ip" 'command -v tailscale >/dev/null 2>&1' 2>/dev/null; then
    if ssh $SSH_OPTS "$SSH_USER@$ip" "sudo tailscale set --advertise-routes=$TS_ROUTES" >/dev/null 2>&1; then
      ok "$n advertising $TS_ROUTES"
    else
      warn "$n: could not set tailscale route"
    fi
  fi
done

# ---- 4. heal loop ------------------------------------------------------------
node_ready() { kubectl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; }
hung_mounts() { # <ip> ; prints hung mountpoints, exits 0 if none
  run_remote_root "$1" '
    for m in $(awk "\$3==\"nfs4\"||\$3==\"nfs\"" /proc/mounts 2>/dev/null | grep "^/var/lib/kubelet"); do
      timeout 5 ls "$m" >/dev/null 2>&1 || echo "$m"
    done' 2>/dev/null
}
heal_node() { # <name> <ip> <svc>
  local name="$1" ip="$2" svc="$3"
  local hung; hung="$(hung_mounts "$ip")"
  if [ -n "$hung" ]; then
    warn "$name: clearing $(printf '%s\n' "$hung" | wc -l | tr -d ' ') hung NFS mount(s)"
    run_remote_root "$ip" "for m in $(printf '%s' "$hung" | tr '\n' ' '); do sudo umount -l \"\$m\" 2>/dev/null || sudo umount -f \"\$m\" 2>/dev/null; done" >/dev/null 2>&1
  fi
  warn "$name: restarting $svc to re-establish mounts"
  ssh $SSH_OPTS "$SSH_USER@$ip" "sudo systemctl restart $svc" >/dev/null 2>&1
}

for round in $(seq 1 "$RECOVER_ROUNDS"); do
  log "heal pass $round/$RECOVER_ROUNDS ..."
  bad=0
  # control plane
  if ! node_ready "$CONTROL_NAME"; then heal_node "$CONTROL_NAME" "$CONTROL_IP" "$CONTROL_SVC"; bad=1; fi
  for entry in "${WORKERS[@]}"; do
    n="${entry%%=*}"; ip="${entry##*=}"
    ssh_ok "$ip" || { bad=1; continue; }
    if ! node_ready "$n" || [ -n "$(hung_mounts "$ip")" ]; then heal_node "$n" "$ip" "k3s-agent"; bad=1; fi
  done
  [ "$bad" = 0 ] && { ok "all reachable nodes healthy (no hung mounts, all Ready)"; break; }

  # wait for nodes to come back this round
  waited=0
  while [ "$waited" -lt "$NODE_WAIT" ]; do
    allready=1
    for entry in "${WORKERS[@]}"; do
      n="${entry%%=*}"; ssh_ok "${entry##*=}" || continue
      node_ready "$n" || allready=0
    done
    node_ready "$CONTROL_NAME" || allready=0
    [ "$allready" = 1 ] && break
    sleep 10; waited=$((waited+10))
  done
done

# ---- 5. final node status ----------------------------------------------------
echo; log "nodes:"; kubectl get nodes -o wide 2>/dev/null | sed 's/^/  /'

# ---- 6. nudge non-self-healing pods -----------------------------------------
stuck="$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4=="Error"||$4=="Unknown"||$4=="CreateContainerError"{print $1" "$2}')"
if [ -n "$stuck" ]; then
  warn "deleting pods in non-self-healing states (controllers will recreate them):"
  printf '%s\n' "$stuck" | while read -r ns pod; do
    [ -n "$pod" ] && { echo "    $ns/$pod"; kubectl delete pod -n "$ns" "$pod" --wait=false >/dev/null 2>&1; }
  done
fi

# ---- 7. wait for pods + report ----------------------------------------------
log "waiting for pods to settle (up to 300s) ..."
for i in $(seq 1 60); do
  n="$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4!="Running"&&$4!="Completed"' | wc -l | tr -d ' ')"
  [ "$n" = 0 ] && break
  sleep 5
done

echo; log "final pod state:"
kubectl get pods -n ai -o wide 2>/dev/null | sed 's/^/  /'
remaining="$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4!="Running"&&$4!="Completed"{print $1"/"$2" ("$4")"}')"
echo
if [ -z "$remaining" ]; then
  ok "recovery complete — every pod is Running/Completed"
else
  warn "still not healthy:"
  printf '%s\n' "$remaining" | sed 's/^/    /'
  warn "check pod events:  kubectl describe pod -n <ns> <pod>"
fi
