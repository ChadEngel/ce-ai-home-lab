# InfluxDB v2

Time-series store for cluster, network, and host metrics. **External
to the cluster** for the bulk of this lab's history; this manifest
deploys an in-cluster InfluxDB v2.8.0 that the lab is migrated to.

## URLs

- In-cluster: `http://influxdb.ai.svc.cluster.local:8086`
- External (LAN-only): `https://influxdb.caehomelab.com` — requires
  a Cloudflare A record pointing at the Traefik node IP.

## Deploy

```
./scripts/deploy-influxdb.sh
# then migrate the data with 'influx backup' from aiserver ->
# 'influx restore --full' into this pod. See docs/migrate-influxdb-to-k8s.md.
```

## Configuration

- **In the repo:** Deployment (pinned to `caelx002`), PVC
  (`influxdb-data`, 50 Gi on NFS), Service, Ingress, and the
  TLS-termination Secret (`ssl-certs.yaml`).
- **Org: `home`. Buckets: `kube_metrics`, `network_metrics`,
  `host_metrics`** (legacy `mac_metrics` aliased to `host_metrics`).
- **Tokens are managed in Infisical:**
  - `INFLUXDB_TOKEN` — write (kube_metrics + network_metrics +
    host_metrics)
  - `INFLUXDB_READ_TOKEN` — read all buckets (Grafana)
- **Persisted in InfluxDB itself**, NOT in this repo.

## Foot-guns

- **`strategy: Recreate`** is mandatory. `replicas: 1` + RWO PVC +
  default `RollingUpdate` deadlocks: the new pod can't take InfluxDB's
  bolt file lock while the old pod holds it, and the old pod won't
  exit until the new one is ready. Observed: 2,765 restarts over 10
  days before this was fixed.
- **Pinned to `caelx002`** (worker). Do not move it back to the
  control plane — see `loki/README.md` for the memory-pressure
  rationale, the same constraint applies.
- **Backup before restore** the legacy data is on aiserver. The
  `deploy-influxdb.sh` runbook uses `influx backup` → `influx restore
  --full`, which preserves tokens so writers only need a URL change
  at cutover.
