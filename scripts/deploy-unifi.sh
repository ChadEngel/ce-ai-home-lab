#!/bin/bash
# deploy-unifi.sh — deploy the self-hosted UniFi Network Application (controller)
# plus its MongoDB, in namespace `ai`.
#
# This is a DISASTER-RECOVERY STANDBY for the UDM Pro's built-in controller,
# kept OUT of deploy-all.sh. Leave it idle: do not adopt devices during normal
# operation. Failover steps are in the app README.
#
# Creates/refreshes `unifi-secrets` from Infisical (auto-generated + stored on
# first run), applies the controller + Mongo StatefulSet, waits for readiness,
# and prints the device-facing (inform) endpoint for the pinned node.
#
# Run from the repository root:  ./scripts/deploy-unifi.sh
#
# Secrets (Infisical, secret-management/prod// via the homelab-agent identity):
#   UNIFI_MONGO_ROOT_PASSWORD   auto-generated + stored on first run if absent
#   UNIFI_MONGO_PASSWORD        auto-generated + stored on first run if absent
#
# See clusters/util-server/applications/unifi/kustomization.yaml for design,
# and clusters/util-server/applications/unifi/README.md for adoption steps.

set -euo pipefail

NAMESPACE="ai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
UNIFI_DIR="$REPO_ROOT/clusters/util-server/applications/unifi"
# Must match the nodeSelector in the controller Deployment.
UNIFI_NODE="caelx003"

# shellcheck source=scripts/infisical-agent.sh
. "$SCRIPT_DIR/infisical-agent.sh"

log()  { printf '\033[1;34m[unifi]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[✅]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[⚠️]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[✖]\033[0m %s\n' "$*" >&2; exit 1; }

echo "=== Deploying UniFi Network Application (${NAMESPACE}) ==="

infisical_agent_token >/dev/null || die "Infisical agent not ready (run scripts/infisical-agent-setup.sh)"

# --- 1. passwords: reuse from Infisical, or generate + store once -----------
# Passwords are only evaluated on FIRST run (empty /data/db), so they must be
# stable across redeploys — never regenerate an existing value.
gen() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32; }

ROOT_PW="$(infs get UNIFI_MONGO_ROOT_PASSWORD 2>/dev/null || true)"
if [ -z "$ROOT_PW" ]; then
  ROOT_PW="$(gen)"
  infs set "UNIFI_MONGO_ROOT_PASSWORD=$ROOT_PW" >/dev/null
  ok "generated UNIFI_MONGO_ROOT_PASSWORD and stored it in Infisical"
else
  log "reusing UNIFI_MONGO_ROOT_PASSWORD from Infisical"
fi

APP_PW="$(infs get UNIFI_MONGO_PASSWORD 2>/dev/null || true)"
if [ -z "$APP_PW" ]; then
  APP_PW="$(gen)"
  infs set "UNIFI_MONGO_PASSWORD=$APP_PW" >/dev/null
  ok "generated UNIFI_MONGO_PASSWORD and stored it in Infisical"
else
  log "reusing UNIFI_MONGO_PASSWORD from Infisical"
fi

# --- 2. K8s Secret ----------------------------------------------------------
# Must exist BEFORE the mongo StatefulSet starts, or the init script has no
# credentials to create the `unifi` user with.
kubectl create secret generic unifi-secrets -n "$NAMESPACE" \
  --from-literal=MONGO_ROOT_PASSWORD="$ROOT_PW" \
  --from-literal=MONGO_PASS="$APP_PW" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "unifi-secrets applied (MONGO_ROOT_PASSWORD + MONGO_PASS)"

# --- 3. manifests -----------------------------------------------------------
kubectl apply -n "$NAMESPACE" -f "$UNIFI_DIR/kustomization.yaml" >/dev/null
ok "unifi MongoDB StatefulSet + controller Deployment + Services applied"

# --- 4. wait for MongoDB, then the controller ------------------------------
log "waiting for unifi-mongo-0 to become Ready ..."
if kubectl rollout status statefulset/unifi-mongo -n "$NAMESPACE" --timeout=300s >/dev/null 2>&1; then
  ok "unifi-mongo-0 is Ready"
else
  warn "unifi-mongo-0 not Ready — check: kubectl describe pod -n $NAMESPACE unifi-mongo-0"
  kubectl get pods -n "$NAMESPACE" -l app=unifi-mongo -o wide
  exit 1
fi

log "waiting for the controller pod to become Ready (first boot can take minutes) ..."
if kubectl rollout status deployment/unifi -n "$NAMESPACE" --timeout=600s >/dev/null 2>&1; then
  ok "unifi controller is Ready"
else
  warn "unifi controller not Ready — check: kubectl describe pod -n $NAMESPACE -l app=unifi"
  kubectl get pods -n "$NAMESPACE" -l app=unifi -o wide
  exit 1
fi

# --- 5. status + device-facing endpoint ------------------------------------
NODE_IP="$(kubectl get node "$UNIFI_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"

echo ""
kubectl get statefulset,deployment,pod,svc -n "$NAMESPACE" -l app=unifi -o wide 2>/dev/null || true
kubectl get pod -n "$NAMESPACE" -l app=unifi-mongo -o wide 2>/dev/null || true

echo ""
log "Controller UI:   https://unifi.caehomelab.com:8443   (self-signed cert on first boot)"
log "Inform endpoint: http://unifi.caehomelab.com:8080/inform"
log "                 (DNS-only record -> ${NODE_IP:-<node-ip>}); fallback to the bare IP if DNS is unavailable"
log ""
log "This is a DR STANDBY — leave it idle. Do NOT adopt devices now; that would"
log "steal them from the UDM Pro controller. Failover steps (restore backup,"
log "set Inform Host Override, re-point devices) are in:"
log "  clusters/util-server/applications/unifi/README.md"
log ""
log "Optional cold standby (frees ~1 GiB RAM until failover):"
log "  kubectl scale deployment/unifi -n $NAMESPACE --replicas=0"
echo ""
