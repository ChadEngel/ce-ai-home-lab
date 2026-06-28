# ce-ai-home-lab

Kubernetes infrastructure and applications for home lab with k3s.

## Overview

This repository contains the GitOps configuration for a single-node k3s Kubernetes cluster used as a home lab environment.

### Technology Stack

- **Kubernetes**: k3s v1.35.5+k3s1
- **Runtime**: containerd
- **Network**: Traefik Ingress (main)
- **Storage**: NFS External Provisioner (nfs-client StorageClass)
- **TLS/SSL**: cert-manager with Let's Encrypt DNS-01 challenge
- **GitOps**: FluxCD for continuous deployment
- **Remote Access**: Tailscale for secure external access

### Internal DNS

All internal services resolve via UDM Pro to `192.168.30.230`:

- ai.caehomelab.com → Open WebUI
- search.caehomelab.com → SearXNG
- grafana.caehomelab.com → Grafana (future)

### Remote Access

Services are accessible via Tailscale using the same internal URLs.

## Repository Structure

```
.
├── PREREQUISITES.md
├── README.md
├── docs/
│   ├── how-to-create-github-ssh-key.md
│   ├── how-to-extend-linux-fs.md
├── homelab_build.md
├── scripts/
└── clusters/
│   └── util-server/
│       ├── namespaces/
│       │   └── ai.yaml
│       ├── networking/
│       │   ├── cert-manager/
│       │   ├── metallb/
│       │   └── traefik/
│       ├── storage/
│       │   └── nfs/
│       └── applications/
│           ├── mcpo/
│           ├── ollama/
│           ├── openwebui/
│           └── searxng/
└── doc/
```

## Deployment

### Prerequisites

For a complete infrastructure requirements overview and architecture diagram, see [`PREREQUISITES.md`](./PREREQUISITES.md)

**System Administration Guides**:
- [SSH Key Setup for GitHub](./docs/how-to-create-github-ssh-key.md) - Create SSH keys for Git authentication
- [Extend Linux Filesystem](./docs/how-to-extend-linux-fs.md) - Add disk space to your Kubernetes node

**Quick checklist**:
- **k3s cluster** with 48GB+ disk space (k3s v1.35.5+k3s1)
- **NFS storage server** (192.168.30.121:/data/pod_data)
- **Internal DNS** configured on UDM Pro
- **Tailscale** configured for remote access
- **GitHub** repository with write access (for GitOps push)
- **Kubectl** configured for the k3s cluster
- **Helm v3** (optional, for chart deployments)

---

## Quick Start - All-in-One Deployment

### Step 1: Clone Repository (SSH)

```bash
# Clone using SSH (recommended)
git clone git@github.com:ChadEngel/ce-ai-home-lab.git
cd ce-ai-home-lab
```

> **Note**: If you haven't set up SSH keys yet, see [How to Create GitHub SSH Keys](./docs/how-to-create-github-ssh-key.md) for setup instructions.

### Step 2: Apply Basic Infrastructure

**Create AI namespace:**
```bash
kubectl apply -f clusters/util-server/namespaces/ai.yaml
```

**Deploy NFS Storage Class:**
```bash
helm repo add nfs-client https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner
helm repo update
helm install nfs-storage nfs-client/nfs-subdir-external-provisioner \
  --namespace ai \
  --create-namespace \
  -f clusters/util-server/storage/nfs/nfs-subdir-external-provisioner-values.yaml
```

**Deploy Traefik:**
```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm install traefik traefik/traefik \
  --namespace kube-system \
  -f clusters/util-server/networking/traefik/values.yaml
```

**Deploy cert-manager:**
```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  -f clusters/util-server/networking/cert-manager/values.yaml
```

**Cloudflare DNS Setup** (Required for TLS certificates):

Before deploying applications with TLS, you need to configure a ClusterIssuer for Let's Encrypt:

