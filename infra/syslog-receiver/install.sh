#!/usr/bin/env bash
# install.sh — turn a fresh Ubuntu 22.04+ box into the UDM Pro syslog receiver.
#
# Idempotent. Safe to re-run. Tests config before starting rsyslog.
#
# What it does:
#   1. apt update + install rsyslog, rsyslog-omhttp, logrotate, jq, curl
#   2. Drop rsyslog config (imudp + omhttp -> Loki)
#   3. Drop local spool config + logrotate
#   4. Validate config with rsyslogd -N1 (no-op test load)
#   5. Enable + restart rsyslog
#   6. (Optional) install + start Tailscale, advertise as subnet router if asked
#   7. Print sanity checks
#
# Required env / args:
#   LOKI_URL  -- e.g. http://loki.ai.svc.cluster.local:3100
#   SUDO_PASS -- password for the running user (used via `sudo -S -p ''`)
#
# Optional env:
#   LISTEN_ADDR          default 0.0.0.0:1514
#   SPOOL_DIR            default /var/log/udm-pro
#   RETENTION_DAYS       default 7
#   ENABLE_TS            default 0  (set to 1 to also install Tailscale)
#   TS_AUTHKEY           default ""  (required if ENABLE_TS=1, else interactive)

set -euo pipefail

LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0:1514}"
SPOOL_DIR="${SPOOL_DIR:-/var/log/udm-pro}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
ENABLE_TS="${ENABLE_TS:-0}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -n "${LOKI_URL:-}" ] || { echo "ERROR: LOKI_URL env var is required (e.g. http://loki.ai.svc.cluster.local:3100)" >&2; exit 1; }
[ -n "${SUDO_PASS:-}" ] || { echo "ERROR: SUDO_PASS env var is required (sudo password for current user)" >&2; exit 1; }

# sudo wrapper -- reads password from stdin, never prints it.
sudo_as() { sudo -S -p '' -H bash -c "$*" <<<"$SUDO_PASS" 2>/dev/null; }

echo "==> syslog receiver install (Ubuntu)"
echo "    LISTEN_ADDR    = $LISTEN_ADDR"
echo "    SPOOL_DIR      = $SPOOL_DIR"
echo "    RETENTION_DAYS = $RETENTION_DAYS"
echo "    LOKI_URL       = $LOKI_URL"
echo "    ENABLE_TS      = $ENABLE_TS"
echo "    user           = $(whoami)"
echo

# 1. apt packages
echo "==> installing packages"
export DEBIAN_FRONTEND=noninteractive
sudo_as "apt-get update -y"
# rsyslog-omhttp is in main on Ubuntu 22.04+ (rsyslog 8.21+)
sudo_as "apt-get install -y --no-install-recommends rsyslog rsyslog-omhttp logrotate jq curl ca-certificates"

# 2. rsyslog config
echo "==> writing rsyslog config"
sudo_as "install -d -m 0755 /etc/rsyslog.d"
sudo_as "install -m 0644 $THIS_DIR/rsyslog/10-udm-loki.conf /etc/rsyslog.d/10-udm-loki.conf"
sudo_as "install -m 0644 $THIS_DIR/rsyslog/templates.conf /etc/rsyslog.d/templates.conf"
# Substitute LOKI_URL into the deployed config
sudo_as "sed -i 's|@@LOKI_URL@@|$LOKI_URL|g' /etc/rsyslog.d/10-udm-loki.conf"

# 3. spool dir + logrotate
echo "==> creating spool dir + logrotate"
sudo_as "install -d -m 0755 $SPOOL_DIR"
sudo_as "install -m 0644 $THIS_DIR/rsyslog/logrotate-udm-pro /etc/logrotate.d/udm-pro"
sudo_as "sed -i 's|@@SPOOL_DIR@@|$SPOOL_DIR|g; s|@@RETENTION_DAYS@@|$RETENTION_DAYS|g' /etc/logrotate.d/udm-pro"

# 4. validate rsyslog config BEFORE starting
echo "==> validating rsyslog config (rsyslogd -N1)"
if ! sudo_as "rsyslogd -N1"; then
    echo "ERROR: rsyslogd -N1 failed -- fix config before starting" >&2
    exit 2
fi

# 5. enable + restart rsyslog (works whether service was already running or not)
echo "==> enabling + restarting rsyslog"
sudo_as "systemctl enable rsyslog 2>/dev/null || systemctl enable syslog 2>/dev/null || true"
sudo_as "systemctl restart rsyslog || systemctl restart syslog"

# 6. optional Tailscale
if [ "$ENABLE_TS" = "1" ]; then
    if ! command -v tailscale >/dev/null; then
        echo "==> installing Tailscale"
        sudo_as "curl -fsSL https://tailscale.com/install.sh | sh"
    fi
    echo "==> bringing Tailscale up"
    if [ -n "$TS_AUTHKEY" ]; then
        sudo_as "tailscale up --authkey=$TS_AUTHKEY"
    else
        echo "    (ENABLE_TS=1 but no TS_AUTHKEY -- you must run 'sudo tailscale up' manually later)"
    fi
    sudo_as "tailscale status" || true
fi

# 7. sanity
echo
echo "==> sanity checks"
echo "-- rsyslog status:"
sudo_as "systemctl is-active rsyslog || systemctl is-active syslog"
echo "-- listen on $LISTEN_ADDR:"
ss -uln | grep -E "$(echo "$LISTEN_ADDR" | sed 's/.*://')" || echo "  (port not bound yet -- rsyslog may need a moment)"
echo "-- spool dir:"
sudo_as "ls -la $SPOOL_DIR || true"

echo
echo "==> done."
echo "    Test: echo '<13>Sep 27 10:00:00 testhost testapp - - [TEST_EVENT] hello world' | nc -u -w1 127.0.0.1 $(echo "$LISTEN_ADDR" | sed 's/.*://')"
