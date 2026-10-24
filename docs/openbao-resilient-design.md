# OpenBao as the future secrets manager — resilient design

## What is this
Design doc for evaluating and (if adopted) running **OpenBao** — the Linux
Foundation fork of HashiCorp Vault (MPL-2.0, Vault-API-compatible) — as the
lab's secrets manager, replacing self-hosted Infisical. Covers target
architectures (single-node trial → 3-node Raft HA with transit auto-unseal),
the K8s sync layer, backups, alerting, and the migration plan. Written
2026-10-19, before any deployment. **Nothing has been deployed yet** — this
doc captures the design and the decisions still open.

Cross-references:
- Incumbent: [`../clusters/util-server/applications/infisical/README.md`](../clusters/util-server/applications/infisical/README.md)
- Sync flows to replicate: [`../clusters/util-server/applications/infisical-operator/infisical-secrets-sync.yaml`](../clusters/util-server/applications/infisical-operator/infisical-secrets-sync.yaml)
- Operator architecture: [`../clusters/util-server/applications/infisical-operator/README.md`](../clusters/util-server/applications/infisical-operator/README.md)
- Fresh-rebuild dependency ordering (current): `scripts/deploy-all.sh`
- Monitoring conventions: InfluxDB `kube_metrics`, Grafana → Pushover via
  `pushover-bridge`

---

## Current state (why evaluate a replacement)

Self-hosted Infisical at `https://secrets.caehomelab.com`, synced by the
Infisical K8s operator into native Secrets. Footprint 2026-10-19:

| Component | ns | Memory | Notes |
|---|---|---|---|
| `infisical` | ai | 762 Mi | app/UI |
| `infisical-db` | ai | 150 Mi | its Postgres |
| `infisical-redis` | ai | 19 Mi | its Redis |
| operator | infisical-operator-system | 36 Mi | **6 restarts / 14 d, last 2 h ago** |

7 sync flows: `CLOUDFLARE_API_TOKEN` (cert-manager — TLS critical path),
InfluxDB read (Grafana) and write (unpoller, synthetic-monitor) tokens,
`UDM_API_KEY`, `BIFROST_API_KEY`, `OPENAI_API_BASE_URL`, Pushover keys.
Auth model: one Machine Identity (`homelab-k8s-operator`, Universal Auth,
Viewer on the whole project root `/`); per-consumer least privilege is
emulated only via `template.data` filtering.

Out-of-band secrets NOT in the sync: `ai/aios-mail-digest-secrets`
(Bifrost VKs, GitHub App PEM), the Infisical bootstrap K8s secret
(`infisical-secrets`), and the operator's `infisical-universal-auth`.

**Motivation:** OpenBao is a single Raft-integrated pod (~200–300 Mi, no
external DB), per-path policies are first-class, MPL-2.0 with no license
risk, and the Vault API compatibility brings the entire ecosystem
(External Secrets Operator, vault CLI, agent tooling) for free.

## Target architecture

### Tier 1 — trial / resilient-enough

- One OpenBao pod, `openbao` container image, **integrated Raft storage** on
  a PVC (local-path or NFS class), its own namespace (`openbao`), untouched
  by any consumer.
- Unseal: manual, single-key Shamir (key printed once, stored offline —
  paper/Bitwarden).
- Snapshot CronJob (`bao operator raft snapshot`) → NAS/backups, retention-
  rotated alongside the UDM config exports
  (`home-network-config/backups/`).
- Survives: pod crash (restart + one unseal command), node reboot. A dead
  disk = snapshot restore (~5 min from the runbook).

### Tier 2 — true HA (the steady-state goal)

