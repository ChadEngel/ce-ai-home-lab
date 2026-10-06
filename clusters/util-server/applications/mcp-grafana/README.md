# mcp-grafana — read-only Grafana MCP server for the NOC agent

Official [Grafana MCP server](https://github.com/grafana/mcp-grafana) exposing
Grafana's observability surface to the Bifrost AI gateway over Model Context
Protocol. One upstream image serves **Loki logs, InfluxDB queries, and Grafana
dashboards/alerts** — no bespoke MCP code.

| | |
|---|---|
| Image | `grafana/mcp-grafana:2.0.1` |

> Docker Hub tags omit the `v` prefix used by GitHub releases; `v2.0.1`
> (GitHub) is `2.0.1` (the image).
| Transport | `streamable-http` on `:8000/mcp` |
| In-cluster URL | `http://mcp-grafana.ai.svc.cluster.local:8000/mcp` |
| Grafana auth | service-account token (`GRAFANA_SERVICE_ACCOUNT_TOKEN`) — read-only |
| Caller auth | none (see *Caller authentication* below) |
| Consumers | Bifrost MCP client `grafana-noc`; Virtual Key `aios-noc` |
| Design | `ce-aios/aios/roadmap/t4-noc-mcp-design.md` |
| Issues | #30 (T4), #31 (T5), #18 (H2) |

## Auth model — two independent credentials

There are **two** things called "auth" here; do not conflate them.

1. **Outbound (MCP server → Grafana):** `GRAFANA_SERVICE_ACCOUNT_TOKEN`. This is
   the Grafana service-account token, minted from a **Viewer** service account.
   It is stored in Infisical and injected as a mounted file
   (`GRAFANA_SERVICE_ACCOUNT_TOKEN_FILE`), which the server re-reads on **every
   request** — a rotation therefore needs no pod restart.
   Set **only** the `_FILE` var: if both the inline token and the `_FILE` var
   are present, the inline one wins and rotation silently stops working.

2. **Inbound (callers → MCP server):** optional bearer token
   (`--server-auth-token` / `MCP_GRAFANA_SERVER_TOKEN`). **Not set here.**

### Caller authentication (Q-T4-5)

Binding a non-loopback address with no caller token makes the server log a
**SECURITY** error at startup; upstream will make it fatal in a later release.
We currently compensate with a **NetworkPolicy** that only admits the Bifrost
pod. The upstream-blessed fix is to set `MCP_GRAFANA_SERVER_TOKEN` and have
Bifrost send `Authorization: Bearer <token>` via `auth_type: headers`.

> **Wiring caveat when you do enable it:** Bifrost resolves an `env.X` header
> value **only when the entire value is `env.X`** — it does not interpolate. Header
> values are sent verbatim, with **no automatic `Bearer ` prefix**
> (`core/mcp/credstore/shared_headers.go`). mcp-grafana, meanwhile, strictly
> requires the `Bearer ` scheme (`caller_auth.go`, `bearerTokenFromRequest`).
> So you need **two** secret values from one source: the raw token for
> mcp-grafana, and `Bearer <token>` for Bifrost. Tracked as follow-up.

## Read-only posture (three layers)

1. **`--disable-write`** — removes all create/update tools.
2. **Viewer-scoped Grafana token** — even the raw query tools cannot mutate.
3. **Bifrost Virtual Key allow-list** — per-agent tool scoping.

`--enable-query` deliberately re-registers the raw query tools
(`query_sql`, `query_influxdb`) that `--disable-write` strips, because
InfluxDB query support needs them. This is safe **only** because layer 2 holds.
If the Grafana token ever gains write scope, remove `--enable-query`.

`--enabled-tools` **replaces** upstream's default tool set rather than adding to
it; `influxdb` is not in the default list and is named explicitly.

## Host validation (read before editing the manifest)

`--allowed-hosts` defaults to loopback variants of `--address`. Once the server
is bound to a pod IP, **every** route on the MCP listener validates `Host`
(incl. `/healthz` and `/metrics`). Two consequences:

- Bifrost's request carries `Host: mcp-grafana.ai.svc.cluster.local:8000`, which
  is **not** in the default allowlist → **403**. The Service DNS name is added
  explicitly.
- A k8s `httpGet` probe sends `Host: <podIP>`, which is also rejected. The
  manifest therefore uses **`tcpSocket`** probes, which carry no `Host`.

If you change `--address` or the Service name, update `--allowed-hosts` to match.

## Credential setup (Infisical)

The Infisical secret `GRAFANA_SERVICE_ACCOUNT_TOKEN` (project
`caehomelab-v1q6`, env `prod`, path `/`) is synced by the `mcp-grafana-secrets-sync`
InfisicalSecret into K8s Secret `mcp-grafana-secrets`. See
`../infisical-operator/infisical-secrets-sync.yaml`.

To (re)create the token: Grafana → *Administration → Users and access →
Service accounts* → a service account with the **Viewer** role → *Add token*.

> An older, unused `GRAFANA_API_TOKEN` from July also exists in Infisical. It is
> not referenced by any manifest. It is **not** the canonical token — do not use
> it, and consider removing it to avoid confusion.

## Deploy

```bash
kubectl apply -n ai -f clusters/util-server/applications/mcp-grafana/kustomization.yaml
```

Then configure the Bifrost side: the git-tracked `bifrost-config` ConfigMap in
`../bifrost/kustomization.yaml` declares the MCP client `grafana-noc` and the
Virtual Key `aios-noc` (mounted at `/app/data/config.json`; restart the pod to
apply).

## Verify

```bash
# Server is up (from inside the cluster):
kubectl -n ai run curl --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sS -o /dev/null -w '%{http_code}\n' \
  http://mcp-grafana.ai.svc.cluster.local:8000/mcp

# After the Bifrost client is registered, confirm the tool list:
#   GET /api/mcp/clients  ->  client "grafana-noc"
```

End-to-end proof (one LogQL query through Bifrost) is issue **#31 (T5)**.
