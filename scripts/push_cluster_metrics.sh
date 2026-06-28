#!/usr/bin/env bash
###############################################################################
# CE AI Lab - Kubernetes Metrics Pusher (Unbreakable Edition)
# Description: Collects live Linux system stats and pushes them to InfluxDB.
###############################################################################

INFLUX_URL_BASE="http://aiserver.home:8086/api/v2/write"
INFLUX_ORG="home"
INFLUX_BUCKET="kube_metrics"
INFLUX_TOKEN="INFLUX_TOKEN_REDACTED"

HOSTNAME=$(hostname)
echo "[✅] Metrics pusher initialized on host: ${HOSTNAME} at $(date)" >&2

# Pure Bash math function (no 'bc' dependency required!)
calc_percent() {
    local num=$1 den=$2
    if [ "$den" -eq 0 ] 2>/dev/null; then echo "0.0"; return; fi
    # Use awk for decimal percentage calculation that works everywhere
    awk "BEGIN {printf \"%.2f\", ($num * 100.0) / $den}"
}

while true; do
    # --- CPU Calculation ----------------------------------------------------
    read -r user nice system idle iowait rest < /proc/stat
    total_cycles=$((user + nice + system + idle))
    used_cycles=$((total_cycles - idle - iowait))
    
    cpu_pct=$(calc_percent "$used_cycles" "$total_cycles")

    # --- Memory Calculation -------------------------------------------------
    mem_total=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
    mem_available=$(grep '^MemAvailable:' /proc/meminfo | awk '{print $2}')
    
    # Default to safe values if grep fails or returns empty
    : "${mem_total:=1}"  # Prevent division by zero
    : "${mem_available:=0}"

    mem_pct=$(calc_percent "$mem_available" "$mem_total")

    # --- Uptime Calculation -------------------------------------------------
    uptime_s=$(awk '{printf "%d", $1}' /proc/uptime)

    # --- Send to InfluxDB ---------------------------------------------------
    INFLUX_URL="${INFLUX_URL_BASE}?org=${INFLUX_ORG}&bucket=${INFLUX_BUCKET}&precision=s"
    
    if curl -sf --max-time 5 "$INFLUX_URL" \
         -H "Authorization: Token ${INFLUX_TOKEN}" \
         -d "cpu_load_pct,host=${HOSTNAME} value=${cpu_pct} 
system_mem_free_pct,host=${HOSTNAME} value=${mem_pct} 
node_uptime_sec,host=${HOSTNAME} value=${uptime_s}" > /dev/null 2>&1; then
        
        echo "[$(date '+%H:%M:%S')] ✅ Pushed: CPU=${cpu_pct}% | Mem=${mem_pct}% | Uptime=${uptime_s}s" >&2
    else
        echo "[$(date '+%H:%M:%S')] ⚠️ Could not reach InfluxDB!" >&2
    fi

    sleep 60
done
