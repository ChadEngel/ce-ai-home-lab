#!/bin/bash
# Deploy InfluxDB v2 to the Kubernetes cluster (pinned to caelx002, NFS storage).
# Run from the repository root: ./scripts/deploy-influxdb.sh
#
# This deploys an EMPTY instance. To migrate data + tokens from the old
# bare-metal instance on aiserver.home, see docs/migrate-influxdb-to-k8s.md
# and the INFLUX_MIGRATE section at the bottom of this script.

set -euo pipefail

NAMESPACE="ai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications/influxdb"

echo "=== Deploying InfluxDB v2 ==="

# 1. Core manifests (Deployment, Service, Ingress, PVC)
kubectl apply -n "$NAMESPACE" -f "$APPS_DIR/kustomization.yaml"
echo "[✅] InfluxDB core manifests applied"

# 2. Pre-create the cert-manager Certificate (DNS-01 via Cloudflare; issues
#    without an A record, but the A record is required for traffic to reach
#    the ingress — see step 5).
kubectl apply -n "$NAMESPACE" -f "$APPS_DIR/ssl-certs.yaml"
echo "[✅] TLS Certificate applied (issuing via DNS-01 / Cloudflare)"

# 3. Wait for the pod to be ready
echo ""
echo "Waiting for InfluxDB pod to be ready..."
if kubectl wait --for=condition=Ready pod \
        -l app=influxdb \
        -n "$NAMESPACE" \
        --timeout=180s 2>/dev/null; then
    echo "[✅] InfluxDB pod is running"
else
    echo "[⚠️] InfluxDB pod did not become Ready within 180s"
    echo "      Check: kubectl describe pod -n ai -l app=influxdb"
fi

# 4. URLs
echo ""
echo "In-cluster:  http://influxdb.ai.svc.cluster.local:8086   (Grafana, unpoller)"
echo "External:    https://influxdb.caehomelab.com              (telegraf on Macs, k3s-metrics-push)"
echo ""
echo "Setup status (allowed:true means EMPTY, ready for restore):"
kubectl exec -n "$NAMESPACE" deploy/influxdb -- influx ping 2>/dev/null || true
echo ""

# 5. DNS reminder
echo "[⚠️]  Create a Cloudflare A record:  influxdb.caehomelab.com -> <traefik node IP>"
echo "       (192.168.30.217 or 192.168.30.59). The TLS cert issues via DNS-01"
echo "       without it, but external writers cannot reach the ingress until it exists."
echo ""
echo "Next: migrate data from aiserver.home — see docs/migrate-influxdb-to-k8s.md"