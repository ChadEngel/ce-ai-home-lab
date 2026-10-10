# AGENTS.md

Instructions for AI coding assistants (and humans) working in this repo.
Read before suggesting changes to anything that touches the network, the
UDM-Pro, or any monitoring pipeline that scrapes a UniFi device.

---

## Rule 0 — Double-check every suggestion for adverse side effects

Before recommending any change that adds polling, scraping, or active
probing of a UniFi device (or any other resource that lives in the
critical path of the network), **trace the call chain end-to-end and ask:
"what else does this action wake up on the other end?"**

A "harmless" operation on the surface can have outsized side effects:

- **SSH to UID 0 on the UDM-Pro looks innocent** — `cat /sys/...` doesn't
  read or write anything sensitive. But every SSH session spawns a
  `systemd --user` lifecycle for UID 0, which briefly blocks the UDM's
  self-inform HTTP endpoint on `127.0.0.1:8080/inform`. The controller
  then appears "unreachable" to its adopted APs and switches for a
  second or two, causing forced disassociates and `mcad reporter_fail`
  errors. **The `udm-thermal` collector was SSHing every 15 seconds for
  13 days** and was the root cause of weeks of UDM instability that we
  initially blamed on firmware, fans, and the "dead Fan 1" theory.
  See `runbooks/udm-thermal-collector-loop.md` for the full story.

- **Adopting new APs / switches / gateways** always re-runs the full
  inform cycle. Don't do it during business hours.

- **InfluxDB write storms** (e.g. setting `INTERVAL=1` on a high-cardinality
  metric) can fill the disk and stall the TSM compaction queue, which
  makes Grafana look like the network is down.

- **k3s `hostNetwork: true` pods** share the host's network namespace —
  whatever port they bind is whatever port the host binds. Two such pods
  with the same port conflict at the kubelet level, not the pod level.

### The checklist for any "let me just add a small collector" suggestion

1. **What transport?** SSH, REST API, SNMP, syslog scrape? SSH to root
   on the UDM is the highest-risk option; the controller API is the
   lowest. Prefer the API.
2. **What cadence?** 15s is an SSH storm; 60s is a slow SSH storm;
   unpoller's default 180s is fine because it uses the API. If you
   find yourself wanting faster than 60s for a metric that the
   controller API doesn't expose, **the answer is to live without the
   metric, not to SSH harder.**
3. **What runs on the device side as a result?** `systemd --user`
   sessions, `pam_unix` audits, syslog lines, controller inform
   cycles, mcad reporters — all of these can be disturbed.
4. **How will we know it's hurting the device?** Look for: load
   average spikes, syslog event rate spikes, `mcad reporter_fail`
   entries, `AP-STA-DISCONNECTED` events, `inform_url` flapping.
   If any of these go up after a deploy, **the deploy is wrong, not
   the firmware.**
5. **Is there an API equivalent?** Always check unpoller's `usg` /
   `uap` / `usw` measurements first. Most things you can read over
   SSH are also readable from the controller REST API.

### When in doubt, escalate to the user

If a suggested change has any of these properties, **ask the user
before applying it**:

- Adds any SSH-based polling of a UniFi device
- Changes the cadence of an existing collector
- Adds a new port-forward or hostNetwork binding on caelx003
- Touches the `inform_url` of any adopted device (cache + force-provision
  dance required, see `home-network-config/network-devices/switches/CAESW002.md`)
- Modifies the UDM controller's mgmt settings (`x_ssh_*`, API keys,
  controller DB)

The cost of asking is one message. The cost of another "udm-thermal"
incident is days of debugging.

---

## Repo conventions

- **Markdown must be useful to a different AI, not just to humans.**
  Every doc has a top heading, a one-line "what is this" summary,
  cross-references to related files, and a "decision log" entry when
  a non-obvious choice was made. The `home-network-config` repo
  follows the same convention (see its `AGENTS.md`).
- **GitOps is the source of truth.** Anything you `kubectl apply` ad-hoc
  must be added to a manifest in this repo before the session ends.
- **Secrets stay in Infisical**, never in git. The Infisical operator
  syncs them into K8s secrets.
- **Loki timestamps are UTC.** The user is in Chicago (CDT, UTC-5).
  Always convert when interpreting logs.
- **Never roll back UDM-Pro firmware 5.1.33** without explicit user
  approval — it is the known-good version.
