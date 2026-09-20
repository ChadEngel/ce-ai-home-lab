# synthetic-monitor

A client-in-the-cluster that probes service health. Makes real HTTP
requests from inside the cluster to the endpoints clients use, and
writes a `service_health` measurement to InfluxDB. Grafana then turns
this into a red/yellow/green availability board and fires Pushover
alerts via the rules in `scripts/grafana/alerts/infra-*.json`.

## URLs

- (No public URL; an internal-only sidecar pod.)

## Deploy

```
./scripts/deploy-synthetic-monitor.sh
```

## Configuration

- **In the repo:** ConfigMap (`synthetic-monitor-poll`) holding the
  poll script + probe list, Deployment.
- **Probe targets (live):** InfluxDB (`aiserver.home:8086/ping`),
  Bifrost (`https://llm.caehomelab.com/health`), Open WebUI
  (`https://ai.caehomelab.com/health`), Ollama
  (`aiserver.home:11434/api/tags`).
- **Secret:** `INFLUXDB_TOKEN` (write) — synced from Infisical into
  K8s Secret `synthetic-monitor-secrets` by
  `synthetic-monitor-secrets-sync`.

## Why it matters

The probe reads the endpoints **clients** use, so a green result
means the whole path works (DNS, TLS, ingress, backend). It's a
different vantage from the k3s pod health, which only tells you
"the container is up" — a pod can be Ready while its upstream
dependency is broken. This is what catches the silent
"Infisical returns 200 but the operator can't reach it" class of
failures that the k3s probes miss.

## Foot-guns

- **Recreate strategy is mandatory.** Single replica, RWO PVC-free
  here, but the poll script does a single-shot write loop, so any
  rolling-update race could double-write. Recreate avoids that.
- **Probe list is hard-coded in the ConfigMap.** To add/remove a
  probe, edit `synthetic-monitor-poll` ConfigMap data and redeploy.
