# FluxCD GitOps Configuration

This directory contains the FluxCD configuration for automated deployment.

## Overview

The cluster uses **FluxCD v2** for continuous delivery following best practices:

- **Git Repository**: All Kubernetes manifests are committed to Git
- **Automated Sync**: Flux continuously monitors commits and applies changes
- **Self-healing**: If manifests drift, Flux automatically restores them
- **Rollback support**: Reverted commits trigger automatic rollback

## Directory Structure

```
flux/
├── README.md
├── flux-install.sh                 # Installation script
├── flux-kustomization.yaml         # Base kustomization
├── flux-namespace.yaml             # Namespace definition
├── gotk-components.yaml            # Component definitions
├── helm-releases.yaml              # Helm chart releases
├── helm-repos.yaml                 # Helm repository definitions
├── apps.yaml                       # Application kustomizations
└── sealer-gk-components.yaml       # GitHub secrets
```

## Installation

### Prerequisites

- kubectl configured for the k3s cluster
- GitHub Personal Access Token (PAT)
- Helm installed locally (optional)

### Install FluxCD

```bash
./flux-install.sh
```

Or manually:

```bash
# Create namespace
kubectl create namespace flux-system

# Install FluxCD
kubectl apply -k github.com/fluxcd/flux2/manifests/install/

# Wait for pods to be ready
kubectl wait --namespace=flux-system \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/name=flux \
    --timeout=180s
```

## Configuration

### Helm Repository Configuration

FluxCD tracks these Helm repositories:

- **traefik**: https://traefik.github.io/charts
- **cert-manager**: https://charts.jetstack.io
- **nfs-client**: https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner
- **metallb**: https://metallb.github.io/metallb

### Application Configuration

The `apps.yaml` kustomization applies all components:

1. **Infrastructure first**: Storage and networking
2. **Then applications**: Open WebUI, Bifrost, Infisical, SearXNG, Grafana

## GitOps Workflow

1. **Make changes** to manifests in `/clusters/util-server`
2. **Commit** to the `main` branch
3. **Push** to GitHub
4. **Flux** detects changes within 1 minute
5. **Flux** applies changes to the cluster
6. **Self-heal** if changes are reverted

## Troubleshooting

### Check Flux status

```bash
flux get components
flux get sources git -n flux-system
flux get kustomizations -n flux-system
flux get reconciliations -n flux-system
```

### Review events

```bash
kubectl get events -n flux-system
```

### Check application health

```bash
kubectl get all -n ai
kubectl get ingresses -n ai
```

## Secrets Management

### Option 1: External Secrets Operator

Configure a vault or secrets manager:

```bash
kubectl apply -f sealer-gk-components.yaml
```

### Option 2: Simple Secret for GitHub

```bash
kubectl create secret generic gitops-auth \
    --from-literal=username=ChadEngel \
    --from-literal=password=YOUR_GITHUB_TOKEN \
    -n flux-system
```

## Best Practices

- Keep all configuration in Git
- Use Kustomize for environment variations
- Use Helm for chart templating
- Use FluxCD for automation
- Keep secrets encrypted (SOPS) or use a secrets manager
- Enable SRE policies for cluster security
