#!/bin/bash
set -e

echo "=== Deploying Grafana ==="

# 1. Apply Grafana manifests (Service, Deployment, PVC, Ingress)
kubectl apply -f clusters/util-server/applications/grafana/
echo "[✅] Grafana deployment applied"

# 2. Wait for pods to come up
NAMESPACE="ai"
DEPLOYMENT="grafana"

echo "Waiting for Grafana pod to be ready..."
kubectl wait --for=condition=Ready pod \
  -l app=${DEPLOYMENT} \
  -n ${NAMESPACE} \
  --timeout=120s >/dev/null 2>&1 && echo "[✅] Grafana pod is running"

# 3. Get Ingress status
echo ""
echo "Grafana Ingress:"
kubectl get ingress grafana-ingress -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[*].ip}' 2>/dev/null || true
echo ""

# 4. Show URL
echo "Access Grafana at: https://grafana.caehomelab.com"
echo "Login: admin / admin (default — change after first login!)"
echo ""

# 5. Apply the k8s monitoring dashboard (import from JSON)
echo ""
echo "=== Applying K8s Monitoring Dashboard ==="
kubectl apply -f scripts/grafana/ --namespace=${NAMESPACE}
echo "[✅] Provisioning configs applied (datasources + dashboards)"
echo ""
echo "[✅] Grafana deployment complete!"
