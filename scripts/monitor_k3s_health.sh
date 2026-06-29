#!/usr/bin/env bash
set -euo pipefail

INFLUX_URL="http://aiserver.home:8086/api/v2/write?org=home&bucket=k3s_metrics"
TOKEN="INFLUX_TOKEN_REDACTED"
LOG="/var/log/k3s-metrics-push.log"

log() { echo "[$(date '+%H:%M:%S')] ${1}" | tee -a "$LOG"; }

# Strict safe defaults (Never crash if kubectl returns empty lines!)
NODE_TOTAL=0; NODE_READY=0; PODS_TOTAL=0; PODS_FAILED=0; FAILED_PVS=0

if command -v kubectl &>/dev/null; then
    # --- Nodes --------------------------------------------------------
    raw_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l) || raw_nodes=0
    NODE_TOTAL=${raw_nodes:-0}

    if [ "$NODE_TOTAL" -gt 0 ]; then
        raw_ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$5 == "Ready" {print $1}' | wc -w) || raw_ready=0
        NODE_READY=${raw_ready:-0}
        
        # --- Pods -------------------------------------------------------
        total_check=$(kubectl get po -A --no-headers 2>/dev/null)
        if [ -n "$(echo "$total_check" | tr -d '[:space:]')" ]; then
            PODS_TOTAL=$(echo "$total_check" | wc -l) || PODS_TOTAL=0
            
            # Count pods that aren't running or succeeded
            fail_raw=$(kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | tail -n +2 | wc -w) || fail_raw=0
            PODS_FAILED=${fail_raw:-0}
        fi

        # --- Storage Volumes --------------------------------------------
        lost_pvs=$(kubectl get pv --no-headers 2>/dev/null | awk '$4 == "Lost" || $4 == "Pending" {print $1}' | wc -w) || lost_pvs=0
        FAILED_PVS=${lost_pvs:-0}
    fi
else
    KUBECONFIG="" # No kubeconfig detected
fi

# Safe arithmetic (Prevent division by zero!)
if [ "$NODE_TOTAL" -gt 0 ]; then
    NODE_HEALTH=$(( NODE_READY * 100 / NODE_TOTAL ))
else
    NODE_HEALTH=0
fi

curl -sf --max-time 5 "${INFLUX_URL}&precision=s" \
     -H "Authorization: Token ${TOKEN}" \
     -d "k8s_cluster_health,host=$(hostname) nodes_total=${NODE_TOTAL},nodes_ready_pct=${NODE_HEALTH},pods_total=${PODS_TOTAL},pods_failed_pending=${PODS_FAILED},stuck_pv_count=${FAILED_PVS}" >> "$LOG"

log "✅ Cluster metrics sent: Nodes ${NODE_READY}/${NODE_TOTAL} | Pods Failed: ${PODS_FAILED} | Stuck PVs: ${FAILED_PVS}"
sleep 60 
done
