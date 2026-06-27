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

- ai.example.com → Open WebUI
- search.example.com → SearXNG
- grafana.example.com → Grafana (future)

### Remote Access

Services are accessible via Tailscale using the same internal URLs.

## Repository Structure

```
.
├── README.md
├── clusters/
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

- k3s cluster with 48GB+ disk space
- NFS storage server (192.168.30.121:/data/pod_data)
- Access to internal DNS (UDM Pro)
- Tailscale for remote access

### Install FluxCD

```bash
git clone https://github.com/ChadEngel/ce-ai-home-lab.git
cd ce-ai-home-lab
flux install \
    --namespace=flux-system \
    --components=source-controller
```

### Apply Configuration

```bash
kubectl apply -f clusters/util-server/namespaces/
kubectl apply -f clusters/util-server/storage/
kubectl apply -f clusters/util-server/networking/
kubectl apply -f clusters/util-server/applications/
```

### GitOps Setup

```bash
cd clusters/util-server/flux
flux create ks infrastructure \
    --namespace=ai \
    --path=./clusters/util-server \
    --source=GitRepository/ce-ai-home-lab
```

## Applications

| Application | Namespace | Internal URL | Description |
|-------------|-----------|--------------|-------------|
| Open WebUI | ai | ai.example.com | LLM UI |
| MCPO | ai | ClusterIP only | MCP Server |
| SearXNG | ai | search.example.com | Search engine |
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
                │ ui.example.com │
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

## Documentation

For detailed build notes and lessons learned, see [`homelab_build.md`](./homelab_build.md).

## License

MIT
