#!/bin/bash
# install-telegraf.sh — install/configure Telegraf on a homelab Linux box to
# push host-level metrics into InfluxDB v2 (bucket `host_metrics`).
#
# Idempotent: safe to run on a box that already has Telegraf (it rewrites the
# config + token env file + systemd drop-in and restarts the service). Used to
# both (a) FIX util-server's existing telegraf (hardcoded plaintext token ->
# Infisical-sourced env var, bucket mac_metrics -> host_metrics) and (b) freshly
# install on caelx002.
#
# All secrets come from Infisical (secret-management/prod// via the
# `homelab-agent` Machine Identity, loaded by scripts/infisical-agent.sh):
#
#   LINUX_USER              SSH username (e.g. cengel)
#   LINUX_PVT_KEY           SSH private key (raw PEM, or base64-encoded PEM)
#   INFLUXDB_TOKEN          all-bucket WRITE token (telegraf writes host_metrics)
#   INFLUXDB_READ_TOKEN     all-bucket READ token (used ONLY here to verify data
#                           landed; NOT written to disk on the node — the write
#                           token is write-only and can't read back its own data)
#
# The InfluxDB WRITE token is NEVER written into /etc/telegraf/telegraf.conf
# (0644). It is delivered to /etc/telegraf/telegraf.env (0600, root) over SSH
# stdin (not as an SSH argument, so it never appears in the remote process list)
# and loaded at runtime via a systemd drop-in (scripts/systemd/telegraf-env.conf).
#
# Usage:
#   ./scripts/install-telegraf.sh <node-host>
#   ./scripts/install-telegraf.sh util-server
#   ./scripts/install-telegraf.sh caelx002
#
# Prereqs on the target node: apt-based distro, passwordless sudo for LINUX_USER,
# and reachability to http://aiserver.home:8086 (InfluxDB). The `host_metrics`
# bucket must already exist in InfluxDB (create it in the UI first).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=scripts/infisical-agent.sh
. "$SCRIPT_DIR/infisical-agent.sh"

log()  { printf '\033[1;34m[telegraf]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[✅]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[⚠️]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[✖]\033[0m %s\n' "$*" >&2; exit 1; }

NODE_HOST="${1:-}"
[ -n "$NODE_HOST" ] || die "usage: $0 <node-host>"

log "installing telegraf on '$NODE_HOST' (-> InfluxDB host_metrics)"

# --- pull secrets from Infisical -------------------------------------------
infisical_agent_token >/dev/null || die "Infisical agent not ready (run scripts/infisical-agent-setup.sh)"

LINUX_USER="$(infs get LINUX_USER 2>/dev/null || true)"
[ -n "$LINUX_USER" ] || die "LINUX_USER not found in Infisical"
LPK="$(infs get LINUX_PVT_KEY 2>/dev/null || true)"
[ -n "$LPK" ] || die "LINUX_PVT_KEY not found in Infisical"
INFLUX_TOKEN="$(infs get INFLUXDB_TOKEN 2>/dev/null || true)"
[ -n "$INFLUX_TOKEN" ] || die "INFLUXDB_TOKEN (write) not found in Infisical"
INFLUX_READ_TOKEN="$(infs get INFLUXDB_READ_TOKEN 2>/dev/null || true)"
[ -n "$INFLUX_READ_TOKEN" ] || die "INFLUXDB_READ_TOKEN not found in Infisical (needed to verify metrics landed — Grafana's read token)"

# --- materialize the SSH key to a 0600 temp file (handle raw or base64 PEM) --
KEYFILE="$(mktemp)"; chmod 600 "$KEYFILE"
cleanup() { rm -f "$KEYFILE"; }
trap cleanup EXIT
case "$LPK" in
  -----BEGIN*) printf '%s\n' "$LPK" > "$KEYFILE" ;;                 # raw PEM
  *)
    dec="$(printf '%s' "$LPK" | base64 -d 2>/dev/null || true)"
    case "$dec" in
      -----BEGIN*) printf '%s\n' "$dec" > "$KEYFILE" ;;             # base64 PEM
      *) die "LINUX_PVT_KEY is neither raw PEM nor base64 PEM (first chars: $(printf '%s' "$LPK" | cut -c1-12)…)" ;;
    esac ;;
esac
ssh-keygen -l -f "$KEYFILE" >/dev/null 2>&1 || die "materialized key is not a valid SSH private key"

SSH=(ssh -i "$KEYFILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
     -o ConnectTimeout=10 "$LINUX_USER@$NODE_HOST")

# --- pre-flight (heredoc-built remote script: clean nested quoting) ---------
log "pre-flight on $NODE_HOST ..."
PF_SCRIPT="$(cat <<'EOF'
echo "hostname=$(hostname)"
echo "os=$(. /etc/os-release; echo $PRETTY_NAME)"
echo "arch=$(uname -m)"
if sudo -n true 2>/dev/null; then echo "sudo=OK"; else echo "sudo=NO"; fi
echo "apt=$(command -v apt-get || echo MISSING)"
echo "influx=$(curl -s -o /dev/null -w %{http_code} -m 6 http://aiserver.home:8086/health 2>/dev/null || echo unreachable)"
EOF
)"
PF_OUT="$("${SSH[@]}" 'bash -s' <<<"$PF_SCRIPT")"
pf() { printf '%s\n' "$PF_OUT" | sed -n "s/^$1=//p"; }
NODE_NAME="$(pf hostname)"; os="$(pf os)"; arch="$(pf arch)"
sudo_v="$(pf sudo)"; apt_v="$(pf apt)"; influx_v="$(pf influx)"

