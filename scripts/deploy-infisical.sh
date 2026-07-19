#!/bin/bash
# Deploy Infisical (secrets management) to the Kubernetes cluster
# Run from the repository root: ./scripts/deploy-infisical.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications/infisical"
NAMESPACE="ai"

echo "Deploying Infisical to namespace: $NAMESPACE"

# 1. Main resources (Deployment, Service, Ingress, ConfigMaps, Secret, PVCs)
kubectl apply --namespace="$NAMESPACE" -f "$APPS_DIR/kustomization.yaml"

# 2. Pre-create the cert-manager Certificate (avoids the 30s wait for the
#    ingress annotation to trigger issuance)
kubectl apply --namespace="$NAMESPACE" -f "$APPS_DIR/ssl-certs.yaml"

echo ""
echo "Infisical deployment applied. Waiting for pods..."
kubectl wait --for=condition=Ready pod \
    -l app=infisical -n "$NAMESPACE" --timeout=300s 2>/dev/null \
    || echo "  (infisical pod not yet ready; check 'kubectl describe pod -n ai -l app=infisical')"

echo ""
echo "URLs:"
echo "  Web UI:    https://secrets.caehomelab.com"
echo "  ClusterIP: http://infisical.ai.svc.cluster.local:3000"
echo ""
echo "Next steps:"
echo "  1. Visit https://secrets.caehomelab.com and create the initial admin user."
echo "  2. Disable open signup once you've registered (UPDATE super_admin SET"
echo "     \"allowSignUp\"=false; in the infisical DB, or via the UI)."
echo "  3. In the UI, create the 'secret-management' project and add the real"
echo "     service secrets to its 'prod' environment at path '/':"
echo "       CLOUDFLARE_API_TOKEN, INFLUXDB_TOKEN (and the legacy"
echo "       GODADDY_API_KEY/SECRET + SEARXNG_SECRET_KEY records)."
echo "  4. Create the 'homelab-k8s-operator' Machine Identity (Universal Auth,"
echo "     Viewer role on secret-management/prod) and create the credentials"
echo "     K8s Secret:"
echo "       kubectl create secret generic infisical-universal-auth -n ai \\"
echo "         --from-literal=clientId=<id> --from-literal=clientSecret=<secret>"
echo "  5. Deploy the operator: ./scripts/deploy-infisical-operator.sh"
echo "     (then cert-manager gets cloudflare-dns-creds, Grafana gets"
echo "     influxdb-secrets — both synced from Infisical.)"
echo ""
