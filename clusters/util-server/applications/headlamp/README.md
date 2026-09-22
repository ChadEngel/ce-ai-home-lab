# Headlamp

Read-only [Headlamp](https://headlamp.dev/) Kubernetes web UI for the
cluster, at `https://headlamp.caehomelab.com`.

## What this is for (and what it is NOT)

Headlamp is a **troubleshooting** window, not a metrics system.

| | Headlamp | InfluxDB + Grafana |
|---|---|---|
| Live pod events, container logs, YAML, describe | ✅ | ❌ |
| Historical metrics / retention | ❌ (in-memory only) | ✅ |
| Alerting | ❌ | ✅ (Pushover) |
| Per-container CPU/mem/network/disk I/O | ❌ | ⚠️ partial |
| "Why is this pod crash-looping right now?" | ✅ | ❌ (60s lag) |

Its CPU/memory sparklines read `metrics-server` — the same source
`scripts/monitor_k3s_health.sh` already uses. It stores nothing and sends no
alerts, so it does not improve metric *collection*. For that, the real gaps
are kube-state-metrics (deployment/PVC/job state over time) and cAdvisor /
node-exporter (per-container I/O, node pressure) — see `MONITORING.md`.

## URLs

- Public: `https://headlamp.caehomelab.com` (token login)
- Internal: `http://headlamp.ai.svc.cluster.local:80`

## Deploy

```bash
./scripts/deploy-headlamp.sh            # deploy
./scripts/deploy-headlamp.sh --token    # deploy, then print a fresh token
```

No secrets or Infisical entries are required — auth is a ServiceAccount token,
not a stored credential.

## Authentication — a ServiceAccount token

The UI is reachable without any password, but **every API call requires a
token** and RBAC decides what that token may do. Paste a token into the
Headlamp login prompt:

```bash
kubectl create token headlamp -n ai --duration=720h   # 30d
```

Use a long duration. The session cookie is capped by `sessionTTL: 86400`
(24h), and Headlamp cannot refresh a static pasted token (refresh is
OIDC-only) — so a 1h token would leave you with a valid cookie making 401'd
API calls after an hour.

The token is bound to the `headlamp` ServiceAccount, which is **read-only**
(see RBAC below). Nothing is stored server-side: minting a token is the entire
setup, and revoking access is just deleting the SA or rotating its tokens.

### Why not basic auth?

An earlier revision of this app used Traefik basic auth (a `Middleware` plus
an htpasswd Secret synced from Infisical). It was **removed deliberately**:

- It prompted for a username/password on *every* visit, on top of the token
  prompt — two gates for one job.
- A shared password is a weaker gate than a token: it is not per-user, it
  does not expire, and it is not RBAC-scoped.
- The token flow alone already gives per-user attribution and scoped,
  expiring credentials.

If you ever do want an edge gate, add OIDC / forward-auth rather than
htpasswd — see "Enabling OIDC later".

### Why not OIDC?

Headlamp supports OIDC, and this lab already runs Entra ID for Open WebUI.
It is a natural follow-up, but it is **not** a drop-in: Headlamp validates
the OIDC token against the API server, which means k3s must run with
`--oidc-issuer-url` / `--oidc-client-id` / `--oidc-username-claim`. That is a
control-plane restart on `util-server` and a change to `/etc/rancher/k3s/config.yaml`.
The token flow gets the UI working today with no control-plane change, and
gives per-user identity once OIDC lands.
See "Enabling OIDC later" below.

## RBAC — read-only, and deliberately no secrets

Bound to the ServiceAccount `headlamp`:

- the built-in **`view`** ClusterRole (pods, deployments, logs, events,
  services, ingress, configmaps, PVCs, endpoints), and
- **`headlamp-cluster-read`** for cluster-scoped objects `view` omits (nodes,
  persistentvolumes, storageclasses, CRDs, ingressclasses, runtimeclasses,
  priorityclasses, apiservices, metrics.k8s.io).

**Secrets are intentionally excluded.** `view` omits them by design and we do
not add them back. In this cluster the `ai` namespace holds
`infisical-universal-auth` — whose `clientSecret` grants read access to *every*
secret in Infisical — plus all seven TLS private keys. Surfacing those through
a web UI is a genuine escalation path, not a theoretical one.
Headlamp works fine without secret read access; the Secrets page just shows
empty or 403.

To opt in anyway (not recommended):

```yaml
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
```

## Foot-guns

- **Do not add `-unsafe-use-service-account-token`.** It makes every visitor
the pod's ServiceAccount with no login at all. Combined with the removed basic
auth, that would leave the UI completely open. It is only safe behind a real
per-user auth proxy (OIDC / forward-auth).
- **Tokens expire.** Headlamp cannot refresh a pasted token, so a short-lived
token (e.g. 1h) leaves you logged in but with every API call returning 401
until you paste a new one. Use `--duration=720h`.
- **The image is digest-pinned.** Upgrades are deliberate — resolve the new
tag's index digest, apply, then confirm the UI loads.
- `-in-cluster-context-name=homelab` is cosmetic (the label on the context in
the UI); it does not affect auth.
- **No ingress auth.** Anyone who can reach the hostname sees the login screen
and can attempt tokens; only a valid, RBAC-scoped token gets data. This is
fine because the token is the gate — do not "fix" a 401 by adding a
trusted-header bypass.

## Enabling OIDC later

1. Register an app in Entra ID with redirect URI
   `https://headlamp.caehomelab.com/oidc-callback`.
2. Put `clientID` / `clientSecret` in Infisical and sync them (same pattern as
   `openwebui-secrets-sync`).
3. Add `--oidc-client-id`, `--oidc-client-secret`, `--oidc-idp-issuer-url`
   (or the `HEADLAMP_CONFIG_OIDC_*` env vars) to the container args.
4. Add `--oidc-issuer-url`, `--oidc-client-id`, `--oidc-username-claim=email`
   to k3s on `util-server` (`/etc/rancher/k3s/config.yaml`) and restart k3s.
5. `kubectl create clusterrolebinding headlamp-oidc-view --clusterrole=view
   --user=<the-email-claim-value>` for each person.

Traefik already forwards `X-Forwarded-Proto`, so Headlamp should build the
`https://` callback correctly; if you see an `http://` callback mismatch, that
header is the thing to check.
