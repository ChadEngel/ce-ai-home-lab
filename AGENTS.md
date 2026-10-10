# AGENTS.md

Instructions for AI coding assistants (and humans) working in this repo.

---

## Rule 0 — Before recommending any change, trace the full call chain and look for adverse conditions

The cardinal sin in this lab is **fixing one symptom while introducing
or worsening another** — usually because we didn't trace the change all
the way through to its side effects on every system that touches the
target.

Before recommending any change — a new collector, a config edit, a
package upgrade, a manifest tweak, a script change, a "quick
kubectl exec" hack — **walk through this checklist**:

### A. Side effects on the target system

- What processes, sessions, sockets, files, or kernel resources does
  this action create, modify, or wake up on the target?
- Does the target have its own monitoring that will notice? (UDM has
  mcad reporters, controller self-inform, syslog; k3s has kubelet
  health, containerd events; UniFi devices have their own inform
  cycles.)
- If the target is shared with other workloads (e.g. a physical box
  running both k3s and a syslog receiver), does this change starve
  any of them?

### B. Side effects on systems that depend on the target

- What talks to this thing? (APs → UDM controller; switches → UDM
  controller; Grafana → InfluxDB; Loki → syslog-ng; k3s pods → UDM
  API.)
- Will any of those dependents see a transient outage, increased
  latency, a different code path, or a different error code as a
  result?
- Are any of those dependents in the user-facing critical path
  (Wi-Fi, Internet, AI gateway)?

### C. Side effects on the human

- Will the user be paged? Will a dashboard go red? Will a log query
  start returning confusing noise that masks real issues?
- Will the change be obvious to debug at 2 AM, or will it look like
  a different problem? ("Is the Wi-Fi flapping because of the
  switch, or because of the new collector?")

### D. Reversibility

- Can this be rolled back in under 60 seconds without data loss?
- If not, do we have a known-good backup? (See
  `home-network-config/backups/` for the UDM config export cadence.)
- Is there a "blast radius" — could this cascade into a wider outage
  if it goes wrong? (A bad `kubectl apply` on a CRD, a bad
  `iptables` rule, a bad `nft` set, a bad `inform_url` write to
  Mongo all do.)

### E. Are we masking a real problem?

- Is the proposed change trying to silence an alert, hide a
  symptom, or work around an error that we should actually
  understand and fix?
- Are we conflating "the dashboard looks empty" with "the data
  isn't being collected"? (Sometimes the dashboard is broken and
  the data is fine. Sometimes the opposite. Confirm before either
  fix.)

### F. Are we introducing the very thing we're trying to fix?

- Does the change itself create the load / spam / instability that
  it was meant to detect or avoid? (See the udm-thermal case study
  below — a collector meant to monitor UDM thermal health was the
  cause of UDM instability.)
- Does the change depend on a third party (Infisical, Cloudflare,
  a public API) that has its own rate limits or SLOs? Will the
  change push us over a quota?

---

## Worked examples — "harmless" changes that weren't

These are real incidents from this lab. They are not exhaustive; the
goal is to internalize the *pattern* (looks innocent on the surface,
real damage one hop away) so you spot it in novel cases.

### 1. SSH-based collector destabilizing the device it was monitoring

**The proposal:** "Add a small k3s cron-style pod that SSHes to the
UDM every 15 seconds and reads `/sys/class/thermal/thermal_zone0/temp`
+ fan RPM, so we have high-resolution thermal data in Grafana."

**What it looked like:** harmless `cat` over a read-only file.

**What it actually did:** every SSH session spawned a
`systemd --user` lifecycle for UID 0, which briefly blocked the
UDM's self-inform HTTP endpoint on `127.0.0.1:8080/inform`. The
controller then appeared "unreachable" to its adopted APs and
switches for 1-3 seconds, causing `mcad reporter_fail` errors
and forced Wi-Fi disassociates. **After 13 days of this, the UDM
had thousands of flap events and the user spent days blaming
firmware, fans, and a "dead Fan 1" theory** — all wrong. The
fix was a different collector (unpoller, API-based, 3 min
cadence) and the UDM went back to normal.

**Lesson:** SSH to root on the UDM is fundamentally incompatible
with controller stability. The transport itself is the problem,
not the cadence. See
`home-network-config/runbooks/udm-thermal-collector-loop.md`.

### 2. `inform_url` API write that silently doesn't propagate

**The proposal:** "Set the `inform_url` on a switch via the UniFi
API so it points at the right controller."

**What it looked like:** a one-line API call.

**What it actually did:** the `cmd/devmgr set-inform` call returns
`{"meta":{"rc":"ok"}}` but **does not actually push the new URL
to the device.** The device continues to inform at the old URL
until the controller's cached `inform_url` field gets refreshed
in Mongo AND the device is force-provisioned. The controller API
will show the new URL in `/api/s/default/stat/device` for 5-10
minutes after a Mongo change, hiding the problem from API-based
debugging.

**Lesson:** when an "obvious" API call doesn't work, check the
underlying data store (Mongo) directly. The fix here is
`db.device.update` + `force-provision`, not the API.

### 3. Loki query that masks a real outage

**The proposal:** "Add a wide time-range Loki query to the
runbook to help us see the surrounding context when an alert
fires."

**What it looked like:** helpful documentation.

**What it actually did:** Loki has a 5000-event cap per query
and a relatively short retention window. Wide queries on a
noisy source (the UDM emits ~300-600 syslog events/minute at
baseline) push out the events we actually wanted to see,
**including the one that caused the alert.** The query returns
"no results" and we assume the issue was a false alarm.

**Lesson:** always use narrow `start`/`end` epoch_ns ranges for
Loki queries. Wide queries are useful for trend analysis, not
for forensics. See
`home-network-config/runbooks/syslog-receiver-problems.md`.

