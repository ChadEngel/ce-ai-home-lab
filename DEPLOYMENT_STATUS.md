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
| Ollama     | `http://aiserver.home:11434` | external | Runs on a separate host, not in this cluster |

## Certificates

All certificates are issued by Let's Encrypt via the Cloudflare DNS-01 solver:

| Secret | Host | Status |
|---|---|---|
| `openwebui-tls`       | `ai.caehomelab.com`     | ✅ Ready |
| `searxng-tls`         | `search.caehomelab.com` | ✅ Ready |
| `bifrost-tls`         | `llm.caehomelab.com`    | ✅ Ready |
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

## Outstanding work

1. **Rotate the Cloudflare API token** — update the value in the Infisical
   UI (`secret-management`/`prod`/`CLOUDFLARE_API_TOKEN`); the operator
   syncs it into `cert-manager/cloudflare-dns-creds` within ~60s. (Also
   rotate at Cloudflare — the leaked token remains in git history.)
2. **Rotate the InfluxDB admin token** — same flow: update
   `INFLUXDB_TOKEN` in Infisical; the operator syncs `ai/influxdb-secrets`,
   then restart Grafana. (Also rotate at the InfluxDB provider; the leaked
   token remains in git history.)
3. **Set up `monitor_k3s_health.sh` as a scheduled job** on `util-server`
   so the Grafana dashboards have live data. No timer/cron is currently
   configured.
4. **(Optional) Revoke the bootstrap service token** `st.51f02f1e-…` once
   you no longer need CLI administration; the operator uses the Machine
   Identity, not the service token.

## Verification

```bash
./scripts/deployment-test.sh
```

Result: 42 tests, 42 passed, 0 failed, 0 warnings.
