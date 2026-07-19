#!/bin/bash
# Deploy SearXNG (search engine) to the Kubernetes cluster
# Run from the repository root: ./scripts/deploy-searxng.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications/searxng"
NAMESPACE="ai"

echo "Deploying SearXNG to namespace: $NAMESPACE"

kubectl apply --namespace="$NAMESPACE" -f "$APPS_DIR/kustomization.yaml"

echo ""
echo "SearXNG deployment completed."
echo "  Web UI:    https://search.caehomelab.com"
echo "  ClusterIP: http://searxng-api.ai.svc.cluster.local:8080"
echo ""
echo "IMPORTANT: Change the secret_key in searxng-settings before exposing publicly."
echo ""
