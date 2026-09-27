#!/bin/bash
# k3s-self-heal.sh — auto-heal the NFS-mount wedge that takes kubelet down
# whenever the LAN router (UDM) drops. Detects hung kubelet NFS mounts,
# lazy-unmounts them, and restarts the local k3s service so the node rejoins
# the cluster when the network returns. Runs unattended from a systemd timer.
#
# Safety:
#   * Only acts when the k3s service is active (won't restart a deliberately
#     stopped cluster, e.g. after ./scripts/cluster-stop.sh).
#   * Throttled to one action per K3S_HEAL_THROTTLE_MIN (default 10 min) so
#     a flapping network can't cause a restart loop.
#   * If a regular `systemctl restart` doesn't clear the wedge, escalates to
#     `/usr/local/bin/k3s-killall.sh` (the heavy hammer shipped with k3s).
#   * Output goes to journald (`journalctl -u k3s-self-heal`).

set -uo pipefail

ENV_FILE="${ENV_FILE:-/etc/ce-ai-lab/k3s-self-heal.env}"
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

NFS_SERVER="${K3S_HEAL_NFS_SERVER:-192.168.30.121}"
NFS_PORT="${K3S_HEAL_NFS_PORT:-2049}"
NFS_WAIT="${K3S_HEAL_NFS_WAIT:-30}"
THROTTLE_FILE="${K3S_HEAL_THROTTLE_FILE:-/var/lib/kubelet/.last-self-heal}"
THROTTLE_MIN="${K3S_HEAL_THROTTLE_MIN:-10}"
MOUNT_TIMEOUT="${K3S_HEAL_MOUNT_TIMEOUT:-5}"

log()  { printf '[k3s-self-heal] %s\n' "$*"; }
warn() { printf '[k3s-self-heal] WARN: %s\n' "$*" >&2; }

# 1. which service runs on this node? control-plane has /etc/rancher/k3s/k3s.yaml
if [ -f /etc/rancher/k3s/k3s.yaml ]; then SVC="k3s"; else SVC="k3s-agent"; fi

# 2. if deliberately stopped, do nothing — the operator may have used
#    scripts/cluster-stop.sh before a network outage. Don't fight them.
if ! systemctl is-active --quiet "$SVC"; then
  log "$SVC not active — nothing to heal"
  exit 0
fi

# 3. wait briefly for NFS to answer. Self-heal is run every minute; we don't
#    want to flap the service while the network is still down.
deadline=$(( $(date +%s) + NFS_WAIT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if timeout 4 bash -c "cat < /dev/null > /dev/tcp/$NFS_SERVER/$NFS_PORT" 2>/dev/null; then
    break
  fi
  sleep 3
done
if ! timeout 4 bash -c "cat < /dev/null > /dev/tcp/$NFS_SERVER/$NFS_PORT" 2>/dev/null; then
  log "NFS $NFS_SERVER:$NFS_PORT still unreachable after ${NFS_WAIT}s — try again next tick"
  exit 0
fi

# 4. detect hung kubelet NFS mounts
hung=""
while read -r m; do
  [ -z "$m" ] && continue
  if ! timeout "$MOUNT_TIMEOUT" ls "$m" >/dev/null 2>&1; then
    hung="$hung$m
"
  fi
done < <(awk '$3=="nfs4" || $3=="nfs" {print $2}' /proc/mounts 2>/dev/null \
         | grep '^/var/lib/kubelet' | sort -u)

if [ -z "$hung" ]; then
  exit 0
fi
count=$(printf '%s\n' "$hung" | grep -c .)
warn "$count hung kubelet NFS mount(s) detected"
printf '%s\n' "$hung" | sed 's/^/    /'

# 5. throttle — don't restart the service more than once per THROTTLE_MIN
mkdir -p "$(dirname "$THROTTLE_FILE")" 2>/dev/null || true
if [ -f "$THROTTLE_FILE" ]; then
  last=$(cat "$THROTTLE_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  age_min=$(( (now - last) / 60 ))
  if [ "$age_min" -lt "$THROTTLE_MIN" ]; then
    log "throttled — last heal ${age_min}m ago (min ${THROTTLE_MIN}m). If the node is still NotReady, run scripts/cluster-recover.sh on the workstation."
    exit 0
  fi
fi

# 6. heal
warn "clearing hung mounts and restarting $SVC"
while read -r m; do
  [ -z "$m" ] && continue
  umount -l "$m" 2>/dev/null || umount -f "$m" 2>/dev/null || true
done <<< "$hung"

if systemctl restart "$SVC"; then
  date +%s > "$THROTTLE_FILE" 2>/dev/null || true
  log "$SVC restarted"

  # 7. if mounts are STILL hung 30s after the restart, escalate to killall
  sleep 30
  still=""
  while read -r m; do
    [ -z "$m" ] && continue
    if ! timeout "$MOUNT_TIMEOUT" ls "$m" >/dev/null 2>&1; then
      still="$still$m
"
    fi
  done < <(awk '$3=="nfs4" || $3=="nfs" {print $2}' /proc/mounts 2>/dev/null \
           | grep '^/var/lib/kubelet' | sort -u)
  if [ -n "$still" ]; then
    warn "restart didn't clear the wedge — escalating to k3s-killall.sh"
    if [ -x /usr/local/bin/k3s-killall.sh ]; then
      /usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || true
      systemctl restart "$SVC" || true
      date +%s > "$THROTTLE_FILE" 2>/dev/null || true
      log "k3s-killall executed; $SVC restarted"
    fi
  fi
fi
