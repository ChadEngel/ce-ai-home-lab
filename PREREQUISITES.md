# Prerequisites

This document outlines all infrastructure requirements and prerequisites needed to deploy the ce-ai-home-lab Kubernetes environment.

---

## Overview

This home lab Kubernetes environment is designed for a **single-node k3s cluster** running on Ubuntu Linux. It uses persistent storage, a unified LLM proxy, and GitOps for automated deployments.

The architecture leverages **NFS storage**, **TLS certificates**, **Ingress routing**, and **GitOps automation** to create a self-managing, reproducible infrastructure.

---

## Infrastructure Requirements

### Minimum Hardware

| Resource | Minimum | Recommended |
|-----------|----------|-------------|
| **CPU** | 4 cores | 8+ cores |
| **RAM** | 8 GB | 16+ GB |
| **Disk** | 48 GB | 100+ GB NVMe SSD |
| **Network** | 1 GbE | 2.5 GbE+ |

### Network Requirements

- **Static IP** for k3s node (recommended: `192.168.30.217`)
- **Internal DNS** server (UDM Pro or similar)
- **Open ports**:
  - `443/TCP` - HTTPS traffic (Ingress)
  - `80/TCP` - HTTP (for Let's Encrypt DNS-01 validation)
  - `8443/TCP` - Tailscale
- **External DNS** configured for:
  - `ai.example.com`
  - `llm.example.com`
  - `secrets.example.com`
  - `search.example.com`

### Storage Requirements

| Component | Storage | Notes |
|-----------|---------|-------|
| **Root filesystem** | 48+ GB | For system + container images |
| **NFS Server** | 100+ GB | For persistent volumes |
| **NFS Share Path** | `/data/pod_data` | Mounted on k3s node |

---

## Software Requirements

### Host System

- **OS**: Ubuntu 26.04 LTS (or 22.04 LTS)
- **Kernel**: 5.15+ (newer preferred)
- **Package Manager**: `apt`

### Kubernetes Components

| Component | Version | Notes |
|-----------|---------|-------|
| **k3s** | v1.35.5+k3s1 | Single-node cluster |
| **containerd** | Latest | Container runtime (included in k3s) |
| **Helm** | v3.x | Chart management (optional) |
| **kubectl** | Latest | CLI for cluster management |

### External Dependencies

| Service | Type | Purpose |
|---------|------|---------|
| **UDM Pro** | Internal DNS | DNS resolution for internal URLs |
| **NFS Server** | Storage | Persistent volume backend |
| **GitHub** | VCS | Git repository for manifests |
| **Let's Encrypt** | CA | TLS certificate authority |

---

## Architecture Overview

```
┌────────────────────────────────────────────────────────────────────┐
│                           INTERNET                                 │
└──────────────────────┬─────────────────────────────────────────────┘
                       │
                 ┌─────▼─────┐
                 │ DNS-01    │  Let's Encrypt challenge validation
                 │ validation│  (Public DNS used only for cert issuance)
                 └─────┬─────┘
                       │
           ┌───────────▼──────────────────┐
           │    Internet DNS              │
           │    (public domain)           │
           │    ai.example.com            │
           │    llm.example.com           │
           │    secrets.example.com       │
           │    search.example.com        │
           └───────┬──────────────────────┘
                   │
                   ▼
        ┌──────────────────────────────┐
        │         cert-manager          │
        │        ClusterIssuer          │
        │    (DNS-01 challenge)         │
        └───────┬──────────────────────┘
                │
                ▼
        ┌──────────────────────────────┐
        │      UDM Pro DNS              │
        │      192.168.30.121           │
        │   Internal resolution         │
        │      to .230                  │
        └───────┬──────────────────────┘
                │
                ▼
        ┌──────────────────────────────┐
        │      Traefik Ingress          │
        │    192.168.30.230             │
        │   Load Balancer + Router      │
        └───────┬──────────────────────┘
                │
                ├─────────────────────────────────────────────┐
                │                                              │
                ▼                                              ▼
        ┌───────────────┐                          ┌─────────────────┐
        │ Open WebUI    │                          │ LiteLLM Proxy   │
        │ 4000-4500     │                          │ 4000-4500       │
        └──────┬────────┘                          └──────┬──────────┘
               │                                            │
               │                                            │
               ▼                                            ▼
        ┌───────────────┐                          ┌─────────────────┐
        │  OpenRouter   │ (via LiteLLM)            │ Open WebUI API  │
        │  Paid models  │                          │ MCP Servers     │
        └───────────────┘                          └─────────────────┘

        ┌─────────────────────────────────────────────────────────┐
        │                    Ollama Node                          │
        │                    11434/OLLAMA                         │
        │              (Local LLM Runtime)                        │
        └───────────────────┬─────────────────────────────────────┘
                            │
                            │
                    ┌───────▼────────────┐
                    │      SearXNG       │
                    │ Search Engine      │
                    └────────────────────┘
```

---

## Network Diagram

```
                              ┌──────────────────────┐
                              │    External DNS      │
                              │   (Example.com)      │
                              └──────────────────────┘
                                         │
                                         │ DNS-01
                                         ▼
                              ┌──────────────────────┐
                              │   Let's Encrypt CA   │
                              │ (DNS challenge)      │
                              └──────────────────────┘
                                         │
                    ┌────────────────────┼────────────────────┐
                    │                    │                    │
                    ▼                    │                    ▼
           ┌──────────────┐              │              ┌──────────────┐
           │   UDM Pro    │              │              │ Tailscale    │
           │   DNS:       │              │              │ Remote Access│
           │ .230         │              │              │              │
           └───────┬──────┘              │              └──────────────┘
                   │                     │
                   │                     │
                   ▼                     │
           ┌────────────────────────────────────┐
           │  k3s Control-Plane Node           │
           │  192.168.30.217                    │
           │───────────────────────────────────  │
           │  Traefik Ingress (192.168.30.230)  │
           └──────────────┬──────────────────────┘
                          │
            ┌─────────────┼─────────────┐
            │             │             │
            ▼             ▼             ▼
    ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
    │ Open WebUI  │ │  LiteLLM    │ │  SearXNG    │
    │  8080       │ │   4000      │ │   8080      │
    │ ClusterIP   │ │  ClusterIP  │ │  ClusterIP  │
    └──────┬──────┘ └──────┬──────┘ └──────┬──────┘
           │               │               │
           │               │               │
           ▼               ▼               │
    ┌─────────────┐ ┌─────────────┐         │
    │ MCPO        │ │  Ollama     │         │
    │ 8000        │ │ 11434       │         │
    │ ClusterIP   │ │ ClusterIP   │         │
    └──────┬──────┘ └──────┬──────┘         │
           │               │                 │
           │               │                 │
           ▼               ▼                 │
    ┌─────────────┐ ┌──────────┐        ┌──────────────────┐
    │ Database    │ │ Models   │        │  Persistent      │
    │ (optional)  │ │ Storage  │        │  Storage (NFS)   │
    └─────────────┘ └──────────┘        └──────────────────┘
```

---

## Detailed Setup Checklist

### Pre-Deployment Tasks

1. **[ ] Provision Ubuntu 26.04 LTS VM/server**
   - Minimum 4 cores, 8GB RAM, 48GB disk
   - Install k3s with `curl -sfL https://get.k3s.io | sh -`

2. **[ ] Configure NFS storage**
   - NFS server at `192.168.30.121:/data/pod_data`
   - Install NFS client on k3s node: `apt install nfs-common`
   - Mount: `sudo mount -t nfs 192.168.30.121:/data/pod_data /var/lib/k3s/storage`

3. **[ ] Expand root filesystem** (critical!)
   ```bash
   sudo growpart /dev/nvme0n1 3
   sudo pvresize /dev/nvme0n1p3
   sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
   ```

4. **[ ] Configure DNS**
   - UDM Pro DNS at `192.168.30.121`
   - Records:
     - `ai.example.com` → `192.168.30.230`
     - `llm.example.com` → `192.168.30.230`
     - `secrets.example.com` → `192.168.30.230`
     - `search.example.com` → `192.168.30.230`

5. **[ ] Configure Let's Encrypt DNS provider**
   - API token for DNS provider (e.g., Cloudflare, Route53)
   - Create `Secret` for DNS credentials

6. **[ ] Set up GitHub repository**
   - Create repository: `ChadEngel/ce-ai-home-lab`
   - Clone locally: `git clone https://github.com/ChadEngel/ce-ai-home-lab.git`

7. **[ ] Configure Tailscale**
   - Install Tailscale on k3s node
   - Enable subnet router for cluster access
   - Verify connectivity to cluster IP range

8. **[ ] Generate secrets (for local setup)**
   - `JWT_SECRET`: 32-character random string
   - `NEXT_SECRET_KEY_BASE`: 32-character random string
   - `LITELLM_SECRET_KEY`: 32-character random string
   - `LITELLM_MASTER_KEY`: 32-character random string
   - Use `openssl rand -hex 32` to generate

---

## Post-Deployment Tasks

### Initial Configuration

1. **Deploy infrastructure components first:**
   ```bash
   kubectl apply -f clusters/util-server/namespaces/ai.yaml
   helm install nfs-storage nfs-client/nfs-subdir-external-provisioner -f storage/nfs/...
   helm install traefik traefik/traefik -f networking/traefik/values.yaml
   helm install cert-manager jetstack/cert-manager -f networking/cert-manager/values.yaml --set installCRDs=true
   ```

2. **Configure LiteLLM secrets:**
   ```bash
   cd clusters/util-server/applications/litellm
   # Edit kustomization.yaml with real values before applying
   kubectl apply -f kustomization.yaml
   ```

3. **Deploy applications:**
   ```bash
   kubectl apply -f applications/searxng/
   kubectl apply -f applications/mcpo/
   kubectl apply -f applications/ollama/
   kubectl apply -f applications/litellm/
   kubectl apply -f applications/openwebui/
   ```

4. **Initialize Infisical (secrets management):**
   - Access: https://secrets.example.com
   - Create project and environments
   - Sync secrets to Kubernetes resources

5. **Verify deployment:**
   ```bash
   kubectl get pods -n ai
   kubectl get ingresses -n ai
   kubectl get certificates -n ai
   ```

---

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| Pods stuck in `Pending` | Check disk space (`df -h`), ensure NFS mounted |
| Ingress 404 errors | Verify DNS A record points to `192.168.30.230` |
| TLS certificate not issued | Check DNS provider API credentials |
| Traefik unreachable | Verify MetalLB not conflicting with Traefik IP |
| Ollama CPU intensive | Adjust resource limits, ensure enough RAM |

### Verification Commands

```bash
# Check cluster health
kubectl get nodes
kubectl get pods -A

# Check storage
kubectl get storageclass
kubectl get pvc -n ai

# Check Ingress
kubectl get ingress -n ai
kubectl describe ingress -n ai

# Check certificates
kubectl get certificate -n ai

# Check network connectivity
curl -f https://ai.example.com