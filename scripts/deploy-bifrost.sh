#!/bin/bash
# Deploy Bifrost (AI Gateway) to the Kubernetes cluster
# Runs on port 8080 and is configured entirely via its web UI.
# Run from the repository root: ./scripts/deploy-bifrost.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications/bifrost"
NAMESPACE="ai"

echo "Deploying Bifrost AI Gateway to namespace: $NAMESPACE"

kubectl apply --namespace="$NAMESPACE" -f "$APPS_DIR/kustomization.yaml"

echo ""
echo "Bifrost deployment completed!"
echo "  ClusterIP: http://bifrost-api.ai.svc.cluster.local:8080"
echo "  Web UI:    https://llm.caehomelab.com"
echo ""
echo "Next steps:"
echo "  1. Configure providers via the web UI (Settings → Providers):"
echo "       - Ollama:     base_url=http://aiserver.home:11434"
echo "       - OpenRouter: api_key=<your-key>"
echo "  2. Verify with curl:"
echo "       curl https://llm.caehomelab.com/v1/models \\"
echo "         -H \"Authorization: Bearer sk-bifrost-secret-key-change-me\""
echo ""
