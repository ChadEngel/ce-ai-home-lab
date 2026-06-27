#!/bin/bash
# Check the status of all deployed applications
# Run from the repository root: ./scripts/check-deployments.sh

set -e

NAMESPACE="ai"

echo "=== Kubernetes Application Status Check ==="
echo "Namespace: $NAMESPACE"
echo ""

# Check namespace exists
if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo "✅ Namespace '$NAMESPACE' is available"
else
    echo "❌ Namespace '$NAMESPACE' does not exist"
    exit 1
fi

echo ""
echo "=== Pods ==="
kubectl get pods -n "$NAMESPACE" -o wide

echo ""
echo "=== Deployments ==="
kubectl get deployments -n "$NAMESPACE"

echo ""
echo "=== Services ==="
kubectl get services -n "$NAMESPACE"

echo ""
echo "=== Ingresses ==="
kubectl get ingress -n "$NAMESPACE"

echo ""
echo "=== PVCs ==="
kubectl get pvc -n "$NAMESPACE"

echo ""
echo "=== ConfigMaps ==="
kubectl get configmaps -n "$NAMESPACE"

echo ""
echo "=== Secrets ==="
kubectl get secrets -n "$NAMESPACE" | grep -v "service-account-token"

echo ""
echo "=== Application Summary ==="
echo "Infisical:     https://infisical.caehomelab.com"
echo "OpenWebUI:     https://ai.caehomelab.com"
echo "SearXNG:       https://search.caehomelab.com"
echo ""
echo "Internal Services (Kubernetes):"
echo "  LiteLLM:      http://litellm-api.ai.svc.cluster.local:4000"
echo "" 
echo "External Services (not in K8s):"
echo "  Ollama:       http://aiserver.home:11434"
echo "" 
echo "Application MCPo: not deployed (no published Docker image)"

echo ""
echo "=== Recent Pod Errors (last 5 pods) ==="
kubectl get pods -n "$NAMESPACE" | tail -6 | while read line; do
    POD=$(echo "$line" | awk '{print $1}')
    kubectl describe pod "$POD" -n "$NAMESPACE" 2>/dev/null | grep -E "(Failed|Error|CrashLoop)" || true
done
