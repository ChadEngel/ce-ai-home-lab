#!/bin/bash
# Deploy LiteLLM to the Kubernetes cluster
# Run from the repository root: ./scripts/deploy-litellm.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications"
NAMESPACE="ai"

echo "Deploying LiteLLM to namespace: $NAMESPACE"

# Apply Kustomization resources (Service, PVC, Secret, ConfigMap, Deployment)
kubectl apply --namespace="$NAMESPACE" -f "$APPS_DIR/litellm/kustomization.yaml" --validate=false

echo "LiteLLM deployment completed."
echo "Service endpoint: http://litellm-api.ai.svc.cluster.local:4000"
echo "IMPORTANT: Update the secrets and model API keys before use.
echo "Use --validate=false flag since validation may fail locally."
