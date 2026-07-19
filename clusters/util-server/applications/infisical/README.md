# Infisical — secrets management

Infisical is the secrets manager for this homelab. It runs in-cluster at
**https://secrets.caehomelab.com** and is the single source of truth for all
secrets. The [Infisical Kubernetes Operator](../infisical-operator/) (deployed
right after Infisical) projects those secrets into native Kubernetes Secrets
that cert-manager, Grafana, and other services consume.

## What's here

- `kustomization.yaml` — all Infisical resources (frontend + Postgres + Service + Ingress + ConfigMaps + Secrets + PVCs)
- `secrets.yaml`    — bootstrap secret (`infisical-secrets`) for JWT and encryption keys
- `ssl-certs.yaml`  — pre-creates a `cert-manager` Certificate so the
  ingress TLS secret exists before the pod is ready

## Bootstrap flow

The chicken-and-egg problem: Infisical needs secrets to start, so the
**bootstrap secrets** must exist in the cluster before the pod starts.
That's what `infisical-secrets` is for — it contains the application-level
keys (JWT_SECRET, ENCRYPTION_KEY, NEXT_SECRET_KEY_BASE) that Infisical
itself uses. These bootstrap keys are the *only* secrets that live as
committed (placeholder) K8s Secrets — every **service** secret lives in
Infisical and is synced into the cluster by the operator.

After Infisical is up, all real service keys go into the Infisical UI under
the `secret-management` project (slug `caehomelab-v1q6`), `prod` environment,
path `/`. The operator then syncs them into the K8s Secrets consumers expect:

| Infisical secret | Synced to K8s Secret | Used by |
|---|---|---|
| `CLOUDFLARE_API_TOKEN` | `cert-manager/cloudflare-dns-creds`[`CF_API_TOKEN`] | cert-manager DNS-01 solver (TLS for every service) |
| `INFLUXDB_TOKEN`        | `ai/influxdb-secrets`[`INFLUX_TOKEN`]              | Grafana InfluxDB datasource |
| `GODADDY_API_KEY`, `GODADDY_API_SECRET`, `SEARXNG_SECRET_KEY` | (records only — not synced) | legacy / not currently used |

See [`../infisical-operator/README.md`](../infisical-operator/README.md) for
the operator architecture, machine-identity setup, rotation, and how to add
new Infisical-managed secrets.

## Deploy order

Infisical deploys **first** in `scripts/deploy-all.sh`, immediately followed
by the operator, so that Infisical-managed secrets (Cloudflare token, InfluxDB
token) are available as K8s Secrets *before* any service that depends on them.
In particular, cert-manager needs `cloudflare-dns-creds` to issue the TLS
certificates every other service relies on.

## First-time setup

1. Deploy Infisical: `./scripts/deploy-infisical.sh`
2. Wait for the `infisical-*` pods to be Running and the `infisical-ssl-certs` cert to be issued.
3. Visit https://secrets.caehomelab.com and create the initial admin user
   (open signup is enabled by default; disable it after — see
   `DEPLOYMENT_STATUS.md`).
4. In the UI, create the `secret-management` project, add the secrets listed
   in the table above to its `prod` environment at path `/`.
5. Create the `homelab-k8s-operator` Machine Identity (Universal Auth, Viewer
   role on `secret-management`/`prod`), and create the credentials K8s Secret:
   ```bash
   kubectl create secret generic infisical-universal-auth -n ai \
     --from-literal=clientId=<id> --from-literal=clientSecret=<secret>
   ```
6. Deploy the operator: `./scripts/deploy-infisical-operator.sh`
7. Only then deploy the rest: `./scripts/deploy-all.sh` (or individual services).

## Image source

`infisical/infisical:latest` (Docker Hub). The earlier
`infisical/infisical-platform:latest` reference is incorrect — that
namespace does not exist on Docker Hub.
