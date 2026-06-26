#!/bin/bash
# FluxCD Installation Script for k3s cluster

set -e

echo "Installing FluxCD on k3s cluster..."

# Create namespace
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -

# Install FluxCD components
kubectl apply -k github.com/fluxcd/flux2/manifests/install/

# Wait for installation
kubectl wait --namespace=flux-system \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/name=flux \
    --selector=component=controller \
    --timeout=180s

echo "FluxCD installation complete!"

# Configure git repository
GIT_REPO="ChadEngel/ce-ai-home-lab"
GIT_BRANCH="main"

flux create source git repository \
    --name=gitops-repo \
    --namespace=flux-system \
    --url=https://github.com/ChadEngel/ce-ai-home-lab.git \
    --branch=main \
    --interval=1m

# Create Kustomization for infrastructure
flux create kustomization infrastructure \
    --namespace=flux-system \
    --name=infrastructure \
    --path=./clusters/util-server \
    --source=GitRepository/gitops-repo \
    --interval=5m

echo "FluxCD repository configured!"
echo ""
echo "Next steps:"
echo "  1. Push your application manifests to the git repository"
echo "  2. Flux will automatically deploy them to the cluster"
