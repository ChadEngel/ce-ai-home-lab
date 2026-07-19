# CE AI Lab — Monitoring Stack

InfluxDB v2 stores cluster metrics. Grafana visualises them.

- **InfluxDB**: `http://aiserver.home:8086` (org `home`, bucket `kube_metrics`)
- **Grafana**: `https://grafana.caehomelab.com` (deployed from
  `clusters/util-server/applications/grafana/`)
- **Writer**: `scripts/monitor_k3s_health.sh` runs as a service on
  a node (see below)

## What the writer does

Every 60 seconds the script:

1. Collects node-level health (total / ready nodes, pod counts,
   failed/pending pods, stuck PVs) from `kubectl`
2. Collects per-pod CPU, memory, and restart counts (via
   `kubectl top pods`, which requires `metrics-server`)
3. Pushes everything as raw counters to InfluxDB

The Grafana dashboards compute derived values (percentages, sums)
in Flux so the writer stays simple.

## Setup the writer

```bash
# 1. Install the script on a node (the control-plane works fine)
sudo install -m755 scripts/monitor_k3s_health.sh /usr/local/bin/

# 2. Set the required environment variable
sudo tee /etc/default/k3s-metrics-push >/dev/null <<'EOF'
INFLUX_HOST="http://aiserver.home:8086"
INFLUX_ORG="home"
INFLUX_BUCKET="kube_metrics"
INFLUX_TOKEN="<your-influxdb-readwrite-token>"
EOF
sudo chmod 600 /etc/default/k3s-metrics-push

# 3. Run as a systemd service
sudo tee /etc/systemd/system/k3s-metrics-push.service >/dev/null <<'EOF'
[Unit]
Description=CE AI Lab cluster metrics pusher
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/default/k3s-metrics-push
ExecStart=/usr/local/bin/monitor_k3s_health.sh
Restart=always
RestartSec=10
StandardOutput=append:/var/log/k3s-metrics-push.log
StandardError=append:/var/log/k3s-metrics-push.log

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now k3s-metrics-push.service
```

## Set up Grafana

The Grafana stack is provisioned automatically. Before deploying,
make sure the InfluxDB token is set:

```bash
INFLUX_TOKEN='<your-influxdb-readwrite-token>'
kubectl create secret generic influxdb-secrets \
    --from-literal=INFLUX_TOKEN="$INFLUX_TOKEN" -n ai \
    --dry-run=client -o yaml | kubectl apply -f -
```

Then:

```bash
./scripts/deploy-grafana.sh
```

This applies the kustomization and builds a `grafana-dashboards-json`
ConfigMap from `scripts/grafana/dashboards/*.json`. The file provider
in Grafana picks the dashboards up from `/var/lib/grafana/dashboards/default`.

## Dashboards

- **CE AI Lab – Kubernetes Realtime View** (`ceai-k8s-influx-metrics`):
  node health percentage, total/ready nodes, total pods, failed
  pods, stuck PV count, and trend graphs.
- **CE AI Lab – Pod Resources & OOM Monitoring** (`ceai-pod-resources`):
  per-pod CPU and memory, plus a table of pods that have restarted.

## Verify data is flowing

```bash
curl -s "http://aiserver.home:8086/api/v2/query?org=home" \
  -H "Authorization: Token $INFLUX_TOKEN" \
  -H 'Content-Type: application/vnd.flux' \
  --data 'from(bucket:"kube_metrics") |> range(start:-5m) |> last()' | head -c 500
```

You should see JSON rows with `_measurement=k8s_cluster_health` and the
expected fields.