1. [GoCloudflare Setup](./docs/how-to-setup-cloudflare-dns-for-cert-manager.md) - Complete setup guide
2. Create Cloudflare DNS credentials secret:
```bash
kubectl create secret generic cloudflare-dns-creds \
  --from-literal=CF_API_TOKEN="your-cloudflare-token-here" \
  -n cert-manager
```
   Or apply the template: `kubectl apply -f clusters/util-server/networking/cert-manager/cloudflare-secrets.yaml`
3. Update email in `clusters/util-server/networking/cert-manager/clusterissuer.yaml`
4. Apply ClusterIssuer: `kubectl apply -f clusters/util-server/networking/cert-manager/clusterissuer.yaml`

**Internal DNS Requirements**:
- UDM Pro DNS must point `*.caehomelab.com` to Traefik at `192.168.30.230` before cert issuance

### Step 3: Deploy Applications (in order)

```bash
# 1. Deploy SearXNG
kubectl apply -f clusters/util-server/applications/searxng/

# 2. Deploy MCPO
kubectl apply -f clusters/util-server/applications/mcpo/

# 3. Deploy Ollama
kubectl apply -f clusters/util-server/applications/ollama/

# 4. Deploy LiteLLM (before OpenWebUI!)
kubectl apply -f clusters/util-server/applications/litellm/

# 5. Deploy Open WebUI
kubectl apply -f clusters/util-server/applications/openwebui/
```

### Step 4: Wait for Pods

```bash
# Check all pods are running
kubectl get pods -n ai

# Check services
kubectl get svc -n ai

# Check ingress
kubectl get ingress -n ai
```

### Step 5: Verify Deployment

```bash
# All applications should be running
kubectl get pods -n ai | grep Running

# Check storage classes
kubectl get storageclass

# Verify Ingress created successfully
kubectl describe ingress -n ai
```

---

## Detailed Deployment Instructions

### Option A: Manual Deployment (Recommended for first time)

1. **Create namespace:**
```bash
kubectl apply -f clusters/util-server/namespaces/ai.yaml
```

2. **Deploy Storage:**
```bash
# NFS StorageClass
helm install \
  nfs-storage \
  oci://registry.nfs-client.io/nfs-subdir-external-provisioner \
  --namespace ai \
  --set nfs.server=192.168.30.121 \
  --set nfs.path=/data/pod_data \
  --set storageClass.name=nfs-client \
  --set storageClass.defaultClass=true
```

3. **Deploy Networking:**
```bash
# Traefik Ingress Controller
helm install traefik traefik/traefik \
  --namespace kube-system \
  -f clusters/util-server/networking/traefik/values.yaml

# cert-manager
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  -f clusters/util-server/networking/cert-manager/values.yaml

# Wait for cert-manager to create ClusterIssuer
kubectl apply -f clusters/util-server/networking/cert-manager/clusterissuer.yaml
```

4. **Deploy Applications:**
```bash
# Order matters: LiteLLM before OpenWebUI
# SearXNG - Search engine
kubectl apply -f clusters/util-server/applications/searxng/

# MCPO - MCP Server (no ingress)
kubectl apply -f clusters/util-server/applications/mcpo/

# Ollama - Local LLM runtime
kubectl apply -f clusters/util-server/applications/ollama/

# LiteLLM - Unified LLM proxy
kubectl apply -f clusters/util-server/applications/litellm/

# IMPORTANT: Update LiteLLM with your API keys before deploying OpenWebUI
# Edit the secrets in: clusters/util-server/applications/litellm/kustomization.yaml
# Then apply:
kubectl apply -f clusters/util-server/applications/openwebui/
```

### Option B: GitOps with FluxCD

See [`clusters/util-server/flux/README.md`](./clusters/util-server/flux/README.md) for detailed instructions.

1. **Install FluxCD:**
```bash
# Install FluxCD to the cluster
flux install \
  --namespace=flux-system \
  --components=source-controller
```

2. **Configure Git Repository:**
```bash
# Create secret for GitHub authentication
cd clusters/util-server/flux
./flux-install.sh
```

