# Deployment Status Report

**Date:** 2026-06-28  
**Cluster:** util-server (K3s v1.35.5)  
**Status:** 3/4 services operational

## 🔧 Issues Resolved

### 1. Cloudflare DNS Token Authentication
- **Problem:** Cloudflare API token was set to placeholder `"your-cloudflare-api-token-here"`
- **Impact:** Cert-manager DNS-01 validation failed with `Invalid format for Authorization header`
- **Fix:** Updated token to `CLOUDFLARE_TOKEN_REDACTED`

### 2. Ingress Class Mismatch
- **Problem:** Kubernetes ingresses had `ingressClassName: traefik-v2`
- **Impact:** k3s Traefik addon ignores these rules (expects `traefik`)
- **Fix:** Changed to `ingressClassName: traefik`

### 3. DNS IP Address Mismatch
- **Problem:** DNS A records pointed to `192.168.30.230`, but Traefik LB is at `192.168.30.217`
- **Impact:** Browser hits wrong IP, gets 404 from Traefik's catch-all
- **Fix:** Updated all DNS A records to `192.168.30.217` (Traefik LB IP)

### 4. SearXNG CrashLoopBackOff - Locale Issue
- **Problem:** `ui.default_locale: "en-US"` not valid in SearXNG 2026
- **Impact:** Pod crashLoopBackOff
- **Fix:** Changed to `ui.default_locale: "en"`

### 5. OpenWebUI OOM Kill + Embedding Issue
- **Problem:** `RAG_EMBEDDING_ENGINE: "off"` is not a valid option
- **Impact:** Container crash with ValueError
- **Fix:** Changed to `RAG_EMBEDDING_ENGINE: "ollama"` (uses local Ollama)

### 6. OpenWebUI HuggingFace Hub Sync
- **Problem:** OpenWebUI tries to sync models from HF Hub causing infinite loop
- **Impact:** Service never starts
- **Fix:** Added `HF_HUB_OFFLINE=1` environment variable

### 7. NFS Provisioner Deleted with Namespace
- **Problem:** NFS provisioner was deleted when namespace was force-deleted
- **Impact:** PVCs stuck Pending (no provisioner to create PVs)
- **Fix:** Recreated NFS provisioner deployment with proper RBAC

## 📦 Services Status

| Service | URL | Ingress | Certificate | Status |
|---------|-----|--------|-------|------|
| **LiteLLM** | https://llm.caehomelab.com | ✅ traefik | ✅ letsencrypt-prod | **OPERATIONAL** |
| **OpenWebUI** | https://ai.caehomelab.com | ✅ traefik | ✅ letsencrypt-prod | **OPERATIONAL** |
| **SearXNG** | https://search.caehomelab.com | ✅ traefik | ✅ letsencrypt-prod | **OPERATIONAL** |
| **Infisical** | https://secrets.caehomelab.com | ✅ traefik | ✅ issued (unused) | **DOWN** - image pull error |

## ⚠️ Remaining Issue: Infisical Image

**Problem:** `infisical/infisical-platform` does not exist on Docker Hub.

**Troubleshooting steps taken:**
- Tried `ghcr.io/infisical/infisical-platform:latest` → 403 Forbidden
- Tried `infisical/infisical-platform:latest` → ErrImagePull (image not found)
- Tried `infisical/platform-backend:latest` → ErrImagePull
- Checked Docker Hub API - repo doesn't exist

**Action required:**
1. Check if Infisical has moved their Docker images to a different registry
2. Build a custom Docker image from the Infisical source code
3. Or use an older version of the Infisical that still has public images

## 📋 Config Files Updated

| File | Change Made |
|------|-----------|
| `cloudflare-secrets.yaml` | Replaced placeholder Cloudflare token with actual value |
| `searxng/_values/values.yaml` | Fixed locale, disabled bot_detection, updated settings |
| `openwebui/_values/values.yaml` | Added HF_HUB_OFFLINE, RAG_EMBEDDING_ENGINE, corrected env vars |
| `infisical/kustomization.yaml` | Changed ingressClassName from traefik-v2 to traefik |
| `clusterissuer.yaml` | Replaced placeholder Cloudflare token |
| `README.md` | Added current infrastructure status and troubleshooting notes |

## 🔍 Verification Commands

Test each service:
```bash
# Test LiteLLM
curl -sk https://llm.caehomelab.com/ | grep -i swagger

# Test OpenWebUI  
curl -sk https://ai.caehomelab.com/ | grep -i "Open WebUI"

# Test SearXNG
curl -sk https://search.caehomelab.com/ | grep -i "SearXNG"

# Check certificates
kubectl get certificates -n ai
```

## 🚀 Next Steps

1. **Fix Infisical:** Find correct Docker image or build custom
2. **Document:** Create setup guide for new cluster deployments
3. **Monitor:** Check certificate renewal (90-day Let's Encrypt cycles)
4. **Backup:** Run `kubectl get all -n ai -o yaml > backup.yaml`
5. **Test:** Verify all services handle TLS termination correctly
