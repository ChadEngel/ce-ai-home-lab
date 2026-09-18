#!/bin/bash
# Deploy Grafana (InfluxDB-backed) to the Kubernetes cluster
# Run from the repository root: ./scripts/deploy-grafana.sh
#
# Dashboard ConfigMap safety: the ConfigMap is mounted at
# /var/lib/grafana/dashboards/default and Grafana's file provider has
# disableDeletion:false, so ANY key missing from this ConfigMap is deleted from
# Grafana's database. A stale/incomplete local checkout must therefore never be
# able to silently remove dashboards. By default this script is ADDITIVE: it
# keeps any live ConfigMap key that has no matching local *.json and warns
# loudly. Pass --prune to make the local directory authoritative and remove
# dashboards that are no longer present locally.

set -euo pipefail

NAMESPACE="ai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_DIR="$REPO_ROOT/clusters/util-server/applications/grafana"
DASH_DIR="$REPO_ROOT/scripts/grafana/dashboards"
CM_NAME="grafana-dashboards-json"

PRUNE=0
for arg in "$@"; do
    case "$arg" in
        --prune) PRUNE=1 ;;
        -h|--help)
            echo "Usage: $0 [--prune]"
            echo "  (default) additive: never delete live dashboards missing locally"
            echo "  --prune           local *.json is authoritative; delete others"
            exit 0 ;;
        *) echo "[⚠️] unknown argument: $arg" >&2; exit 2 ;;
    esac
done

echo "=== Deploying Grafana ==="

# 1. Apply Grafana core manifests (Deployment, Service, Ingress, ConfigMaps, Secrets, PVC)
kubectl apply -n "$NAMESPACE" -f "$APPS_DIR/kustomization.yaml"
echo "[✅] Grafana core manifests applied"

# 2. Build the dashboard ConfigMap from JSON files. Each *.json becomes a
#    data key in the grafana-dashboards-json ConfigMap, which is mounted
#    into /var/lib/grafana/dashboards/default so the file provider picks
#    them up automatically.
#
#    Safety: compute the set of live keys first. Any live key with no local
#    *.json is either (a) a dashboard that only exists in the cluster (drift),
#    or (b) a sign this checkout is stale. We refuse to delete it unless
#    --prune was passed, and we carry its current value forward so the
#    ConfigMap stays complete.
echo ""
echo "Building dashboard ConfigMap from $DASH_DIR/*.json"

# Local keys (basename of each *.json), sorted.
LOCAL_KEYS=()
CM_ARGS=()
for f in "$DASH_DIR"/*.json; do
    [ -f "$f" ] || continue
    key="$(basename "$f")"
    LOCAL_KEYS+=("$key")
    CM_ARGS+=("--from-file=$key=$f")
done

if [ "${#CM_ARGS[@]}" -eq 0 ]; then
    echo "[⚠️] No dashboard JSON files found in $DASH_DIR — refusing to touch the ConfigMap" >&2
    echo "      (an empty local dir would otherwise wipe every live dashboard)" >&2
    exit 1
fi

# Live keys currently in the ConfigMap (may not exist yet on first run).
LIVE_KEYS_RAW="$(kubectl get configmap "$CM_NAME" -n "$NAMESPACE" \
    -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null || true)"

# Live keys with no local file.
ORPHANS=()
while IFS= read -r key; do
    [ -n "$key" ] || continue
    found=0
    for lk in "${LOCAL_KEYS[@]}"; do
        [ "$lk" = "$key" ] && { found=1; break; }
    done
    [ "$found" -eq 0 ] && ORPHANS+=("$key")
done <<< "$LIVE_KEYS_RAW"

if [ "${#ORPHANS[@]}" -gt 0 ]; then
    if [ "$PRUNE" -eq 1 ]; then
        echo "[ ] --prune: removing ${#ORPHANS[@]} dashboard(s) not present locally:"
        printf '      - %s\n' "${ORPHANS[@]}"
        echo "      These will be DELETED from Grafana by the file provider."
    else
        echo "[⚠️] ${#ORPHANS[@]} live dashboard(s) have no local *.json — PRESERVING them:"
        printf '      - %s\n' "${ORPHANS[@]}"
        echo "      (additive mode; pass --prune to delete. Commit them to git to track.)"
        # Re-apply each orphan's CURRENT value byte-for-byte. We read the whole
        # ConfigMap as JSON and write each value to a temp file (rather than
        # go-template, whose command substitution would strip the trailing
        # newline and cause ConfigMap churn on every run).
        ORPHAN_TMP="$(mktemp -d)"
        kubectl get configmap "$CM_NAME" -n "$NAMESPACE" -o json > "$ORPHAN_TMP/cm.json"
        for key in "${ORPHANS[@]}"; do
            python3 - "$ORPHAN_TMP/cm.json" "$key" "$ORPHAN_TMP/$key" <<'PYEOF'
import json, sys
cm = json.load(open(sys.argv[1]))
with open(sys.argv[3], "w") as fh:
    fh.write(cm["data"][sys.argv[2]])
PYEOF
            CM_ARGS+=("--from-file=$key=$ORPHAN_TMP/$key")
        done
    fi
fi

kubectl create configmap "$CM_NAME" \
    --namespace="$NAMESPACE" \
    "${CM_ARGS[@]}" \
    --dry-run=client -o yaml | kubectl apply -f -
echo "[✅] Dashboard ConfigMap applied (${#LOCAL_KEYS[@]} local + ${#ORPHANS[@]} preserved)"
if [ -n "${ORPHAN_TMP:-}" ]; then rm -rf "$ORPHAN_TMP"; fi

# 3. Wait for the pod to be ready
echo ""
echo "Waiting for Grafana pod to be ready..."
if kubectl wait --for=condition=Ready pod \
        -l app=grafana \
        -n "$NAMESPACE" \
        --timeout=180s 2>/dev/null; then
    echo "[✅] Grafana pod is running"
else
    echo "[⚠️] Grafana pod did not become Ready within 180s"
    echo "      Check: kubectl describe pod -n ai -l app=grafana"
fi

# 4. Ingress status
echo ""
echo "Grafana Ingress:"
kubectl get ingress grafana-ingress -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[*].ip}' 2>/dev/null || true
echo ""

# 5. URL info
echo ""
echo "Access Grafana at:  https://grafana.caehomelab.com"
echo "Login:              admin / admin   (CHANGE AFTER FIRST LOGIN)"
echo "InfluxDB token:     kubectl get secret -n ai influxdb-secrets -o jsonpath='{.data.INFLUX_TOKEN}' | base64 -d"
echo ""
