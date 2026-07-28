# Migrate InfluxDB v2 from `aiserver.home` into k3s (caelx002, NFS)

## Goal
Move InfluxDB v2.8.0 off the bare-metal host `aiserver.home` (`192.168.30.10`)
into the k3s cluster, pinned to the `caelx002` worker node, with data on the
`nfs-client` storage class (NAS `192.168.30.121`). Preserve the existing
org/buckets/**tokens** so writers only need a URL change (no Infisical edits).

## Source (aiserver.home)
- Version: v2.8.0 · Org: `home` (id `a9b336696a27c82b`)
- Buckets: `host_metrics`, `kube_metrics`, `mac_metrics`, `network_metrics`,
  `proxmox_metrics`
- Tokens (Infisical `caehomelab-v1q6/prod/`):
  - `INFLUXDB_TOKEN` — write (bucket-scoped)
  - `INFLUXDB_READ_TOKEN` — read all buckets (Grafana)
- **No all-access/operator token is stored in Infisical.** It only exists in
  the aiserver InfluxDB UI. It is required for `influx backup` (the read token
  fails with `read:authorizations is unauthorized`).

## Target (k3s)
- Deployment `influxdb` in namespace `ai`, image `influxdb:2.8.0`, pinned to
  `caelx002` via required node affinity.
- PVC `influxdb-data` on `nfs-client` (50Gi), mounted at `/var/lib/influxdb2`.
- Service `influxdb:8086` (in-cluster) + Ingress `influxdb.caehomelab.com`
  (TLS via cert-manager DNS-01; A record → `192.168.30.217`).
- Endpoints:
  - in-cluster: `http://influxdb.ai.svc.cluster.local:8086` (Grafana, unpoller)
  - external:    `https://influxdb.caehomelab.com` (telegraf on Macs,
                 k3s-metrics-push systemd)

## Migration method: `influx backup` → `influx restore --full`
Online backup from aiserver (no source downtime), full restore into the fresh
k8s instance. This preserves org, all 5 buckets, **all tokens** (so the
Infisical read/write tokens remain valid), dashboards, tasks, and any telegraf
configs. Writers therefore only need a URL change at cutover.

**Requires the all-access operator token for aiserver** (generate one in the
aiserver InfluxDB UI: *Data → API Tokens → Generate API Token → All Access*).

### Steps (executed from the new influxdb pod, which can reach aiserver)
```bash
POD=influxdb-<pod>   # kubectl get pod -n ai -l app=influxdb
# 1. Online backup of everything (metadata + all buckets) from aiserver
kubectl exec -n ai $POD -- influx backup \
  --host http://192.168.30.10:8086 --token <ALL_ACCESS_TOKEN> /tmp/backup

# 2. Full restore into the fresh k8s instance (localhost = the pod itself)
kubectl exec -n ai $POD -- influx restore --full /tmp/backup
#   (if restore requires a token on the empty instance, run `influx setup`
#    first with a throwaway org to obtain an all-access token, then --full
#    replaces it with the restored org/tokens; or pass the all-access token
#    from the backup via --token.)

# 3. Verify
kubectl exec -n ai $POD -- influx ping
kubectl exec -n ai $POD -- influx bucket list --org home   # needs a valid token
```

## Cutover (URL changes only — tokens/org/buckets unchanged)
| Client | Location | Old → New | Restart |
|---|---|---|---|
| Grafana datasource | `clusters/.../grafana/kustomization.yaml` | `http://aiserver.home:8086` → `http://influxdb.ai.svc.cluster.local:8086` | `kubectl rollout restart deploy/grafana -n ai` |
| unpoller | `clusters/.../unpoller/kustomization.yaml` | `url = "http://aiserver.home:8086"` → `url = "http://influxdb.ai.svc.cluster.local:8086"` | `kubectl rollout restart deploy/unpoller -n ai` |
| k3s-metrics-push (systemd) | `/etc/default/k3s-metrics-push` | `INFLUX_HOST` → `https://influxdb.caehomelab.com` | `sudo systemctl restart k3s-metrics-push` |
| telegraf (Macs/hosts) | fetched from InfluxDB (see below) | — | `sudo systemctl restart telegraf` |

## Centralized Telegraf configs (for the Macs)
So telegraf config edits live in one place, the Macs fetch their config from
InfluxDB's Telegraf API instead of a local file:

```bash
# Create a telegraf config in the new InfluxDB (needs the all-access token):
# The config contains host input plugins + an influxdb_v2 output pointing at
# the new instance (org=home, bucket=host_metrics, token=<write token>).
# In the UI:  Load Data → Telegraf → Create → "System" template →
#   set output URL https://influxdb.caehomelab.com, org home, bucket host_metrics
#   → save. Note the config ID and the token it offers.
```
On each Mac, run telegraf fetching the remote config (one place to edit):
```bash
telegraf --config https://influxdb.caehomelab.com/api/v2/telegrafs/<CONFIG_ID> \
         --token <TELEGRAF_FETCH_TOKEN>
```
(`TELEGRAF_FETCH_TOKEN` needs read access to telegraf configs — use the
all-access token or a dedicated token; for a homelab a shared token is
acceptable. The *write* token for the output is embedded in the config itself.)

## Verify data is flowing (after cutover)
```bash
INFLUX_TOKEN='<INFLUXDB_READ_TOKEN>'
curl -s "https://influxdb.caehomelab.com/api/v2/query?org=home" \
  -H "Authorization: Token $INFLUX_TOKEN" -H 'Content-type: application/vnd.flux' \
  --data 'from(bucket:"kube_metrics") |> range(start:-5m) |> last()' | head -c 500
```

## Decommission
Once the new instance is confirmed for a few cycles, stop InfluxDB on aiserver:
`sudo systemctl disable --now influxdb` (back up `/var/lib/influxdb2` first).

## Rollback
Keep aiserver running until verified. To roll back, revert the URL changes in
git, `kubectl rollout restart` grafana/unpoller, and restore the systemd/telegraf
`INFLUX_HOST`/`url` to `http://aiserver.home:8086`.