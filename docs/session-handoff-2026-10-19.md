# Session handoff — 2026-10-19

One-line summary: network hunt closed and documented; **active thread = aios-mail digest runs failing** (no digest emails since ~18 Oct ~13:00 CDT).

Resume from here. Related docs: `docs/migrate-influxdb-to-k8s.md`,
`AGENTS.md` (Rule 0 + escalation list), home-network-config
`docs/decision-log.md` (2026-10-16 entry).

## 1. What was just finished (committed)

- **Media-room wall drop mystery: RESOLVED.** Sonos "Media Room"
  speaker (`f0:f6:c1:72:a9:69`, 192.168.40.51) was WiFi-only since
  13:35 CDT 2026-10-16 because its wall drop terminated at
  **CAESW002 p5** but was never patched into service. User seated the
  cord; user set `native=Music` in the UI; assistant aligned
  `tagged_vlan_mgmt: custom→auto`; speaker power-cycled and came up
  **wired** (full DHCP cycle on `br40` 14:53 CDT, IP 40.51 preserved,
  WiFi assoc never returned). UniFi's `is_wired` flag lagged (`False`
  while `_last_seen_by_usw` refreshed every 15s) — trust
  `usw`/`uap` seen-fields for path migrations.
- **TV** (Sony `14:3f:a6:ac:7d:d2`, 192.168.250.250) moved from the
  Netgear to **CAESW002 p6** (native Default, zero config change).
- **L2 loop incident caught mid-hunt:** two cords seated at once put
  the TV on two switch paths → UDM logged `STP Port Blocked`
  14:39:57 CDT. RSTP held. Lesson recorded: one cord / one device /
  one path; a MAC on two UniFi ports simultaneously = loop signature.
- Committed as `898341b` in **home-network-config** (CAESW002.md port
  map corrected — uplink is p16, not p2 — + decision-log 2026-10-16
  entry).

## 2. ACTIVE: aios-mail digest failures (the current discussion)

**Symptom:** user stopped receiving mail digest "updates". Root cause
confirmed via pod logs + cronjob spec:

- CronJob `aios-mail-digest` (ns `ai`, `0 5,12,17 * * *`
  America/Chicago, image `caehomelab/aios-mail-digest:0.3.4`,
  `imagePullPolicy: Never` → runs from a local image on an amd64
  node; `envFrom → secretRef aios-mail-digest-secrets`).
- Last 3 schedules failed (27h / 15h / 3h13m ago). Failure mode:
  `attempt 1: unusable model content (finish=length, tokens=1200)`
  then `attempt 2 ... tokens=1800` →
  `RuntimeError: empty model content after retry (finish=length)`.
- Last success (18 Oct 17:00 UTC = 12:00 CDT): `digest generated:
  723 chars` posted ✓. Since then the input corpus tripled:
  `prose fresh: 29 → 190`, ledger `209 → 259`.
- **Root cause:** mail volume spike + small local model
  (`DIGEST_MODEL=ollama/muse-glimmer:latest` via
  `BIFROST_URL=https://llm.caehomelab.com`) hitting its baked-in
  output cap before producing parsable content. Token caps are in
  the app code (NOT env-tunable). `catchup-1018b` failed 19h ago —
  same family.
- Everything else is healthy: k3s nodes Ready (caelx002/caelx003/
  util-server), aios-mail-digest schedule unchanged, postgres-backup
  fine, Bifrost reachable.

**CronJob env (full list, for reference):** `BIFROST_URL`,
`DIGEST_MODEL=ollama/muse-glimmer:latest`, `DIGEST_ISSUE_NUMBER=50`,
`GITHUB_INSTALLATION_ID=168700840`, `DIGEST_PRIORITY_KEYWORDS`,
`DIGEST_PROTECTED_DOMAINS`, `DIGEST_CONTACT_EXCLUDES=ui.com`,
`DIGEST_SENT_TOP=250`, `DIGEST_ORDERS_FOLDER/RECEIPTS_FOLDER/
FILED_FOLDER`, `DIGEST_FILED_DAYS=10`, `DIGEST_SCAN_TOP=200`.
Secrets: `secretRef: aios-mail-digest-secrets`.
Manifests exported to `clusters/util-server/applications/aios-mail/cronjob-digest.yaml`.
`aios-mail-catchup` is an ad-hoc Job, not a CronJob.

**Pending user decision:**

1. Pick the replacement `DIGEST_MODEL` (cannot list Bifrost's models
   from this machine — need the Ollama host or Bifrost path).
   Caveat: `muse-glimmer:latest` is a mutable tag — a recent rebuild
   could silently have changed behavior; if so, pin a digest tag.
2. Then flush the backlog with a one-off manual digest run.
3. Optional app-side fix (wherever aios source lives — NOT in this
   repo): make the token cap env-tunable / raise it.

## 3. Loose ends / follow-ups

- **Verify Loki + InfluxDB pipeline on next machine**: one transient
  Loki query failure (~15:05 CDT 10-19, `Expecting value` = empty
  body) and an empty InfluxDB `usg` grep result in the sweep — both
  may be transient/auth, both need a re-test (unpoller pod status,
  latest point timestamps).
- **CronJob manifests in git** (partially done here — proper
  GitOps-ification incl. the `aios-mail-digest-secrets` Infisical
  sync remains open).
- `topology.md` (home-network-config): Netgear correction pending
  (VLAN-aware Plus switch, mgmt `9C:C9:EB:CC:2E:40` @ 192.168.250.8;
  stale gateway MAC `0c:ea:14:4e:7a:95`; "non-managed" claim wrong).
- CAESW002/Garage forget/adopt window (after 11pm) for clean
  `default_url`; UDM memory re-check (IPS disabled; DPI = next lever);
  Sonos `is_wired` flag should self-correct — confirm visually.

## 4. Resume checklist (next machine)

1. Pull both repos: `ce-ai-lab` (branch
   `chore/pre-udm-swap-2026-09-27`) and `home-network-config` (main).
2. Read this file + `docs/decision-log.md` 2026-10-16 entry.
3. UDM creds: `exports/udm-config-2026-09-26/secrets-cache.env`
   (UDM_API_KEY for `https://192.168.250.1/proxy/network/api/...`).
4. kubectl context already points at the util-server cluster; the ai
   ns CronJob logs: `kubectl logs -n ai job/aios-mail-digest-<id>`.
5. Ask the user for their DIGEST_MODEL choice → edit CronJob → run
   one-off digest → verify "digest generated" + comment posted.