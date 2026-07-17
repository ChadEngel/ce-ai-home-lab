#!/bin/bash
# Deploy all applications to the Kubernetes cluster
# Run from the repository root: ./scripts/deploy-all.sh
#
# This script deploys all applications in the correct order:
# 1. bifrost    - AI gateway (replaces LiteLLM; configure providers via web UI)
#                Ollama model syntax:        ollama/chat/llama3
#                OpenRouter model syntax:     openrouter/meta-llama/llama-3-70b-instruct
# 2. openwebui  - Main AI interface (connects to bifrost-api on :8080)
# 3. infisical  - Secrets management
# 4. searxng    - Search engine
# 5. grafana    - Monitoring dashboard
#
# Note: MCPo is not deployed (no published Docker images yet)
# Note: Ollama runs on separate server aiserver.home, not in Kubernetes

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="ai"

echo "=============================================="
echo "Deploying all applications to namespace: $NAMESPACE"
echo "Bifrost AI gateway: llm.caehomelab.com (port 8080)"
echo "Ollama external host: aiserver.home:11434"
echo "=============================================="

# Step 1: Deploy Bifrost AI Gateway (replaces LiteLLM)
echo ""
echo ">>> Step 1: Deploying Bifrost AI Gateway..."
$SCRIPT_DIR/deploy-bifrost.sh

# Step 2: Update OpenWebUI config for Bifrost endpoint
echo ""
echo ">>> Step 2: Updating OpenWebUI LLM gateway endpoint..."
kubectl apply --namespace="$NAMESPACE" \
  -f "$SCRIPT_DIR/../clusters/util-server/applications/openwebui/bifrost-config.yaml"

# Step 3: Deploy OpenWebUI
echo ""
echo ">>> Step 3: Deploying OpenWebUI..."
$SCRIPT_DIR/deploy-openwebui.sh

# Step 4: Deploy Infisical
echo ""
echo ">>> Step 4: Deploying Infisical..."
$SCRIPT_DIR/deploy-infisical.sh

# Step 5: Deploy SearXNG
echo ""
echo ">>> Step 5: Deploying SearXNG..."
$SCRIPT_DIR/deploy-searxng.sh

# Step 6: Deploy Grafana
echo ""
echo ">>> Step 6: Deploying Grafana..."
$SCRIPT_DIR/deploy-grafana.sh

echo ""
echo "=============================================="
echo "All applications deployed!"
echo "=============================================="
echo ""
echo "Access URLs:"
echo "  OpenWebUI:   https://ai.caehomelab.com"
echo "  Bifrost API: https://llm.caehomelab.com  (configure providers via web UI)"
echo "  Infisical:   https://infisical.caehomelab.com"
echo "  Grafana:     https://grafana.caehomelab.com"
echo ""
echo "Run './scripts/check-deployments.sh' to verify all pods are running."
echo ""
