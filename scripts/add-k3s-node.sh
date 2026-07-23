#!/bin/bash
# add-k3s-node.sh — add a worker (agent) node to the homelab k3s cluster.
#
# All secrets come from Infisical (secret-management/prod// via the
# `homelab-agent` Machine Identity, loaded by scripts/infisical-agent.sh):
#
#   LINUX_USER        SSH username for the new node (e.g. cengel)
#   LINUX_PVT_KEY     SSH private key (raw PEM, or base64-encoded PEM)
#   K3S_NODE_TOKEN    k3s node-token from the control-plane node
#                     (read off util-server at /var/lib/rancher/k3s/server/node-token
#                      and stored in Infisical — see docs/how-to-add-k3s-node.md)
#
# Usage:
#   ./scripts/add-k3s-node.sh <node-host> [k3s-server-url] [k3s-version]
#
#   <node-host>        resolvable hostname or IP of the new worker (e.g. caelx003)
#   [k3s-server-url]   default: auto-detected from the current kubeconfig
#                     (https://192.168.30.217:6443)
#   [k3s-version]      default: auto-detected from the control-plane node's
#                     kubeletVersion (e.g. v1.35.5+k3s1) — pins the agent to match
#                     the server.
#
# Examples:
#   ./scripts/add-k3s-node.sh caelx003
#   ./scripts/add-k3s-node.sh 192.168.30.60 https://192.168.30.217:6443 v1.35.5+k3s1
#   FORCE=1 ./scripts/add-k3s-node.sh caelx003   # re-install even if k3s is present
#
# The node-token is passed to the install over SSH via a 0600 temp file on the
# node that is deleted before the installer runs; it is never printed.
#
# This adds a WORKER (agent) node — no control-plane / etcd role. The homelab
# runs a single control-plane node (util-server) with the embedded SQLite
# datastore, which cannot accept a second server. See the doc for HA notes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=scripts/infisical-agent.sh
. "$SCRIPT_DIR/infisical-agent.sh"

log()  { printf '\033[1;34m[k3s]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[✅]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[⚠️]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[✖]\033[0m %s\n' "$*" >&2; exit 1; }

NODE_HOST="${1:-}"
SERVER_URL="${2:-}"
K3S_VERSION="${3:-}"
FORCE="${FORCE:-0}"

[ -n "$NODE_HOST" ] || die "usage: $0 <node-host> [k3s-server-url] [k3s-version]"

# --- defaults: server URL + version from the live cluster -------------------
if [ -z "$SERVER_URL" ]; then
  SERVER_URL="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  [ -n "$SERVER_URL" ] || SERVER_URL="https://192.168.30.217:6443"
fi
if [ -z "$K3S_VERSION" ]; then
  K3S_VERSION="$(kubectl get node -l node-role.kubernetes.io/control-plane= \
                  -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null || true)"
  [ -n "$K3S_VERSION" ] || K3S_VERSION="$(kubectl get nodes \
                  -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null || true)"
  [ -n "$K3S_VERSION" ] || K3S_VERSION="v1.35.5+k3s1"
fi

log "adding worker node '$NODE_HOST' to cluster"
log "  server:   $SERVER_URL"
log "  version:  $K3S_VERSION (pinned to match control-plane)"

# --- pull secrets from Infisical -------------------------------------------
infisical_agent_token >/dev/null || die "Infisical agent not ready (run scripts/infisical-agent-setup.sh)"

LINUX_USER="$(infs get LINUX_USER 2>/dev/null || true)"
[ -n "$LINUX_USER" ] || die "LINUX_USER not found in Infisical"
log "  ssh user: $LINUX_USER"

LPK="$(infs get LINUX_PVT_KEY 2>/dev/null || true)"
[ -n "$LPK" ] || die "LINUX_PVT_KEY not found in Infisical"

TOKEN="$(infs get K3S_NODE_TOKEN 2>/dev/null || true)"
[ -n "$TOKEN" ] || die "K3S_NODE_TOKEN not found in Infisical (store it first — see docs/how-to-add-k3s-node.md)"

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
log "  ssh key: materialized ($(ssh-keygen -l -f "$KEYFILE" | awk '{print $NF,$(NF-1)}'))"

SSH=(ssh -i "$KEYFILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
     -o ConnectTimeout=10 "$LINUX_USER@$NODE_HOST")

