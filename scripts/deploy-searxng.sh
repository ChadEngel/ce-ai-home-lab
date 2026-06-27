#!/bin/bash
# Deploy SearXNG to the Kubernetes cluster
# Run from the repository root: ./scripts/deploy-searxng.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications"
NAMESPACE="ai"

echo "Deploying SearXNG to namespace: $NAMESPACE"

# Apply Kustomization resources (this contains Service, PVC, Ingress, Deployment, ConfigMap)
kubectl apply --namespace="$NAMESPACE" -f "$APPS_DIR/searxng/kustomization.yaml"

echo "SearXNG deployment completed."
echo "Access URL: https://search.caehomelab.com"
echo "IMPORTANT: Set the secret_key in the settings.yml with a secure value before using in production."
