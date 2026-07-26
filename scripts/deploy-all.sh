#!/bin/bash
# Deploy all applications to the Kubernetes cluster
# Run from the repository root: ./scripts/deploy-all.sh
#
# Deploy order is deliberate: Infisical and its Kubernetes Operator come
# FIRST so that Infisical-managed secrets (Cloudflare token, InfluxDB
# token) are available as native K8s Secrets before any service that
# depends on them is deployed. cert-manager needs cloudflare-dns-creds
# to issue TLS certs for every service; Grafana needs influxdb-secrets.
#
#   1. infisical          - Secrets manager (self-hosted, in-cluster)
#   2. infisical-operator - K8s operator syncing Infisical -> K8s Secrets
#   3. bifrost            - AI gateway (replaces LiteLLM; configure providers via web UI)
#                          Ollama model syntax:        ollama/chat/llama3
#                          OpenRouter model syntax:    openrouter/meta-llama/llama-3-70b-instruct
#   4. openwebui          - Main AI interface (connects to bifrost-api on :8080)
#   5. searxng            - Search engine
#   6. grafana            - Monitoring dashboard (needs influxdb-secrets from Infisical)
#   7. loki               - Log aggregation (Loki + Promtail syslog intake for the UDM)
#
# Note: MCPo is not deployed (no published Docker images yet)
# Note: Ollama runs on separate server aiserver.home, not in Kubernetes
#
# One-time prerequisites BEFORE first run (see clusters/util-server/applications/infisical-operator/README.md):
#   - Infisical admin account created at https://secrets.caehomelab.com
#   - `secret-management` project + `prod` environment holding the secrets
#   - Machine Identity `homelab-k8s-operator` (Universal Auth, Viewer role)
#   - K8s Secret `infisical-universal-auth` in namespace `ai` with the
#     machine identity's clientId/clientSecret

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="ai"

echo "=============================================="
echo "Deploying all applications to namespace: $NAMESPACE"
echo "Order: infisical -> operator -> apps"
echo "Bifrost AI gateway: llm.caehomelab.com (port 8080)"
echo "Ollama external host: aiserver.home:11434"
echo "=============================================="

# Step 1: Deploy Infisical (must be first — it holds the secrets)
echo ""
echo ">>> Step 1: Deploying Infisical (secrets manager)..."
$SCRIPT_DIR/deploy-infisical.sh

# Step 2: Deploy Infisical Kubernetes Operator (syncs Infisical -> K8s Secrets)
echo ""
echo ">>> Step 2: Deploying Infisical Kubernetes Operator..."
$SCRIPT_DIR/deploy-infisical-operator.sh

# Step 3: Deploy Bifrost AI Gateway (replaces LiteLLM)
echo ""
echo ">>> Step 3: Deploying Bifrost AI Gateway..."
$SCRIPT_DIR/deploy-bifrost.sh

# Step 4: Deploy OpenWebUI
echo ""
echo ">>> Step 4: Deploying OpenWebUI..."
$SCRIPT_DIR/deploy-openwebui.sh

# Step 5: Deploy SearXNG
echo ""
echo ">>> Step 5: Deploying SearXNG..."
$SCRIPT_DIR/deploy-searxng.sh

# Step 6: Deploy Grafana
# (Loki is deployed after Grafana so the Loki datasource in Grafana's
# provisioning ConfigMap has a live backend to health-check on first boot.)
echo ""
echo ">>> Step 6: Deploying Grafana..."
$SCRIPT_DIR/deploy-grafana.sh

# Step 7: Deploy Loki + Promtail (log aggregation; UDM syslog intake)
echo ""
echo ">>> Step 7: Deploying Loki + Promtail..."
$SCRIPT_DIR/deploy-loki.sh

# Grafana must be restarted so its datasource init container re-renders the
# Loki entry (added to grafana-datasources ConfigMap) on a fresh pod boot.
echo ""
echo ">>> Restarting Grafana to pick up the Loki datasource..."
kubectl -n "$NAMESPACE" rollout restart deployment/grafana
kubectl -n "$NAMESPACE" rollout status deployment/grafana --timeout=180s

echo ""
echo "=============================================="
echo "All applications deployed!"
echo "=============================================="
echo ""
echo "Access URLs:"
echo "  OpenWebUI:   https://ai.caehomelab.com"
echo "  Bifrost API: https://llm.caehomelab.com  (configure providers via web UI)"
echo "  Infisical:   https://secrets.caehomelab.com"
echo "  Grafana:     https://grafana.caehomelab.com"
echo "  Loki:        https://loki.caehomelab.com   (UDM syslog -> 192.168.30.217:30014 UDP, 15-day retention)"
echo ""
echo "Run './scripts/deployment-test.sh' to verify everything is healthy."
echo ""