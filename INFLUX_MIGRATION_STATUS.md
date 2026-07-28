# InfluxDB Migration — Status & Handoff

> Snapshot of the in-progress InfluxDB migration. Created so work can resume on
> another machine. Last updated: 2026-07-27.

## Context

Migrate InfluxDB v2.8.0 off the bare-metal host **`aiserver.home`**
(`192.168.30.10`) into the k3s cluster, pinned to the **`caelx002`** worker
node, with data on the **`nfs-client`** storage class (NAS `192.168.30.121`).
Preserve org/buckets/**tokens** so writers only need a URL change (no Infisical
edits, and the Infisical machine identity is read-only so it can't be updated
programmatically anyway).

- Source: `http://aiserver.home:8086` · org `home` (id `a9b336696a27c82b`)
- Buckets (5): `host_metrics`, `kube_metrics`, `mac_metrics`, `network_metrics`,
  `proxmox_metrics`
- Infisical tokens (`caehomelab-v1q6/prod/`): `INFLUXDB_TOKEN` (write),
  `INFLUXDB_READ_TOKEN` (read all). **No all-access token is in Infisical.**

## ✅ Completed (committed in `599abc2`, pushed to `main`)

- **New InfluxDB deployed** in k8s, namespace `ai`:
  - Deployment `influxdb`, image `influxdb:2.8.0`, pinned to `caelx002` via
    required node affinity, `/health` probes (5s timeout, 6 failureThreshold).
  - PVC `influxdb-data` (nfs-client, 50Gi) → mounted at `/var/lib/influxdb2`.
  - Service `influxdb:8086` (in-cluster) + Ingress `influxdb.caehomelab.com`
    (TLS via cert-manager DNS-01 / Cloudflare).
  - Pod running & healthy; `/api/v2/setup` → `allowed:true` (empty, ready for
    restore).
- Files added:
  - `clusters/util-server/applications/influxdb/kustomization.yaml`
  - `clusters/util-server/applications/influxdb/ssl-certs.yaml`
  - `scripts/deploy-influxdb.sh`
  - `docs/migrate-influxdb-to-k8s.md` (full procedure)
- De-risked: the new pod can reach `aiserver.home:8086` (ping OK; DNS resolves
  from inside the pod). The read token successfully lists all 5 buckets.
- DNS: `influxdb.caehomelab.com` A record already exists → `192.168.30.217`
  (no Cloudflare action needed).
- Other recent commits this session: `74a62a5` (Infisical probe timeouts),
  `518d78a` (openwebui → caelx002), `3067a19` (grafana mem limit).

## ⚠️ Blocker — need the aiserver all-access token

I can SSH to `util-server` (with passwordless sudo via Infisical
`UTIL_SERVER_SSH_PRIVATE_KEY` / user `cengel`) but **not `aiserver`**, and there
is **no all-access token in Infisical**. The read token cannot run
`influx backup` (fails: `read:authorizations is unauthorized`).

**Action needed (once):** generate an All-Access API token in the aiserver
InfluxDB UI — `http://aiserver.home:8086` → *Data → API Tokens → Generate API
Token → All Access* — and have it available where the migration runs.

## ▶️ Resume steps (run on the machine with kubectl access to the cluster)

Set the all-access token and go:
```bash
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
ALL_ACCESS='<paste the all-access token from aiserver UI>'
POD=$(kubectl get pod -n ai -l app=influxdb -o jsonpath='{.items[0].metadata.name}')
```

### 1. Backup aiserver → restore --full into the new instance (preserves tokens)
```bash
# Online backup of everything (metadata + all buckets) from aiserver — no downtime
kubectl exec -n ai "$POD" -- influx backup \
  --host http://192.168.30.10:8086 --token "$ALL_ACCESS" /tmp/backup

# Full restore into the fresh k8s instance (localhost = the pod)
kubectl exec -n ai "$POD" -- influx restore --full /tmp/backup
# NOTE: if restore errors that a token is required on the empty instance, run
#   `influx setup` first with a throwaway org to get an all-access token, then
#   re-run `influx restore --full` (it replaces everything with the restored
#   org/tokens). Or pass --token "$ALL_ACCESS".

# Verify
kubectl exec -n ai "$POD" -- influx ping
kubectl exec -n ai "$POD" -- influx bucket list --host http://localhost:8086 \
  --org home --token "$ALL_ACCESS"     # expect 5 buckets
```

### 2. Repoint in-cluster connections (URL only; tokens unchanged)
Edit + apply:
- `clusters/util-server/applications/grafana/kustomization.yaml`: datasource
  `url: http://aiserver.home:8086` → `url: http://influxdb.ai.svc.cluster.local:8086`
- `clusters/util-server/applications/unpoller/kustomization.yaml`:
  `url = "http://aiserver.home:8086"` → `url = "http://influxdb.ai.svc.cluster.local:8086"`

```bash
kubectl apply -n ai -f clusters/util-server/applications/grafana/kustomization.yaml
kubectl apply -n ai -f clusters/util-server/applications/unpoller/kustomization.yaml
kubectl rollout restart deploy/grafana -n ai
kubectl rollout restart deploy/unpoller -n ai
```
Verify Grafana dashboards show fresh points and unpoller logs show writes to the
new instance.

### 3. Create the centralized Telegraf config for the Macs
In the new InfluxDB UI (`https://influxdb.caehomelab.com`): *Load Data →
Telegraf → Create → System* template; set output URL
`https://influxdb.caehomelab.com`, org `home`, bucket `host_metrics`, and use
the existing `INFLUXDB_TOKEN` (write) embedded in the config. Note the **config
ID**. (Can also be done via the API with the all-access token.)

On each Mac, fetch the config from InfluxDB (one place to edit going forward):
```bash
telegraf --config https://influxdb.caehomelab.com/api/v2/telegrafs/<CONFIG_ID> \
         --token <TELEGRAF_FETCH_TOKEN>
sudo systemctl restart telegraf
```
(`TELEGRAF_FETCH_TOKEN` needs read on telegraf configs — use the all-access
token or a dedicated token; the *write* token for the output is embedded in the
config itself.)

## 📋 Remaining (host-side, can't be done from k8s)

- Paste the all-access token (above).
- Switch each Mac's telegraf to the remote config URL (one line), restart.
- `k3s-metrics-push` systemd writer: found **inactive on util-server** with no
  env file — so it's either running on aiserver or not yet installed. Decide
  where it should live; if on util-server, it can be set up there (sudo is
  available) with `INFLUX_HOST=https://influxdb.caehomelab.com` per
  `MONITORING.md`. Repoint `INFLUX_HOST` and `systemctl restart`.
- After the new instance is confirmed for a few cycles, decommission aiserver:
  `sudo systemctl disable --now influxdb` (back up `/var/lib/influxdb2` first).

## Rollback

Keep aiserver running until verified. To roll back: revert the two URL edits
in git, `kubectl rollout restart` grafana/unpoller, restore systemd/telegraf
`INFLUX_HOST`/`url` to `http://aiserver.home:8086`, restart those services.

## Notes / gotchas

- TLS cert `influxdb-tls` was still issuing (DNS-01 propagation) at the time of
  this snapshot — non-blocking for steps 1–2 (in-cluster Service is HTTP).
  Check: `kubectl get certificate -n ai influxdb-tls`.
- **Security:** the old completed `influx-metrics-pusher` Job in `default`
  had a plaintext write token in its spec. Delete it and rotate `INFLUXDB_TOKEN`
  after migration (create new write token in the new UI, update Infisical,
  restart writers):
  `kubectl delete job -n default influx-metrics-pusher`.
- NFS for a TSDB adds IO latency and can stall (same risk class as the
  Postgres-on-NFS crash fixed in `74a62a5`). `local-path` on caelx002 would be
  faster/safer if you reconsider storage.