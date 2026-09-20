# SearXNG

Self-hosted metasearch engine — one form, many search engines, no
tracking.

## URLs

- Public: `https://search.caehomelab.com`
- Internal: `http://searxng-api.ai.svc.cluster.local:8080`

## Deploy

```
./scripts/deploy-searxng.sh
```

## Configuration

- **In the repo:** Service, PVC (2 Gi on NFS), Ingress, and
  `kustomization.yaml` references the `searxng-settings` ConfigMap.
- **Via ConfigMap `searxng-settings`:** engine on/off, safe-search,
  themes, secret_key, etc. The kustomization only mounts it — the
  contents live in ConfigMap form, not in this directory.

## Foot-guns

- **`secret_key` must be set** in the ConfigMap before exposing
  publicly; an instance-default key lets any caller forge sessions.
  See the warning in `deploy-searxng.sh`'s output.
- **Stale `searxng-config` ConfigMap** from a prior rename was cleaned
  up in `DEPLOYMENT_STATUS.md`'s "Earlier fixes" — if you see it,
  `kubectl delete cm -n ai searxng-config`.
