# unpoller

UniFi network metrics collector. Reads the UDM Pro controller API and
writes to InfluxDB v2 bucket `network_metrics`.

## URLs

- (No public URL; an internal-only collector pod.)

## Deploy

```
./scripts/deploy-unpoller.sh
```

## Configuration

- **In the repo:** Deployment (with an init container that templates
  the InfluxDB output plugin URL), ConfigMap (`up.conf` — controller
  URL, scrape interval, what to collect), and Service.
- **Auth model:**
  - UniFi controller: **API KEY** auth (UniFi OS API key), NOT
    username/password. Lives in Infisical as `UDM_API_KEY`.
  - InfluxDB v2: the **write-only** `INFLUXDB_TOKEN`, scoped to
    `kube_metrics + network_metrics`. Same write token the metrics
    writers use; Grafana's read token is separate.
- **Secret:** `unpoller-secrets`, synced from Infisical.

## Why in k8s (not on the UDM)

UniFi OS removes manually-installed packages on every firmware upgrade,
so any telegraf/poller installed on the UDM itself eventually
vanishes. A k8s Deployment is independent of the UDM filesystem and
keeps collecting across upgrades.

## Foot-guns

- **API key, not user/pass.** The bundled `up.conf` treats these as
  exclusive — we set `api_key` and leave user/pass unset. Mixing
  them makes the controller reject auth.
- **InfluxDB v2 output URL must use `/api/v2/write`** (not
  `/write`, which is the v1 path). The init container templates this
  from `INFLUX_HOST`.
- **Pinned to `caelx002`** — see the rationale in
  [`./influxdb/README.md`](./influxdb/README.md).
