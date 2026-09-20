# Open WebUI

Main LLM chat UI. Talks to Bifrost via the OpenAI-compatible API
(`/v1/*`); does **not** talk to Ollama directly when Bifrost is in
the path.

## URLs

- Public: `https://ai.caehomelab.com`
- Internal: `http://openwebui.ai.svc.cluster.local:8080`

## Deploy

```
./scripts/deploy-openwebui.sh
```

## Configuration

- **In the repo:** Deployment, Service, Ingress, PVC (5 Gi on NFS), the
  Recreate strategy (single replica, RWO PVC), and the env-var
  connection to Bifrost (URL + key, both from Infisical-synced
  Secrets).
- **Via the UI at https://ai.caehomelab.com:** users, conversations,
  RAG knowledge bases, custom system prompts. First admin to register
  becomes the admin.
- **Secret:** `OPENWEBUI_OLLAMA_BASE_URL` (must end in `/v1`),
  `BIFROST_OLLAMA_KEY` — both synced from Infisical.

## Authentication

The default install uses local accounts (first signup becomes admin).
For family use, the recommended path is **OIDC against your Entra
tenant** — single sign-on with MFA, no per-user password to manage.
Runbook: [`../../../../docs/openwebui-entra-oidc.md`](../../../../docs/openwebui-entra-oidc.md).

## Foot-guns

- **OpenAI vs. Ollama URL.** Bifrost speaks the OpenAI API
  (`/v1/models`, `/v1/chat/completions`), **not** the Ollama API
  (`/api/tags`). So Open WebUI MUST reach it via `OPENAI_API_BASE_URL`,
  not via `OLLAMA_BASE_URL`. Pointing `OLLAMA_BASE_URL` at Bifrost
  yields an empty model list because Open WebUI then calls
  `/api/tags`, which Bifrost does not implement.
- **The admin "Connections" UI overrides env vars.** Open WebUI
  persists the OpenAI connection (`api_base_urls`, `api_keys`,
  `api_configs`) in its DB on first save, and that DB config TAKES
  PRECEDENCE over the Infisical-supplied env vars. For Infisical to
  stay the single source of truth, the DB `openai` entry must be kept
  as `{"enable": true}` ONLY. If models disappear from the UI, check
  this first.
- **Multi-replica requires `WEBUI_SECRET_KEY`** so each replica can
  sign the same session cookies. The kustomization supplies this from
  the `openwebui-secrets` Secret (synced from Infisical).
- **Stale `openwebui-bifrost-config` ConfigMap** from the LiteLLM era
  is still in the cluster but is no longer referenced. Safe to delete:
  `kubectl delete cm -n ai openwebui-bifrost-config`.
