#!/bin/bash
# Deploy OpenWebUI to the Kubernetes cluster
# Run from the repository root: ./scripts/deploy-openwebui.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications"
NAMESPACE="ai"

echo "Deploying OpenWebUI to namespace: $NAMESPACE"

# Apply Kustomization resources (Service, PVC, Ingress, Deployment)
kubectl apply --namespace="$NAMESPACE" -f "$APPS_DIR/openwebui/kustomization.yaml"

echo "OpenWebUI deployment completed."
echo "Access URL: https://ai.caehomelab.com"
echo "Connects to external Ollama: http://aiserver.home:11434"
