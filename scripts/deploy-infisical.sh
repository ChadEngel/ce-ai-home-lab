#!/bin/bash
# Deploy Infisical to the Kubernetes cluster
# Run from the repository root: ./scripts/deploy-infisical.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications"
NAMESPACE="ai"
SECRET_NAME="infisical-secrets"
CERT_NAME="infisical-tls"

echo "Deploying Infisical to namespace: $NAMESPACE"

# Apply secrets first
echo "Applying secrets..."
kubectl apply --namespace="$NAMESPACE" -f "$APPS_DIR/infisical/secrets.yaml"

# Apply SSL certificate secrets
echo "Applying SSL certificates..."
kubectl apply --namespace="$NAMESPACE" -f "$APPS_DIR/infisical/ssl-certs.yaml"

# Apply the main Kustomization resources
echo "Applying Kustomization resources..."
kubectl apply --namespace="$NAMESPACE" -f "$APPS_DIR/infisical/kustomization.yaml"

# Update any existing deployment with the new secret
echo "Updating deployment with new secrets..."
kubectl --namespace="$NAMESPACE" rollout restart deployment/infisical

echo "Infisical deployment completed."
echo "Access URL: https://infisical.caehomelab.com"
echo "IMPORTANT: Remember to set up the initial admin credentials after deployment."
