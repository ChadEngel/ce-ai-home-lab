#!/usr/bin/env bash
# uninstall.sh — reverse install.sh. Stops rsyslog, removes configs, keeps spool dir.

set -euo pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
SPOOL_DIR="${SPOOL_DIR:-/var/log/udm-pro}"

echo "==> syslog receiver uninstall"
echo "    SPOOL_DIR = $SPOOL_DIR (kept -- delete manually if desired)"
echo

sudo systemctl stop rsyslog 2>/dev/null || sudo systemctl stop syslog 2>/dev/null || true
sudo rm -f /etc/rsyslog.d/10-udm-loki.conf /etc/rsyslog.d/templates.conf
sudo rm -f /etc/logrotate.d/udm-pro
sudo systemctl start rsyslog 2>/dev/null || sudo systemctl start syslog 2>/dev/null || true

echo "==> removed:"
echo "    /etc/rsyslog.d/10-udm-loki.conf"
echo "    /etc/rsyslog.d/templates.conf"
echo "    /etc/logrotate.d/udm-pro"
echo "    rsyslog service restarted"
echo
echo "Spool dir still at $SPOOL_DIR -- remove manually with: sudo rm -rf $SPOOL_DIR"
