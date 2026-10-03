#!/usr/bin/env bash
# install-remote.sh — run install.sh on a remote host with sudo password.
#
# Required env:
#   REMOTE_HOST       -- SSH host (default: 192.168.30.189 == caelx004.home).
#                        IP is the safer default during first boot before mDNS
#                        settles; caelx004.home works once the UDM's host
#                        records are in place (or once the host advertises
#                        itself via Tailscale / Avahi).
#   REMOTE_USER       -- SSH user (default: cengel)
#   REMOTE_KEY        -- SSH private key (default: ~/.ssh/homelab-agent-util-server,
#                        materialized from Infisical LINUX_PVT_KEY if missing)
#   LOKI_URL          -- Loki endpoint (e.g. http://192.168.30.217:3100)
#   SUDO_PASS         -- sudo password for REMOTE_USER (used via `sudo -S`)
#
# Optional env:
#   LISTEN_ADDR       default 0.0.0.0:1514
#   DATA_DIR          default /data/udm-pro  (lives inside DATA_MOUNT)
#   DATA_MOUNT        default /data           (must be a separate filesystem, see README)
#   RETENTION_DAYS    default 7
#   ENABLE_TS         default 0
#   TS_AUTHKEY        default ""
#
# If REMOTE_KEY doesn't exist locally, this script:
#   1. sources scripts/infisical-agent.sh
#   2. runs `infs ssh-key` to materialize the canonical homelab key from
#      LINUX_PVT_KEY in Infisical
#
# This script:
#   1. Validates env, materializes key if needed
#   2. SCPs infra/syslog-receiver/ to /tmp/syslog-receiver on the remote
#   3. Runs install.sh over SSH with SUDO_PASS in env
#   4. Prints final status

set -euo pipefail

REMOTE_HOST="${REMOTE_HOST:-192.168.30.189}"  # caelx004.home
REMOTE_USER="${REMOTE_USER:-cengel}"
REMOTE_KEY="${REMOTE_KEY:-$HOME/.ssh/homelab-agent-util-server}"

[ -n "${LOKI_URL:-}" ] || { echo "ERROR: LOKI_URL required" >&2; exit 1; }
[ -n "${SUDO_PASS:-}" ] || { echo "ERROR: SUDO_PASS required" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/infra/syslog-receiver"

# Materialize the canonical key from Infisical if it doesn't exist locally.
# `infs ssh-key` reads LINUX_PVT_KEY from Infisical, decodes it, and writes
# the private key to the path with mode 0600.
if [ ! -f "$REMOTE_KEY" ]; then
    echo "==> $REMOTE_KEY missing -- materializing from Infisical LINUX_PVT_KEY"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/infisical-agent.sh" >/dev/null 2>&1 || true
    infs ssh-key "$REMOTE_KEY" || {
        echo "ERROR: could not materialize key from Infisical. Run:" >&2
        echo "    . scripts/infisical-agent.sh && infs ssh-key" >&2
        exit 2
    }
fi

echo "==> $0"
echo "    REMOTE_HOST = $REMOTE_USER@$REMOTE_HOST"
echo "    REMOTE_KEY  = $REMOTE_KEY"
echo "    LOKI_URL    = $LOKI_URL"
echo "    SRC         = $SRC"
echo

SSH_BASE="-i $REMOTE_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8"

echo "==> verifying SSH connectivity"
ssh $SSH_BASE "$REMOTE_USER@$REMOTE_HOST" 'hostname; uname -a'

echo "==> copying $SRC to /tmp/syslog-receiver on $REMOTE_HOST"
ssh $SSH_BASE "$REMOTE_USER@$REMOTE_HOST" 'rm -rf /tmp/syslog-receiver && mkdir -p /tmp/syslog-receiver'
scp $SSH_BASE -r "$SRC/." "$REMOTE_USER@$REMOTE_HOST:/tmp/syslog-receiver/"

echo "==> running install.sh on $REMOTE_HOST"
# SUDO_PASS goes via heredoc interpolation -- visible only to bash on the
# receiving side. sshd env forwarding could expose it on the command line
# of intermediate processes on the remote, so we don't use SendEnv.
ssh $SSH_BASE "$REMOTE_USER@$REMOTE_HOST" bash <<REMOTE
export SUDO_PASS='$(printf '%s' "$SUDO_PASS")'
export LOKI_URL='$LOKI_URL'
export LISTEN_ADDR='${LISTEN_ADDR:-0.0.0.0:1514}'
export DATA_DIR='${DATA_DIR:-/data/udm-pro}'
export DATA_MOUNT='${DATA_MOUNT:-/data}'
export RETENTION_DAYS='${RETENTION_DAYS:-7}'
export ENABLE_TS='${ENABLE_TS:-0}'
export TS_AUTHKEY='${TS_AUTHKEY:-}'
cd /tmp/syslog-receiver
chmod +x install.sh
bash ./install.sh
REMOTE

_LISTEN_PORT="${LISTEN_ADDR:-0.0.0.0:1514}"
_LISTEN_PORT="${_LISTEN_PORT##*:}"   # strip "host:" prefix
echo
echo "==> verifying receiver listening on UDP ${LISTEN_ADDR:-0.0.0.0:1514}"
ssh $SSH_BASE "$REMOTE_USER@$REMOTE_HOST" "ss -uln | grep -E ':${_LISTEN_PORT}\b' || echo '(not bound yet)'"

echo
echo "==> done. To uninstall:"
echo "    ssh $REMOTE_USER@$REMOTE_HOST 'cd /tmp/syslog-receiver && sudo bash uninstall.sh'"
