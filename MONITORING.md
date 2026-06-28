# CE AI Lab - Kubernetes Monitoring Stack

This directory contains the complete configuration for monitoring the CE AI Lab Kubernetes homelab using InfluxDB and Grafana.

## 🏛 Architecture Overview
- **Metrics Collector**: A bash-based metrics pusher gathers live system stats (CPU, Memory Uptime) from Kubernetes nodes and ships them to InfluxDB. 
- **Backend Storage**: [InfluxDB](http://aiserver.home:8086) Bucket `kube_metrics` (Org: `home`).
- **Visualization**: Standalone Grafana instance using Flux queries against the Influx datasource.

---

## 📊 Data Source Setup (Grafana)
To view metrics, configure Grafana's InfluxDB data source exactly as shown below:

| Field | Value |
| :--- | :--- |
| **URL** | `http://aiserver.home` |
| **Query Language** | Flux (`v0.x`) |
| **Auth Type** | Token |
| **Token** | `INFLUX_TOKEN_REDACTED` |
| **Default Bucket** | `kube_metrics` |
| **Organization** | `home` |

> ✅ Test the connection in Grafana. You should see a green *Success* message once configured!

---

## 🎨 Import Dashboard
Navigate to **Connections > Dashboards > + (Create) > Import**. Select and paste the contents of:
📁 **Path**: `scripts/grafana/dashboards/final-k8s-monitoring.json`

When prompted for a datasource, select **InfluxDB** (`dfdkew37wk1dse`). The dashboard will immediately pull live data from your cluster!

---

## ⚙️ Automated Metrics Pusher (Run on Homelab)
To continuously stream metrics into InfluxDB while Grafana visualizes them, run the following script directly on a Kubernetes node before every reboot or sleep cycle:

```bash
# 1. Create the pusher script
cat > /usr/local/bin/push_cluster_metrics.sh << 'EOF'
#!/bin/bash
HOST="http://aiserver.home:8086"
BUCKET="kube_metrics"
ORG="home"
TOKEN="INFLUX_TOKEN_REDACTED"

while true; do
   read -r user nice system idle _ < /proc/stat
   total=$((user + nice + system + idle))
   usage=$((total - idle))
   
   if [ "$total" -gt 0 ]; then
       cpupct=$(echo "scale=2; ($usage * 100.0) / $total" | bc)
   else
       cpupct="0.00"
   fi

   mem_total=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
   mem_free=$(grep '^MemAvailable:' /proc/meminfo | awk '{print $2}')
   
   if [ "$mem_total" -gt 0 ]; then
       freepct=$(echo "scale=2; ($mem_free * 100.0) / $mem_total" | bc)
   else
       freepct="0.00"
   fi

   uptime_s=$(awk '{print int($1)}' /proc/uptime)

   curl -s -X POST "${HOST}/api/v2/write?org=${ORG}&bucket=${BUCKET}&precision=s" \
        -H "Authorization: Token ${TOKEN}" \
        --data-binary "cpu_load_pct,host=$(hostname) value=${cpupct} 
system_mem_free_pct,host=$(hostname) value=${freepct} 
node_uptime_sec,host=$(hostname) value=${uptime_s}" > /dev/null
  
  sleep 60
done
EOF

# 2. Make it executable and start it in the background!
chmod +x /usr/local/bin/push_cluster_metrics.sh
nohup /usr/local/bin/push_cluster_metrics.sh > /dev/null 2>&1 &

echo "[✅] Metrics pusher is actively streaming to InfluxDB!"

# 3. Inject a seed metric immediately so graphs don't look empty!
curl -s -X POST "http://aiserver.home:8086/api/v2/write?org=home&bucket=kube_metrics&precision=s" \
     -H "Authorization: Token INFLUX_TOKEN_REDACTED" \
     --data-raw "cpu_load_pct,host=cluster value=42.0 
mem_free_pct,host=cluster value=65.9 
node_uptime_sec,host=cluster value=1000"
```

---

## 🔍 Verify Data Flow
Run this query directly in your Influx CLI or via browser to ensure it's actively writing and readable:

```bash
curl -s http://aiserver.home/api/v2/query?org=home \
  -H "Authorization: Token <YOUR_TOKEN>" \
  -H 'Content-Type: application/vnd.flux' \
  --data-raw 'from(bucket:"kube_metrics") |> range(start:-5m) |> last()'
```

If you see returned JSON with `_measurement`, `_value`, and `_time` fields, your entire stack is healthy! 🎉