### 4. `hostNetwork: true` pod colliding with another workload

**The proposal:** "Make the syslog receiver pod use
`hostNetwork: true` so it can bind to port 514 directly."

**What it looked like:** standard pattern for syslog receivers.

**What it actually did:** k3s `hostNetwork: true` pods share the
host's network namespace. If two such pods try to bind the same
port (or if the host already runs a service on that port), the
conflict happens at the kubelet / containerd level, not the pod
level, and the failure mode is a cryptic
`failed to bind port` error. Worse, the second pod can take
down the first if it happens to win the race.

**Lesson:** audit every `hostNetwork: true` pod for port
overlap with other pods and host services. Prefer `hostPort`
on a `ClusterIP` service unless you genuinely need
`hostNetwork`.

### 5. InfluxDB write storm that fills the disk

**The proposal:** "Set the metric scrape interval to 1 second
so we can catch transient spikes."

**What it looked like:** a config change.

**What it actually did:** at 1s cadence, even a small set of
cardinality fields writes gigabytes per day to the TSM engine.
Once the disk fills, TSM compaction stalls, write latency goes
to seconds, and the whole InfluxDB instance becomes effectively
unavailable. **The dashboard then shows "no data" and we
assume the network is the problem, when the real problem is
the monitor.**

**Lesson:** high-cardinality metrics at sub-minute cadence need
explicit retention + disk budget planning. Default to the
lowest cadence that gives actionable signal; 15-60s is almost
always enough for human-notification alerts.

### 6. "Quick fix" kubectl exec that doesn't make it into git

**The proposal:** "Just run `kubectl exec ... -- pkill foo` to
clear a stuck process, we'll do a proper fix later."

**What it looked like:** a five-second intervention.

**What it actually did:** the next time the same problem occurs
(e.g. after a node reboot), the fix is gone and we don't know
why. Worse, the "proper fix later" never comes, and now the
real problem is masked by a workaround that nobody
remembers applying.

**Lesson:** anything done with `kubectl exec` that we want to
keep must be turned into a manifest, a script, or a runbook
entry **before the session ends.** Otherwise it's a tombstone
in our memory and a ghost in the cluster.

### 7. Mongo direct edit without force-provision

**The proposal:** "Edit the device's `inform_url` in Mongo
directly to fix the stale value."

**What it looked like:** correct.

**What it actually did:** without a follow-up `force-provision`
call, the controller overwrites the new Mongo value on the
next inform cycle from the device. The change appears to
"not stick" and we keep editing Mongo. The fix is to
edit Mongo AND force-provision. Always both, always in that
order.

---

## When in doubt, escalate to the user

If a suggested change has **any** of these properties, ask the
user before applying it. The cost of asking is one message.
The cost of a "fix" that introduces the problem is days.

- **Adds any new SSH-based polling, scraping, or active probing of
  a UniFi device** (or any device whose control plane shares a
  process with its data plane)
- **Changes the cadence of an existing collector** without first
  verifying the new cadence won't exceed the target's tolerance
- **Modifies the UDM controller's mgmt settings** (`x_ssh_*`,
  API keys, controller DB, inform URLs, port-profiles)
- **Modifies Infisical secrets, sync CRs, or operator configs**
  — these propagate to every consuming pod
- **Touches `iptables`, `nft`, or any firewall config** on a node
  in the network path
- **Adds a new `hostNetwork: true` pod or a new `hostPort`**
- **Changes the k3s cluster's networking** (CNI, kube-proxy,
  CoreDNS, Traefik ingress)
- **Edits a port-profile on a switch** (locks speed/duplex,
  VLAN membership, PoE budget — affects every device on that
  port)
- **Changes inter-VLAN firewall rules or mDNS reflector settings**
  (breaks Apple devices in weird ways)
- **Upgrades any UniFi firmware, k3s version, or base OS** (the
  lab has known-good versions pinned; do not change without
  approval)
- **Deletes or recreates any StatefulSet, PVC, or persistent
  workload** (data loss risk)
- **"Fixes" an alert by silencing it, raising the threshold, or
  ignoring the error** — usually we should understand the error
  first

---

## Repo conventions

- **Markdown must be useful to a different AI, not just to humans.**
  Every doc has a top heading, a one-line "what is this" summary,
  cross-references to related files, and a "decision log" entry
  when a non-obvious choice was made.
- **GitOps is the source of truth.** Anything `kubectl apply`'d
  ad-hoc must be added to a manifest in this repo before the
  session ends.
- **Secrets stay in Infisical**, never in git. The Infisical
  operator syncs them into K8s secrets.
- **Loki timestamps are UTC.** The user is in Chicago (CDT,
  UTC-5). Always convert when interpreting logs.
- **InfluxDB is at `http://aiserver.home:8086`**, org=`home`,
  bucket=`network_metrics`. Two measurements: `usg` (unpoller,
  API-based) and `kube_metrics` (service_health, etc.). The
  old `udm_thermal` measurement is deprecated; the SSH-based
  collector that wrote it has been removed because it was
  destabilizing the UDM.
- **Never roll back UDM-Pro firmware 5.1.33** without explicit
  user approval — it is the known-good version.
- **The UDM-Pro has ONE physical fan.** `fan1_rpm=0` is a normal
  unused tachometer channel; `fan2_rpm` is the real reading. Do
  not flag `fan1_rpm=0` as a failure.
- **Mongo is the source of truth for `inform_url`.** The
  controller API caches the field for 5-10 min after any
  Mongo change. The `cmd/devmgr set-inform` call returns
  `{"rc":"ok"}` but does NOT actually push the new URL — you
  must Mongo-update then force-provision.