# --- pre-flight on the new node ---------------------------------------------
log "pre-flight on $NODE_HOST ..."
# Build the remote pre-flight script with the server URL interpolated, then
# pipe it to the remote shell.  (Interpolate on the SCRIPT, not the output.)
PF_SCRIPT="$(cat <<EOF
echo "hostname=\$(hostname)"
echo "ip=\$(hostname -I | awk '{print \$1}')"
echo "os=\$(. /etc/os-release; echo "\$PRETTY_NAME")"
echo "arch=\$(uname -m)"
echo "curl=\$(command -v curl || echo MISSING)"
if sudo -n true 2>/dev/null; then echo "sudo=OK"; else echo "sudo=NO"; fi
if command -v k3s >/dev/null; then echo "k3s=PRESENT"; else echo "k3s=none"; fi
echo "ports=\$(ss -tln 2>/dev/null | grep -E ':6443|:8080' | wc -l | tr -d ' ')"
echo "readyz=\$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 -k ${SERVER_URL}/readyz 2>/dev/null || echo unreachable)"
EOF
)"
PF_OUT="$("${SSH[@]}" 'bash -s' <<<"$PF_SCRIPT")"

pf() { printf '%s\n' "$PF_OUT" | sed -n "s/^$1=//p"; }
hostname_v="$(pf hostname)"; ip="$(pf ip)"; os="$(pf os)"; arch="$(pf arch)"
curl_v="$(pf curl)"; sudo_v="$(pf sudo)"; k3s_v="$(pf k3s)"; ports_v="$(pf ports)"; readyz="$(pf readyz)"

NODE_NAME="$hostname_v"
log "  node:        $NODE_NAME ($ip)"
log "  os:          $os ($arch)"
[ "$curl_v" = "MISSING" ] && die "curl is required on $NODE_HOST"
[ "$sudo_v" = "OK" ]     || die "passwordless sudo is required for $LINUX_USER on $NODE_HOST"
[ "$k3s_v" = "none" ]    || { [ "$FORCE" = "1" ] && warn "k3s already present on $NODE_HOST — FORCE=1, continuing" || die "k3s already present on $NODE_HOST (use FORCE=1 to re-install)"; }
[ "$ports_v" = "0" ]    || warn "ports 6443/8080 already in use on $NODE_HOST"
case "$readyz" in
  401|403|200) ok "  $NODE_HOST can reach the API ($readyz)" ;;
  *) die "$NODE_HOST cannot reach the API at $SERVER_URL (got: $readyz)" ;;
esac

# --- install the k3s agent --------------------------------------------------
# Build the remote command with local vars ($K3S_VERSION/$SERVER_URL) expanded
# and remote vars (\$T / \$(cat …)) kept literal, then pipe the token over stdin
# to the remote `cat > /tmp/k3s.tok`.  No heredoc-as-stdin conflict because the
# heredoc here builds the *string*, not ssh's stdin.
log "installing k3s agent $K3S_VERSION on $NODE_NAME ..."
REMOTE_CMD="$(cat <<EOF
umask 077; cat > /tmp/k3s.tok
echo "  token staged (\$(wc -c < /tmp/k3s.tok) bytes)"
sudo bash -c 'T=\$(cat /tmp/k3s.tok); rm -f /tmp/k3s.tok; curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION K3S_URL=$SERVER_URL K3S_TOKEN=\$T sh -'
echo "  token file removed: \$([ -f /tmp/k3s.tok ] && echo STILL-PRESENT || echo gone)"
EOF
)"
printf '%s\n' "$TOKEN" | "${SSH[@]}" "$REMOTE_CMD"
ok "k3s-agent installed"

# --- wait for the node to join + go Ready -----------------------------------
log "waiting for $NODE_NAME to register + go Ready ..."
ready=0
for i in $(seq 1 18); do
  s="$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [ "$s" = "True" ]; then ready=1; break; fi
  sleep 5
done
if [ "$ready" = "1" ]; then
  ok "$NODE_NAME is Ready"
else
  warn "$NODE_NAME has not gone Ready yet (last: '${s:-not-registered}'); check: kubectl get node $NODE_NAME -o wide; ssh $LINUX_USER@$NODE_HOST 'sudo journalctl -u k3s-agent --no-pager | tail'"
fi

echo ""
kubectl get nodes -o wide