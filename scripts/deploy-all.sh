#!/bin/bash
# Deploy all applications to the Kubernetes cluster
# Run from the repository root: ./scripts/deploy-all.sh
#
# This script deploys all applications in the correct order:
# 1. litellm - API proxy layer
# 2. litellm-config - Configuration for Open WebUI
# 3. openwebui - Main AI interface (connects to external ollama on aiserver.home)
# 4. infisical - Secrets management
# 5. searxng - Search engine
# 6. mcpo - MCP server
#
# Note: Ollama runs on separate server aiserver.home, not in Kubernetes

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="ai"

echo "=============================================="
echo "Deploying all applications to namespace: $NAMESPACE"
echo "Ollama external host: aiserver.home:11434"
echo "=============================================="

# Step 1: Deploy LiteLLM
echo ""
echo ">>> Step 1: Deploying LiteLLM..."
$SCRIPT_DIR/deploy-litellm.sh

# Step 2: Deploy LiteLLM config
echo ""
echo ">>> Step 2: Deploying LiteLLM config map..."
$SCRIPT_DIR/deploy-litellm-config.sh

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

# Step 6: Deploy MCPo
echo ""
echo ">>> Step 6: Deploying MCPo..."
$SCRIPT_DIR/deploy-mcpo.sh

echo ""
echo "=============================================="
echo "All applications deployed!"
echo "=============================================="
echo ""
echo "Access URLs:"
echo "  OpenWebUI:   https://ai.caehomelab.com"
echo "  Infisical:   https://infisical.caehomelab.com"
echo "  SearXNG:     https://search.caehomelab.com"
echo ""
echo "Run './scripts/check-deployments.sh' to verify all pods are running."
echo ""
