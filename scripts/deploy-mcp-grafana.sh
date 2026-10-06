#!/bin/bash
# Deploy the mcp-grafana MCP server and (re)load the Bifrost config.json that
# registers the "grafana-noc" MCP client + "aios-noc" Virtual Key.
# Run from the repository root: ./scripts/deploy-mcp-grafana.sh
#
# Brings up:
#   - mcp-grafana 2.0.1 (streamable-http :8000/mcp, --disable-write, read-only)
#   - NetworkPolicy limiting ingress to the Bifrost pod
#   - InfisicalSecret syncing GRAFANA_SERVICE_ACCOUNT_TOKEN -> ai/mcp-grafana-secrets
#   - Bifrost config.json (bifrost-config ConfigMap) mounted at /app/data/config.json,
#     declaring the grafana-noc MCP client and the aios-noc Virtual Key
#
# Prerequisite: the Infisical secret GRAFANA_SERVICE_ACCOUNT_TOKEN must exist
# (a token from a read-only Grafana service account). See the mcp-grafana README.
#
# Design + rationale: ce-aios/aios/roadmap/t4-noc-mcp-design.md (T4 / issue #30)

set -euo pipefail

NAMESPACE="ai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications"

echo "=== Deploying mcp-grafana (read-only Grafana MCP server) ==="

# 1. Sync the Infisical secret first so the K8s Secret exists before the pod starts.
echo ""
echo ">>> Syncing Infisical secrets (incl. mcp-grafana-secrets)..."
kubectl apply -n "$NAMESPACE" -f "$APPS_DIR/infisical-operator/infisical-secrets-sync.yaml"

echo ""
echo "Waiting for K8s Secret mcp-grafana-secrets to be created by the operator..."
for _ in $(seq 1 30); do
    if kubectl -n "$NAMESPACE" get secret mcp-grafana-secrets >/dev/null 2>&1; then
        echo "[✅] mcp-grafana-secrets exists"
        break
    fi
    sleep 2
done
if ! kubectl -n "$NAMESPACE" get secret mcp-grafana-secrets >/dev/null 2>&1; then
    echo "[⚠️]  mcp-grafana-secrets not created yet."
    echo "       Check the InfisicalSecret status:"
    echo "         kubectl -n ai describe infisicalsecret mcp-grafana-secrets-sync"
    echo "       The GRAFANA_SERVICE_ACCOUNT_TOKEN key must exist in Infisical"
    echo "       (project caehomelab-v1q6, env prod, path /)."
fi

# 2. Deploy mcp-grafana (Deployment + Service + NetworkPolicy)
echo ""
echo ">>> Applying mcp-grafana manifests..."
kubectl apply -n "$NAMESPACE" -f "$APPS_DIR/mcp-grafana/kustomization.yaml"
echo "[✅] mcp-grafana manifests applied"

echo ""
echo "Waiting for mcp-grafana pod to be ready..."
if kubectl wait --for=condition=Ready pod -l app=mcp-grafana -n "$NAMESPACE" \
        --timeout=180s 2>/dev/null; then
    echo "[✅] mcp-grafana is running"
else
    echo "[⚠️]  mcp-grafana did not become Ready within 180s"
    echo "       kubectl describe pod -n ai -l app=mcp-grafana"
    echo "       kubectl logs -n ai -l app=mcp-grafana --tail=40"
fi

# 3. Apply the Bifrost config.json ConfigMap + rolled-out Deployment.
#    This edits the Deployment (adds the subPath mount), so it triggers a
#    rollout automatically; we follow with an explicit restart for certainty.
echo ""
echo ">>> Applying Bifrost config.json (bifrost-config ConfigMap + mount)..."
kubectl apply -n "$NAMESPACE" -f "$APPS_DIR/bifrost/kustomization.yaml"

echo ""
echo ">>> Restarting Bifrost to load config.json..."
kubectl -n "$NAMESPACE" rollout restart deployment/bifrost
kubectl -n "$NAMESPACE" rollout status deployment/bifrost --timeout=180s

# 4. Verify the MCP client + Virtual Key registered.
echo ""
echo "=== Verification ==="
sleep 5

echo ""
echo "--- MCP clients (expect grafana-noc) ---"
kubectl -n ai exec deploy/bifrost -- \
    wget -qO- http://localhost:8080/api/mcp/clients 2>/dev/null \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('count:',d.get('count'));[print('  -',c.get('name'),'| conn:',c.get('connection_type'),'| state:',c.get('state')) for c in d.get('clients',[])]" \
    || echo "  (could not read /api/mcp/clients)"

echo ""
echo "--- Virtual keys (expect aios-noc + the pre-existing two) ---"
kubectl -n ai exec deploy/bifrost -- \
    wget -qO- http://localhost:8080/api/governance/virtual-keys 2>/dev/null \
    | python3 -c "import sys,json;d=json.load(sys.stdin);ks=d.get('virtual_keys') or d.get('data') or [];[print('  -',k.get('name'),'| mcp_configs:',len(k.get('mcp_configs') or [])) for k in ks]" \
    || echo "  (could not read /api/governance/virtual-keys)"

# 5. Summary
echo ""
echo "=== mcp-grafana deployed ==="
echo "  Internal:  http://mcp-grafana.ai.svc.cluster.local:8000/mcp"
echo "  Bifrost MCP client:  grafana-noc"
echo "  Bifrost Virtual Key: aios-noc  (R0: tools_to_auto_execute = [], nothing auto-runs)"
echo ""
echo "  Grafana auth: read-only service-account token from Infisical"
echo "    -> K8s Secret mcp-grafana-secrets[GRAFANA_SERVICE_ACCOUNT_TOKEN]"
echo ""
echo "  Next: prove one read-only tool end-to-end (issue #31 / T5), e.g. a LogQL query."
echo "    The aios-noc key value is auto-generated; read it with:"
echo "      kubectl -n ai exec deploy/bifrost -- wget -qO- http://localhost:8080/api/governance/virtual-keys"
