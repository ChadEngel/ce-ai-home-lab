#!/bin/bash
# Deploy OpenWebUI to the Kubernetes cluster
# Run from the repository root: ./scripts/deploy-openwebui.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications/openwebui"
NAMESPACE="ai"

echo "Deploying OpenWebUI to namespace: $NAMESPACE"

kubectl apply --namespace="$NAMESPACE" -f "$APPS_DIR/kustomization.yaml"

echo ""
echo "OpenWebUI deployment completed."
echo "  Web UI:    https://ai.caehomelab.com"
echo "  ClusterIP: http://openwebui.ai.svc.cluster.local:8080"
echo ""
echo "If Bifrost is the LLM target, providers must be configured at:"
echo "  https://llm.caehomelab.com  (Settings → Providers)"
echo ""
