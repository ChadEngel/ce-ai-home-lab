#!/bin/bash
# Deploy Grafana (InfluxDB-backed) to the Kubernetes cluster
# Run from the repository root: ./scripts/deploy-grafana.sh

set -euo pipefail

NAMESPACE="ai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications/grafana"
DASH_DIR="$REPO_ROOT/scripts/grafana/dashboards"

echo "=== Deploying Grafana ==="

# 1. Apply Grafana core manifests (Deployment, Service, Ingress, ConfigMaps, Secrets, PVC)
kubectl apply -n "$NAMESPACE" -f "$APPS_DIR/kustomization.yaml"
echo "[✅] Grafana core manifests applied"

# 2. Build the dashboard ConfigMap from JSON files. Each *.json becomes a
#    data key in the grafana-dashboards-json ConfigMap, which is mounted
#    into /var/lib/grafana/dashboards/default so the file provider picks
#    them up automatically.
echo ""
echo "Building dashboard ConfigMap from $DASH_DIR/*.json"
CM_ARGS=()
for f in "$DASH_DIR"/*.json; do
    [ -f "$f" ] || continue
    CM_ARGS+=("--from-file=$(basename "$f")=$f")
done
if [ "${#CM_ARGS[@]}" -gt 0 ]; then
    kubectl create configmap grafana-dashboards-json \
        --namespace="$NAMESPACE" \
        "${CM_ARGS[@]}" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "[✅] Dashboard ConfigMap applied (${#CM_ARGS[@]} dashboards)"
else
    echo "[⚠️] No dashboard JSON files found in $DASH_DIR"
fi

# 3. Wait for the pod to be ready
echo ""
echo "Waiting for Grafana pod to be ready..."
if kubectl wait --for=condition=Ready pod \
        -l app=grafana \
        -n "$NAMESPACE" \
        --timeout=180s 2>/dev/null; then
    echo "[✅] Grafana pod is running"
else
    echo "[⚠️] Grafana pod did not become Ready within 180s"
    echo "      Check: kubectl describe pod -n ai -l app=grafana"
fi

# 4. Ingress status
echo ""
echo "Grafana Ingress:"
kubectl get ingress grafana-ingress -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[*].ip}' 2>/dev/null || true
echo ""

# 5. URL info
echo ""
echo "Access Grafana at:  https://grafana.caehomelab.com"
echo "Login:              admin / admin   (CHANGE AFTER FIRST LOGIN)"
echo "InfluxDB token:     kubectl get secret -n ai influxdb-secrets -o jsonpath='{.data.INFLUX_TOKEN}' | base64 -d"
echo ""
