#!/bin/bash
# Debug script for diagnosing pod issues and cert-manager status
# Run from the repository root: ./scripts/debug-pods.sh

set -u

NAMESPACE="ai"

echo "=== Cert-Manager Status ==="
kubectl get pods -n cert-manager 2>/dev/null
echo ""

echo "=== Certificate Status ==="
kubectl get certificates -n "$NAMESPACE" 2>/dev/null
echo ""

for app in openwebui searxng bifrost infisical infisical-db grafana; do
    echo "=== $app Pod Details ==="
    kubectl describe pod -l "app=$app" -n "$NAMESPACE" 2>/dev/null \
        | grep -A 8 "Events:" | tail -15
    echo ""
done

echo "=== Recent Cluster Events ==="
kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
    | grep -v "kube-system" | tail -20