3. **Apply Infrastructure First:**
```bash
flux create ks infrastructure \
  --namespace=ai \
  --path=./clusters/util-server \
  --source=GitRepository/ce-ai-home-lab \
  --interval=5m \
  --prune=true
```

4. **Monitor Deployment:**
```bash
flux get reconciliations
flux get kustomizations
kubectl get events -n ai
```

---

## Configuration Files

### Update LiteLLM API Keys

Edit `clusters/util-server/applications/litellm/kustomization.yaml` and update:

```yaml
stringData:
  LITELLM_SECRET_KEY: "sk-litellm-secret-key-your-secure-key"
  LITELLM_MASTER_KEY: "sk-litellm-master-key-your-secure-key"
  OSK_OPENROUTER_API_KEY: "osk-your-openrouter-api-key"
```

### Update OpenWebUI to Use LiteLLM

After LiteLLM is deployed, update OpenWebUI's environment variable:
```yaml
env:
  - name: OLLAMA_BASE_URL
    value: "http://litellm-api.ai.svc.cluster.local:4000/v1"
```

---

## Application URLs

| Application | Public URL | Internal URL | Notes |
|-------------|------------|--------------|-------|
| **Open WebUI** | https://ai.caehomelab.com | http://openwebui:8080 | Main LLM UI |
| **LiteLLM** | https://llm.caehomelab.com | http://litellm-api:4000 | Unified LLM proxy |
| **SearXNG** | https://search.caehomelab.com | http://searxng-api:8080 | Search engine |
| **MCPO** | ClusterIP only | http://mcpo:8000 | MCP Server (no ingress) |
| **Ollama** | ClusterIP only | http://ollama-api:11434 | Local LLM (no ingress) |

---

## Monitoring & Troubleshooting

### Check Pod Status
```bash
kubectl get pods -n ai
```

### View Pod Logs
```bash
kubectl logs -f <pod-name> -n ai
```

### Check Storage Class
```bash
kubectl get storageclass
kubectl get pvc -n ai
```

### View Ingress Status
```bash
kubectl get ingress -n ai
kubectl describe ingress -n ai
```

### Check Certificate Status
```bash
kubectl get certificate -n ai
kubectl describe certificate <certificate-name> -n ai
```

### FluxCD Health (if using GitOps)
```bash
flux get components
flux get sources git -n flux-system
flux get kustomizations -n ai
flux get reconciliations -n ai
```

---

## Applications

| Application | Namespace | Type | Port | Description |
|-------------|-----------|------|------|-------------|
| **Open WebUI** | ai | Ingress | 443 | LLM Interface WebUI with MCP support |
| **LiteLLM** | ai | Ingress | 4000 | Unified LLM proxy (Ollama + OpenRouter) |
| **MCPO** | ai | ClusterIP | 8000 | Model Context Protocol Server |
| **Ollama** | ai | ClusterIP | 11434 | Local LLM runtime |
| **SearXNG** | ai | Ingress | 443 | Search engine |

---

## Architecture

```
                    ┌─────┐
                    │Internet───│
                    └─┬───┘
                       │
                  ┌───────┐
                  │DNS-01 │ (Let's Encrypt validation)
                  └──┬────
                       │
            ┌──────────┴──────────┐
            │ cert-manager        │
            │ + UDM Pro DNS       │
            └────┬────────────┬───┘
                 │           │
                 ▼           ▼
            ┌─────────┐  ┌──────────┐
            │DNS:ai.  │  │DNS:search│
            │         │  │          │
            └────┬────┘  └────┬─────┘
                 │           │
                 ▼           ▼
            ┌────────────────────────┐
            │  UDM Pro (all resolve)│
            │  to 192.168.30.230     │
            └────┬───────────────────┘
                 │
                 ▼
            ┌──────────┐
            │ Traefik  │
            │ Ingress  │
            │ (192.168.│
            │ 30.230)   │
            └────┬─────┘
                 │
   ┌─────────────┼─────────────┐
   │             │             │
   ▼             ▼             ▼
┌────────┐  ┌──────────┐  ┌───────┐
│Open    │  │ SearXNG  │  │ LiteLL│
│ WebUI  │  │          │  │  M    │
│        │  │          │  │       │
└───┬────┘  └────┬─────┘  └───┬───┘
    │           │            │
    ▼           ▼            ▼
┌────┐      ┌────────────┐  │
│MCPO│      │ Ollama     │  │
│(CIP)│     │ (CIP)      │  │
└────┘      └────────────┘  │
                           │
                    ┌──────┴──────┐
                    │OpenRouter   │
                    │(API access) │
                    └─────────────┘
```

