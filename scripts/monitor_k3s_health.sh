#!/usr/bin/env bash
# CE AI Lab - K3s Cluster Health Metrics Pusher
# Sends raw counters to InfluxDB every 60 seconds.

INFLUX_URL="http://aiserver.home:8086/api/v2/write?org=home&bucket=kube_metrics&precision=s"
TOKEN="INFLUX_TOKEN_REDACTED"
LOG="/var/log/k3s-metrics-push.log"

# Ensure log file exists
touch "$LOG" 2>/dev/null || chmod 666 "$LOG" 2>/dev/null || true

while true; do
    # ---- Cluster Health Metrics ----
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

        # Prevent division by zero
        if [ "$NODE_TOTAL" -gt 0 ] 2>/dev/null; then
            NODE_HEALTH=$(awk "BEGIN {printf \"%.1f\", ($NODE_READY / $NODE_TOTAL) * 100}")
        else
            NODE_HEALTH=0
        fi

        # ---- Pod Resource Usage (from metrics-server if available) ----
        if kubectl top nodes &>/dev/null; then
            POD_METRICS=$(kubectl top pods --all-namespaces --no-headers 2>/dev/null || true)
            if [ -n "$POD_METRICS" ]; then
                while read -r namespace pod cpu mem rest; do
                    # Convert CPU to millicores (cores * 1000)
                    cpu_mc=$(echo "$cpu" | sed 's/m//; s/Ki//') 
                    if [[ "$cpu" == *"Ki"* ]]; then cpu_mc=$(awk "BEGIN{print $cpu/1024*1000}"); fi
                    if [ -z "$cpu_mc" ] || ! [[ "$cpu_mc" =~ ^[0-9]+$ ]]; then cpu_mc=0; fi
                    
                    # Convert memory to KB
                    mem_kb=$(echo "$mem" | sed 's/Ki//')
                    if [ -z "$mem_kb" ] || ! [[ "$mem_kb" =~ ^[0-9]+$ ]]; then mem_kb=0; fi

                    curl -sf --max-time 3 \
                        "${INFLUX_URL}" \
                        -H "Authorization: Token ${TOKEN}" \
                        -d "k8s_pod_resources,host=$(hostname),namespace=${namespace},pod=${pod} cpu_millicores=${cpu_mc},memory_kb=${mem_kb}" >> "$LOG" 2>&1 || true
                done <<< "$POD_METRICS"
            fi
        else
            # Fallback: use pod resource requests from kube API
            pod_resources=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{","}{.metadata.name}{","}{"{"}{(get (index .spec.containers 0).resources.requests.cpu) if .spec.containers[0] else "0m"}{"}{"}{(get (index .spec.containers 0).resources.requests.memory) if .spec.containers[0] else "0Ki"}{"\n"}{end}' 2>/dev/null || true)
            if [ -n "$pod_resources" ]; then
                echo "$pod_resources" | while IFS=, read -r ns pod req_cpu req_mem; do
                    cpu_mc=${req_cpu%%m}
                    mem_kb=$(echo "$req_mem" | sed 's/Ki//')
                    [ -z "$cpu_mc" ] && cpu_mc=0
                    [ -z "$mem_kb" ] && mem_kb=0
                    curl -sf --max-time 3 \
                        "${INFLUX_URL}" \
                        -H "Authorization: Token ${TOKEN}" \
                        -d "k8s_pod_requests,host=$(hostname),namespace=${ns},pod=${pod} cpu_millicores=${cpu_mc},memory_kb=${mem_kb}" >> "$LOG" 2>&1 || true
                done
            fi
        fi

        # ---- Pod Restart Counts (for debugging OOMKilled/stuck pods) ----
        pod_restart_data=$(kubectl get pods --all-namespaces -o custom-columns='NAMESPACE:{.metadata.namespace},POD:{.metadata.name},RESTARTS:{.status.containerStatuses[0].restartCount}' 2>/dev/null | tail -n +2 || true)
        if [ -n "$pod_restart_data" ]; then
            while IFS=$'\t' read -r ns pod rest_count; do
                [ -z "$rest_count" ] && rest_count=0
                curl -sf --max-time 3 \
                    "${INFLUX_URL}" \
                    -H "Authorization: Token ${TOKEN}" \
                    -d "k8s_pod_restarts,host=$(hostname),namespace=${ns},pod=${pod} count=${rest_count}" >> "$LOG" 2>&1 || true
            done <<< "$pod_restart_data"
        fi

    else
        echo "[$(date '+%H:%M:%S')] ⚠️ kubectl not found, sending zeros" >> "$LOG" 2>&1
        NODE_TOTAL=0; NODE_READY=0; PODS_TOTAL=0; PODS_FAILED=0; FAILED_PVS=0
    fi

    # ---- Send cluster metrics ----
    if [ -z "${curl_output:-}" ]; then
        curl_output=""
    fi
    curl_result=$(curl -s --max-time 5 \
        "${INFLUX_URL}" \
        -H "Authorization: Token ${TOKEN}" \
        -d "k8s_cluster_health,host=$(hostname) nodes_total=${NODE_TOTAL},nodes_ready_pct=${NODE_HEALTH},pods_total=${PODS_TOTAL},pods_failed_pending=${PODS_FAILED},stuck_pv_count=${FAILED_PVS}" 2>&1) || curl_result="CURL_ERROR: ${curl_result}"

    if [ -z "$curl_result" ] || [[ ! "$curl_result" =~ error ]]; then
        echo "[$(date '+%H:%M:%S')] ✅ Cluster: Nodes ${NODE_READY}/${NODE_TOTAL} | Pods Failed: ${PODS_FAILED} | PVs: ${FAILED_PVS}" >> "$LOG" 2>&1
    else
        echo "[$(date '+%H:%M:%S')] ⚠️ InfluxDB error: ${curl_result}" >> "$LOG" 2>&1
    fi

    sleep 60
done
