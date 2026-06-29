#!/usr/bin/env bash
# CE AI Lab - K3s Cluster Health Metrics Pusher
# Sends raw counters to InfluxDB every 60 seconds.

INFLUX_URL="http://aiserver.home:8086/api/v2/write?org=home&bucket=k3s_metrics&precision=s"
TOKEN="INFLUX_TOKEN_REDACTED"
LOG="/var/log/k3s-metrics-push.log"

# Ensure log file exists
touch "$LOG" 2>/dev/null || chmod 666 "$LOG" 2>/dev/null || true

while true; do
    # ---- Gather Metrics ----
    NODE_TOTAL=0
    NODE_READY=0
    PODS_TOTAL=0
    PODS_FAILED=0
    FAILED_PVS=0

    if command -v kubectl &>/dev/null; then
        raw=$(kubectl get nodes --no-headers 2>/dev/null || true)
        if [ -n "$raw" ]; then
            NODE_TOTAL=$(echo "$raw" | wc -l | tr -d ' ')
            NODE_READY=$(echo "$raw" | awk '$2 == "Ready" {c++} END {print c+0}')
        fi

        pods_out=$(kubectl get po -A --no-headers 2>/dev/null || true)
        if [ -n "$pods_out" ]; then
            PODS_TOTAL=$(echo "$pods_out" | wc -l | tr -d ' ')
        fi

        fail_raw=$(kubectl get pods --all-namespaces \
            --field-selector=status.phase!=Running,status.phase!=Succeeded \
            2>/dev/null | tail -n +2 || true)
        if [ -n "$fail_raw" ]; then
            PODS_FAILED=$(echo "$fail_raw" | grep -c . || echo "0")
        fi

        pv_fail=$(kubectl get pv --no-headers 2>/dev/null | awk '$5 == "Lost" || $5 == "Pending" {print}' || true)
        if [ -n "$pv_fail" ]; then
            FAILED_PVS=$(echo "$pv_fail" | wc -l | tr -d ' ')
        fi
    else
        echo "[$(date '+%H:%M:%S')] ⚠️ kubectl not found, sending zeros" >> "$LOG" 2>&1
        NODE_TOTAL=0; NODE_READY=0; PODS_TOTAL=0; PODS_FAILED=0; FAILED_PVS=0
    fi

    # ---- Prevent division by zero ----
    if [ "$NODE_TOTAL" -gt 0 ] 2>/dev/null; then
        NODE_HEALTH=$(awk "BEGIN {printf \"%.1f\", ($NODE_READY / $NODE_TOTAL) * 100}")
    else
        NODE_HEALTH=0
    fi

    # ---- Send to InfluxDB ----
    curl_output=$(curl -s --max-time 5 \
        "${INFLUX_URL}" \
        -H "Authorization: Token ${TOKEN}" \
        -d "k8s_cluster_health,host=$(hostname) nodes_total=${NODE_TOTAL},nodes_ready_pct=${NODE_HEALTH},pods_total=${PODS_TOTAL},pods_failed_pending=${PODS_FAILED},stuck_pv_count=${FAILED_PVS}" 2>&1) || curl_output="CURL_ERROR: ${curl_output}"

    if [ -z "$curl_output" ]; then
        echo "[$(date '+%H:%M:%S')] ✅ Metrics sent: Nodes ${NODE_READY}/${NODE_TOTAL} | Pods Failed: ${PODS_FAILED} | PVs: ${FAILED_PVS}" >> "$LOG" 2>&1
    else
        echo "[$(date '+%H:%M:%S')] ⚠️ InfluxDB error: ${curl_output}" >> "$LOG" 2>&1
    fi

    sleep 60
done
