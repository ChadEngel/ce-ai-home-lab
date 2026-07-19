# ce-ai-home-lab

Kubernetes infrastructure and applications for the home lab, managed as
GitOps-friendly manifests on a single-node k3s cluster.

## Technology stack

- **Kubernetes**: k3s v1.35.5+k3s1
- **Runtime**: containerd
- **Ingress**: Traefik (k3s addon, `ingressClassName: traefik`)
- **Storage**: NFS external provisioner, `nfs-client` StorageClass
- **TLS**: cert-manager with Let's Encrypt DNS-01 via Cloudflare
- **Secrets**: Infisical (self-hosted) for application secrets
- **Monitoring**: Grafana + InfluxDB v2 (external on `aiserver.home`)

## Prerequisites

Before you can apply anything in this repo, you need the following tooling
and external services. Full hardware/network/storage details live in
[`PREREQUISITES.md`](./PREREQUISITES.md).

### Tools to install (on your workstation / deploy host)

| Tool | Why | Install |
|---|---|---|
| `git` | Clone this repo | `apt install git` / Homebrew |
| `kubectl` | Apply manifests, check status | <https://kubernetes.io/docs/tasks/tools/> |
| `helm` | Install Traefik / cert-manager charts | <https://helm.sh/docs/intro/install/> |
| `k3s` | The cluster runtime (on the node) | `curl -sfL https://get.k3s.io \| sh -` |
| `nfs-common` | NFS client on the k3s node | `apt install nfs-common` |
| (optional) `flux` | GitOps path under `clusters/.../flux/` | <https://fluxcd.io/installation/> |

### External services / accounts

- **A domain** managed in **Cloudflare** (for DNS-01 TLS issuance).
- **A Cloudflare API token** with `Zone:DNS:Edit` on that zone.
- **An NFS server** exporting a share for persistent volumes.
- **An InfluxDB v2** instance (for the Grafana monitoring dashboards). Optional —
  only needed if you want the cluster-health metrics.
- **Let's Encrypt** — used automatically by cert-manager (no account needed
  beyond an email address).
- **Tailscale** (optional) — for remote access to the LAN.

### On the cluster node

1. Install k3s (above).
2. Install `nfs-common` and mount the NFS export — see
   [`persistant_nfs_mount.md`](./persistant_nfs_mount.md).
3. Copy the k3s kubeconfig to your workstation:
   `scp node:/etc/rancher/k3s/k3s.yaml ~/.kube/config` and edit the server URL.

## DNS

All public services resolve via Cloudflare + the Traefik LoadBalancer
(`192.168.30.217`) on the LAN. UDM Pro forwards internal lookups to the
same Traefik IP, so internal and external clients get the same answer.

| Host | Service |
|---|---|
| `ai.caehomelab.com`      | Open WebUI |
| `llm.caehomelab.com`     | Bifrost (AI gateway) |
| `search.caehomelab.com`  | SearXNG |
| `secrets.caehomelab.com` | Infisical |
| `grafana.caehomelab.com` | Grafana |

## Repository structure

```
.
├── README.md
├── PREREQUISITES.md
├── SETUP.md                 (physical topology / setup log)
├── homelab_build.md         (build notes)
├── DEPLOYMENT_STATUS.md     (current service status)
├── MONITORING.md            (InfluxDB/Grafana metrics setup)
├── persistant_nfs_mount.md  (NFS export + node mount steps)
├── .gitignore               (excludes backups/ and local secrets)
├── docs/
├── clusters/
│   └── util-server/
│       ├── namespaces/
│       ├── networking/        (cert-manager, traefik)
│       ├── storage/           (nfs provisioner)
│       └── applications/
│           ├── bifrost/
│           ├── openwebui/
│           ├── infisical/
│           ├── searxng/
│           ├── grafana/
│           ├── ollama/         (README only — runs on external host)
│           └── mcpo/           (README only — image not published)
├── scripts/
│   ├── deploy-*.sh
│   ├── check-deployments.sh
│   ├── deployment-test.sh
│   ├── debug-pods.sh
│   └── monitor_k3s_health.sh
```

(backups/ and other local snapshots are gitignored — see `.gitignore`.)

## Quick start

