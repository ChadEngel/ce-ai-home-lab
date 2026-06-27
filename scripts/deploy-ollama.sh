#!/bin/bash
# Deploy Ollama to the Kubernetes cluster
# Run from the repository root: ./scripts/deploy-ollama.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications"
NAMESPACE="ai"

echo "Deploying Ollama to namespace: $NAMESPACE"

# Apply Kustomization resources (Service, PVC, Deployment)
kubectl apply --namespace="$NAMESPACE" -f "$APPS_DIR/ollama/kustomization.yaml"

echo "Ollama deployment completed."
echo "Service endpoint: http://ollama-api.ai.svc.cluster.local:11434"
