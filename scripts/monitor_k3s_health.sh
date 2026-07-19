#!/usr/bin/env bash
# CE AI Lab - K3s Cluster Health Metrics Pusher (single-shot)
#
# Runs once, collects cluster health + pod resource metrics via kubectl,
# and pushes them to InfluxDB v2. Designed to be triggered by a systemd
# timer (see scripts/systemd/k3s-metrics-push.timer) every 60s.
#
# Token sourcing (in priority order):
#   1. INFLUX_TOKEN env var (if set — useful for manual runs/tests)
#   2. Infisical secret INFLUXDB_TOKEN, fetched via the helper in
#      scripts/infisical-agent.sh (the canonical source for the homelab).
#
# Optional env:
#   INFLUX_HOST    default: http://aiserver.home:8086
#   INFLUX_ORG     default: home
#   INFLUX_BUCKET  default: kube_metrics
#
# Logs go to stdout/stderr so systemd captures them in journald:
#   journalctl -u k3s-metrics-push.service -f

set -u

INFLUX_HOST="${INFLUX_HOST:-http://aiserver.home:8086}"
INFLUX_ORG="${INFLUX_ORG:-home}"
INFLUX_BUCKET="${INFLUX_BUCKET:-kube_metrics}"
TOKEN="${INFLUX_TOKEN:-}"

# Fetch the token from Infisical if not provided in the environment.
if [ -z "$TOKEN" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$SCRIPT_DIR/infisical-agent.sh" ]; then
        # shellcheck disable=SC1091
        . "$SCRIPT_DIR/infisical-agent.sh" 2>/dev/null || true
        TOKEN="$(infs get INFLUXDB_TOKEN 2>/dev/null)" || TOKEN=""
    fi
fi

if [ -z "$TOKEN" ]; then
    echo "[$(date '+%H:%M:%S')] INFLUX_TOKEN unavailable (env not set and Infisical fetch failed)" >&2
    exit 1
fi

INFLUX_URL="${INFLUX_HOST}/api/v2/write?org=${INFLUX_ORG}&bucket=${INFLUX_BUCKET}&precision=s"

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

# Convert "250m" / "1" (cores) to integer millicores.  Echoes 0 on parse failure.
to_millicores() {
    local v="$1"
    case "$v" in
        *m) v="${v%m}" ;;
        *)  v=$(awk -v x="$v" 'BEGIN{print int(x*1000)}') ;;
    esac
    echo "${v:-0}"
}

# Convert "256Mi" / "1Gi" / "512Ki" / bare bytes to integer KiB.
to_kib() {
    local v="$1"
    case "$v" in
        *Gi) v=$(awk -v x="${v%Gi}" 'BEGIN{print int(x*1024*1024)}') ;;
        *Mi) v=$(awk -v x="${v%Mi}" 'BEGIN{print int(x*1024)}') ;;
        *Ki) v=$(awk -v x="${v%Ki}" 'BEGIN{print int(x)}') ;;
        *G)  v=$(awk -v x="${v%G}"  'BEGIN{print int(x*1024*1024)}') ;;
        *M)  v=$(awk -v x="${v%M}"  'BEGIN{print int(x*1024)}') ;;
        *)   v=$(awk -v x="$v" 'BEGIN{print int(x/1024)}') ;;
    esac
    echo "${v:-0}"
}

# Line-protocol safe: escape commas, spaces, equals in tag values.
escape_lp() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/,/\\,/g' -e 's/ /\\ /g' -e 's/=/\\=/g'
}

# Influx line-protocol write. Logs failures to stderr (journald captures it).
influx_write() {
    local line="$1"
    local out
    out=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' \
        "${INFLUX_URL}" \
        -H "Authorization: Token ${TOKEN}" \
        --data-binary "${line}" 2>&1) || out="curl-fail"
    if [ "$out" != "204" ] && [ "$out" != "200" ]; then
        echo "[$(date '+%H:%M:%S')] Influx write failed (${out}): ${line}" >&2
    fi
    return 0
}

# ----------------------------------------------------------------------
# Collect + push (single-shot)
# ----------------------------------------------------------------------

HOST_TAG=$(escape_lp "$(hostname)")

