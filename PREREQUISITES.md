# Prerequisites

This document outlines all infrastructure requirements and prerequisites needed to deploy the ce-ai-home-lab Kubernetes environment.

---

## Overview

This home lab Kubernetes environment is designed for a **single-node k3s cluster** running on Ubuntu Linux. It uses persistent storage, a unified LLM proxy, and GitOps for automated deployments.

The architecture leverages **NFS storage**, **TLS certificates**, **Ingress routing**, and **GitOps automation** to create a self-managing, reproducible infrastructure.

---

## Infrastructure Requirements

### Minimum Hardware

Sized from measured steady-state usage (`kubectl top`) plus headroom for bursts.
A single node runs **all** workloads below.

| Resource | Minimum | Recommended | Notes |
|----------|---------|-------------|-------|
| **CPU** | 4 cores | 8 cores | Pod *requests* total ~0.7 core; *limits* ~4 cores. 2 cores boots but chokes during Infisical/Open WebUI startup + RAG embeddings. |
| **RAM** | 8 GB | **16 GB** | Pod *requests* total ~3.0 GiB; *limits* ~9.2 GiB (overcommitted). 8 GB runs but Infisical (~0.9 GiB) + Open WebUI (~0.7 GiB, spikes higher on embeddings/STT) leave little room. 16 GB removes memory pressure. |
| **Disk (local)** | 48 GB | 100 GB SSD | k3s + etcd + container images (~15 GB). Persistent volumes live on NFS, not here. |
| **Network** | 1 GbE | 2.5 GbE+ | LLM traffic is the bandwidth driver. |

> **Why 16 GB RAM is recommended over the 8 GB minimum:** Open WebUI and
> Infisical are the two memory-hungry workloads. Their *limits* are 3 GiB each
> so they can burst during embedding generation / Node.js GC. On 8 GB the sum
> of memory *limits* (~9.2 GiB) exceeds physical RAM, so two simultaneous
> bursts can trigger the kernel OOM-killer. 16 GB makes that a non-issue.

#### Per-pod resource budget (requests / limits)

These are the values committed in the manifests (`applications/*/kustomization.yaml`).
Requests = guaranteed/reserved; limits = burst ceiling.

| Pod | CPU req | CPU lim | Mem req | Mem lim | Steady-state usage |
|-----|---------|---------|---------|---------|--------------------|
| openwebui | 200m | 1 | 1 GiB | 3 GiB | ~10m / ~700 MiB (spikes on RAG) |
| infisical | 100m | 1 | 1 GiB | 3 GiB | ~25m / ~760 MiB |
| infisical-db (Postgres) | 50m | 500m | 256 MiB | 1 GiB | ~10m / ~70 MiB |
| infisical-redis | 25m | 100m | 32 MiB | 128 MiB | ~15m / ~8 MiB |
| bifrost | 25m | 500m | 128 MiB | 512 MiB | ~1m / ~55 MiB (bursts on streaming) |
| grafana | 50m | 250m | 128 MiB | 512 MiB | ~25m / ~125 MiB |
| searxng | 50m | 250m | 192 MiB | 512 MiB | ~1m / ~110 MiB |
| nfs-provisioner | 10m | 100m | 16 MiB | 64 MiB | ~2m / ~6 MiB |
| **App subtotal** | **510m** | **3.7** | **~2.7 GiB** | **~8.2 GiB** | |

System pods (k3s / Traefik / coredns / metrics-server / cert-manager /
Infisical operator) add roughly **~0.2 core / ~0.2 GiB** of requests on top.

**Total requests: ~0.7 core CPU, ~3.0 GiB RAM. Total limits: ~4.2 core CPU, ~9.2 GiB RAM.**

To re-measure on your own node:
```bash
kubectl top nodes
kubectl top pods -A
kubectl describe node <node> | sed -n '/Allocated resources:/,/Events:/p'
```

### Network Requirements

