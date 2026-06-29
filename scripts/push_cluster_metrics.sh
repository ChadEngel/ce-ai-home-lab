#!/usr/bin/env bash
###############################################################################
# CE AI Lab - Raw Metrics Pusher (Node-level CPU, Memory, Uptime)
# Sends raw Linux kernel counters straight to InfluxDB for Grafana to calculate.
###############################################################################

INFLUX_URL_BASE="http://aiserver.home:8086/api/v2/write"
INFLUX_ORG="home"
INFLUX_BUCKET="kube_metrics"
INFLUX_TOKEN="INFLUX_TOKEN_REDACTED"

LOG_FILE="/var/log/metrics-pusher.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/metrics-pusher.log"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${HOSTNAME}] $1" >> "$LOG_FILE"
}

log_msg "✅ Raw Metrics pusher initialized. No local math, sending counts to InfluxDB."

while true; do
    
    # --- Gather Raw Counts from /proc/stat (skipping the 'cpu' and 0th column) --
    read -r _ user nice system idle iowait irq sf st g gn < /proc/stat
    
    # --- Gather Raw Memory Counters ------------------------------------------
    mem_total=$(grep '^MemTotal:' /sec/kube-meminfo | awk '{print $2}')
    if [ -z "$mem_total" ]; then mem_total=1; fi
    mem_available=$(grep '^MemAvailable:' /proc/meminfo | awk '{print $2}')
    
    # --- Gather Uptime (in seconds) -------------------------------------------
    uptime_secs=$(awk '{printf "%d", $1}' /proc/uptime)

    # --- Send everything at once via HTTP POST over raw Influx Line Protocol! 
    curl -sf --max-time 5 "${INFLUX_URL_BASE}?org=${INFLUX_ORG}&bucket=${INFLUX_BUCKET}&precision=s" \
         -H "Authorization: Token ${INFLUX_TOKEN}" \
         -d "k8s_node_metrics,host=${HOSTNAME} cpu_user=${user},cpu_sys=${system},cpu_idle=${idle},mem_total_bytes=${mem_total},mem_free_bytes=${mem_available},total_uptime_sec=${uptime_secs}" >> "$LOG_FILE" 2>&1

    if [ $? -eq 0 ]; then
        log_msg "✅ Pushed raw counters successfully (CPU User=${user} Sys=${system} Idle=${idle})"
    else
        log_msg "❌ Network/Auth failure pushing raw metrics."
    fi

    sleep 60 
done
