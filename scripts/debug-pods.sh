#!/bin/bash
# Debug script for diagnosing pod issues and cert-manager status

NAMESPACE="ai"

echo "=== Cert-Manager Status ==="
kubectl get cm -n cert-manager
kubectl get pods -n cert-manager

echo ""
echo "=== Certificate Status ==="
kubectl get certificates -n $NAMESPACE

echo ""
echo "=== Litellm Pod Details ==="
kubectl describe pod -l app=litellm -n ai | grep -A5 "Events:" | tail -20

echo ""
echo "=== Searxng Pod Details ==="
kubectl describe pod -l app=searxng -n ai | grep -A5 "Events:" | tail -20

echo ""
echo "=== Infisical Pod Details ==="
kubectl describe pod -l app=infisical -n ai | grep -A5 "Events:" | tail -20

echo ""
echo "=== Recent Cluster Events ==="
kubectl get events -n ai --sort-by='.lastTimestamp' | grep -v "kube-system" | tail -20
