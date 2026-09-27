#!/bin/bash
# cluster-stop.sh — gracefully stop the k3s cluster (NAS + aiserver left RUNNING).
#
# Why stop k3s at all before a network outage:
#   The UDM Pro is the LAN router/DNS/DHCP. When it goes away, the NAS (NFS) at
#   192.168.30.121 becomes unreachable, kubelet's hard NFS mounts hang, nodes go
#   NotReady and pods wedge. Stopping k3s cleanly now means a clean start later
#   (see scripts/cluster-recover.sh) instead of a stale-mount rescue.
#
# Order: workers -> control plane -> optionally power the nodes off.
# NAS (.121) and aiserver (.10) are intentionally NOT touched.
#
# Usage (from the repo root, workstation with SSH to the nodes):
#   ./scripts/cluster-stop.sh              # stop k3s services only
#   ./scripts/cluster-stop.sh --poweroff   # also `shutdown -h now` each node
#
# Env overrides:
#   SSH_USER=cengel   NODES="name=ip ..."   SSH_KEY=~/.ssh/homelab-agent-util-server

set -euo pipefail

SSH_USER="${SSH_USER:-cengel}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/homelab-agent-util-server}"
SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8"
# Workers first, control plane last.
WORKERS=("caelx002=192.168.30.60" "caelx003=192.168.30.251")
CONTROL=("util-server=192.168.30.217")
POWEROFF=0
[ "${1:-}" = "--poweroff" ] && POWEROFF=1

log()  { printf '\033[1;34m[cluster-stop]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[✅]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[⚠️]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[✖]\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$SSH_KEY" ] || die "SSH key not found: $SSH_KEY (set SSH_KEY=...)"

echo "=== Stopping k3s cluster (NAS + aiserver stay up) ==="

# 1) stop the metrics push timer so util-server stops writing to Influx while
#    things wind down (harmless if absent).
ssh $SSH_OPTS "$SSH_USER@192.168.30.217" 'sudo systemctl stop k3s-metrics-push.timer 2>/dev/null || true' >/dev/null 2>&1 \
  && ok "stopped k3s-metrics-push.timer (util-server)" || warn "metrics timer stop skipped"

# 2) workers first
for entry in "${WORKERS[@]}"; do
  name="${entry%%=*}"; ip="${entry##*=}"
  log "stopping k3s-agent on $name ($ip) ..."
  ssh $SSH_OPTS "$SSH_USER@$ip" 'sudo systemctl stop k3s-agent' && ok "$name k3s-agent stopped" || warn "$name stop returned non-zero"
done

# 3) control plane last (apiserver goes away here -- kubectl stops working)
for entry in "${CONTROL[@]}"; do
  name="${entry%%=*}"; ip="${entry##*=}"
  log "stopping k3s on $name ($ip) ..."
  ssh $SSH_OPTS "$SSH_USER@$ip" 'sudo systemctl stop k3s' && ok "$name k3s stopped" || warn "$name stop returned non-zero"
done

# 4) verify no k3s/containerd left.  NB: `pgrep k3s` matches by *command name*; the
#    containerd-shim-runc-v2 binary path contains "k3s" but its comm is
#    containerd-shim-runc-v2, so we check by comm and the k3s binary specifically.
log "verifying nothing k3s-related is still running ..."
for entry in "${WORKERS[@]}" "${CONTROL[@]}"; do
  name="${entry%%=*}"; ip="${entry##*=}"
  out="$(ssh $SSH_OPTS "$SSH_USER@$ip" '{ pgrep -a -x k3s; pgrep -a -x k3s-agent; pgrep -a -x containerd-shim-runc-v2; pgrep -a -x kubelet; } 2>/dev/null' 2>/dev/null | head -5 || true)"
  [ -z "$out" ] && ok "$name clean" || { warn "$name still has processes:"; printf '%s\n' "$out" | sed 's/^/    /'; }
done

log "running k3s-killall.sh on every node (stops containerd + cleans up shims) ..."
for entry in "${WORKERS[@]}" "${CONTROL[@]}"; do
  name="${entry%%=*}"; ip="${entry##*=}"
  if ssh $SSH_OPTS "$SSH_USER@$ip" '[ -x /usr/local/bin/k3s-killall.sh ]' 2>/dev/null; then
    ssh $SSH_OPTS "$SSH_USER@$ip" 'sudo /usr/local/bin/k3s-killall.sh >/dev/null 2>&1' \
      && ok "$name killall ok" || warn "$name killall returned non-zero"
  else
    warn "$name has no k3s-killall.sh — containers may still be running"
  fi
done

# 4b) re-assert the Tailscale subnet route. k3s-killall.sh on these nodes used
#     to run `tailscale set --advertise-routes=` which WIPED the route and
#     silently broke tailnet access to the LAN. Harmless on nodes without
#     tailscale. (See docs/tailscale-subnet-router.md.)
TS_ROUTES="${TS_ROUTES:-192.168.30.0/24}"
log "ensuring Tailscale subnet route ($TS_ROUTES) is advertised ..."
for entry in "${WORKERS[@]}" "${CONTROL[@]}"; do
  name="${entry%%=*}"; ip="${entry##*=}"
  if ssh $SSH_OPTS "$SSH_USER@$ip" 'command -v tailscale >/dev/null 2>&1' 2>/dev/null; then
    ssh $SSH_OPTS "$SSH_USER@$ip" "sudo tailscale set --advertise-routes=$TS_ROUTES" >/dev/null 2>&1 \
      && ok "$name advertising $TS_ROUTES" || warn "$name: could not set tailscale route"
  fi
done

# 5) optional power-off
if [ "$POWEROFF" = "1" ]; then
  for entry in "${WORKERS[@]}" "${CONTROL[@]}"; do
    name="${entry%%=*}"; ip="${entry##*=}"
    log "powering off $name ($ip) ..."
    ssh $SSH_OPTS "$SSH_USER@$ip" 'sudo shutdown -h now' 2>/dev/null || true
  done
  ok "shutdown issued to all nodes"
  echo
  echo "Proxmox VMs (run on 192.168.30.204 if you also want those off):"
  echo "  qm shutdown 100   # caelx002"
  echo "  qm shutdown 101   # caelx003"
else
  echo
  log "k3s stopped, nodes left powered on. To also power them off:"
  log "  $0 --poweroff"
fi

echo
log "Recovery when you're ready:  ./scripts/cluster-recover.sh"
