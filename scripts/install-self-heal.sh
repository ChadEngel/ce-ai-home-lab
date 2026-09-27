#!/bin/bash
# install-self-heal.sh — install the k3s-self-heal systemd timer on every
# cluster node. Idempotent. Re-running is safe.
#
# What it does per node:
#   * installs /usr/local/bin/k3s-self-heal.sh        (mode 0755)
#   * installs /etc/systemd/system/k3s-self-heal.service
#   * installs /etc/systemd/system/k3s-self-heal.timer
#   * installs /etc/ce-ai-lab/k3s-self-heal.env      (mode 0644)
#   * systemctl daemon-reload && enable --now k3s-self-heal.timer
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)/systemd"
REMOTE_SCRIPT="/usr/local/bin/k3s-self-heal.sh"
SYSTEMD_DIR="/etc/systemd/system"
ENV_DIR="/etc/ce-ai-lab"

SSH_USER="${SSH_USER:-cengel}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/homelab-agent-util-server}"
SSH_OPTS_SSH="-i $SSH_KEY -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8"
NODES=("util-server=192.168.30.217" "caelx002=192.168.30.60" "caelx003=192.168.30.251")

log() { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[✅]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[✖]\033[0m %s\n' "$*" >&2; exit 1; }

for f in k3s-self-heal.sh k3s-self-heal.service k3s-self-heal.timer k3s-self-heal.env; do
  [ -f "$HERE/$f" ] || die "missing $HERE/$f"
done

for entry in "${NODES[@]}"; do
  name="${entry%%=*}"; ip="${entry##*=}"
  log "installing on $name ($ip) ..."
  ssh $SSH_OPTS_SSH "$SSH_USER@$ip" "sudo mkdir -p $ENV_DIR" >/dev/null 2>&1 || die "mkdir failed on $name"

  scp $SSH_OPTS_SSH "$HERE/k3s-self-heal.sh"      "$SSH_USER@$ip:/tmp/k3s-self-heal.sh"      >/dev/null 2>&1 || die "scp script failed on $name"
  scp $SSH_OPTS_SSH "$HERE/k3s-self-heal.service" "$SSH_USER@$ip:/tmp/k3s-self-heal.service" >/dev/null 2>&1 || die "scp service failed on $name"
  scp $SSH_OPTS_SSH "$HERE/k3s-self-heal.timer"   "$SSH_USER@$ip:/tmp/k3s-self-heal.timer"   >/dev/null 2>&1 || die "scp timer failed on $name"
  scp $SSH_OPTS_SSH "$HERE/k3s-self-heal.env"     "$SSH_USER@$ip:/tmp/k3s-self-heal.env"     >/dev/null 2>&1 || die "scp env failed on $name"

  ssh $SSH_OPTS_SSH "$SSH_USER@$ip" "set -e; \
      sudo install -m 0755 /tmp/k3s-self-heal.sh $REMOTE_SCRIPT; \
      sudo install -m 0644 /tmp/k3s-self-heal.service $SYSTEMD_DIR/k3s-self-heal.service; \
      sudo install -m 0644 /tmp/k3s-self-heal.timer   $SYSTEMD_DIR/k3s-self-heal.timer; \
      sudo install -m 0644 /tmp/k3s-self-heal.env     $ENV_DIR/k3s-self-heal.env; \
      rm -f /tmp/k3s-self-heal.sh /tmp/k3s-self-heal.service /tmp/k3s-self-heal.timer /tmp/k3s-self-heal.env; \
      sudo systemctl daemon-reload; \
      sudo systemctl enable --now k3s-self-heal.timer" \
    >/dev/null 2>&1 || die "$name install failed"

  ok "$name installed and timer enabled"
  log "  next 2 timer triggers:"
  ssh $SSH_OPTS_SSH "$SSH_USER@$ip" "systemctl list-timers k3s-self-heal.timer --no-pager 2>/dev/null | sed -n '1,3p'" 2>&1 | sed 's/^/    /'
done

ok "all nodes installed"
echo
log "verify with:   journalctl -u k3s-self-heal -f"
log "tune:           /etc/ce-ai-lab/k3s-self-heal.env on each node"
