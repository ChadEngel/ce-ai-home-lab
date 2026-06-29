#!/usr/bin/env bash
set -euo pipefail

INFLUX_URL="http://aiserver.home:8086/api/v2/write?org=home&bucket=k3s_metrics"
TOKEN="INFLUX_TOKEN_REDACTED"
LOG="/var/log/k3s-metrics-push.log"

log() { echo "[$(date '+%H:%M:%S')] ${1}" | tee -a "$LOG"; }

# Strict safe defaults  
NODE_TOTAL=0; NODE_READY=0; PODS_TOTAL=0; PODS_FAILED=0; FAILED_PVS=0

if command -v kubectl &>/dev/null && [ -f /etc/rancher/k3s/k3s.yaml ]; then
    
    # --- Nodes -----------------------------------------------------------
    raw_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ') || raw_nodes=""
    NODE_TOTAL="${raw_nodes:-0}"

    if [ "$NODE_TOTAL" -gt 0 ] 2>/dev/null; then
        # STATUS is column $2 (NAME=$1, STATUS=$2, ROLES=$3...)
        raw_ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {print}' | wc -l | tr -d ' ') || raw_ready=""
        NODE_READY="${raw_ready:-0}"
        
        # --- Pod totals ----------------------------------------------------
        raw_pods=$(kubectl get po -A --no-headers 2>/dev/null | wc -l | tr -d ' ') || raw_pods=""
        PODS_TOTAL="${raw_pods:-0}"
        
        # Failed pods: anything that isn't Running or Succeeded
        raw_failed=$(kubectl get pods --all-namespaces \
            --field-selector=status.phase!=Running,status.phase!=Succeeded \
            2>/dev/null | tail -n +2 | wc -l | tr -d ' ') || raw_failed=""
        PODS_FAILED="${raw_failed:-0}"
        
        # Storage health: PVs that are actually broken (Lost/Pending) — column $5
        raw_lost=$(kubectl get pv --no-headers 2>/dev/null \
            | awk '$5 == "Lost" || $5 == "Pending" {print}' | wc -l | tr -d ' ') || raw_lost=""
        FAILED_PVS="${raw_lost:-0}"
        
    fi
else
    log "⚠️ kubectl not found or /etc/rancher/k3s/k3s.yaml missing!"
fi

# Prevent division by zero — only if NODE_TOTAL is a valid number
if [ "$NODE_TOTAL" -gt 0 ] 2>/dev/null; then
    NODE_HEALTH=$(( NODE_READY * 100 / NODE_TOTAL ))
else
    NODE_HEALTH=0
fi

curl -sf --max-time 5 "${INFLUX_URL}&precision=s" \
     -H "Authorization: Token ${TOKEN}" \
     -d "k8s_cluster_health,host=$(hostname) nodes_total=${NODE_TOTAL},nodes_ready_pct=${NODE_HEALTH},pods_total=${PODS_TOTAL},pods_failed_pending=${PODS_FAILED},stuck_pv_count=${FAILED_PVS}" >> "$LOG" 2>&1

log "✅ Cluster metrics sent: Nodes ${NODE_READY}/${NODE_TOTAL} | Pods Failed: ${PODS_FAILED} | Stuck PVs: ${FAILED_PVS}"
sleep 60 
done
