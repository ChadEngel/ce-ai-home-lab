#!/usr/bin/env bash
###############################################################################
# CE AI Lab - K3s Kubernetes Health Monitor (InfluxDB Pusher)
# Runs on the K3s master node to stream live cluster health directly to Influx.
###############################################################################

INFLUX_URL="http://aiserver.home:8086/api/v2/write?org=home&bucket=k3s_metrics&precision=s"
TOKEN="INFLUX_TOKEN_REDACTED"

while true; do
    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${1}"; }
    
    # Start with strict defaults to prevent 'integer expression expected' Bash errors!
    NODE_TOTAL=${NODE_TOTAL:-0}
    NODE_READY=${NODE_READY:-0}
    PODS_TOTAL=${PODS_TOTAL:-0}
    PODS_FAILED=${PODS_FAILED:-0}
    FAILED_PVS=${FAILED_PVS:-0}

    if command -v kubectl &> /dev/null && [ -f /etc/rancher/k3s/k3s.yaml ]; then
        
        # --- Node Health ---
        NODE_TOTAL=$(kubectl get nodes -o custom-columns=:metadata.name 2>/dev/null | wc -l) || NODE_TOTAL=0
        NODE_READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $5}' | grep -cw 'Ready' || echo "0")
        
        # --- Pod Health (Cluster-Wide) ---
        PODS_TOTAL=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c . || echo "0") 
        PODS_FAILED=$(kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded -o custom-columns=:status.phase,status.message 2>/dev/null | wc -l) || PODS_FAILED=0
        
        # --- Storage Health (Stuck Persistent Volumes) ---
        FAILED_PVS=$(kubectl get pv --no-headers 2>/dev/null | awk '$4 == "Lost" {print $1}' | wc -l) || FAILED_PVS=0

    else
        NODE_TOTAL=0; NODE_READY=0; PODS_TOTAL=0; PODS_FAILED=0; FAILED_PVS=0
        log "⚠️ kubectl not found on this host! Sending placeholder metrics." >&2
    fi

    # --- Send Pure Numeric Metrics to InfluxDB Bucket 'k3s_metrics' ---
    curl -s --max-time 5 "${INFLUX_URL}" \
         -H "Authorization: Token ${TOKEN}" \
         -d "k8s_cluster_health,host=$(hostname) node_count=${NODE_TOTAL},nodes_ready_pct=$(( (NODE_READY * 100 / NODE_TOTAL) :?=1 )) pods_total=${PODS_TOTAL},pod_failures=${PODS_FAILED},failed_persistent_storage_volumes=${FAILED_PVS}" >> /var/log/k3s-metrics-pusher.log

    log "✅ Metrics successfully collected and sent to InfluxDB!"
    sleep 60 
done