- **Static IP** for k3s node (recommended: `192.168.30.217`)
- **Internal DNS** server (UDM Pro or similar)
- **Open ports**:
  - `443/TCP` - HTTPS traffic (Ingress)
  - `80/TCP` - HTTP (for Let's Encrypt DNS-01 validation)
  - `8443/TCP` - Tailscale
- **External DNS** configured for (all → `192.168.30.217`):
  - `ai.caehomelab.com`
  - `llm.caehomelab.com`
  - `secrets.caehomelab.com`
  - `search.caehomelab.com`
  - `grafana.caehomelab.com`

### Storage Requirements

| Component | Storage | Notes |
|-----------|---------|-------|
| **Root filesystem** | 48+ GB | For system + container images (images ~15 GB) |
| **NFS Server** | 100+ GB | For persistent volumes |
| **NFS Share Path** | `/data/pod_data` | Mounted/exported to k3s node |

Persistent volumes (all on NFS, `nfs-client` StorageClass):

| PVC | Size | Used by |
|-----|------|---------|
| openwebui-pvc | 5 GiB | Open WebUI DB + uploads |
| bifrost-pvc | 5 GiB | Bifrost config DB |
| grafana-pvc | 5 GiB | Grafana DB + dashboards |
| searxng-pvc | 2 GiB | SearXNG config |
| infisical-data | 5 GiB | Infisical attachments |
| infisical-db-data | 10 GiB | Infisical Postgres |
| **Total** | **32 GiB** | (NFS; not counted against local disk) |

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
                          INTERNET
                             |
                    Let's Encrypt (DNS-01)
                             |
        Public DNS (Cloudflare): *.caehomelab.com -> 192.168.30.217
                             |
                cert-manager ClusterIssuer (DNS-01)
                             |
             Traefik Ingress :443/:80   (node 192.168.30.217)
                             |
   +-------------+-----------+-----------+-------------+
   v             v           v           v             v
 Open WebUI    Bifrost    Infisical    SearXNG      Grafana
 ai.*          llm.*      secrets.*    search.*     grafana.*
 :8080         :8080      :8080        :8080        :3000
   |             |
   |   OpenAI API  (/v1/models, /v1/chat/completions)
   +---->---------+
                  v
        Ollama (external)   aiserver.home:11434
        Local LLM runtime -- 7 models

 Cross-cutting:
  - Infisical operator syncs Infisical secrets -> K8s Secrets
    (bifrost-secrets, openwebui-secrets, cloudflare-dns-creds, influxdb-secrets)
  - NFS PVs: 192.168.30.121:/data/pod_data  (6 PVCs, 32 GiB)
```

---

## Network Diagram

```
                      +------------------+
                      |  External DNS    |
                      |  Cloudflare      |
                      | *.caehomelab.com |
                      +--------+---------+
                               | A -> 192.168.30.217
                               |  + DNS-01 challenge for Let's Encrypt
                               v
                      +------------------+
                      | Let's Encrypt CA |
                      +--------+---------+
                               | cert (cert-manager DNS-01)
                               v
        +----------------------------------------------+
        |  k3s single-node cluster -- util-server     |
        |  192.168.30.217                             |
        |  +----------------------------------------+ |
        |  | Traefik Ingress  :443/:80              | |
        |  +------------------+---------------------+ |
        |                     |                       |
        |   +-----------------+---------+             |
        |   v                 v         v             v
        | Open WebUI      Bifrost    Infisical     SearXNG   Grafana
        |  :8080           :8080      :8080         :8080    :3000
        |   |                |                         |
        |   | OpenAI /v1     |                         |
        |   +->(cluster)-----+                         |
        |                    v                         |
        |             Ollama (external)                |
        |             aiserver.home:11434              |
        |                                              |
        |  NFS PVs <- 192.168.30.121:/data/pod_data    |
        +----------------------------------------------+

  Tailscale on the node provides remote access (subnet router).
```

---

## Detailed Setup Checklist

### Pre-Deployment Tasks

1. **[ ] Provision Ubuntu 26.04 LTS VM/server**
   - Minimum 4 cores / 8 GB RAM / 48 GB disk (**16 GB RAM recommended** — see Minimum Hardware above)
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
     - `ai.caehomelab.com` → `192.168.30.217`
     - `llm.caehomelab.com` → `192.168.30.217`
     - `secrets.caehomelab.com` → `192.168.30.217`
     - `search.caehomelab.com` → `192.168.30.217`
     - `grafana.caehomelab.com` → `192.168.30.217`

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
   - Use `openssl rand -hex 32` to generate
   (These live in Infisical and are synced into the cluster by the Infisical
   operator — see `applications/infisical-operator/`. No secrets are stored
   in this repo.)

---

## Post-Deployment Tasks

### Initial Configuration

1. **Deploy infrastructure components first:**
   ```bash
   kubectl apply -f clusters/util-server/namespaces/ai.yaml
   # NFS provisioner: applied from repo manifests (no helm needed)
   kubectl apply -k clusters/util-server/storage/nfs/
   # Traefik ships with k3s (ServiceLB binds it to the node IP .217) — no install needed.
   helm install cert-manager jetstack/cert-manager -f clusters/util-server/networking/cert-manager/values.yaml --set installCRDs=true
   kubectl apply -f clusters/util-server/networking/cert-manager/clusterissuer.yaml
   ```

2. **Deploy Infisical + the operator first** (it syncs the secrets the other
   apps consume):
   ```bash
   kubectl apply -f clusters/util-server/applications/infisical/kustomization.yaml
   kubectl apply -f clusters/util-server/applications/infisical-operator/install-secrets-operator.yaml
   kubectl apply -f clusters/util-server/applications/infisical-operator/infisical-secrets-sync.yaml
   ```
   Then create these secrets in the Infisical UI (https://secrets.caehomelab.com):
   `BIFROST_OLLAMA_KEY`, `OPENWEBUI_OLLAMA_BASE_URL` (must end in `/v1`),
   `CF_API_TOKEN`, `INFLUX_TOKEN`, and Infisical's own `JWT_SECRET` /
   `ENCRYPTION_KEY`. The operator syncs them into K8s Secrets automatically.

3. **Deploy applications** (Bifrost is an OpenAI-compatible gateway; Open WebUI
   reaches it via the OpenAI API at `/v1/*`, NOT the Ollama API):
   ```bash
   kubectl apply -f clusters/util-server/applications/bifrost/kustomization.yaml
   kubectl apply -f clusters/util-server/applications/openwebui/kustomization.yaml
   kubectl apply -f clusters/util-server/applications/searxng/kustomization.yaml
   kubectl apply -f clusters/util-server/applications/grafana/kustomization.yaml
   ```

4. **Initialize Infisical (secrets management):**
   - Access: https://secrets.caehomelab.com
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
| Ingress 404 errors | Verify DNS A record points to `192.168.30.217` |
| TLS certificate not issued | Check DNS provider API credentials |
| Traefik unreachable | k3s ServiceLB binds Traefik to the node IP; check `kubectl get svc -n kube-system traefik` |
| Memory pressure / OOM-kills | Open WebUI & Infisical are memory-hungry; 16 GB RAM recommended (see Minimum Hardware) |

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
curl -f https://ai.caehomelab.com