```bash
# 1. Clone (SSH)
git clone git@github.com:ChadEngel/ce-ai-home-lab.git
cd ce-ai-home-lab

# 2. Apply infrastructure (once per cluster)
kubectl apply -f clusters/util-server/namespaces/ai.yaml
# Storage + Traefik + cert-manager are installed via Helm; see
# PREREQUISITES.md for the full list.

# 3. Apply the ClusterIssuer (references the cloudflare-dns-creds Secret,
#    which is synced from Infisical by the operator in the next step)
kubectl apply -f clusters/util-server/networking/cert-manager/clusterissuer.yaml

# 4. Bootstrap Infisical (one-time, see
#    clusters/util-server/applications/infisical-operator/README.md):
#      ./scripts/deploy-infisical.sh        # deploy Infisical
#      - create the admin account at https://secrets.caehomelab.com
#      - create the 'secret-management' project + 'prod' env, add the
#        secrets (CLOUDFLARE_API_TOKEN, INFLUXDB_TOKEN, ...)
#      - create the 'homelab-k8s-operator' Machine Identity (Universal
#        Auth, Viewer role on secret-management/prod)
#      - create the credentials K8s Secret:
#          kubectl create secret generic infisical-universal-auth -n ai \
#            --from-literal=clientId=<id> --from-literal=clientSecret=<secret>
#      ./scripts/deploy-infisical-operator.sh  # operator now syncs the
#                                               # K8s Secrets (incl. cloudflare-dns-creds)

# 5. Deploy all applications (Infisical + operator first, then the rest)
./scripts/deploy-all.sh

# 6. Add your LLM providers at https://llm.caehomelab.com
#    (Settings → Providers)
```

> **Deploy order matters.** `deploy-all.sh` deploys Infisical and its
> operator *before* the other services, because cert-manager needs the
> Infisical-synced `cloudflare-dns-creds` Secret to issue the TLS
> certificates every service relies on. Bootstrap Infisical first
> (step 4 above) on a fresh cluster.

## Configuration

### Secrets

This repo does **not** contain real secrets. Placeholders are clearly
marked (`REPLACE_WITH_*` or `*-change-me`). The only committed secrets are
Infisical's own bootstrap keys (`infisical-secrets`, placeholders) — every
**service** secret lives in Infisical and is synced into the cluster by the
Infisical operator. Real values are supplied via:

1. **Infisical** (recommended) — see `clusters/util-server/applications/infisical/README.md`
   and `clusters/util-server/applications/infisical-operator/README.md`.
   The `homelab-k8s-operator` Machine Identity's clientSecret is stored in
   the out-of-band `infisical-universal-auth` K8s Secret (never committed).
2. **Out-of-band `kubectl create secret`** — used only for the Infisical
   bootstrap credentials (above) and Infisical's own `infisical-secrets`.
3. **SOPS+age** (not currently used in this repo)

For rotation: the Cloudflare and InfluxDB tokens referenced in older
commits were leaked in git history. **Rotate those tokens at the
provider**, update the values in the Infisical UI, and the operator
propagates the new values into the K8s Secrets within ~60s.

### Bifrost

Bifrost is the OpenAI-compatible AI gateway. After deploying, visit
`https://llm.caehomelab.com` and add providers under **Settings →
Providers**. Models are addressed as `provider/model`, e.g.
`ollama/chat/llama3` or `openrouter/meta-llama/llama-3-70b-instruct`.

### Open WebUI → Bifrost

The default `openwebui/kustomization.yaml` already points Open WebUI at
Bifrost via `OLLAMA_BASE_URL=http://bifrost-api.ai.svc.cluster.local:8080/v1`
plus an `OPENAI_API_KEY` placeholder (Bifrost itself is keyless; the
key just flips Open WebUI into OpenAI-compatible mode).

## Adapting to your environment

This repo is configured for *my* home lab. To reuse it in another
environment, search-and-replace the following values across the manifests and
scripts (a one-time bootstrap step). None of these are secrets — they're
names/addresses/IPs.

