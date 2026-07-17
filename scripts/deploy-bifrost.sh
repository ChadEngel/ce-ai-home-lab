#!/bin/bash
# Deploy Bifrost (AI Gateway) to the Kubernetes cluster
# Runs on port 8080 — replaces LiteLLM as the LLM proxy layer.
# Run from the repository root: ./scripts/deploy-bifrost.sh
#
# IMPORTANT: After deployment:
#   1. Visit https://llm.caehomelab.com in a browser
#   2. Use the web UI to configure your providers (Ollama, OpenRouter, etc.)
#      - Provider keys are entered via the "Settings" → "Providers" tab
#      - Model names use format: provider/model  (e.g., ollama/chat/llama3)
#   3. Update openwebui-ollama-config.yaml if needed

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications"
NAMESPACE="ai"

echo "Deploying Bifrost AI Gateway to namespace: $NAMESPACE"
echo ""

# Apply Kustomization resources (Service, PVC, Secret, Deployment, Ingress)
kubectl apply --namespace="$NAMESPACE" -f "$APPS_DIR/bifrost/kustomization.yaml" --validate=false

echo ""
echo "Bifrost deployment completed!"
echo "  Service endpoint: http://bifrost-api.ai.svc.cluster.local:8080"
echo "  Web UI:           https://llm.caehomelab.com"
echo ""
echo "Next steps:"
echo "  1. Configure providers via the web UI (Settings → Providers)"
echo "     - Ollama:    provider=ollama, base_url=http://aiserver.home:11434"
echo "     - OpenRouter: provider=openrouter, api_key=<your-key>"
echo "  2. Verify with curl:"
echo "     curl https://llm.caehomelab.com/v1/models -H \"Authorization: Bearer sk-bifrost-secret-key-change-me\""
echo "  3. Update openwebui-ollama-config.yaml OLLAMA_BASE_URL if OpenWebUI still uses old endpoint"
