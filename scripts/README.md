# Deployment Scripts

This directory contains deployment scripts for the applications running
in the `ai` namespace of the k3s cluster.

## Prerequisites

- `kubectl` configured to talk to the cluster
- `nfs-client` StorageClass available (see `clusters/util-server/storage/`)
- `cert-manager` and the `letsencrypt-prod` ClusterIssuer installed and working

## Quick start

```bash
./scripts/deploy-all.sh
```

This applies the manifests in the right order — **Infisical and its operator
go first** so Infisical-managed secrets (Cloudflare token, InfluxDB token)
are available as K8s Secrets before any service that depends on them:
1. **infisical**          — secrets manager (self-hosted, in-cluster)
2. **infisical-operator** — syncs Infisical secrets into K8s Secrets
3. **bifrost**   — AI gateway (configure providers via web UI)
4. **openwebui** — main chat UI
5. **searxng**   — search engine
6. **grafana**   — InfluxDB-backed monitoring

> First-time only: before `deploy-all.sh` will fully work, Infisical must be
> bootstrapped — create the admin account, the `secret-management` project
> with its secrets, the `homelab-k8s-operator` Machine Identity, and the
> `infisical-universal-auth` K8s Secret. See
> `clusters/util-server/applications/infisical-operator/README.md`.

## Individual scripts

| Script | What it deploys | URL |
|---|---|---|
| `deploy-infisical.sh`          | Infisical secrets manager | https://secrets.caehomelab.com |
| `deploy-infisical-operator.sh` | Infisical K8s operator + InfisicalSecret sync CRs | (operator; no UI) |
| `deploy-bifrost.sh`    | Bifrost AI gateway on port 8080 | https://llm.caehomelab.com |
| `deploy-openwebui.sh`  | Open WebUI chat interface       | https://ai.caehomelab.com |
| `deploy-searxng.sh`    | SearXNG metasearch engine       | https://search.caehomelab.com |
| `deploy-grafana.sh`    | Grafana + auto-provisioned dashboards | https://grafana.caehomelab.com |
| `add-k3s-node.sh`       | Add a worker (agent) node to the cluster (secrets from Infisical) | (cluster node) |

After deploying Bifrost, visit https://llm.caehomelab.com → **Settings →
Providers** to add your LLM provider credentials (Ollama, OpenRouter,
etc.). Provider model names use the format `provider/model`, e.g.
`ollama/chat/llama3` or `openrouter/meta-llama/llama-3-70b-instruct`.

## Status & testing

```bash
./scripts/check-deployments.sh   # show pods/svcs/ingresses/pvcs/secrets
./scripts/deployment-test.sh     # pass/fail summary of the cluster
./scripts/debug-pods.sh          # events + pod descriptions for each app
```

## Cluster endpoint summary

| Service | Internal URL |
|---|---|
| Open WebUI | `http://openwebui.ai.svc.cluster.local:8080` |
| Bifrost    | `http://bifrost-api.ai.svc.cluster.local:8080` |
| SearXNG    | `http://searxng-api.ai.svc.cluster.local:8080` |
| Infisical  | `http://infisical.ai.svc.cluster.local:3000` |
| Grafana    | `http://grafana.ai.svc.cluster.local:3000` |
| Ollama     | external — `http://aiserver.home:11434` |

## Not deployed

- **MCPo** — `ghcr.io/open-webui/mcpo` is not published as a stable image.
- **Ollama** — runs on a separate host (`aiserver.home`); not in-cluster.

## Adding cluster nodes

See [`docs/how-to-add-k3s-node.md`](../docs/how-to-add-k3s-node.md). One-liner:

```bash
./scripts/add-k3s-node.sh caelx003   # secrets (LINUX_USER/LINUX_PVT_KEY/K3S_NODE_TOKEN) come from Infisical
```

The script auto-detects the server URL + k3s version, runs pre-flight over
SSH, installs the agent pinned to the server's version, and waits for the
node to go `Ready`. (Workers only — the single-server SQLite install can't
accept a second control-plane server.)

## Troubleshooting

### `kubectl apply -f <directory>/` fails with validation errors

Directories like `clusters/util-server/applications/openwebui/` may contain
`_values/values.yaml` (Helm-style) which lacks `apiVersion`/`kind`. Always
either:
- use the per-app `deploy-*.sh` script (which applies only the
  kustomization.yaml), or
- apply the kustomization file directly:
  `kubectl apply -f clusters/util-server/applications/searxng/kustomization.yaml`.

### Secret changes don't take effect

Restart the deployment:
```bash
kubectl rollout restart deployment/<name> -n ai
```

### TLS cert isn't being issued

```bash
kubectl describe certificate <cert-name> -n ai
kubectl describe challenge -n ai
kubectl logs -n cert-manager -l app=cert-manager
```

### Infisical pod is in ImagePullBackOff

Verify the image name. As of this writing the correct image is
`infisical/infisical:latest` on Docker Hub — `infisical/infisical-platform`
does not exist.
