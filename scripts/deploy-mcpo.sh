#!/bin/bash
# Deploy MCPo to the Kubernetes cluster
# Run from the repository root: ./scripts/deploy-mcpo.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications"
NAMESPACE="ai"

echo "Deploying MCPo to namespace: $NAMESPACE"

# Apply Kustomization resources (Service, Deployment)
kubectl apply --namespace="$NAMESPACE" -f "$APPS_DIR/mcpo/kustomization.yaml"

echo "MCPo deployment completed."
echo "Service endpoint: http://mcpo.ai.svc.cluster.local:8000"
