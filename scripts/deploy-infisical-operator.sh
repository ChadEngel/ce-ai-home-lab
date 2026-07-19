#!/bin/bash
# Deploy the Infisical Kubernetes Operator + the InfisicalSecret CRs that sync
# Infisical secrets into native Kubernetes Secrets.
#
# Run from the repository root: ./scripts/deploy-infisical-operator.sh
#
# Prerequisites (see clusters/util-server/applications/infisical-operator/):
#   - Infisical itself is already running (./scripts/deploy-infisical.sh)
#   - The `secret-management` project's `prod` environment holds the secrets
#     (CLOUDFLARE_API_TOKEN, INFLUXDB_TOKEN, ...) in Infisical
#   - A Machine Identity `homelab-k8s-operator` exists with Universal Auth and
#     a Viewer role on that project/env
#   - The K8s Secret `infisical-universal-auth` exists in namespace `ai`
#     holding the machine identity's clientId/clientSecret:
#
#       kubectl create secret generic infisical-universal-auth -n ai \
#         --from-literal=clientId=<id> --from-literal=clientSecret=<secret>
#
# This script is idempotent. It installs:
#   - the operator (namespace infisical-operator-system) — image pinned to v0.10.34
#     (the :latest image requires v1beta1 CRDs not in the install manifest; see README)
#   - the InfisicalSecret CRs (namespace ai) that the operator reconciles.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OP_DIR="$REPO_ROOT/clusters/util-server/applications/infisical-operator"

echo "Deploying Infisical Kubernetes Operator..."

kubectl apply -k "$OP_DIR"

echo ""
echo "Waiting for operator pod to be Ready..."
kubectl wait --for=condition=Ready pod \
    -l control-plane=controller-manager -n infisical-operator-system \
    --timeout=180s 2>/dev/null \
    || echo "  (operator pod not ready; check 'kubectl get pods -n infisical-operator-system')"

echo ""
echo "InfisicalSecret syncs (should reach ReadyToSyncSecrets):"
kubectl get infisicalsecret -n ai 2>/dev/null || echo "  (none)"

echo ""
echo "Next steps:"
echo "  - Verify the synced K8s Secrets:"
echo "      kubectl get secret -n cert-manager cloudflare-dns-creds"
echo "      kubectl get secret -n ai influxdb-secrets"
echo "  - Rotate a secret in the Infisical UI; the operator updates the K8s"
echo "    Secret within ~60s (resyncInterval)."
echo ""