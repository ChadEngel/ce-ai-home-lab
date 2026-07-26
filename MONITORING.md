# CE AI Lab — Monitoring Stack

InfluxDB v2 stores cluster + network metrics. Grafana visualises them.

- **InfluxDB**: `http://aiserver.home:8086` (org `home`, buckets:
  `kube_metrics`, `mac_metrics`, `network_metrics`)
- **Grafana**: `https://grafana.caehomelab.com` (deployed from
  `clusters/util-server/applications/grafana/`)
- **Writers**:
  - `scripts/monitor_k3s_health.sh` — k8s cluster/pod metrics → `kube_metrics`
    (runs as a systemd service on a node; see below)
  - **unpoller** — UniFi network metrics from the UDM Pro → `network_metrics`
    (runs as a k8s Deployment in the `ai` namespace; see
    `clusters/util-server/applications/unpoller/`)

## Token model (read vs write — keep them separate)

InfluxDB uses **two** separate tokens, stored in Infisical
(`caehomelab-v1q6` / `prod` / `/`):

| Infisical key | Capability | Consumed by |
|---|---|---|
| `INFLUXDB_TOKEN` | **write** `kube_metrics` + `network_metrics` | the k8s metrics writer (`monitor_k3s_health.sh` via `infs get INFLUXDB_TOKEN`) and unpoller |
| `INFLUXDB_READ_TOKEN` | **read** all 3 buckets, no write | Grafana datasource |

Why split: a single shared token means rotating Grafana's access to a
read-only scope silently breaks every writer (writes start 403'ing) — which
is exactly how the k8s metrics feed died once. The Infisical Kubernetes
operator syncs these into separate k8s Secrets:

- `ai/influxdb-secrets[INFLUX_TOKEN]` ← `INFLUXDB_READ_TOKEN` (Grafana)
- `ai/unpoller-secrets[INFLUXDB_TOKEN,UDM_API_KEY]` ← the write token + the
  UniFi API key (unpoller)

Both sync CRs live in
`clusters/util-server/applications/infisical-operator/infisical-secrets-sync.yaml`.
Grafana renders its token at pod start via an `envsubst` initContainer, so
**rotating either token requires `kubectl rollout restart deployment/grafana`**
(or `deployment/unpoller`) to take effect.

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
#    The writer reads INFLUXDB_TOKEN from Infisical at runtime
#    (scripts/infisical-agent.sh: `infs get INFLUXDB_TOKEN`), so this
#    file only needs the non-secret connection details. INFLUX_TOKEN may
#    still be set here to override (e.g. for a manual test run).
sudo tee /etc/default/k3s-metrics-push >/dev/null <<'EOF'
INFLUX_HOST="http://aiserver.home:8086"
INFLUX_ORG="home"
INFLUX_BUCKET="kube_metrics"
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

The Grafana stack is provisioned automatically. Grafana's InfluxDB
datasource token is **not** created by hand — it is synced from Infisical
`INFLUXDB_READ_TOKEN` into the `influxdb-secrets` K8s Secret by the
Infisical operator (see the InfisicalSecret CR `influxdb-secrets-sync` in
`clusters/util-server/applications/infisical-operator/infisical-secrets-sync.yaml`).
An `envsubst` initContainer renders the token into the datasource file at
pod start.

```bash
./scripts/deploy-grafana.sh
```

This applies the kustomization and builds a `grafana-dashboards-json`
ConfigMap from `scripts/grafana/dashboards/*.json`. The file provider
in Grafana picks the dashboards up from `/var/lib/grafana/dashboards/default`.

After rotating `INFLUXDB_READ_TOKEN` in Infisical, restart Grafana so the
initContainer re-renders: `kubectl rollout restart deployment/grafana -n ai`.

## unpoller (UniFi network metrics → network_metrics)

unpoller polls the UDM Pro controller (`https://192.168.250.1`) using a
UniFi OS **API key** (Infisical `UDM_API_KEY`, exclusive of user/pass auth)
and writes UniFi metrics to the `network_metrics` bucket. It runs in k8s
(not on the UDM) so it survives UDM firmware upgrades — UniFi OS wipes
on-box add-on packages on upgrade, which is what killed the previous
on-UDM telegraf collector.

The write token it uses is the same Infisical `INFLUXDB_TOKEN` the k8s
writer uses (synced into a separate `unpoller-secrets` Secret). The
`up.conf` is rendered at pod start from a ConfigMap template via
`envsubst` (the unpoller image is distroless / has no shell), mirroring the
Grafana initContainer pattern.

```bash
./scripts/deploy-unpoller.sh
```

After rotating `INFLUXDB_TOKEN` or `UDM_API_KEY` in Infisical, restart:
`kubectl rollout restart deployment/unpoller -n ai`.

Note: unpoller logs a non-fatal `integration .../firewall/zones ... 400`
error every cycle on current UDM firmware — it's a controller API quirk
and does not affect the rest of the collection.

## Dashboards

- **CE AI Lab – Kubernetes Realtime View** (`ceai-k8s-influx-metrics`):
  node health percentage, total/ready nodes, total pods, failed
  pods, stuck PV count, and trend graphs.
- **CE AI Lab – Pod Resources & OOM Monitoring** (`ceai-pod-resources`):
  per-pod CPU and memory, plus a table of pods that have restarted.

## Verify data is flowing

Use the **read** token (`INFLUXDB_READ_TOKEN` from Infisical) for queries:

```bash
INFLUX_TOKEN='<INFLUXDB_READ_TOKEN>'
# k8s metrics (writer)
curl -s "http://aiserver.home:8086/api/v2/query?org=home" \
  -H "Authorization: Token $INFLUX_TOKEN" \
  -H 'Content-type: application/vnd.flux' \
  --data 'from(bucket:"kube_metrics") |> range(start:-5m) |> last()' | head -c 500
# network metrics (unpoller) — newest timestamps should be < 60s old
curl -s "http://aiserver.home:8086/api/v2/query?org=home" \
  -H "Authorization: Token $INFLUX_TOKEN" \
  -H 'Content-type: application/vnd.flux' \
  --data 'from(bucket:"network_metrics") |> range(start:-2m) |> keep(columns:["_time","_measurement"]) |> group() |> sort(desc:true) |> limit(n:3)'
```

You should see recent rows with `_measurement=k8s_cluster_health` (writer)
and UniFi measurements like `uap`, `usw`, `usg`, `clients`, `wan` (unpoller).
(Grafana's datasource UID `dfdkew37wk1dse` proxies the same queries.)
