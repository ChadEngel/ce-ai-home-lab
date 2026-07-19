# Grafana Dashboards

Provisioned automatically into Grafana by `scripts/deploy-grafana.sh`, which
globs every `*.json` here into the `grafana-dashboards-json` ConfigMap mounted
at `/var/lib/grafana/dashboards/default`.

## Dashboards

- **`k8s-cluster-monitor.json`** — `CE AI Lab — K3s Cluster Monitor`
  The single consolidated dashboard for the homelab cluster. Backed by the
  InfluxDB v2 datasource (uid `dfdkew37wk1dse`) querying the `kube_metrics`
  bucket with **Flux**. Data is written by
  `scripts/monitor_k3s_health.sh` (run every 60s by the
  `k3s-metrics-push.timer` systemd unit on `util-server`).

  Panels:
  - **Cluster health stats** — Total Nodes, Nodes Ready %, Total Pods,
    Failed/Pending Pods, Stuck PVs (last value of each `k8s_cluster_health`
    field).
  - **Node Ready % Trend** — `nodes_ready_pct` over time.
  - **Pod Count Trend** — `pods_total` vs `pods_failed_pending` over time.
  - **Pod Inventory** — a table of every running pod with its namespace,
    CPU (millicores), memory (KiB), and restart count, joined from
    `k8s_pod_resources` + `k8s_pod_restarts`. Cells with high restart counts
    are highlighted (yellow ≥1, red ≥5) as a crude OOMKilled indicator.

## Datasource requirements

The dashboard hardcodes datasource uid `dfdkew37wk1dse`, which is the uid set
in the Grafana kustomization's provisioned InfluxDB datasource. That datasource
**must** have `jsonData.queryLanguage: "flux"` — without it Grafana falls back
to InfluxQL mode and silently sends empty `SELECT FROM ""` queries (this is
what caused the old dashboards to show no data).

## Modifying

Edit the JSON here, then re-run `./scripts/deploy-grafana.sh` (it rebuilds the
ConfigMap and restarts Grafana's file-provider pickup). Or edit live in the
Grafana UI and export back to this file.

## Removed (historical)

The previous dashboards (`final-k8s-monitoring.json`, `k8s-monitoring.json`,
`pod-resources.json`) were removed — they used a `$cluster_datasource`
templating variable and the datasource was provisioned without
`queryLanguage: flux`, so every panel sent a malformed empty InfluxQL query
and showed no data. They're superseded by `k8s-cluster-monitor.json`.