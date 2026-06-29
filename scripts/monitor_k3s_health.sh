#!/usr/bin/env bash
set -euo pipefail  # Strict mode to catch errors early before they cause math crashes!

# -- InfluxDB Configuration --------------------------------------------------
INFLUX_URL="http://aiserver.home:8086/api/v2/write?org=home&bucket=k3s_metrics"
TOKEN="INFLUX_TOKEN_REDACTED"

# --- Initialize every variable to a safe default right away! ----------------
NODE_TOTAL=0; NODE_READY=0; PODS_TOTAL=0; PODS_FAILED=0; FAILED_PVS=0

while true; do
    # --- 1. Node Health ------------------------------------------------------
    if [ -f /etc/rancher/k3s/k3s.yaml ]; then
        raw_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
        NODE_TOTAL=${raw_nodes:-0} # Strict fallback!
        
        raw_ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$5 == "Ready" {print $1}' | wc -l)
        NODE_READY=${raw_ready:-0}

        # --- 2. Pod & Storage Health -------------------------------------------
        total_pods=$(kubectl get pods --all-namespaces -o jsonpath='{.items*.metadata.name}' 2>/dev/null >/dev/null && echo "1" || echo "")
        if [ "${#total_pods:-0}" -gt 0 ]; then 
            PODS_TOTAL=$(kubectl get po -A | wc -l) || PODS_TOTAL=0
            PODS_FAILED=$(kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded -o jsonpath='{.items[].metadata.name}' 2>/dev/null | wc -w) || PODS_FAILED=0
        fi

        raw_pvs=$(kubectl get pv --no-headers 2>/dev/null | awk '{print $4}') 
        FAILED_PVS=${raw_pvs//[^0-9]/} # Force only digits
        if [ -z "$FAILED_PVS" ]; then FAILED_PVS=0; fi
    else
        echo "⚠️ kubectl not found! Sending zeros as fallback."
    fi

    # --- 3. Send to InfluxDB Bucket -------------------------------------------
    curl -s --max-time 5 "${INFLUX_URL}&precision=s" \
      -H "Authorization: Token ${TOKEN}" \
      -d "k8s_cluster_health,host=$(hostname) count_total_nodes=${NODE_TOTAL},nodes_ready_pct=$(( NODE_READY / NODE_TOTAL * 100 )),pods_total=${PODS_TOTAL},failed_pods=${PODS_FAILED},stuck_storage_volumes=${FAILED_PVS}" > /dev/null

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ Metrics pushed: Nodes ${NODE_READY}/${NODE_TOTAL} | Pods Failed: ${PODS_FAILED} | Stuck Vols: ${FAILED_PVS}"
    sleep 60 
done
