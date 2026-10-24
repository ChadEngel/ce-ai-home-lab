# OpenBao — trial deployment (Phase 1, auto-unseal from day one)

OpenBao (Linux Foundation fork of Vault, MPL-2.0) running as the **trial**
secrets manager alongside (not yet replacing) Infisical. Design + rollout
plan: [`docs/openbao-resilient-design.md`](../../../../docs/openbao-resilient-design.md).
Deployed 2026-10-19. Image pinned `openbao/openbao:2.7.1`.

## Topology (as deployed)

```
seal-box (1 pod, raft on nfs PVC)  --transit/autounseal-->  main (raft on nfs PVC)
   manual unseal after restart,                        transit auto-unseal from day one
   auto-recovered by CronJob                           ZERO shamir unseal keys exist
```

- `sealbox.yaml` — seal box: single-node raft, serves `transit/encrypt|decrypt`
  for the autounseal key. Holds NO application secrets. `cluster_addr` is
  **required** when using raft storage (OpenBao refuses otherwise).
- `main.yaml` — main instance: raft + `seal "transit"` stanza; the transit
  token is rendered into the HCL by a busybox init container (sed) from
  k8s secret `openbao-transit-token` (lab envsubst pattern). File must be
  world-readable (644) — container runs as uid 100.
- `cronjobs.yaml` — three CronJobs (see below).

## CronJobs (all proven working 2026-10-19)

| CronJob | Schedule | Purpose |
|---|---|---|
| `openbao-unseal-seal-box` | `*/5 * * * *` | unseals the seal box after its pod restart (key from k8s secret) |
| `openbao-renew-transit-token` | Monday 03:00 UTC | **hard dependency**: renews the autounseal periodic token (`bao write auth/token/renew token=$BAO_TOKEN increment=700h`); live TTL resets to 768 h no matter the period horizon |
| `openbao-raft-snapshot` | 02:15 daily | `raft snapshot save` → `openbao-snapshots` PVC (nfs = NAS), 14-day retention |

## K8s secrets inventory (namespace `openbao`)

| Secret | Contents | Notes |
|---|---|---|
| `openbao-sealbox-creds` | `UNSEAL_KEY`, `ROOT_TOKEN` | seal-box Shamir 1/1 + root. Trial storage in-cluster; **long-term home is offline paper**. |
| `openbao-transit-token` | `token` | 768 h periodic, orphan, policy `autounseal`, renewed weekly by CronJob |
| `openbao-main-creds` | `ROOT_TOKEN` | main vault root; break-glass only |
| `openbao-snapshot-token` | `token` | policy `snapshot` (sys/storage/raft/snapshot read/create/update/sudo), 768 h periodic — **NOT auto-renewed; rotate if it expires** (recreate via seal… see gotchas) |

## Seeded data (demo only)

- `kv/trial/hello` — throwaway smoke test
- `kv/pushover/PUSHOVER_USER_KEY`, `kv/pushover/PUSHOVER_API_TOKEN` — copies
  of the Infisical-managed values (read from `ai/pushover-secrets`, never
  printed to transcripts)

## Proven behaviors (evidence 2026-10-19)

- `bao operator init` on main returned **0 unseal keys** (transit-sealed) and
  the instance served while `Sealed=false` from first boot — auto-unseal works.
- `kubectl delete pod` on main → new pod booted **unsealed automatically**,
  raft data (seeds) intact.
- Snapshot job wrote `openbao-main-20261024T214651.snap` (24 KB) to the NFS PVC.
- Renewal job reset ttl to 768 h.

## Gotchas learned (keep for Tier 2)

1. OpenBao 2.x **removed the `file` storage backend** — use raft everywhere.
2. `cluster_addr` is mandatory with raft storage.
3. `disable_mlock` is not a valid top-level config field in 2.7 — omit it.
4. Transit mount `max_lease_ttl` caps periodic token TTL (default **768 h**);
   tuned the mount to 8760 h, but live TTL still resets to 768 h per renewal —
   the renewal CronJob is a hard dependency, not optional.
5. `bao token renew` CLI needs the token as an argument/body field (CLI
   behavior differs from Vault's `-self` flag); the working form is the API
   body write above.
6. `autounseal` policy needs `transit/encrypt|decrypt/autounseal` **plus**
   `auth/token/renew` (update, sudo) for self-renewal via the cron job.
7. Init container renders config root-owned — 644, not 640.

## Restore drill (quarterly; also the disaster path)

```bash
# newest snapshot
SNAP=$(kubectl -n openbao run -it --rm --restart=Never --image=busybox:1.36 \
  ls-back -o name --overrides='...' 2>/dev/null || echo "see PVC listing below")
# 1) list snapshots: kubectl -n openbao exec deploy/openbao-main -- \
#      sh -c 'ls -t /openbao/data/vault.db 2>/dev/null'; snapshots live on the
#      openbao-snapshots PVC — mount it in a scratch pod and pick the newest.
# 2) from a pod with BAO_ADDR + BAO_TOKEN (root or sudo-capable), and the
#    chosen snapshot mounted:
#      bao operator raft snapshot restore -address=... /backups/<snap>.snap
# 3) restart main; verify `bao kv get kv/trial/hello`.
```

## Rollback / teardown

Infisical is untouched and still authoritative for all consumers. Trial
teardown: `kubectl delete ns openbao` (+ delete the 3 PVCs if desired — nfs
`Retain` keeps the volumes).

## Next phases (design doc drives)

- Phase 2: install ESO, one ExternalSecret for `pushover-secrets` sourced
  from `kv/pushover/*` — run parallel with the Infisical sync for a week.
- Phase 3: full import + consumer migration, cert-manager last; Tier 2 =
  main scales to 3 replicas with anti-affinity (seal box stays 1).
- Snapshot expiry watch: `openbao-snapshot-token` (768 h periodic, not
  auto-renewed) — recreate before it expires or fold into the renewal cron.