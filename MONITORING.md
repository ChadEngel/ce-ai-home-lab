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

## udm-thermal (UDM SoC thermal zone + fans → network_metrics)

The UniFi controller API that unpoller uses only exposes **board** temps
(`temp_cpu`/`temp_phy`/`temp_local`). The reading that actually spikes under
CPU load is the **SoC / Linux thermal zone** (`/sys/class/thermal/thermal_zone0`,
type `cpu-thermal`), which is ONLY readable over SSH sysfs and is invisible to
unpoller. The `udm-thermal` collector (`clusters/util-server/applications/`
`udm-thermal/`) closes that gap: it runs in k8s (survives UDM firmware
upgrades, same as unpoller) and every 15s SSHes to the UDM as root to read the
thermal zone, fans, board temps, uptime, load and memory, then writes a
`udm_thermal` measurement to the `network_metrics` bucket with fields:
`up` (1 reachable / 0 unreachable), `soc_temp_c`, `soc_temp_raw`, `fan1_rpm`,
`fan2_rpm`, `uptime_s`, `load1`, `mem_used_pct`, `mem_total_kb`, `mem_avail_kb`,
`board_temp1_c`/`board_temp2_c`/`board_temp3_c`. The `up` flag plus `uptime_s`
are what make a **shutdown/reboot visible** (an `up=0` gap, then an `uptime_s`
reset).

> Note: this collector is the *only* on-device dependency — it reads sysfs over
> SSH. It does **not** require any service installed on the UDM. A legacy
> `telegraf-custom.service` (left over from the old on-UDM setup, failing in a
> restart loop with no binary) was removed; see the git history for that change.

Secrets: `UDM_SSH_PASS` (UDM root SSH password) + `INFLUXDB_TOKEN` (write),
synced from Infisical into the `udm-thermal-secrets` Secret by an
InfisicalSecret CR (see `infisical-secrets-sync.yaml`). The password is passed
to sshpass via `$SSHPASS` (never argv).

**Prereqs (once):** enable SSH on the UDM (Settings → System → Advanced → SSH,
set root password) and add `UDM_SSH_PASS` to Infisical (`caehomelab-v1q6` /
`prod` / root).

```bash
./scripts/deploy-udm-thermal.sh
```

Verify a fresh SoC point lands (~15s): `kubectl logs -n ai -l app=udm-thermal
--tail=5`, or query `_measurement == "udm_thermal"` in `network_metrics`. The
`UDM Temperature` panel in `unifi-network.json` graphs `soc_temp_c` alongside
the unpoller board temps.

## synthetic-monitor (service availability → kube_metrics)

A **client-in-the-cluster** (`clusters/util-server/applications/synthetic-monitor/`)
that every 30s HTTP-checks each core service's health endpoint *from inside the
cluster* (acting as a remote client, so DNS/TLS/ingress/backend are all
exercised) and writes a `service_health` measurement to `kube_metrics`:
fields `up` (1/0), `http_code`, `latency_ms` (total client-observed time),
`server_ms` (service processing only — connection/TLS excluded), `dns_ms`,
`connect_ms`, `tls_ms`; tag `service`.

> **Latency note:** `latency_ms` includes DNS + TCP + TLS + ingress, so HTTPS
> services (bifrost, openwebui) look ~200–300ms slower purely from the TLS
> handshake. Use `server_ms` (≈3–10ms for everything) for a fair cross-service
> comparison; the dashboard shows both.

| service | endpoint checked |
|---------|------------------|
| influxdb | `http://aiserver.home:8086/health` |
| bifrost | `https://llm.caehomelab.com/health` |
| openwebui | `https://ai.caehomelab.com/health` |
| ollama | `http://aiserver.home:11434/api/tags` |

Secret: `INFLUXDB_TOKEN` (write) from `synthetic-monitor-secrets`, synced from
Infisical by `synthetic-monitor-secrets-sync`.

```bash
kubectl apply -f clusters/util-server/applications/synthetic-monitor/kustomization.yaml
```

Dashboard **CE AI Lab — Infrastructure Availability** (`infra-availability`)
shows a **red/yellow/green traffic light** per service (plus UDM reachability,
unioned from `udm_thermal.up`):

- 🟢 **green** = up for the last 10 minutes
- 🟡 **yellow** = recovering (down within the last 10 min but up now)
- 🔴 **red** = down now

## Infrastructure availability alerts (Grafana → Pushover → iPhone)

Two rules in `scripts/grafana/alerts/` cover the four services (UDM has its own
offline/reboot alerts below):

| Alert | Condition | Severity |
|-------|-----------|----------|
| **Infrastructure service down** | state == 0 for 1m | critical (siren) |
| **Infrastructure service recovering** | state == 1 | info (gentle) |

They are per-service (Grafana creates one alert instance per `service` series,
and the notification policy groups by `service`), and both **resolve
automatically** — the resolve message is the all-clear (✅).

## UDM alerts (Grafana → Pushover → iPhone)

Three alerts fire into Pushover. Critical ones use **high priority + siren**
(bypass quiet hours); the informational one uses **normal priority** (chosen by
the `severity` label: `critical` vs `info`).

| Alert | Condition | Severity |
|-------|-----------|----------|
| **UDM SoC temperature high** | `soc_temp_c >= 90` for 1m | critical |
| **UDM offline (unreachable)** | `up == 0` for 2m | critical |
| **UDM rebooted** | `uptime_s < 300` (fresh boot) | info |

Together these capture a shutdown from both sides: the device going dark
(`up=0`) and coming back (uptime reset). When one fires, open the
**UDM Health & Reboots** row on the `unifi-network` dashboard and read off the
SoC temp, memory and load at that moment to fingerprint the cause.

Pipeline: Grafana alert rule → webhook contact point `pushover-bridge` (a small
in-cluster svc, `clusters/util-server/applications/pushover-bridge/`) →
`api.pushover.net` → iOS push. Everything outbound, so it works whether you're
home or away. Pushover keys (`PUSHOVER_USER_KEY` / `PUSHOVER_API_TOKEN`) are
synced from Infisical by `pushover-secrets-sync`. The bridge marks recovered
alerts with `✅ ... resolved` and picks priority/sound from `severity`.

The alerting resources (folder `UDM Alerts`, contact point, notification policy,
and every rule) are provisioned idempotently by:

```bash
./scripts/deploy-grafana-alerts.sh
```

Each rule's source of truth is a file in `scripts/grafana/alerts/*.json` (the
`query → reduce → threshold` data pipeline). Add/edit a file and re-run the
script to update the live rules. Grafana file provisioning only covers rules
(not contact points/policies), so this script drives Grafana's provisioning API
instead.

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
