#!/usr/bin/env bash
###############################################################################
# CE AI Lab - Kubernetes Metrics Pusher
# Description: Collects live Linux system stats and pushes them to InfluxDB.
# Run this on your K8s worker node! It will run continuously until killed.
###############################################################################

set -euo pipefail

# -- InfluxDB Configuration --------------------------------------------------
INFLUX_URL="http://aiserver.home:8086/api/v2/write"
INFLUX_ORG="home"
INFLUX_BUCKET="kube_metrics"
INFLUX_TOKEN="INFLUX_TOKEN_REDACTED"

HOSTNAME=$(hostname)
echo "[✅] Metrics pusher initialized on host: ${HOSTNAME}" >&2
echo "[✅] Pushing data to InfluxDB bucket '${INFLUX_BUCKET}'..." >&2

# -- Main Loop --------------------------------------------------------------
while true; do
    
    # --- CPU Usage Calculation (Non-Idle Percentage) ------------------------
    read -r user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    total_cycles=$((user + nice + system + idle))
    # CPU usage = Total - Idle - IOWait (IOWait isn't true CPU load)
    used_cycles=$((total_cycles - idle - iowait))
    
    if [ "$total_cycles" -gt 0 ]; then
        cpu_pct=$(echo "scale=2; ($used_cycles * 100.0) / $total_cycles" | bc)
    else
        cpu_pct="0.00"
    fi

    # --- Memory Free Percentage Calculation ---------------------------------
    mem_total=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
    mem_available=$(grep '^MemAvailable:' /proc/meminfo | awk '{print $2}')
    
    if [ "$mem_total" -gt 0 ]; then
        mem_pct=$(echo "scale=2; ($mem_available * 100.0) / $mem_total" | bc)
    else
        mem_pct="0.00"
    fi

    # --- Node Uptime in Seconds ---------------------------------------------
    uptime_s=$(awk '{printf "%d", $1}' /proc/uptime)

    # --- Send Metrics to InfluxDB via HTTP POST ---------------------------
    curl -sf --max-time 5 "$INFLUX_URL?org=${INFLUX_ORG}&bucket=${INFLUX_BUCKET}&precision=s" \
         -H "Authorization: Token ${INFLUX_TOKEN}" \
         -d "cpu_load_pct,host=${HOSTNAME} value=${cpu_pct} 
system_mem_free_pct,host=${HOSTNAME} value=${mem_pct} 
node_uptime_sec,host=${HOSTNAME} value=${uptime_s}" > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ Successfully pushed metrics to InfluxDB!" >&2
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Failed to reach InfluxDB (check network/credentials)" >&2
    fi

    sleep 60 # Sleep for 60 seconds before the next data stream 🛌
done
