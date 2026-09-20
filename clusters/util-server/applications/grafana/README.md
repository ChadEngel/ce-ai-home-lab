# Grafana

Monitoring dashboards, fed by InfluxDB v2.

## URLs

- Public: `https://grafana.caehomelab.com`
- Internal: `http://grafana.ai.svc.cluster.local:3000`

## Deploy

```
./scripts/deploy-grafana.sh             # manifest + initial datasource/dashboards
./scripts/deploy-grafana-alerts.sh      # alert rules, folders, contact point, notification policy
./scripts/verify-grafana.sh             # read-only drift check vs the repo (run anytime)
```

## Configuration

- **In the repo:** the datasource ConfigMap (UID `dfdkew37wk1dse`,
  points at `http://aiserver.home:8086`, org `home`, bucket
  `kube_metrics`), the admin-password Secret (placeholder), and the
  alert rules under `scripts/grafana/alerts/` + dashboards under
  `scripts/grafana/dashboards/`.
- **InfluxDB is external.** It is **not** deployed by this repo —
  this lab runs InfluxDB v2 on a separate host (`aiserver.home`).
  See [`MONITORING.md`](../../../../MONITORING.md) and the top comment
  in `kustomization.yaml` for what to change if you reuse this
  manifest.
- **Secret:** `INFLUX_TOKEN` (read) — synced from Infisical.

## Foot-guns

- The Grafana datasource uses `basicAuth: true` with the v2 token in
  `secureJsonData.basicAuthPassword` because the `secureJsonData.token`
  path silently fails on this Grafana version. **Do not switch back**
  to `token` without testing.
- The datasource ConfigMap uses `deleteDatasources` to force-recreate
  the InfluxDB datasource on every apply, because Grafana's file
  provisioning only applies `secureJsonData` on first creation — it
  will NOT overwrite a secure field on an already-existing datasource.
  Without the delete step, rotating the token silently has no effect.
- `grafana-secrets` defaults to `admin`/`admin`. Rotate before
  exposing publicly (see
  [`../../../../docs/rotate-placeholder-credentials.md`](../../../../docs/rotate-placeholder-credentials.md)).
