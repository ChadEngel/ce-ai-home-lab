#!/bin/bash
# Deploy Headlamp (read-only Kubernetes web UI) to the cluster.
# Run from the repository root: ./scripts/deploy-headlamp.sh
#
# Auth is Headlamp's own token prompt: the UI is reachable but every API call
# needs a ServiceAccount token, and RBAC decides what that token can do. There
# is deliberately NO ingress basic auth — see the "Auth model" note at the top
# of applications/headlamp/kustomization.yaml for why that was removed.
#
# Usage:
#   ./scripts/deploy-headlamp.sh            # deploy
#   ./scripts/deploy-headlamp.sh --token    # deploy, then print a fresh token
#
# The printed token is bound to the `headlamp` SA (read-only; secrets excluded).

set -euo pipefail

NAMESPACE="ai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications/headlamp"
SA_NAME="headlamp"
TOKEN_DURATION="720h"   # 30d — Headlamp cannot refresh a static pasted token

PRINT_TOKEN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --token) PRINT_TOKEN=1 ;;
        -h|--help)
            # Print the leading comment banner only.
            awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) echo "[⚠️] unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

echo "=== Deploying Headlamp (read-only k8s UI) ==="

# --- 1. Apply manifests (SA, RBAC, Deployment, Service, Ingress) -------------
echo ""
kubectl apply -n "$NAMESPACE" -f "$APPS_DIR/kustomization.yaml"
echo "[✅] Headlamp manifests applied"

# --- 2. Wait for the pod ----------------------------------------------------
echo ""
echo "Waiting for Headlamp pod to be ready..."
if kubectl wait --for=condition=Ready pod -l app=headlamp -n "$NAMESPACE" \
        --timeout=180s 2>/dev/null; then
    echo "[✅] Headlamp pod is running"
else
    echo "[⚠️] Headlamp pod did not become Ready within 180s"
    echo "      Check: kubectl describe pod -n $NAMESPACE -l app=headlamp"
fi

# --- 3. TLS / ingress status ------------------------------------------------
echo ""
echo "Waiting for the TLS certificate (cert-manager DNS-01 via Cloudflare)..."
if kubectl wait --for=condition=Ready certificate/headlamp-tls -n "$NAMESPACE" \
        --timeout=300s 2>/dev/null; then
    echo "[✅] headlamp-tls is Ready"
else
    echo "[⚠️] headlamp-tls not Ready yet — first issuance can take a few minutes."
    echo "      Check: kubectl describe certificate headlamp-tls -n $NAMESPACE"
fi

# --- 4. Mint a token --------------------------------------------------------
echo ""
TOKEN=""
if TOKEN="$(kubectl create token "$SA_NAME" -n "$NAMESPACE" \
        --duration="$TOKEN_DURATION" 2>/dev/null)" && [ -n "$TOKEN" ]; then
    echo "[✅] Token minted for $SA_NAME (duration $TOKEN_DURATION)"
else
    TOKEN=""
    echo "[⚠️] Could not mint a token. Create one with:"
    echo "       kubectl create token $SA_NAME -n $NAMESPACE --duration=$TOKEN_DURATION"
fi

echo ""
echo "=== Done ==="
echo ""
echo "  URL:        https://headlamp.caehomelab.com"
echo "  Ingress IP: $(kubectl get ingress headlamp-ingress -n "$NAMESPACE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
echo ""
echo "Log in by pasting a ServiceAccount token into the Headlamp prompt."
echo "RBAC (not the token itself) decides what it can do:"
echo "  * read-only: view + headlamp-cluster-read"
echo "  * secrets deliberately excluded"
echo ""
echo "Mint a fresh token any time:"
echo "  kubectl create token $SA_NAME -n $NAMESPACE --duration=$TOKEN_DURATION"
echo ""

if [ "$PRINT_TOKEN" -eq 1 ] && [ -n "$TOKEN" ]; then
    echo "=== TOKEN (valid $TOKEN_DURATION) ==="
    echo "$TOKEN"
    echo "=== END TOKEN ==="
    echo ""
fi
