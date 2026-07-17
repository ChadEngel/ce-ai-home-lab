# Deployment Scripts

This directory contains deployment scripts for all applications in the home lab.

## Prerequisites

- `kubectl` must be installed and configured to connect to your Kubernetes cluster
- The applications require a PersistentVolumeClass named `nfs-client` to be available
- Cert-manager must be installed and configured for ingress TLS certificates

## Quick Start

### Deploy All Applications
```bash
./scripts/deploy-all.sh
```
Deploys all applications in the correct dependency order.

**Note**: Ollama runs on external server `aiserver.home:11434`, not in Kubernetes.

### Check Deployment Status
```bash
./scripts/check-deployments.sh
```
Verifies all pods and services are running correctly.

## Deployment Scripts

### OpenWebUI
```bash
./deploy-openwebui.sh
```
Deploys OpenWebUI with the AI web interface.
- Access URL: https://ai.caehomelab.com
- Dependencies: LiteLLM (API proxy), Ollama (external on aiserver.home)
- Ollama API: http://aiserver.home:11434

### Bifrost (AI Gateway) — replaces LiteLLM
```
./deploy-bifrost.sh
```
Deploys the Bifrost AI gateway on port 8080.
- Service endpoint: http://bifrost-api.ai.svc.cluster.local:8080
- **Web UI**: https://llm.caehomelab.com — configure your providers after deployment (Settings → Providers)
- **IMPORTANT**: Set provider API keys via the web UI. Model names use `provider/model` format:
  - Ollama:       `ollama/chat/llama3`
  - OpenRouter:   `openrouter/meta-llama/llama-3-70b-instruct`

### Bifrost Config for OpenWebUI
```
kubectl apply -f clusters/util-server/applications/openwebui/bifrost-config.yaml
```
Updates the OpenWebUI configMap to point to the Bifrost API gateway.
- Required for OpenWebUI to connect to LiteLLM models.

### MCPo
```bash
./deploy-mcpo.sh
```
Deploys MCPo (Model Context Protocol Server).
- Service endpoint: http://mcpo.ai.svc.cluster.local:8000

### Ollama

**Ollama runs on external server**, not in Kubernetes.

- **Server**: `aiserver.home:11434`
- **Access**: Direct connection from your local machine to the separate Ollama server
- Storage and compute resources fully available on the external machine

### SearXNG
```bash
./deploy-searxng.sh
```
Deploys SearXNG search engine.
- Access URL: https://search.caehomelab.com
- IMPORTANT: Set the secret_key in settings.yml before production use.

### Infisical
```bash
./deploy-infisical.sh
```
Deploys Infisical for secrets management.
- Access URL: https://infisical.caehomelab.com
- IMPORTANT: Set up initial admin credentials after deployment.

## Deployment Order

For the best results, deploy Kubernetes applications in this order:

1. **bifrost** - AI gateway (configure providers via web UI at https://llm.caehomelab.com)
2. **openwebui** - Main AI interface (requires Bifrost running on :8080)
3. **infisical** - Secrets management
4. **searxng** - Search engine (standalone, no dependencies)

## Migration Notes: LiteLLM ➜ Bifrost

Bifrost is a drop-in replacement for LiteLLM at the network level:
- Same hostname: `llm.caehomelab.com` (`/v1/chat/completions` compatible)
- OpenWebUI config updated: `OLLAMA_BASE_URL=http://bifrost-api.ai.svc.cluster.local:8080/v1`
- Port changed: 4000 ➜ 8080
- Model names change format:
  - LiteLLM style:   `ollama/chat/llama3`, `openrouter/meta-llama/...` (same)
  - OpenWebUI config: points to `bifrost-api` service instead of `litellm-api`
- **Key difference**: Bifrost is configured via its web UI (**not** YAML config files). Deploy first, then visit the Ingress to set up providers.

**Note**: MCPo not deployed (no published Docker images available yet)

Note: All Kubernetes applications connect to external Ollama server at `aiserver.home:11434`.

## Troubleshooting

### kubectl apply -f directory/ fails with validation errors

This happens because the application directories contain `_values/values.yaml` files which are Helm-style values, not Kubernetes resources. When running `kubectl apply -f <directory>/`, kubectl tries to apply ALL yaml files, including these values files, which lack the required `apiVersion` and `kind` fields.

**Solution**: Always use the deployment scripts or apply specific files:
```bash
# Run from repository root, from scripts directory:
./scripts/deploy-searxng.sh

# Or apply kustomization directly:
kubectl apply -f clusters/util-server/applications/searxng/kustomization.yaml
```

### SSL certificate conflicts with cert-manager

If you see errors about the `infisical-ssl-certs` secret conflict, the `ssl-certs.yaml` file should only contain the Certificate resource. Cert-manager automatically creates the TLS secret when processing the Certificate.

### Secrets not being picked up by deployments

After updating secrets, restart deployments:

```bash
kubectl rollout restart deployment/<deployment-name> -n ai
```

## Checking Deployment Status

```bash
# Check pods
kubectl get pods -n ai

# Check for errors
kubectl describe deployments -n ai

# View logs
kubectl logs -n ai deployment/<deployment-name>
```