| Value in repo | What it is | Where it appears (examples) |
|---|---|---|
| `caehomelab.com` | The public DNS domain | every `Ingress` host, `infisical/ssl-certs.yaml`, `infisical-secrets-sync.yaml` (`hostAPI`), deploy scripts |
| `ai. / llm. / search. / secrets. / grafana.` subdomains | Public service hostnames | each app's `kustomization.yaml` + `_values/values.yaml` |
| `192.168.30.217` | k3s node / Traefik LoadBalancer IP (LAN) | `README.md`, DNS records |
| `192.168.30.121` | NFS server IP | `storage/nfs/deployment.yaml`, `storage/nfs/nfs-subdir-external-provisioner-values.yaml` |
| `/data/pod_data` | NFS export path | `storage/nfs/` |
| `aiserver.home` | External host running InfluxDB + Ollama | `grafana/kustomization.yaml` (datasource), `openwebui/_values/values.yaml` (`OLLAMA_BASE_URL`), `scripts/monitor_k3s_health.sh` |
| `aiserver.home:8086` | InfluxDB v2 endpoint | Grafana datasource, metrics scripts |
| InfluxDB org `home`, bucket `kube_metrics` | Monitoring bucket | `scripts/monitor_k3s_health.sh`, Grafana dashboards |
| `you@example.com` | Let's Encrypt account email | `networking/cert-manager/clusterissuer.yaml` |
| `ChadEngel/ce-ai-home-lab` | GitHub repo URL (Flux GitRepository) | `clusters/util-server/flux/gitops-secrets.yml`, `flux/apps.yaml` |
| Infisical org `caehomelab`, project `secret-management`, env `prod` | Infisical coordinates | `applications/infisical-operator/`, scripts/infisical-agent*.sh |

Quick find-and-replace from the repo root:

```bash
grep -rIl 'caehomelab.com\|192.168.30\|aiserver.home' clusters/ scripts/ |
```

### Secrets

**This repo contains no secrets.** All service credentials (Cloudflare API
token, InfluxDB token, Infisical JWT, DB passwords, TLS keys) live in
[self-hosted Infisical](https://infisical.com) and are synced into the cluster
by the Infisical operator. See `Configuration → Secrets` above and
[`clusters/util-server/applications/infisical-operator/README.md`](./clusters/util-server/applications/infisical-operator/README.md).
Placeholders in the repo are marked `REPLACE_WITH_*`, `*-change-me`, or
`your-*-here`.

> **If you forked an earlier revision:** some commits in prior history
> leaked a Cloudflare API token, an InfluxDB token, and TLS private keys
> (in a since-removed `backups/` directory). Those credentials were rotated
> at the provider and the history was rewritten; if you have an old clone,
> re-clone from `main`.

## Applications

| Application | Type | Port | Public URL |
|---|---|---|---|
| Open WebUI | Deployment + Ingress | 8080 | `ai.caehomelab.com` |
| Bifrost    | Deployment + Ingress | 8080 | `llm.caehomelab.com` |
| SearXNG    | Deployment + Ingress | 8080 | `search.caehomelab.com` |
| Infisical  | Deployment + Ingress | 3000 | `secrets.caehomelab.com` |
| Grafana    | Deployment + Ingress | 3000 | `grafana.caehomelab.com` |
| Ollama     | external host        | 11434 | (no public URL) |

## Monitoring

`scripts/monitor_k3s_health.sh` runs on a node and pushes cluster health
metrics (node count, pod count, failed pods, PV status) plus per-pod
CPU/memory/restart counts to InfluxDB every 60s. Grafana ships with two
auto-provisioned dashboards that read this data.

The script requires `INFLUX_TOKEN` to be set in the environment before
running — see the header comment.

## Architecture

```
                    ┌──────────┐
                    │ Internet │
                    └────┬─────┘
                         │   (Cloudflare DNS + Tailscale for remote)
                  ┌──────┴──────┐
                  │  cert-      │   DNS-01 validation
                  │  manager    │
                  └──────┬──────┘
                         │
            ┌────────────┴────────────┐
            │  Traefik (k3s addon)    │
            │  LoadBalancer 192.168.  │
            │  30.217                 │
            └────┬────┬────┬────┬─────┘
                 │    │    │    │
       ┌─────────┘    │    │    └─────────┐
       ▼              ▼    ▼              ▼
   Open WebUI    SearXNG  Bifrost      Infisical
       │              │    │              │
       └──────────────┴────┴──────────────┘
                         │
                         ▼
                  ┌────────────┐
                  │  Grafana   │  ──reads──▶  InfluxDB
                  │            │              (aiserver.home:8086)
                  └────────────┘
```

## Status & troubleshooting

```bash
./scripts/check-deployments.sh   # overall status
./scripts/deployment-test.sh     # automated pass/fail
./scripts/debug-pods.sh          # events + pod descriptions
kubectl logs -n ai <pod-name>    # per-pod logs
```

See [`DEPLOYMENT_STATUS.md`](./DEPLOYMENT_STATUS.md) for the current
state of each component and [`PREREQUISITES.md`](./PREREQUISITES.md) for
hardware/network/storage requirements.

## License

MIT