---

## Documentation & Resources

- **Build Notes:** [`homelab_build.md`](./homelab_build.md)
- **FluxCD Instructions:** [`clusters/util-server/flux/README.md`](./clusters/util-server/flux/README.md)
- **Kubernetes k3s:** https://k3s.io
- **Traefik Ingress:** https://traefik.io
- **cert-manager:** https://cert-manager.io
- **LiteLLM:** https://github.com/BerriAI/litellm

---

## Support

For issues, check:
1. Pod logs: `kubectl logs <pod-name> -n ai`
2. Events: `kubectl get events -n ai`
3. Ingress status: `kubectl describe ingress -n ai`
4. Storage: `kubectl get pvc -n ai`

---

## License

MIT

## Applications

| Application | Namespace | Internal URL | Description |
|-------------|-----------|--------------|-------------|
| Open WebUI | ai | ai.caehomelab.com | LLM UI |
| MCPO | ai | ClusterIP only | MCP Server |
| SearXNG | ai | search.caehomelab.com | Search engine |
| Ollama | ai | ClusterIP only | Local LLM runtime |

## Services

```
                    ┌────────────┐
                    │ Internet   │
                    └─────┬──────┘
                          │
                    ┌─────▼──────┐
                    │ DNS-01     │ (Let's Encrypt)
                    └─────┬──────┘
                          │
                    ┌─────▼──────────────────────────────┐
                    │ cert-manager + Internal DNS        │
                    └─────────┬──────────────────────────┘
                              │
              ┌───────────────▼────────────────┐
              │  UDM Pro DNS (192.168.30.121) │
              └─────────┬─────────────────────┘
                        │
                        ▼
                ┌───────────────┐
                │ ui.caehomelab.com │
                │               │ (192.168.30.230)
                └───────┬───────┘
                        │
                    ┌───▼───────┐
                    │ Traefik  │
                    │ Ingress  │
                    └─────┬─────┘
                          │
              ┌───────────▼───────────┐
              │  Open WebUI           │
              │  MCPO (ClusterIP)     │
              │  SearXNG              │
              │  Ollama (ClusterIP)   │
              └───────────────────────┘
```

## Testing & Validation

After deployment, verify all components are running correctly:

```bash
# Run the deployment test script
./scripts/deployment-test.sh

# Test specific namespace
./scripts/deployment-test.sh my-namespace

# Expected results:
# - All pod statuses should show Running
# - All services should be available
# - Ingress configurations should be applied
# - Certificates should be issued
# - Storage should be bound
# - Network connectivity should work
```

For detailed test coverage, see the [test script documentation](./scripts/deployment-test.sh).

## Documentation

- **Deployment Guide**: [`README.md`](./README.md) - Comprehensive setup instructions
- **Infrastructure Requirements**: [`PREREQUISITES.md`](./PREREQUISITES.md) - Hardware, network, and storage requirements
- **Build Notes**: [`homelab_build.md`](./homelab_build.md) - Detailed build process and lessons learned
- **FluxCD Setup**: [`clusters/util-server/flux/README.md`](./clusters/util-server/flux/README.md) - GitOps configuration
- **System Administration**:
  - [GitHub SSH Key Setup](./docs/how-to-create-github-ssh-key.md) - Authentication and security
  - [Linux Storage Extension](./docs/how-to-extend-linux-fs.md) - Disk management for your node
- **Testing**: [`scripts/deployment-test.sh`](./scripts/deployment-test.sh) - Automated validation

## License

MIT


