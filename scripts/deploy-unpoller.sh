#!/bin/bash
# Deploy unpoller to the Kubernetes cluster.
# unpoller collects UniFi network metrics from the UDM Pro controller
# (https://192.168.250.1) using an API key and writes them to InfluxDB v2
# bucket `network_metrics`. See
# clusters/util-server/applications/unpoller/kustomization.yaml for design.
#
# Run from the repository root: ./scripts/deploy-unpoller.sh

set -euo pipefail

NAMESPACE="ai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
UNPOLLER_DIR="$REPO_ROOT/clusters/util-server/applications/unpoller"
INFISICAL_SYNC="$REPO_ROOT/clusters/util-server/applications/infisical-operator/infisical-secrets-sync.yaml"

echo "=== Deploying unpoller ==="

# 1. (Re)apply InfisicalSecret CRs — this (re)creates the unpoller-secrets
#    K8s Secret synced from Infisical (INFLUXDB_TOKEN write + UDM_API_KEY).
#    Idempotent; also touches the other sync CRs (harmless).
kubectl apply -f "$INFISICAL_SYNC"
echo "[✅] InfisicalSecret CRs applied (unpoller-secrets-sync included)"

# 2. Wait for the operator to populate unpoller-secrets before starting the
#    pod, otherwise the initContainer's empty-secret guard fails the pod.
echo ""
echo "Waiting for unpoller-secrets to be synced by the Infisical operator..."
for i in $(seq 1 20); do
  if kubectl get secret unpoller-secrets -n "$NAMESPACE" -o jsonpath='{.data.INFLUXDB_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null | grep -q . \
     && kubectl get secret unpoller-secrets -n "$NAMESPACE" -o jsonpath='{.data.UDM_API_KEY}' 2>/dev/null | base64 -d 2>/dev/null | grep -q .; then
    echo "[✅] unpoller-secrets populated (attempt $i)"
    break
  fi
  echo "  ($i) not yet — retrying in 5s"
  sleep 5
  if [ "$i" = 20 ]; then
    echo "[⚠️] unpoller-secrets not populated after 100s"
    echo "      Check: kubectl get infisicalsecret -n ai unpoller-secrets-sync"
    exit 1
  fi
done

# 3. Apply unpoller manifests (ConfigMap, Service, Deployment).
kubectl apply -n "$NAMESPACE" -f "$UNPOLLER_DIR/kustomization.yaml"
echo "[✅] unpoller manifests applied"

# 4. Wait for the pod to be ready.
echo ""
echo "Waiting for unpoller pod to be ready..."
if kubectl wait --for=condition=Ready pod -l app=unpoller -n "$NAMESPACE" --timeout=180s 2>/dev/null; then
    echo "[✅] unpoller pod is running"
else
    echo "[⚠️] unpoller pod did not become Ready within 180s"
    echo "      Check: kubectl describe pod -n ai -l app=unpoller"
    echo "      Logs:  kubectl logs -n ai -l app=unpoller -c unpoller"
fi

# 5. Quick status + how to verify data flow.
echo ""
echo "Pods:"
kubectl get pods -n "$NAMESPACE" -l app=unpoller
echo ""
echo "Next: confirm fresh writes to network_metrics (timestamps should advance ~30s):"
echo "  ./scripts/monitor_k3s_health.sh   # pattern reference; or query InfluxDB:"
echo "    from(bucket:\"network_metrics\") |> range(start:-5m) |> filter(fn:(r)=>r._measurement==\"uap\") |> last()"
echo ""