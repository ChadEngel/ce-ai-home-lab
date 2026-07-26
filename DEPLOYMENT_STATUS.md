# Deployment Status

Last verified: 2026-07-18 (k3s `v1.35.5+k3s1` on `util-server`).

## Services

| Service | URL | Status | Notes |
|---|---|---|---|
| Open WebUI | `https://ai.caehomelab.com` | ✅ Running | Talks to Bifrost; no providers configured yet (you must add them at `https://llm.caehomelab.com`) |
| Bifrost    | `https://llm.caehomelab.com` | ✅ Running | Add providers via web UI (Settings → Providers) |
| SearXNG    | `https://search.caehomelab.com` | ✅ Running | Settings mounted from `searxng-settings` ConfigMap |
| Infisical  | `https://secrets.caehomelab.com` | ✅ Running | |
| Grafana    | `https://grafana.caehomelab.com` | ✅ Running | Datasource connected to InfluxDB v2 on `aiserver.home:8086`; dashboards loaded |
| Loki       | `https://loki.caehomelab.com` | ✅ Running | Log aggregation (Loki 3.7.4 single-binary, filesystem-on-NFS, 15-day retention); Promtail ingests UDM syslog via UDP NodePort `192.168.30.217:30014`; added as a Grafana datasource (uid `loki`) |
| Ollama     | `http://aiserver.home:11434` | external | Runs on a separate host, not in this cluster |

## Certificates

All certificates are issued by Let's Encrypt via the Cloudflare DNS-01 solver:

| Secret | Host | Status |
|---|---|---|
| `openwebui-tls`       | `ai.caehomelab.com`     | ✅ Ready |
| `searxng-tls`         | `search.caehomelab.com` | ✅ Ready |
| `bifrost-tls`         | `llm.caehomelab.com`    | ✅ Ready |
| `loki-tls`           | `loki.caehomelab.com`   | ✅ Ready |
| `infisical-ssl-certs` | `secrets.caehomelab.com` | ✅ Ready |
| `grafana-tls`         | `grafana.caehomelab.com` | ✅ Ready |

## Recently fixed (this commit)

- **Grafana datasource auth** — the InfluxDB datasource wasn't passing
  the token (the `secureJsonData.token` path silently fails on this
  Grafana version). Switched to `basicAuth: true` with the token in
  `secureJsonData.basicAuthPassword`; InfluxDB v2 accepts a v2 token
  as the basic-auth password.