if ! command -v kubectl &>/dev/null; then
    echo "[$(date '+%H:%M:%S')] kubectl not found, sending zeros" >&2
    influx_write "k8s_cluster_health,host=${HOST_TAG} nodes_total=0,nodes_ready_pct=0,pods_total=0,pods_failed_pending=0,stuck_pv_count=0"
    exit 0
fi

# ---- Cluster Health Metrics ----
NODE_TOTAL=0
NODE_READY=0
PODS_TOTAL=0
PODS_FAILED=0
FAILED_PVS=0

raw=$(kubectl get nodes --no-headers 2>/dev/null || true)
if [ -n "$raw" ]; then
    NODE_TOTAL=$(printf '%s\n' "$raw" | wc -l | tr -d ' ')
    NODE_READY=$(printf '%s\n' "$raw" | awk '$2 == "Ready" {c++} END {print c+0}')
fi

pods_out=$(kubectl get po -A --no-headers 2>/dev/null || true)
if [ -n "$pods_out" ]; then
    PODS_TOTAL=$(printf '%s\n' "$pods_out" | wc -l | tr -d ' ')
fi

fail_raw=$(kubectl get pods --all-namespaces \
    --field-selector=status.phase!=Running,status.phase!=Succeeded \
    2>/dev/null | tail -n +2 || true)
if [ -n "$fail_raw" ]; then
    PODS_FAILED=$(printf '%s\n' "$fail_raw" | grep -c . || echo 0)
fi

pv_fail=$(kubectl get pv --no-headers 2>/dev/null | awk '$5 == "Lost" || $5 == "Pending" {print}' || true)
if [ -n "$pv_fail" ]; then
    FAILED_PVS=$(printf '%s\n' "$pv_fail" | wc -l | tr -d ' ')
fi

if [ "${NODE_TOTAL:-0}" -gt 0 ] 2>/dev/null; then
    NODE_HEALTH=$(awk -v r="$NODE_READY" -v t="$NODE_TOTAL" 'BEGIN {printf "%.1f", (r/t)*100}')
else
    NODE_HEALTH="0.0"
fi

influx_write "k8s_cluster_health,host=${HOST_TAG} nodes_total=${NODE_TOTAL},nodes_ready_pct=${NODE_HEALTH},pods_total=${PODS_TOTAL},pods_failed_pending=${PODS_FAILED},stuck_pv_count=${FAILED_PVS}"

# ---- Pod Resource Usage (metrics-server path) ----
if kubectl top nodes &>/dev/null; then
    POD_METRICS=$(kubectl top pods --all-namespaces --no-headers 2>/dev/null || true)
    if [ -n "$POD_METRICS" ]; then
        while IFS=' ' read -r namespace pod cpu mem _rest; do
            [ -z "$namespace" ] || [ -z "$pod" ] || [ -z "$cpu" ] && continue
            ns_t=$(escape_lp "$namespace")
            pod_t=$(escape_lp "$pod")
            cpu_mc=$(to_millicores "$cpu")
            mem_kb=$(to_kib "$mem")
            influx_write "k8s_pod_resources,host=${HOST_TAG},namespace=${ns_t},pod=${pod_t} cpu_millicores=${cpu_mc},memory_kb=${mem_kb}"
        done <<< "$POD_METRICS"
    fi
fi

# ---- Pod Restart Counts ----
pod_restart_data=$(kubectl get pods --all-namespaces \
    -o custom-columns='NAMESPACE:{.metadata.namespace},POD:{.metadata.name},RESTARTS:{.status.containerStatuses[0].restartCount}' \
    2>/dev/null | tail -n +2 || true)
if [ -n "$pod_restart_data" ]; then
    while read -r ns pod rest_count; do
        [ -z "$ns" ] || [ -z "$pod" ] && continue
        : "${rest_count:=0}"
        ns_t=$(escape_lp "$ns")
        pod_t=$(escape_lp "$pod")
        influx_write "k8s_pod_restarts,host=${HOST_TAG},namespace=${ns_t},pod=${pod_t} count=${rest_count}i"
    done <<< "$pod_restart_data"
fi

echo "[$(date '+%H:%M:%S')] Nodes ${NODE_READY}/${NODE_TOTAL} | Failed pods: ${PODS_FAILED} | Stuck PVs: ${FAILED_PVS}"
exit 0