## 📋 Current Infrastructure Status (Updated 2026-06-28)

### ✅ Working Services

| Service | URL | Status | Notes |
|---------|-----|--------|-------|
| **LiteLLM** | https://llm.caehomelab.com | ✅ Running | Swagger UI accessible, proxy service running |
| **OpenWebUI** | https://ai.caehomelab.com | ✅ Running | Web UI accessible with websockets/SSL working |
| **SearXNG** | https://search.caehomelab.com | ✅ Running | Search engine working |
| **cert-manager** | - | ✅ Ready | All 4 certificates issued (letsencrypt-prod) |
| **Traefik** | 192.168.30.217 | ✅ Running | LoadBalancer ingress controller |
| **MetalLB** | 192.168.30.217 | ✅ Running | IP pool: 192.168.30.230-240 |
| **NFS Provisioner** | 192.168.30.121:/data/pod_data | ✅ Running | StorageClass: nfs-client |

### ⚠️ Known Issues

#### 1. Infisical - Image Pull Error
- **Service**: https://secrets.caehomelab.com (ingress created, certificate issued)
- **Issue**: `ImagePullBackOff` / `ErrImagePull` for all Infisical images
- **Attempted**: 
  - `ghcr.io/infisical/infisical-platform:latest` → 403 Forbidden
  - `infisical/infisical-platform:latest` → ErrImagePull
  - `infisical/platform-backend:latest` → ErrImagePull

**Resolution Required**: The official Infisical Docker images are either private or have been moved/renamed. You'll need to either:
- Provide Docker Hub credentials in the cluster
- Build your own Docker image from the Infisical source code
- Use a different version/tag of the Infisical image

#### 2. DNS Resolution Fix Required
- All domains (`ai.caehomelab.com`, `llm.caehomelab.com`, `search.caehomelab.com`, `secrets.caehomelab.com`)
- Set their A records to point to **192.168.30.217** (Traefik LB IP), NOT 192.168.30.230 (old IP)

**Fix applied via Cloudflare API** on 2026-06-28. If you need to fix DNS again in the future:

```bash
TOKEN="your-cloudflare-token"
ZONE=$(curl -s "https://api.cloudflare.com/client/v4/zones?name=caehomelab.com" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
for DOMAIN in ai.caehomelab.com search.caehomelab.com secrets.caehomelab.com llm.caehomelab.com; do
  curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?type=A&name=$DOMAIN" | grep -o '"id":"[^"]*" | head -1
done
```

### 📦 Certificates (All Issued by Let's Encrypt)
- `llm.caehomelab.com` → `litellm-tls` ✅
- `ai.caehomelab.com` → `openwebui-tls` ✅
- `search.caehomelab.com` → `searxng-tls` ✅
- `secrets.caehomelab.com` → `infisical-ssl-certs` ✅ (ready, but Infisical needs to be running)

### 📁 Config Changes Applied
1. **cloudflare-secrets.yaml** → Updated with real Cloudflare API token
2. **searxng/_values/values.yaml** → Fixed locale (`en` instead of `en-US`), added bot_detection disabled
3. **openwebui/_values/values.yaml** → Added proper env vars (HF_HUB_OFFLINE, RAG_EMBEDDING_ENGINE, etc)
4. **clusterissuer.yaml** → Updated Cloudflare token placeholder
5. **Ingress classes** → Changed from `traefik-v2` to `traefik` (k3s addon compatibility)

### 🔑 Cloudflare DNS Records
All A records for caehomelab.com domains point to **192.168.30.217** (Traefik LoadBalancer IP)

### 🛠️ Troubleshooting Notes
- **Traefik addon in k3s**: Uses `ingressClassName: traefik` (NOT `traefik-v2`)
- **SearXNG bot detection**: Had to disable `limiter` and `bot_detection` to avoid X-Forwarded-For requirements
- **OpenWebUI**: Must set `HF_HUB_OFFLINE=1` to avoid infinite HuggingFace sync
- **LiteLLM**: Running as single pod proxy for AI model routing