- **Grafana datasource DB** — added `database: kube_metrics` so
  InfluxQL queries get the right `?db=` parameter (empty by default
  on v2 datasources, which InfluxDB rejects with "database name
  required").
- **Grafana `INFLUX_TOKEN` substitution** — the ConfigMap template
  uses `${INFLUX_TOKEN}` but Grafana doesn't do env-var substitution
  in provisioning files. Added an `alpine` init container that
  `envsubst`s the template and renders the file before Grafana starts.
- **`influxdb-secrets` removed from kustomization** — it was
  re-applying a placeholder value and overwriting the real token
  on every `kubectl apply`. The Secret is now **synced from Infisical**
  by the Infisical operator (see the "Infisical operator" section below),
  so `kubectl apply` no longer touches it.
- **Grafana PVC** — there was a stale `grafana.db` from a previous
  run with a different admin password. Deleted the PVC so the new
  pod starts with a fresh database and the env-var password sticks.
- **Stale `searxng-config` ConfigMap** deleted (the rename to
  `searxng-settings` was applied but the old one remained).
- **All four kustomizations applied** so the cluster state matches
  the repo (bifrost, searxng, grafana, infisical, openwebui).
- **`deployment-test.sh`** internal probe now runs in-cluster via
  `kubectl run ... --rm --image=curlimages/curl` so cluster DNS
  resolves; SearXNG `/healthcheck` → `/` (no such endpoint exists);
  Infisical `:3000/health` → `:8080/api/status`. All 42 tests pass.

## Stale resources in cluster (not in any kustomization)

These are leftover from the LiteLLM era and can be deleted:

```bash
kubectl delete cm -n ai openwebui-env openwebui-ollama-config litellm-config
kubectl delete secret -n ai litellm-secrets
kubectl delete pvc -n ai litellm-pvc
kubectl delete secret -n ai litellm-tls           # ingress now uses bifrost-tls
```

(Do this after confirming the new `bifrost-tls` Secret is being
read by the ingress — it's already present, so this is safe.)

## Infisical Kubernetes Operator (secret sync)

Service secrets now flow from Infisical into native K8s Secrets via the
[Infisical operator](clusters/util-server/applications/infisical-operator/):

- Operator installed in namespace `infisical-operator-system`, image pinned
  to `infisical/kubernetes-operator:v0.10.34` (the `:latest` image requires
  v1beta1 CRDs not in the install manifest and crash-loops — see the
  operator README).
- A Machine Identity `homelab-k8s-operator` (Universal Auth, Viewer role
  on `secret-management`/`prod`) reads secrets. Its credentials live in the
  out-of-band K8s Secret `ai/infisical-universal-auth`.
- `InfisicalSecret` CRs sync:
  - `CLOUDFLARE_API_TOKEN` → `cert-manager/cloudflare-dns-creds`[`CF_API_TOKEN`]
  - `INFLUXDB_TOKEN`        → `ai/influxdb-secrets`[`INFLUX_TOKEN`]
  - (`GODADDY_*` and `SEARXNG_SECRET_KEY` are records only, not synced.)
- resyncInterval = 60s. Changing a value in the Infisical UI propagates to
  the K8s Secret within ~60s (verified end-to-end). The 5 leaked secrets
  from git history have been imported into Infisical under
  `secret-management` / `prod` / `/`.

## Setup (one-time per cluster)

Bootstrapping order is **Infisical first, then the operator, then apps**
(see `scripts/deploy-all.sh` and
`clusters/util-server/applications/infisical-operator/README.md`):

1. `./scripts/deploy-infisical.sh` → create the admin account at
   https://secrets.caehomelab.com.
2. In the UI: create the `secret-management` project, add the service secrets
   (`CLOUDFLARE_API_TOKEN`, `INFLUXDB_TOKEN`, …) to `prod` / `/`.
3. Create the `homelab-k8s-operator` Machine Identity (Universal Auth, Viewer
   role on `secret-management`/`prod`).
4. Create the credentials K8s Secret (out-of-band, never committed):
   ```bash
   kubectl create secret generic infisical-universal-auth -n ai \
     --from-literal=clientId=<id> --from-literal=clientSecret=<secret>
   ```
5. `./scripts/deploy-infisical-operator.sh` → the operator now syncs
   `cloudflare-dns-creds` and `influxdb-secrets`.
6. `./scripts/deploy-all.sh` for the rest.

Do **not** create `influxdb-secrets` or `cloudflare-dns-creds` manually on a
cluster where the operator is running — it owns those Secrets.

## Host & Proxmox monitoring

Host-level metrics for the Linux boxes + the Proxmox host, into the existing
InfluxDB v2 + Grafana stack. Full setup in
[`docs/how-to-monitor-hosts.md`](docs/how-to-monitor-hosts.md).

| Target | Method | Bucket | Status |
|---|---|---|---|
| `util-server` (k3s control-plane) | Telegraf (`install-telegraf.sh`) | `host_metrics` | ✅ writing (reconfigured: token off disk, bucket `mac_metrics`->`host_metrics`) |
| `caelx002` (k3s worker) | Telegraf (`install-telegraf.sh`) | `host_metrics` | ✅ writing (fresh install, InfluxData repo + key) |
| `caevmhost01` / 192.168.30.204 (Proxmox VE 9.2) | Telegraf on host (`SSH_USER=root ./scripts/install-telegraf.sh 192.168.30.204`) | `host_metrics` | ✅ writing (host=caevmhost01) — PVE native metric server was a dead end (no InfluxDB2.pm plugin; metric server never covers host disk/net/temp anyway) |
| Grafana dashboard | `linux-host-overview.json` (9 panels, `host` variable) | `host_metrics` | ✅ loaded + query-verified via `/api/ds/query` |
| Proxmox Grafana dashboard | TBD | `proxmox_metrics` | ⏳ build once PVE is pushing (introspect measurement names) |

**Two-token model** (both in Infisical, no rotation needed to add buckets):
- `INFLUXDB_TOKEN` — all-bucket **write** (Telegraf, k3s monitor, PVE metric server).
- `INFLUXDB_READ_TOKEN` — all-bucket **read** (Grafana; synced into K8s Secret
  `influxdb-secrets[INFLUX_TOKEN]` by the `influxdb-secrets-sync` InfisicalSecret
  CR). The write token is write-only, so `install-telegraf.sh` verifies with
  the read token (transiently over SSH stdin, never on disk).

## Log aggregation (Loki + Promtail)

UDM Pro syslog -> Loki, 15-day retention, queryable in Grafana.

| Component | Detail |
|---|---|
| Loki | 3.7.4 single-binary, filesystem-on-NFS (`loki-pvc` 10Gi), `retention_period: 360h` (15d), compactor `retention_enabled: true` + `delete_request_store: filesystem`; **pinned to `caelx002`** via `nodeSelector` (moved off util-server to relieve its memory pressure — util-server OOM'd with Loki stacked on the control plane); resources trimmed to 256Mi req / 512Mi lim |
| Promtail | 3.6.11 UDP syslog receiver on NodePort `192.168.30.217:30014` (UDP); pinned to `util-server` (pushes to Loki via the in-cluster Service — works cross-node) |
| Ingress | `https://loki.caehomelab.com` (TLS via `letsencrypt-prod`, LAN-only) |
| Grafana | Loki datasource (uid `loki`, internal `http://loki.ai.svc.cluster.local:3100`) — ✅ health OK |
| UDM config | UniFi Network -> System Settings -> Advanced -> Syslog Server: host `192.168.30.217`, port `30014`, UDP |

UDM syslog typically carries: firewall accept/deny, IDS/IPS (Suricata)
alerts, auth/login, DHCP/DNS queries, wireless/AP events, system logs.

To check what's flowing once the UDM is pointed:
```bash
kubectl -n ai exec -l app=loki -c loki -- wget -qO- 'http://localhost:3100/loki/api/v1/labels'
kubectl -n ai logs -l app=promtail --tail=30
```

## Outstanding work

1. **Rotate the Cloudflare API token** — update the value in the Infisical
   UI (`secret-management`/`prod`/`CLOUDFLARE_API_TOKEN`); the operator
   syncs it into `cert-manager/cloudflare-dns-creds` within ~60s. (Also
   rotate at Cloudflare — the leaked token remains in git history.)
2. **Point the UDM Pro at Loki** — UniFi Network -> System Settings ->
   Advanced -> Syslog Server: host `192.168.30.217`, port `30014`, UDP.
   Then verify labels appear in Loki and build a UDM logs Grafana dashboard.
3. **(Optional) Monitor `aiserver`** (the InfluxDB host itself) — one more
   `./scripts/install-telegraf.sh aiserver.home` run; not in the original
   2-boxes + Proxmox scope.
4. **(Optional) Revoke the bootstrap service token** `st.51f02f1e-…` once
   you no longer need CLI administration; the operator uses the Machine
   Identity, not the service token.

## Verification

```bash
./scripts/deployment-test.sh
```

Result: 42 tests, 42 passed, 0 failed, 0 warnings.
