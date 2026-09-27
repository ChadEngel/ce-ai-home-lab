#!/usr/bin/env bash
# uninstall.sh — reverse install.sh. Stops syslog-ng, removes configs,
# keeps the data dir so you can inspect it.

set -euo pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${DATA_DIR:-/data/udm-pro}"

echo "==> syslog receiver uninstall"
echo "    DATA_DIR = $DATA_DIR (kept -- delete manually if desired)"
echo

sudo systemctl stop syslog-ng 2>/dev/null || true
sudo systemctl disable syslog-ng 2>/dev/null || true
sudo rm -f /etc/syslog-ng/conf.d/udm-loki.conf
sudo rm -f /etc/logrotate.d/udm-pro
# Don't restart syslog-ng automatically -- it stays stopped so the next
# operator sees the daemon is down. Re-enable with: systemctl start syslog-ng

echo "==> removed:"
echo "    /etc/syslog-ng/conf.d/udm-loki.conf"
echo "    /etc/logrotate.d/udm-pro"
echo "    syslog-ng.service disabled"
echo
echo "Data dir still at $DATA_DIR -- remove manually with: sudo rm -rf $DATA_DIR"
echo "syslog-ng is STOPPED. Start it again with: sudo systemctl start syslog-ng"