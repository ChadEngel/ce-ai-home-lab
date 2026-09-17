#!/bin/bash
# install-e1000e-workaround.sh — mitigate the Intel e1000e "Detected Hardware
# Unit Hang" bug that wedges a NIC and severs all bridge/VM networking.
#
# Background: on 2026-09-17 the Proxmox host caevmhost01's onboard e1000e NIC
# (`nic0`, the *sole* uplink of `vmbr0`) hardware-hung. The host stayed up but
# every VM on the bridge — including the k3s node caelx002 — lost all network
# for ~14 hours and could not rejoin the cluster until the host was rebooted.
# See docs/how-to-monitor-hosts.md ("Proxmox e1000e hardware unit hang").
#
# This installs (idempotently):
#   /usr/local/sbin/e1000e-tune.sh       disable TSO/GSO/GRO + EEE on the NIC
#   /usr/local/sbin/e1000e-watchdog.sh   detect a hang and reset the NIC
#   e1000e-tune.service                  re-apply the tuning at every boot
#   e1000e-watchdog.timer                run the watchdog every 30s
#   /etc/default/e1000e-{tune,watchdog}  NIC + gateway discovered per host
#
# The watchdog only resets when a *new* hang is logged AND the default gateway
# is unreachable, so it will not disrupt a healthy NIC — it recovers a wedged
# one without a host reboot.
#
# Secrets/keys come from Infisical (secret-management/prod// via the
# `homelab-agent` Machine Identity, loaded by scripts/infisical-agent.sh):
#   UTIL_SERVER_SSH_PRIVATE_KEY  canonical homelab-agent ed25519 key (base64 PEM)
#   LINUX_PVT_KEY                fallback agent key (raw or base64 PEM)
#
# Proxmox is managed as root and has no standard LINUX_USER account, so
# SSH_USER defaults to root for this script.
#
# Usage:
#   ./scripts/install-e1000e-workaround.sh <host> [nic]
#   ./scripts/install-e1000e-workaround.sh 192.168.30.204
#   ./scripts/install-e1000e-workaround.sh 192.168.30.204 enp1s0
#
# Prereqs on the target: ethtool, ip, systemd, and root (or passwordless sudo).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=scripts/infisical-agent.sh
. "$SCRIPT_DIR/infisical-agent.sh"

log()  { printf '\033[1;34m[e1000e]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[✅]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[✖]\033[0m %s\n' "$*" >&2; exit 1; }

NODE_HOST="${1:-}"
NIC="${2:-nic0}"
[ -n "$NODE_HOST" ] || die "usage: $0 <host> [nic]"

log "installing e1000e workaround on '$NODE_HOST' (NIC=$NIC)"

# --- SSH key from Infisical -------------------------------------------------
infisical_agent_token >/dev/null || die "Infisical agent not ready (run scripts/infisical-agent-setup.sh)"
SSH_USER="${SSH_USER:-root}"
LPK="$(infs get UTIL_SERVER_SSH_PRIVATE_KEY 2>/dev/null || true)"
KEY_SOURCE="UTIL_SERVER_SSH_PRIVATE_KEY"
if [ -z "$LPK" ]; then
  LPK="$(infs get LINUX_PVT_KEY 2>/dev/null || true)"
  KEY_SOURCE="LINUX_PVT_KEY"
fi
[ -n "$LPK" ] || die "neither UTIL_SERVER_SSH_PRIVATE_KEY nor LINUX_PVT_KEY found in Infisical"
log "  using agent key from $KEY_SOURCE, SSH_USER=$SSH_USER"

KEYFILE="$(mktemp)"; chmod 600 "$KEYFILE"
cleanup() { rm -f "$KEYFILE"; }
trap cleanup EXIT
case "$LPK" in
  -----BEGIN*) printf '%s\n' "$LPK" > "$KEYFILE" ;;
  *)
    dec="$(printf '%s' "$LPK" | base64 -d 2>/dev/null || true)"
    case "$dec" in
      -----BEGIN*) printf '%s\n' "$dec" > "$KEYFILE" ;;
      *) die "$KEY_SOURCE is neither raw PEM nor base64 PEM (first chars: $(printf '%s' "$LPK" | cut -c1-12)…)" ;;
    esac ;;
esac
ssh-keygen -l -f "$KEYFILE" >/dev/null 2>&1 || die "materialized key is not a valid SSH private key"

SSH=(ssh -i "$KEYFILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
     -o ConnectTimeout=10 "$SSH_USER@$NODE_HOST")

# --- remote install (quoted heredoc; NIC passed in the environment) ---------
log "installing units + watchdog on $NODE_HOST ..."
REMOTE_SCRIPT="$(cat <<'REMOTE'
set -euo pipefail
IF="${NIC:-nic0}"
GW="$(ip route show default | awk '{print $3; exit}')"
[ -n "$GW" ] || { echo "no default gateway found on $IF" >&2; exit 1; }
echo "nic=$IF gateway=$GW"

