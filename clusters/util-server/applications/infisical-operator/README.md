# Infisical Kubernetes Operator

The [Infisical Kubernetes Operator](https://github.com/Infisical/kubernetes-operator)
syncs secrets stored in Infisical into native Kubernetes Secrets, which pods
consume like any other `Secret`. This is how `cert-manager` gets the Cloudflare
API token and Grafana gets the InfluxDB token — **Infisical is the single
source of truth; the K8s Secrets are just a projection of it.**

## What's here

- `install-secrets-operator.yaml` — the operator: namespace `infisical-operator-system`,
  CRDs (`InfisicalSecret`, `InfisicalPushSecret`, `InfisicalDynamicSecret`),
  RBAC, and the controller Deployment. **Image pinned to `v0.10.34`** (see
  "Why pin the image" below).
- `infisical-secrets-sync.yaml` — the `InfisicalSecret` CRs that tell the
  operator which Infisical secrets to sync into which K8s Secrets.
- `kustomization.yaml` — applies both, preserving each resource's own
  namespace (operator in `infisical-operator-system`, CRs in `ai`).

## Architecture

```
Infisical (secrets.caehomelab.com)
  org: caehomelab
    project: secret-management   (slug: caehomelab-v1q6)
      env: prod  (path "/")
        CLOUDFLARE_API_TOKEN
        INFLUXDB_TOKEN
        GODADDY_API_KEY, GODADDY_API_SECRET     (records only)
        SEARXNG_SECRET_KEY                       (record only)
            │
            │  Machine Identity "homelab-k8s-operator"
            │  (Universal Auth: clientId/clientSecret, Viewer role on prod)
            ▼
   infisical-operator  (ns infisical-operator-system)
            │  reads via Universal Auth
            ▼
   InfisicalSecret CRs (ns ai)
     cloudflare-dns-creds-sync  -> K8s Secret cert-manager/cloudflare-dns-creds[CF_API_TOKEN]
     influxdb-secrets-sync     -> K8S Secret ai/influxdb-secrets[INFLUX_TOKEN]
            │
            ▼
   pods (cert-manager ClusterIssuer, Grafana) mount the K8s Secrets
```

Each `InfisicalSecret` uses `template.data` to write **only the key the
consumer needs** (least-privilege) and remaps the Infisical secret name to the
K8s Secret key the consumer expects:

| Infisical secret        | K8s Secret                       | Key           | Consumer                        |
|-------------------------|----------------------------------|---------------|---------------------------------|
| `CLOUDFLARE_API_TOKEN`  | `cert-manager/cloudflare-dns-creds` | `CF_API_TOKEN` | cert-manager `letsencrypt-prod` ClusterIssuer (DNS-01) |
| `INFLUXDB_TOKEN`        | `ai/influxdb-secrets`            | `INFLUX_TOKEN`| Grafana InfluxDB datasource (basic-auth password) |

`GODADDY_*` and `SEARXNG_SECRET_KEY` are kept in Infisical as records but are
**not** synced to any K8s Secret (no live pod uses them).

## One-time setup (do this once, before first deploy)

1. **Infisical must be running** — `./scripts/deploy-infisical.sh`, create the
   admin account at https://secrets.caehomelab.com.
2. **Create the project & secrets** in the UI:
   - Org `caehomelab` → new project `secret-management` → keep the `prod` env.
   - At path `/`, add `CLOUDFLARE_API_TOKEN`, `INFLUXDB_TOKEN` (and the
     legacy `GODADDY_*` / `SEARXNG_SECRET_KEY` records).
3. **Create the Machine Identity** (Org Settings → Machine Identities):
   - Name it `homelab-k8s-operator`.
   - Auth method: **Universal Auth** → copy the **Client ID** and
     **Client Secret** (shown once).
   - Add it to the `secret-management` project with the **Viewer** role,
     scoped to the `prod` environment.
4. **Create the credentials K8s Secret** (out-of-band — never commit it):
   ```bash
   kubectl create secret generic infisical-universal-auth -n ai \
     --from-literal=clientId=<client-id> \
     --from-literal=clientSecret=<client-secret>
   ```

## Deploy / re-apply

```bash
./scripts/deploy-infisical-operator.sh
# or directly:
kubectl apply -k clusters/util-server/applications/infisical-operator/
```

Verify the syncs reach `ReadyToSyncSecrets` and the K8s Secrets are populated:
```bash
kubectl get infisicalsecret -n ai
kubectl get secret -n cert-manager cloudflare-dns-creds
kubectl get secret -n ai influxdb-secrets
```

## Rotating a secret

1. Update the value in the Infisical UI (or CLI) at
   `secret-management` / `prod` / `/`.
2. The operator re-syncs within `resyncInterval` (60s). The K8s Secret is
   updated in place.
3. Restart the consuming pod so it picks up the new value (e.g.
   `kubectl rollout restart deploy/grafana -n ai`). cert-manager picks up the
   Cloudflare token on its next reconciliation automatically.

## Adding a new Infisical-managed secret

1. Add the secret in Infisical at `secret-management` / `prod` / `/`.
2. Edit `infisical-secrets-sync.yaml`: add a new `InfisicalSecret` (or a new
   `managedKubeSecretReferences` entry) with a `template.data` mapping from
   the Infisical secret name to the K8s Secret key the consumer expects.
3. `kubectl apply -k clusters/util-server/applications/infisical-operator/`.

## Why pin the operator image to v0.10.34

The official `kubectl-install/install-secrets-operator.yaml` ships the
**v1alpha1** CRDs (`InfisicalSecret` etc.) but references the image
`infisical/kubernetes-operator:latest`. The `latest` image (v0.11.x) also
starts controllers for the newer **v1beta1** API (`InfisicalConnection`,
`InfisicalAuth`, `InfisicalStaticSecret`), whose CRDs are **not** in the
install manifest — so the manager crashes with `no matches for kind ... v1beta1`
and enters `CrashLoopBackOff`.

Pinning to **v0.10.34** (the last release before v1beta1 was introduced in
v0.11.0) makes the image and CRDs self-consistent: only the v1alpha1
controllers start, and the `InfisicalSecret` CRs reconcile cleanly. The
`infisical-secrets-sync.yaml` CRs use the v1alpha1 `InfisicalSecret` API
that this image supports (`universalAuth`, `managedKubeSecretReferences`,
`template.data`).

To migrate to the v1beta1 API later, install the v1beta1 CRDs (from
`config/crd/bases` in the operator repo) and switch the CRs to
`InfisicalConnection` + `InfisicalAuth` + `InfisicalStaticSecret`.