#!/bin/bash
# Deploy the udm-thermal collector to the Kubernetes cluster.
#
# udm-thermal SSHes to the UDM Pro (https://192.168.250.1) as root to read the
# SoC thermal zone (thermal_zone0, type=cpu-thermal) and fan RPM — telemetry
# unpoller CANNOT collect because the UniFi controller API only exposes board
# temps (temp_cpu/temp_phy/temp_local). It writes a `udm_thermal` measurement to
# the `network_metrics` bucket. See
# clusters/util-server/applications/udm-thermal/kustomization.yaml.
#
# Prereqs (once):
#   1. Enable SSH on the UDM: Settings -> System -> Advanced -> SSH, and set the
#      root password.
#   2. Add the root password to Infisical (caehomelab-v1q6 / prod / root) as
#      UDM_SSH_PASS. INFLUXDB_TOKEN (write) should already exist there.
#
# Run from the repository root: ./scripts/deploy-udm-thermal.sh

set -euo pipefail

NAMESPACE="ai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
UDM_THERMAL_DIR="$REPO_ROOT/clusters/util-server/applications/udm-thermal"
INFISICAL_SYNC="$REPO_ROOT/clusters/util-server/applications/infisical-operator/infisical-secrets-sync.yaml"

echo "=== Deploying udm-thermal ==="

# 1. (Re)apply InfisicalSecret CRs — creates udm-thermal-secrets synced from
#    Infisical (UDM_SSH_PASS + INFLUXDB_TOKEN write). Idempotent; touches the
#    other sync CRs too (harmless).
kubectl apply -f "$INFISICAL_SYNC"
echo "[✅] InfisicalSecret CRs applied (udm-thermal-secrets-sync included)"

# 2. Wait for the operator to populate udm-thermal-secrets before starting the
#    pod, otherwise poll.sh's guard (UDM_SSH_PASS / INFLUXDB_TOKEN unset) loops.
echo ""
echo "Waiting for udm-thermal-secrets to be synced by the Infisical operator..."
for i in $(seq 1 20); do
  if kubectl get secret udm-thermal-secrets -n "$NAMESPACE" -o jsonpath='{.data.UDM_SSH_PASS}' 2>/dev/null | base64 -d 2>/dev/null | grep -q . \
     && kubectl get secret udm-thermal-secrets -n "$NAMESPACE" -o jsonpath='{.data.INFLUXDB_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null | grep -q .; then
    echo "[✅] udm-thermal-secrets populated (attempt $i)"
    break
  fi
  echo "  ($i) not yet — retrying in 5s"
  sleep 5
  if [ "$i" = 20 ]; then
    echo "[⚠️] udm-thermal-secrets not populated after 100s"
    echo "      Did you add UDM_SSH_PASS to Infisical?"
    echo "      Check: kubectl get infisicalsecret -n ai udm-thermal-secrets-sync"
    exit 1
  fi
done

# 3. Apply the udm-thermal manifests (ConfigMap, Deployment).
kubectl apply -n "$NAMESPACE" -f "$UDM_THERMAL_DIR/kustomization.yaml"
echo "[✅] udm-thermal manifests applied"

# 4. Wait for the pod to be ready.
echo ""
echo "Waiting for udm-thermal pod to be ready..."
if kubectl wait --for=condition=Ready pod -l app=udm-thermal -n "$NAMESPACE" --timeout=180s 2>/dev/null; then
    echo "[✅] udm-thermal pod is running"
else
    echo "[⚠️] udm-thermal pod did not become Ready within 180s"
    echo "      Check: kubectl describe pod -n ai -l app=udm-thermal"
    echo "      Logs:  kubectl logs -n ai -l app=udm-thermal"
fi

# 5. Quick status + how to verify data flow.
echo ""
echo "Pods:"
kubectl get pods -n "$NAMESPACE" -l app=udm-thermal
echo ""
echo "Verify fresh SoC writes land in network_metrics (~15s cadence):"
echo '  kubectl logs -n ai -l app=udm-thermal --tail=5'
echo '  from(bucket:"network_metrics") |> range(start:-5m) |> filter(fn:(r)=>r._measurement=="udm_thermal") |> last()'
echo ""