# NIC + gateway for this host (sourced by the units below).
cat > /etc/default/e1000e-tune <<ENV
E1000E_IF=$IF
ENV
cat > /etc/default/e1000e-watchdog <<ENV
E1000E_IF=$IF
E1000E_GW=$GW
ENV

# 1. Tuning helper: disable the offloads/EEE that trigger the e1000e hang.
cat > /usr/local/sbin/e1000e-tune.sh <<'TUNE'
#!/bin/sh
# Prevent Intel e1000e "Detected Hardware Unit Hang" by disabling segmentation
# offloads and EEE. Safe to re-run; invoked at boot and after a watchdog reset.
IF="${E1000E_IF:-nic0}"
ethtool -K "$IF" tso off gso off gro off 2>/dev/null || true
ethtool --set-eee "$IF" eee off 2>/dev/null || true
TUNE
chmod 0755 /usr/local/sbin/e1000e-tune.sh

# 2. Watchdog: reset a wedged NIC instead of needing a full host reboot.
cat > /usr/local/sbin/e1000e-watchdog.sh <<'WATCHDOG'
#!/bin/sh
# Detect Intel e1000e "Hardware Unit Hang" and recover by resetting the link.
# Resets only when a hang is newly logged AND the gateway is unreachable
# (i.e. the NIC is actually wedged) so a healthy link is never disrupted.
IF="${E1000E_IF:-nic0}"
GW="${E1000E_GW:-}"
LOG=/var/log/e1000e-watchdog.log
STATE=/run/e1000e-watchdog.count

[ -n "$GW" ] || exit 0

count=$(dmesg 2>/dev/null | grep -c "Hardware Unit Hang")
last=0
[ -f "$STATE" ] && last=$(cat "$STATE" 2>/dev/null || echo 0)
echo "$count" > "$STATE"

# No new hang since last check (also covers dmesg ring-buffer wrap).
[ "$count" -le "$last" ] && exit 0

if ping -c1 -W3 "$GW" >/dev/null 2>&1; then
  echo "$(date -Is) e1000e hang logged (${last}->${count}) but ${GW} reachable; deferring reset" >>"$LOG"
  exit 0
fi

echo "$(date -Is) e1000e hang + ${GW} unreachable (${last}->${count}); resetting ${IF}" >>"$LOG"
ip link set "$IF" down
sleep 2
ip link set "$IF" up
/usr/local/sbin/e1000e-tune.sh
sleep 3
if ping -c1 -W3 "$GW" >/dev/null 2>&1; then
  echo "$(date -Is) ${IF} reset OK; ${GW} reachable" >>"$LOG"
else
  echo "$(date -Is) ${IF} reset done but ${GW} still unreachable" >>"$LOG"
fi
WATCHDOG
chmod 0755 /usr/local/sbin/e1000e-watchdog.sh

# 3. Units.
cat > /etc/systemd/system/e1000e-tune.service <<'UNIT'
[Unit]
Description=Tune Intel e1000e NIC (disable TSO/GSO/GRO/EEE) to prevent hardware unit hang
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/e1000e-tune
ExecStart=/usr/local/sbin/e1000e-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/e1000e-watchdog.service <<'UNIT'
[Unit]
Description=Intel e1000e NIC hang watchdog (auto-reset)

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/e1000e-watchdog
ExecStart=/usr/local/sbin/e1000e-watchdog.sh
UNIT

cat > /etc/systemd/system/e1000e-watchdog.timer <<'UNIT'
[Unit]
Description=Run Intel e1000e NIC hang watchdog every 30s

[Timer]
OnBootSec=2min
OnUnitActiveSec=30s
AccuracySec=5s
Unit=e1000e-watchdog.service

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now e1000e-tune.service
systemctl enable --now e1000e-watchdog.timer

echo "tune=$(systemctl is-enabled e1000e-tune.service)/$(systemctl is-active e1000e-tune.service)"
echo "watchdog=$(systemctl is-enabled e1000e-watchdog.timer)/$(systemctl is-active e1000e-watchdog.timer)"
echo "tso=$(ethtool -k "$IF" | awk -F: '/^tcp-segmentation-offload/{print $2}' | tr -d ' ')"
echo "eee=$(ethtool --show-eee "$IF" 2>/dev/null | awk -F: '/EEE status/{print $2}' | tr -d ' ')"
REMOTE
)"

OUT="$("${SSH[@]}" "NIC=$NIC bash -s" <<<"$REMOTE_SCRIPT")"
printf '%s\n' "$OUT"
ok "e1000e workaround installed on $NODE_HOST"
echo
echo "Watchdog log (entries appear only when a hang is recovered):"
echo "  ssh $SSH_USER@$NODE_HOST 'cat /var/log/e1000e-watchdog.log'"