log "  node:   $NODE_NAME ($os, $arch)"
[ "$sudo_v" = "OK" ]      || die "passwordless sudo is required for $LINUX_USER on $NODE_HOST"
[ "$apt_v" != "MISSING" ] || die "$NODE_HOST is not apt-based (this script targets Debian/Ubuntu)"
case "$influx_v" in
  200) ok "  $NODE_HOST can reach InfluxDB (aiserver.home:8086, HTTP 200)" ;;
  *)   die "$NODE_HOST cannot reach aiserver.home:8086 (got: $influx_v) — InfluxDB must be reachable for telegraf to write" ;;
esac

# --- install telegraf (idempotent) ------------------------------------------
# InfluxData apt repo (telegraf is NOT in Ubuntu's default repos; util-server
# had it pre-configured, fresh boxes like caelx002 do not). Idempotent: only
# set up the repo + install if telegraf isn't already present.
INSTALL_SCRIPT="$(cat <<'EOF'
set -e
if ! command -v telegraf >/dev/null 2>&1; then
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://repos.influxdata.com/influxdata-archive.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/influxdata-archive.gpg
  echo "deb [signed-by=/etc/apt/keyrings/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main" | sudo tee /etc/apt/sources.list.d/influxdata.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq telegraf
fi
echo "  telegraf: $(command -v telegraf || echo MISSING)"
EOF
)"
log "installing telegraf package on $NODE_NAME ..."
"${SSH[@]}" 'bash -s' <<<"$INSTALL_SCRIPT"

# --- render the config from the template (substitute {{HOSTNAME}} only; ------
# leave ${INFLUXDB_TOKEN} literal for telegraf's runtime env interpolation) ---
TEMPLATE="$REPO_ROOT/config/telegraf/telegraf.conf.template"
[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"
RENDERED="$(sed "s/{{HOSTNAME}}/${NODE_NAME}/g" "$TEMPLATE")"

log "writing /etc/telegraf/telegraf.conf (0644, no secret) on $NODE_NAME ..."
printf '%s\n' "$RENDERED" | "${SSH[@]}" 'sudo tee /etc/telegraf/telegraf.conf >/dev/null && sudo chmod 644 /etc/telegraf/telegraf.conf'

# --- deliver the WRITE token via SSH stdin -> 0600 root env file -----------
log "writing /etc/telegraf/telegraf.env (0600, root) ..."
printf 'INFLUXDB_TOKEN=%s\n' "$INFLUX_TOKEN" \
  | "${SSH[@]}" 'sudo tee /etc/telegraf/telegraf.env >/dev/null && sudo chmod 600 /etc/telegraf/telegraf.env && sudo chown root:root /etc/telegraf/telegraf.env'

# --- systemd drop-in so the env file is loaded into the telegraf process -----
log "installing systemd drop-in (EnvironmentFile) ..."
"${SSH[@]}" "sudo mkdir -p /etc/systemd/system/telegraf.service.d && sudo tee /etc/systemd/system/telegraf.service.d/env.conf >/dev/null" \
  < "$REPO_ROOT/scripts/systemd/telegraf-env.conf"

# --- enable + restart -------------------------------------------------------
log "enabling + restarting telegraf on $NODE_NAME ..."
"${SSH[@]}" 'sudo systemctl daemon-reload; sudo systemctl enable telegraf >/dev/null 2>&1; sudo systemctl restart telegraf; sleep 2; echo "  active: $(systemctl is-active telegraf)"'

# --- verify: service healthy, no errors, and metrics are landing in Influx ---
log "verifying ..."
"${SSH[@]}" 'sleep 20; echo "  recent errors (last 90s):"; { journalctl -u telegraf --since "90s ago" --no-pager 2>/dev/null | grep -iE "error|fail|refused|denied|not found" | head -4 | sed "s/^/    /"; } || echo "    (none)"'

# Read-back a cpu point with the READ token (the write token in the env file is
# write-only, so it cannot read its own data back). The READ token is piped over
# SSH stdin (never an arg) and is NOT written to disk on the node.
Q_OK="$(printf '%s' "$INFLUX_READ_TOKEN" | "${SSH[@]}" 'T=$(cat); curl -s -m 8 -X POST "http://aiserver.home:8086/api/v2/query?org=home" -H "Authorization: Token $T" -H "Accept: application/csv" -H "Content-Type: application/vnd.flux" --data-binary "from(bucket:\"host_metrics\") |> range(start:-10m) |> filter(fn: (r) => r.host==\"'"$NODE_NAME"'\") |> filter(fn: (r) => r._measurement==\"cpu\") |> limit(n:1)" 2>/dev/null | grep -cE ",cpu," || true')"
if [ "${Q_OK:-0}" -ge 1 ]; then
  ok "metrics landing in host_metrics (host=$NODE_NAME)"
else
  warn "no cpu point found for host=$NODE_NAME in host_metrics yet — give it ~30s and re-check: ssh $LINUX_USER@$NODE_HOST 'sudo journalctl -u telegraf -n 20'"
fi

echo ""
ok "telegraf configured on $NODE_NAME -> InfluxDB host_metrics"
echo "  manage:    ssh $LINUX_USER@$NODE_HOST 'sudo systemctl status telegraf'"
echo "  rotate:    infs set INFLUXDB_TOKEN=<new>; ./scripts/install-telegraf.sh $NODE_HOST"