- **3 OpenBao pods, integrated Raft, one per node** (`caelx002`, `caelx003`,
  `util-server`), anti-affinity across hostnames. The image is multi-arch
  (covers util-server's arm64). Fits the cluster: nodes run at 44–64 %
  memory today, 3 × ~300 Mi is well inside headroom. Loses any 1 node with
  zero downtime; leader election is automatic.
- **Auto-unseal via transit from a tiny "seal" OpenBao** (single-node, no
  state burden): the main cluster stores its unseal key there; the seal box
  is unsealed manually only after a full-host outage. You never race to
  unseal the main cluster unattended again.
- Root token + seal-box tokens: offline, break-glass only.

### Sealing is the one behavioral change to internalize

Infisical is a web app: restart and it's back. OpenBao must be **unsealed
after every restart** before serving. The mitigating property (same as
Infisical today):

> **Sealed vault ≠ broken lab.** ESO materializes secrets into real K8s
> Secrets; consumers (cert-manager, Grafana, unpoller, Bifrost, …) read
> `secretKeyRef`s from etcd and keep working through vault downtime. Only
> *new* secret creation, *rotations*, and fresh-cluster builds need the
> vault up.

## Sync layer: External Secrets Operator

Replace `InfisicalSecret` CRs with **ExternalSecret** CRs served by ESO
(HA: 2 replicas, Vault provider against OpenBao — API-compatible, OpenBao
publishes the integration pattern). Consumers do not change: the same
`secretName`/`secretKeyRef` K8s Secrets get written, refreshed on
`refreshInterval` (equivalent of today's `resyncInterval: 60`).

Mapping example (one of seven):

```
today: InfisicalSecret cloudflare-dns-creds-sync → Secret cert-manager/cloudflare-dns-creds[CF_API_TOKEN]
future: ExternalSecret in ns cert-manager → RemoteRef kv/cert-manager/CLOUDFLARE_API_TOKEN
        → writes Secret cert-manager/cloudflare-dns-creds[CF_API_TOKEN]
```

Auth: ESO authenticates via **Kubernetes auth** (bound ServiceAccount,
short-lived token) — no long-lived static credential like
`infisical-universal-auth`. The ESO bootstrap token/SA Secret is created
out-of-band (same pattern as `infisical-universal-auth` today).

## Secrets layout & policies

- Path layout: `kv/<app>/<NAME>` (e.g. `kv/cert-manager/CLOUDFLARE_API_TOKEN`,
  `kv/influx/grafana-read`, `kv/influx/writer`, `kv/unpoller/UDM_API_KEY`,
  `kv/pushover/*`, `kv/aios-digest/*`, `kv/bifrost/*`).
- Policy per app namespace: only the consumer's ServiceAccount can read its
  path. This is real least-privilege instead of "Viewer on `/`" + template
  filtering.
- Migration seeding: one scripted `bao kv` import (checked into the repo),
  from the Infisical export — keeps cutover deterministic and re-runnable.
- **cert-manager is migrated LAST** — it is the TLS critical path for every
  service; a mistake there is a cluster-wide outage.

## Backups, alerting, drills

- Raft snapshots via CronJob → NAS/backups (retention rotated); tested
  **restore drill quarterly** — an untested backup is a rumor.
- Telemetry → existing stack: expose OpenBao metrics, alert via
  InfluxDB/Grafana → Pushover (same pipeline as UDM alerts):
  - **sealed state** (the 2 AM signal)
  - Raft peers < 3, leader changes
  - ESO sync failures / stale Secret age
  - upcoming lease/cert expirations
- Optional: Vault-style audit log → syslog-ng → Loki (paper trail for
  break-glass access).

## Failure scenarios

| Event | Tier 1 | Tier 2 (transit auto-unseal) |
|---|---|---|
| Pod crash | auto-restart (PVC), one unseal cmd | re-election, no action |
| One node dies | — (PVC lost → restore from snapshot) | no downtime; re-add peer later |
| Whole cluster reboot | unseal (1 cmd) | unseal the seal box (1 cmd) → all auto |
| Vault data loss | snapshot restore | Raft peers absorb it |
| You're asleep | consumers serve; alerts wait on unseal | same + auto-recovery after seal-box unseal |
| Rotation of a secret | `bao kv put` + ESO refreshes in ≤ refreshInterval | same |

## Fresh-cluster rebuild ordering (GitOps)

Same dependency shape as `scripts/deploy-all.sh` has today, with Infisical
swapped:

```
1. cert-manager CRDs (no TLS issuance yet)
2. OpenBao (+ unseal) → seal boxes for Tier 2
3. Seed script (bao kv import from snapshot/export)
4. ESO + ExternalSecrets (materializes all synced K8s Secrets)
5. Pushover bridge, Grafana, unpoller, Bifrost, OpenWebUI, …
6. cert-manager Cloudflare DNS-01 creds → TLS issuance
```

Bootstrap chicken-and-egg: the ESO auth Secret and (Tier 2) the seal-box
address/token are created out-of-band, exactly like
`infisical-universal-auth` and `infisical-secrets` today.

## Rollout plan (phased, reversible)

0. **This doc** + explicit user approval (AGENTS.md escalation rule: new
   shared-cluster service).
1. **Trial**: single-node Tier 1 in ns `openbao`, seeded with a throwaway
   test secret + copies of `PUSHOVER_*` (low sensitivity, real consumer).
   Infisical untouched; full teardown = one `kubectl delete ns openbao`.
2. **Parallel run**: ESO + one ExternalSecret for `pushover-secrets`
   sourced from OpenBao side-by-side with the Infisical sync for a week.
   Grafana alerting must not break.
3. **Cutover** (only if the trial earns it): import all secrets, migrate
   sync flows one by one, cert-manager last; keep Infisical running cold for
   one more cycle; then decommission (frees ~750 Mi) and delete its sync
   CRs.

## Decisions made

- **Evaluation target: OpenBao, not Vault** — license-safe (MPL-2.0),
  LF-governed, Vault-API-compatible; avoids another BUSL-surprise.
- **Sync via ESO, not the Bao agent injector** — preserves the
  "materialized K8s Secret + secretKeyRef" consumption model; zero
  consumer changes; closest drop-in for the 7 existing flows.
- **Integrated Raft storage, no external DB** — removes the Postgres
  dependency class Infisical carries; snapshots are native.
- **Phased rollout with parallel run** — Infisical keeps serving during the
  evaluation; reversibility at every step (one namespace, then one CR).
- **AUTO-UNSEAL FROM DAY ONE** (user decision 2026-10-19: manual unseal
  rejected) — even the Tier 1 trial runs a seal-box + transit topology.
  The seal box is manually unsealed only after *its own* restart, which the
  unseal CronJob automates (key in k8s secret — pragmatic homelab
  tradeoff, documented; real long-term protection is offline break-glass
  credentials).
- **Snapshots on the NAS** (user decision 2026-10-19: yes) — via the
  existing `nfs-client` storage class (NAS `192.168.30.121`), Retain
  policy, 14-day rotation, quarterly restore drills.
- **PKI/transit other uses: out of scope** (user decision 2026-10-19).

## Trial deployed (2026-10-19) — results

Deployed to ns `openbao` per this design with the decisions above
(manifests: `clusters/util-server/applications/openbao/`, README includes
the gotcha list — raft `cluster_addr` mandatory, `file` storage backend
removed in OpenBao 2.x, transit mount max TTL 768 h caps the periodic
autounseal token, token-renewal CronJob is a hard dependency).

| Check | Result |
|---|---|
| `bao operator init` on main | **0 unseal keys returned, served unsealed immediately** — transit auto-unseal proven |
| `kubectl delete pod` (main) | new pod booted **unsealed automatically**, raft seeds intact |
| Daily raft snapshot | works, lands on NFS PVC (NAS), 24 KB first snapshot |
| Weekly transit-token renewal | works (`ttl` reset to 768 h); policy needed `auth/token/renew` (update, sudo) |
| Footprint | 2 pods, ~108 Mi total (vs Infisical's ~1 GB) |
| Infisical | **untouched, still authoritative for all consumers** |

## Open questions (gated on the user)

1. ~~Manual unseal acceptable for Tier 1 trial?~~ **Answered: NO — auto-unseal from day one.**
2. ~~Trial seeds: throwaway + `PUSHOVER_*` copies OK?~~ **Answered: yes — deployed.**
3. ~~Tier 2 target: transit seal-box vs stay manual?~~ **Answered: transit seal-box (auto-unseal).**
4. ~~Snapshot destination — NAS?~~ **Answered: yes — `nfs-client` PVC.**
5. ~~PKI/transit beyond auto-unseal?~~ **Answered: leave out of scope.**
6. Phase 2 timing: when to install ESO and start the pushover parallel run?