#!/bin/bash
# Deploy OpenWebUI Ollama Config to the Kubernetes cluster
# Run from the repository root: ./scripts/deploy-litellm-config.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications"
NAMESPACE="ai"

echo "Deploying LiteLLM config map to namespace: $NAMESPACE"

# Apply the OpenWebUI Ollama config
kubectl apply --namespace="$NAMESPACE" -f "$APPS_DIR/litellm/openwebui-ollama-config.yaml"

echo "LiteLLM config deployment completed."
