# Bifrost

OpenAI-compatible AI gateway. Routes requests to local Ollama models
and cloud providers (OpenRouter, etc.) via a single API. Also serves
the provider/admin web UI.

Provider model syntax is `provider/model`, e.g.
`ollama/chat/llama3` or `openrouter/meta-llama/llama-3-70b-instruct`.

## URLs

- Public: `https://llm.caehomelab.com`
- API:    `https://llm.caehomelab.com/v1/models`, `/v1/chat/completions`
- Internal: `http://bifrost-api.ai.svc.cluster.local:8080`

## Deploy

```
./scripts/deploy-bifrost.sh
```

## Configuration

Bifrost is **primarily configured via its web UI** — `kustomization.yaml`
only sets the deployment shape (image, service, ingress, PVC).

- **In the repo:** Deployment, Service, Ingress, PVC (5 Gi on NFS),
  the `bifrost-secrets` Secret (placeholder BIFROST_API_KEY), and the
  Recreate strategy (single replica, RWO PVC).
- **Via the UI at https://llm.caehomelab.com → Settings → Providers:**
  provider credentials, model aliases, governance rules. Also
  `client_config` settings (governance, MCP, virtual keys, content
  logging, retention, etc.).
- **Persisted in `/app/data/config.db`** on the PVC, so they survive
  pod restarts. They **do NOT survive PVC recreation** — see the top
  comment in `kustomization.yaml` for the items that must be re-applied
  on a fresh PVC.

## Foot-guns

- **`log_retention_days` defaults to 365.** With full content logging,
  that grows `logs.db` to multi-GB and produces the NFS lock/fsync
  stalls that time out `/health`. Set it to `3` via
  `PUT /api/config {"client_config":{"log_retention_days":3}}` after
  first deploy, then restart the pod so the cleanup routine
  re-initializes with the new value. Run a one-time `VACUUM` to
  reclaim disk.
- **`bifrost-secrets`** has a placeholder `BIFROST_API_KEY`. Replace
  before exposing publicly (or before Open WebUI starts using it —
  see [`./openwebui/README.md`](./openwebui/README.md) for how the
  same key flows in via Infisical as `BIFROST_OLLAMA_KEY`).
- **Image is `:latest` with `imagePullPolicy: Always`** so restarts
  pick up upstream releases. If you want a pinned build, set both
  in `kustomization.yaml` and accept the maintenance cost.
