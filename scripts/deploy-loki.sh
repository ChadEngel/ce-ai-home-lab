#!/bin/bash
# Deploy Loki (log aggregation) + Promtail (UDM syslog intake) to the cluster.
# Run from the repository root: ./scripts/deploy-loki.sh
#
# Brings up:
#   - Loki 3.7.4 single-binary, filesystem-on-NFS, 15-day retention
#   - Promtail 3.6.11 UDP syslog receiver on NodePort 30014 (UDP)
#   - TLS ingress at https://loki.caehomelab.com (cert-manager + letsencrypt-prod)
#
# After deploy, point the UDM Pro at the syslog intake:
#   UniFi Network -> System Settings -> Advanced -> Syslog Server
#   Host: 192.168.30.217   Port: 30014   Protocol: UDP

set -euo pipefail

NAMESPACE="ai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications/loki"

echo "=== Deploying Loki + Promtail ==="

# 1. Apply manifests (Loki, Promtail, NodePort, Ingress, PVC, ConfigMaps)
kubectl apply -n "$NAMESPACE" -f "$APPS_DIR/kustomization.yaml"
echo "[✅] Loki + Promtail manifests applied"

# 2. Wait for Loki to be ready (it pulls the image on first run)
echo ""
echo "Waiting for Loki pod to be ready..."
if kubectl wait --for=condition=Ready pod -l app=loki -n "$NAMESPACE" \
        --timeout=240s 2>/dev/null; then
    echo "[✅] Loki is running"
else
    echo "[⚠️]  Loki did not become Ready within 240s"
    echo "       kubectl describe pod -n ai -l app=loki"
    echo "       kubectl logs -n ai -l app=loki --tail=40"
fi

# 3. Wait for Promtail
echo ""
echo "Waiting for Promtail pod to be ready..."
if kubectl wait --for=condition=Ready pod -l app=promtail -n "$NAMESPACE" \
        --timeout=120s 2>/dev/null; then
    echo "[✅] Promtail is running"
else
    echo "[⚠️]  Promtail did not become Ready within 120s"
    echo "       kubectl describe pod -n ai -l app=promtail"
fi

# 4. Verify retention is configured
echo ""
echo "=== Loki retention config ==="
RET="$(kubectl -n "$NAMESPACE" exec -l app=loki --container=loki -- \
        wget -qO- http://localhost:3100/config 2>/dev/null \
        | grep -E '^retention_period|retention_enabled' || true)"
echo "$RET" | sed 's/^/  /'
[ -n "$RET" ] || echo "  (could not read /config from Loki pod -- check logs)"

# 5. Summary
echo ""
echo "=== Loki deployed ==="
echo "  UI:        https://loki.caehomelab.com"
echo "  Internal:  http://loki.ai.svc.cluster.local:3100"
echo "  Retention: 15 days (360h)"
echo ""
echo "  UDM syslog target (UDP):  192.168.30.217:30014"
echo "    UniFi Network -> System Settings -> Advanced -> Syslog Server"
echo "    Host 192.168.30.217, Port 30014, Protocol UDP"
echo ""
echo "  Verify logs are flowing (after pointing the UDM):"
echo "    kubectl -n ai exec -l app=loki -c loki -- wget -qO- 'http://localhost:3100/loki/api/v1/labels'"
echo "    kubectl -n ai logs -l app=promtail --tail=20"