#!/bin/bash
# deploy-postgres.sh — deploy the shared Postgres used by multi-replica apps.
#
# Creates/refreshes the `postgres-secrets` K8s Secret from Infisical, applies
# the StatefulSet (pinned to util-server, local-path storage) plus the nightly
# pg_dump backup CronJob, waits for readiness, and ensures the per-app
# databases exist.
#
# Run from the repository root:  ./scripts/deploy-postgres.sh
#
# Secrets (Infisical, secret-management/prod// via the homelab-agent identity):
#   POSTGRES_PASSWORD   auto-generated + stored on first run if absent
#
# See clusters/util-server/applications/postgres/kustomization.yaml for design.

set -euo pipefail

NAMESPACE="ai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PG_DIR="$REPO_ROOT/clusters/util-server/applications/postgres"
DATABASES="grafana openwebui"

# shellcheck source=scripts/infisical-agent.sh
. "$SCRIPT_DIR/infisical-agent.sh"

log()  { printf '\033[1;34m[postgres]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[✅]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[⚠️]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[✖]\033[0m %s\n' "$*" >&2; exit 1; }

echo "=== Deploying shared Postgres (${NAMESPACE}) ==="

infisical_agent_token >/dev/null || die "Infisical agent not ready (run scripts/infisical-agent-setup.sh)"

# --- 1. password: reuse from Infisical, or generate + store once ------------
PW="$(infs get POSTGRES_PASSWORD 2>/dev/null || true)"
if [ -z "$PW" ]; then
  PW="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)"
  infs set "POSTGRES_PASSWORD=$PW" >/dev/null
  ok "generated POSTGRES_PASSWORD and stored it in Infisical"
else
  log "reusing POSTGRES_PASSWORD from Infisical"
fi

# --- 2. K8s Secret ----------------------------------------------------------
# Also carries a ready-made connection URL per app, so consumers can just
# `secretKeyRef` it into DATABASE_URL instead of assembling the string.
kubectl create secret generic postgres-secrets -n "$NAMESPACE" \
  --from-literal=POSTGRES_PASSWORD="$PW" \
  --from-literal=OPENWEBUI_DATABASE_URL="postgresql://postgres:${PW}@postgres.${NAMESPACE}.svc.cluster.local:5432/openwebui" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "postgres-secrets applied (POSTGRES_PASSWORD + OPENWEBUI_DATABASE_URL)"

# --- 3. manifests -----------------------------------------------------------
kubectl apply -n "$NAMESPACE" -f "$PG_DIR/kustomization.yaml" >/dev/null
ok "postgres StatefulSet/Service/init applied"
kubectl apply -n "$NAMESPACE" -f "$PG_DIR/backup.yaml" >/dev/null
ok "backup PVC + nightly pg_dump CronJob applied"

# --- 4. wait for readiness --------------------------------------------------
log "waiting for postgres-0 to become Ready ..."
if kubectl rollout status statefulset/postgres -n "$NAMESPACE" --timeout=240s >/dev/null 2>&1; then
  ok "postgres-0 is Ready"
else
  warn "postgres-0 not Ready yet — check: kubectl describe pod -n $NAMESPACE postgres-0"
  kubectl get pods -n "$NAMESPACE" -l app=postgres -o wide
  exit 1
fi

# --- 5. ensure per-app databases exist --------------------------------------
for db in $DATABASES; do
  if kubectl exec -n "$NAMESPACE" postgres-0 -- \
       psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'" 2>/dev/null | grep -q 1; then
    log "database '${db}' present"
  else
    kubectl exec -n "$NAMESPACE" postgres-0 -- \
      psql -U postgres -c "CREATE DATABASE ${db}" >/dev/null
    ok "database '${db}' created"
  fi
done

echo ""
kubectl get statefulset,pod,svc -n "$NAMESPACE" -l app=postgres -o wide
echo ""
log "connection string for apps:"
log "  postgresql://postgres:<POSTGRES_PASSWORD>@postgres.${NAMESPACE}.svc.cluster.local:5432/<db>"
log "next: migrate grafana / openwebui off SQLite (see their kustomization.yaml)"
