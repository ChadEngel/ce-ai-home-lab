#!/usr/bin/env bash
# install.sh — turn a fresh Ubuntu 24.04+ box into the UDM Pro syslog receiver.
#
# Idempotent. Safe to re-run. Tests config before (re)starting syslog-ng.
#
# What it does:
#   1. apt update + install syslog-ng, syslog-ng-mod-http, logrotate, jq, curl
#   2. Drop syslog-ng config into /etc/syslog-ng/conf.d/udm-loki.conf
#   3. Substitute @@LOKI_URL@@ and @@DATA_DIR@@
#   4. Validate config with syslog-ng --syntax-only
#   5. Enable + restart syslog-ng
#   6. (Optional) install + start Tailscale, advertise as subnet router if asked
#   7. Print sanity checks
#
# Required env / args:
#   LOKI_URL  -- e.g. http://192.168.30.217:3100
#   SUDO_PASS -- password for the running user (used via `sudo -S -p ''`)
#
# Optional env:
#   LISTEN_ADDR          default 0.0.0.0:1514
#   DATA_DIR             default /data/udm-pro  (lives inside DATA_MOUNT)
#   DATA_MOUNT           default /data         (MUST be a separate filesystem;
#                        this is what install.sh guards on. Holds the live
#                        spool + 7 days of rotated logs + syslog-ng's
#                        disk-buffer for Loki outages. Min 2 GiB, recommend
#                        8 GiB+.)
#   RETENTION_DAYS       default 7
#   ENABLE_TS            default 0  (set to 1 to also install Tailscale)
#   TS_AUTHKEY           default ""  (required if ENABLE_TS=1, else interactive)

set -euo pipefail

LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0:1514}"
LISTEN_PORT="${LISTEN_ADDR##*:}"           # 1514
DATA_DIR="${DATA_DIR:-/data/udm-pro}"      # everything syslog-ng writes lives here
# The mount root that must be a separate filesystem. DATA_DIR lives inside it.
# Guarding on the mount root (not DATA_DIR) is what stops a Loki outage from
# filling the OS volume -- DATA_DIR itself is just a subdirectory of the mount.
DATA_MOUNT="${DATA_MOUNT:-/data}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
ENABLE_TS="${ENABLE_TS:-0}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -n "${LOKI_URL:-}" ] || { echo "ERROR: LOKI_URL env var is required (e.g. http://192.168.30.217:3100)" >&2; exit 1; }
[ -n "${SUDO_PASS:-}" ] || { echo "ERROR: SUDO_PASS env var is required (sudo password for current user)" >&2; exit 1; }

# Reject the old default that would put the spool on the OS volume
if [ "$DATA_MOUNT" = "/var/log" ] || [ "$DATA_MOUNT" = "/" ]; then
    echo "ERROR: DATA_MOUNT=$DATA_MOUNT is the OS volume. Mount a separate volume at /data first (see README §provisioning)" >&2
    exit 1
fi

# sudo wrapper -- reads password from stdin, never prints it.
sudo_as() { sudo -S -p '' -H bash -c "$*" <<<"$SUDO_PASS" 2>/dev/null; }

echo "==> syslog-ng receiver install (Ubuntu)"
echo "    LISTEN_ADDR    = $LISTEN_ADDR"
echo "    DATA_DIR       = $DATA_DIR"
echo "    DATA_MOUNT     = $DATA_MOUNT  (must be a separate filesystem)"
echo "    RETENTION_DAYS = $RETENTION_DAYS"
echo "    LOKI_URL       = $LOKI_URL"
echo "    ENABLE_TS      = $ENABLE_TS"
echo "    user           = $(whoami)"
echo

# 1. apt packages
echo "==> installing packages"
export DEBIAN_FRONTEND=noninteractive
sudo_as "apt-get update -y"
# syslog-ng-core + syslog-ng-mod-http + logrotate + jq + curl + ca-certs
sudo_as "apt-get install -y --no-install-recommends syslog-ng-core syslog-ng-mod-http logrotate jq curl ca-certificates"

# 2. syslog-ng config
echo "==> writing syslog-ng config"
sudo_as "install -d -m 0755 /etc/syslog-ng/conf.d"
sudo_as "install -m 0644 $THIS_DIR/syslog-ng/udm-loki.conf /etc/syslog-ng/conf.d/udm-loki.conf"
# Substitute LOKI_URL into the deployed config
sudo_as "sed -i 's|@@LOKI_URL@@|$LOKI_URL|g; s|@@DATA_DIR@@|$DATA_DIR|g' /etc/syslog-ng/conf.d/udm-loki.conf"

# 3. verify the mount root is a separate filesystem BEFORE writing anything to it
echo "==> verifying $DATA_MOUNT is a separate mount (not on the OS volume)"
if ! sudo_as "mountpoint -q $DATA_MOUNT"; then
    echo "ERROR: $DATA_MOUNT is not a mountpoint. Mount a separate volume there first (see README §provisioning)" >&2
    echo "       Suggested: 8 GiB minimum. The spool grows during Loki outages (disk-buffer) and holds 7 days of rotated logs." >&2
    exit 1
fi
# DATA_DIR must be on the same filesystem as DATA_MOUNT (i.e. not a stray dir
# on the OS volume that happens to sit at the same path).
DATA_FS="$(sudo_as "stat -c %d $DATA_MOUNT")"
if [ -d "$DATA_DIR" ]; then
    DIR_FS="$(sudo_as "stat -c %d $DATA_DIR")"
    if [ "$DATA_FS" != "$DIR_FS" ]; then
        echo "ERROR: $DATA_DIR is on a DIFFERENT filesystem than $DATA_MOUNT -- refusing to write" >&2
        exit 1
    fi
fi
DATA_FREE_KB="$(sudo_as "df -Pk $DATA_MOUNT | awk 'NR==2{print \$4}'")"
if [ "${DATA_FREE_KB:-0}" -lt 2097152 ]; then  # 2 GiB
    echo "WARNING: $DATA_MOUNT has only ${DATA_FREE_KB} KiB free. Recommend >= 2 GiB (8 GiB+ to absorb Loki outages)." >&2
fi
echo "    ok ($(( DATA_FREE_KB / 1024 / 1024 )) GiB free on $DATA_MOUNT)"

# 4. spool dir + logrotate
echo "==> creating spool dir + logrotate"
sudo_as "install -d -m 0755 $DATA_DIR $DATA_DIR/disk-buffer"
sudo_as "install -m 0644 $THIS_DIR/logrotate-udm-pro /etc/logrotate.d/udm-pro"
sudo_as "sed -i 's|@@DATA_DIR@@|$DATA_DIR|g; s|@@RETENTION_DAYS@@|$RETENTION_DAYS|g' /etc/logrotate.d/udm-pro"

# 5. validate syslog-ng config BEFORE starting
echo "==> validating syslog-ng config (syslog-ng --syntax-only)"
if ! sudo_as "syslog-ng --syntax-only -f /etc/syslog-ng/syslog-ng.conf"; then
    echo "ERROR: syslog-ng --syntax-only failed -- fix config before starting" >&2
    exit 2
fi

# 6. enable + restart syslog-ng (works whether service was already running or not)
echo "==> enabling + restarting syslog-ng"
sudo_as "systemctl enable syslog-ng"
sudo_as "systemctl restart syslog-ng"

# 7. optional Tailscale
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

# 8. sanity
echo
echo "==> sanity checks"
echo "-- syslog-ng status:"
sudo_as "systemctl is-active syslog-ng"
echo "-- listen on UDP $LISTEN_PORT:"
ss -uln | grep -E ":${LISTEN_PORT}\b" || echo "  (port not bound yet -- syslog-ng may need a moment)"
echo "-- data dir:"
sudo_as "ls -la $DATA_DIR"
echo "-- free space on data dir:"
sudo_as "df -h $DATA_DIR"

echo
echo "==> done."
echo "    Test: echo '<13>Sep 27 10:00:00 testhost testapp - - [TEST_EVENT] hello world' | nc -u -w1 127.0.0.1 $LISTEN_PORT"