# What was fixed

## Issues Found

1. **Litellm** - Missing Deployment resource, container never started
2. **Seaxng** - Crashing due to invalid secret_key ("CHANGE_ME_SECRET_KEY" too short)  
3. **MCPo** - Using non-existent image tag `:main`

## Changes Made

### litellm/kustomization.yaml
- Added missing **Deployment** resource
- Added missing **Ingress** resource
- Added **PersistentVolumeClaim** for config persistence
- Changed image to `ghcr.io/berriai/litellm:latest`
- Added proper volume mounts for config and data

### searxng/kustomization.yaml
- Fixed `secret_key` with proper secure value (32 characters)
- Secret key should be at least 16 characters for SearXNG

### mcpo/kustomization.yaml
- Changed image from `ghcr.io/open-webui/mcpo:main` 
- Changed to `ghcr.io/open-webui/mcpo:v0.0.20` (actual latest release)

## Next Steps

### On util-server (where kubectl is available):

```bash
# 1. Pull the latest changes
cd ~/source/ce-ai-home-lab
git pull origin main

# 2. Deploy fixed applications
./scripts/deploy-litellm.sh
./scripts/deploy-mcpo.sh
./scripts/deploy-searxng.sh
```

### Verify deployments:

```bash
./scripts/check-deployments.sh
```

### Update secrets (before production use):

- **Litellm**: Update `LITELLM_SECRET_KEY` and `LITELLM_MASTER_KEY` in secrets
- **OpenRouter**: Add your actual OpenRouter API key in litellm_settings.yaml
- **Default API key**: Update `osk-DEFAULT` for fallback models

## Troubleshooting

If pods still crash after applying:

```bash
# Check pod logs
kubectl logs <pod-name> -n ai

# Check pod events
kubectl describe pod <pod-name> -n ai
```

## Images Used

| Application | Image | Tag |
|-------------|-------|-----|
| Litellm | ghcr.io/berriai/litellm | latest |
| MCPo | ghcr.io/open-webui/mcpo | v0.0.20 |
| OpenWebUI | ghcr.io/open-webui/open-webui | main |
| Searxng | searxng/searxng | latest |
| Infisical | infisical/infisical-platform | latest |
| PostgreSQL (Infisical DB) | postgres | 16-alpine |
