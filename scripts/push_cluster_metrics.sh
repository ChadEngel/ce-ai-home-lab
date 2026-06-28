#!/usr/bin/env bash
###############################################################################
# CE AI Lab - Kubernetes Metrics Pusher (CPU/Memory Uptime)
# Designed to run on a Linux node and push metrics to InfluxDB.
###############################################################################

INFLUX_URL_BASE="http://aiserver.home:8086/api/v2/write"
INFLUX_ORG="home"
INFLUX_BUCKET="kube_metrics"
INFLUX_TOKEN="INFLUX_TOKEN_REDACTED"

SERVER_HOSTNAME=$(hostname)
LOG_FILE="/var/log/metrics-pusher.log"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/metrics-pusher.log"

log_msg() {
    echo "[${SERVER_HOSTNAME}] [$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Helper function to calculate percentages safely using awk (No dependencies!)
calc_pct() {
    local num=$1
    local den=$2
    if [ "$den" -eq 0 ] 2>/dev/null; then echo "0.00"; return; fi
    awk "BEGIN {printf \"%.2f\", ($num / $den) * 100}"
}

log_msg "Initializing metrics collector on host: ${SERVER_HOSTNAME}"

# --- Main Infinite Loop ---------------------------------------------------
while true; do
    
    # --- 1. CPU Metrics (Skip first 2 columns: 'cpu' and the number)
    read -r u n s i w irq sf st g gn < <(tail -n +3 /proc/stat | awk '/^cpu / {print $3, $4, $5, $6, $7, $8, $9, $10, $11, $12}' | head -n1)
    
    # Calculate total cycles (excluding guest and guest_nice for standard usage%)
    # We subtract guest time to get real user CPU load
    if [ "$u" -ge 0 ] && [ "$n" -ge 0 ]; then
        total_cpu=$((u + n + s + i + w))
        used_cpu=$((total_cpu - i - w)) # Real load is everything except idle and wait
        cpu_usage_pct=$(calc_pct "$used_cpu" "$total_cpu")
    else
        cpu_usage_pct="0.00" # Fallback if /proc/stat hasn't loaded yet
    fi

    # --- 2. Memory Metrics --------------------------------------------------
    mem_total=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
    mem_available=$(grep '^MemAvailable:' /proc/meminfo | awk '{print $2}')
    
    : "${mem_total:=1}"  # Fallback to prevent division-by-zero if /proc fails
    : "${mem_available:=0}"
    
    mem_free_pct=$(calc_pct "$mem_available" "$mem_total")

    # --- 3. Uptime Metrics --------------------------------------------------
    uptime_secs=$(awk '{printf "%d", $1}' /proc/uptime)

    # --- 4. Push Data to InfluxDB -------------------------------------------
    curl -sf --max-time 5 "${INFLUX_URL_BASE}?org=${INFLUX_ORG}&bucket=${INFLUX_BUCKET}&precision=s" \
         -H "Authorization: Token ${INFLUX_TOKEN}" \
         -d "cpu_load_pct,host=${SERVER_HOSTNAME} value=${cpu_usage_pct} 
system_mem_free_pct,host=${SERVER_HOSTNAME} value=${mem_free_pct} 
node_uptime_sec,host=${SERVER_HOSTNAME} value=${uptime_secs}" >> "$LOG_FILE" 2>&1

    if [ $? -eq 0 ]; then
        log_msg "✅ Success -> CPU: ${cpu_usage_pct}% | Mem Free: ${mem_free_pct}% | Uptime: ${uptime_secs}s"
    else
        log_msg "❌ Failed to push metrics to InfluxDB (Network/Auth issue)"
    fi

    # Sleep for 60 seconds before gathering the next snapshot 🛌
    sleep 60 

done
