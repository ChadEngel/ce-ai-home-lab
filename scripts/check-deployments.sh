#!/bin/bash
# Check the status of all deployed applications
# Run from the repository root: ./scripts/check-deployments.sh

set -u

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
echo "=== ConfigMaps (filtered) ==="
kubectl get configmaps -n "$NAMESPACE" \
    | grep -v -E "kube-root-ca|kubelet-serving|^NAME"

echo ""
echo "=== Secrets (filtered) ==="
kubectl get secrets -n "$NAMESPACE" \
    | grep -v -E "service-account-token|default-token|^NAME"

echo ""
echo "=== Application URLs ==="
echo "Open WebUI:   https://ai.caehomelab.com"
echo "Bifrost:      https://llm.caehomelab.com  (configure providers via web UI)"
echo "SearXNG:      https://search.caehomelab.com"
echo "Infisical:    https://secrets.caehomelab.com"
echo "Grafana:      https://grafana.caehomelab.com"
echo ""
echo "=== Internal Cluster Endpoints ==="
echo "  Bifrost API:  http://bifrost-api.ai.svc.cluster.local:8080"
echo "  Open WebUI:   http://openwebui.ai.svc.cluster.local:8080"
echo "  SearXNG:      http://searxng-api.ai.svc.cluster.local:8080"
echo "  Infisical:    http://infisical.ai.svc.cluster.local:3000"
echo ""
echo "=== External (not in K8s) ==="
echo "  Ollama:       http://aiserver.home:11434"
echo ""
echo "Note: MCPo is not deployed (no published Docker image yet)."

echo ""
echo "=== Pod Errors (last 10 pods, only events) ==="
kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | tail -10 \
    | awk '{print $1}' \
    | while read -r POD; do
        [ -z "$POD" ] && continue
        events=$(kubectl describe pod "$POD" -n "$NAMESPACE" 2>/dev/null \
                 | grep -E "Failed|Error|CrashLoop|ImagePull" || true)
        if [ -n "$events" ]; then
            echo "--- $POD ---"
            echo "$events"
        fi
    done
