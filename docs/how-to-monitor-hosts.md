# Host & Proxmox Monitoring

Host-level metrics for the homelab Linux boxes and the Proxmox VE host, all
flowing into the existing InfluxDB v2 + Grafana stack.

```
 util-server          caelx002            caevmhost01 (Proxmox VE 9.2)
 Telegraf             Telegraf            PVE Metric Server (native, no agent)
    │                    │                        │
    └────────────────────┴────────────────────────┘
                         │  write (INFLUXDB_TOKEN)
                         ▼
        InfluxDB v2 — aiserver.home:8086 (org=home)
        buckets: kube_metrics · host_metrics · proxmox_metrics
                         │  read (INFLUXDB_READ_TOKEN → operator-synced
                         │        K8s Secret influxdb-secrets[INFLUX_TOKEN])
                         ▼
        Grafana — grafana.caehomelab.com
        dashboards: K3s Cluster Monitor · Linux Host Overview · (Proxmox, TBD)
```

## The two-token model

InfluxDB auth is split into a **write** token and a **read** token, both stored
in Infisical (`secret-management` / `prod` / `/`):

| Infisical key | Scope | Used by |
|---------------|-------|---------|
| `INFLUXDB_TOKEN` | all-bucket **write** | Telegraf (every host), the k3s monitor script, and the Proxmox metric server |
| `INFLUXDB_READ_TOKEN` | all-bucket **read** | Grafana (synced into K8s Secret `influxdb-secrets[INFLUX_TOKEN]` by the `influxdb-secrets-sync` InfisicalSecret CR) |

The write token is **write-only** — it cannot read its own data back (InfluxDB
returns "could not find bucket" for unauthorized reads). That is why
`install-telegraf.sh` verifies with the *read* token (transiently, over SSH
stdin — never written to disk on the node), while the node's env file holds only
the write token.

**No token rotation was needed** to add `host_metrics` / `proxmox_metrics` —
both tokens are *all-bucket*, so they automatically cover any new bucket you
create.

## Prerequisites (one-time)

1. **Buckets** — create in the InfluxDB UI (Data → Buckets → Create Bucket),
   30-day retention:
   - `host_metrics` (Telegraf writes here)
   - `proxmox_metrics` (Proxmox writes here)

   `kube_metrics` already exists for the k3s monitor script. The existing
   `INFLUXDB_TOKEN` / `INFLUXDB_READ_TOKEN` automatically cover the new buckets.

2. **Reachability** — each monitored host must reach `http://aiserver.home:8086`.
   `util-server` and `caelx002` already do (same LAN). Proxmox must too (verify
   from the PVE host shell: `curl -s http://aiserver.home:8086/health` → 200).

## Install Telegraf on a Linux box

Idempotent — safe on a fresh box **and** on one that already has Telegraf
(reconfigures it: moves any hardcoded token off disk, repoints the bucket at
`host_metrics`, sources the token from Infisical).

```bash
./scripts/install-telegraf.sh util-server    # reconfigures the existing telegraf
./scripts/install-telegraf.sh caelx002      # fresh install
./scripts/install-telegraf.sh aiserver      # optional: monitor the InfluxDB host too
```

What it does:
- SSHes in via Infisical (`LINUX_USER` / `LINUX_PVT_KEY`).
- Pre-flight: sudo, apt, and `aiserver.home:8086` reachable.
- Installs Telegraf from the **InfluxData apt repo** (Telegraf is NOT in
  Ubuntu's default repos). Adds the key (`influxdata-archive.key`, dearmored to
  `/etc/apt/keyrings/influxdata-archive.gpg`) + the
  `https://repos.influxdata.com/debian stable main` repo line. Idempotent —
  skips the repo/install step if `telegraf` is already present.
- Renders `config/telegraf/telegraf.conf.template` (substituting the node's
  hostname; `${INFLUXDB_TOKEN}` stays literal for runtime env interpolation).
- Writes the write token to `/etc/telegraf/telegraf.env` (**0600, root**) over
  SSH stdin — never as an SSH argument, so it never appears in the remote
  process list. The main config stays **0644 with no secret**.
- Installs a systemd drop-in (`scripts/systemd/telegraf-env.conf`) so systemd
  loads the env file into the telegraf process.
- Restarts telegraf and verifies a `cpu` point for the host landed in
  `host_metrics` (read-back with the read token).

Inputs (host-level only — `cpu, mem, disk, diskio, net, system, processes,
kernel, temp`). k3s cluster metrics are pushed separately by
`monitor_k3s_health.sh` → `kube_metrics`, so the `kubernetes` input is
intentionally NOT enabled here (avoids double-counting).

Manage on a node:
```bash
ssh cengel@<node> 'sudo systemctl status telegraf'
ssh cengel@<node> 'sudo journalctl -u telegraf -n 50'
```

## Configure the Proxmox metric server (PVE UI, one-time)

The Proxmox API token in Infisical (`PROXMOX_API_ID` / `PROXMOX_API_KEY`) is
restricted (no `Sys.Audit`/`Sys.Modify` on `/`), so this is a manual UI step
rather than an API call — and it's a one-time config anyway.

In the PVE web UI (https://192.168.30.204:8006):

**Datacenter → Metric Server → Add → InfluxDB**

| Field | Value |
|-------|-------|
| Name / ID | `aiserver-influxdb` |
| Type | InfluxDB |
| API version | **2** |
| Protocol | HTTP |
| Server | `aiserver.home` |
| Port | `8086` |
| Organization | `home` |
| Bucket | `proxmox_metrics` |
| Token | the `INFLUXDB_TOKEN` value (`infs get INFLUXDB_TOKEN` on a host with the agent, or copy from the Infisical UI) |

Create the `proxmox_metrics` bucket first (above), then add the metric server
(so PVE doesn't log write errors to a missing bucket). Data appears in
`proxmox_metrics` within ~10s. PVE stores the config in `/etc/pve/status.cfg`
(root-readable) and pushes host + VM/CT + storage stats.

Once data is flowing, build the Proxmox Grafana dashboard (TBD) by
introspecting the actual measurement names PVE writes
(`from(bucket:"proxmox_metrics") |> range(start:-10m) |> group() |> distinct(column:"_measurement")`
with a single-`_field` filter to avoid the "schema collision" Flux error).

## Grafana dashboards

Provisioned automatically by `scripts/deploy-grafana.sh`, which globs every
`*.json` in `scripts/grafana/dashboards/` into the `grafana-dashboards-json`
ConfigMap (mounted at `/var/lib/grafana/dashboards/default`). After adding or
editing a dashboard JSON, re-run `deploy-grafana.sh` **and** restart Grafana
so the file provider picks up the ConfigMap change:

```bash
./scripts/deploy-grafana.sh
kubectl rollout restart deployment/grafana -n ai
```

- **`linux-host-overview.json`** — *CE AI Lab — Linux Host Overview*
  (`/d/linux-host-overview/...`). 9 panels: CPU % per core, Memory %, Load
  1/5/15, Memory usage, Disk % per mount, Network throughput, Disk I/O, CPU
  temp, Processes. A `host` multi-select variable (All by default) filters every
  panel via `r.host =~ /${host:regex}/`. Backed by `host_metrics`. Generated by
  `build-linux-host.py` (re-run after editing panel definitions).

- **Proxmox dashboard** — TBD once PVE is pushing (see above).

## Token rotation

To rotate the write token (e.g. after a leak), create a new all-bucket write
token in the InfluxDB UI, store it in Infisical, and re-run the installer on each
host (the k3s monitor script picks up the new value on its next run since it
fetches `INFLUXDB_TOKEN` from Infisical each run; the operator re-syncs the read
token to the cluster within ~60s):

```bash
infs set INFLUXDB_TOKEN=<new-write-token>
./scripts/install-telegraf.sh util-server
./scripts/install-telegraf.sh caelx002
# Proxmox: update the token in Datacenter → Metric Server → aiserver-influxdb
```

Read token (`INFLUXDB_READ_TOKEN`) rotation: `infs set INFLUXDB_READ_TOKEN=<new>`
→ the `influxdb-secrets-sync` InfisicalSecret CR re-syncs it to the
`influxdb-secrets` K8s Secret within ~60s → Grafana picks it up on the next
datasource query (the `deleteDatasources:` block in the grafana kustomization
forces re-creation so the new token takes effect).

## Troubleshooting

- **Telegraf "could not find bucket"** — the write token can't read (expected);
  this only matters for *verification*. If it appears in the ongoing journal,
  the bucket is missing or the token lacks write on it. Confirm the bucket
  exists in the InfluxDB UI and that `INFLUXDB_TOKEN` is the all-bucket write
  token.
- **`apt install telegraf` → "package not found" / NO_PUBKEY** — the InfluxData
  repo/key step was skipped or used the wrong key. The installer uses
  `influxdata-archive.key` (which contains the `DA61C26A0585BD3B` signing
  subkey) → `/etc/apt/keyrings/influxdata-archive.gpg`, repo
  `https://repos.influxdata.com/debian stable main`. Do NOT use
  `influxdata-archive_compat.key` (old, expired key) or the `ubuntu <codename>`
  repo path (no Release file).
- **Flux `distinct()` "schema collision: cannot group float and integer"** —
  filter to a single `_field` before `distinct()`/`count()` across measurements,
  or `group(columns:["_field"])` first.
- **Dashboard not found after `deploy-grafana.sh`** — the ConfigMap updated but
  the pod's mounted volume is stale. `kubectl rollout restart deployment/grafana
  -n ai` to refresh.
- **`/api/ds/query` "bad request data"** — the Flux query has `"` chars; build
  the JSON payload with a tool that escapes them (python `json.dumps`), not
  shell string interpolation.