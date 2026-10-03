# UDM Pro Syslog Receiver (caelx004)

Standalone **syslog-ng** on a single-purpose VM that ingests UDM Pro remote
syslog (UDP 1514) and forwards structured events to Loki over the LAN.
The host is named **caelx004** in the lab; the static IP is **192.168.30.189**.

This intentionally lives **outside** the k3s cluster — syslog intake keeps
working when the cluster is down or restarting, and we don't waste a
worker pod on what is fundamentally a 1-CPU log forwarder.

## Why syslog-ng (not rsyslog / Promtail / Vector / Alloy)

* Both Promtail and Alloy's `loki.source.syslog` parser is locked to
  RFC 5424. The UDM sends RFC 3164 (BSD), so packets were being silently
  dropped with "expecting a version value in the range 1-999" parse errors.
* Vector's `syslog` source auto-detects RFC 5424 structured data and
  mangles UDM bodies that contain `[CATEGORY-SUB]` brackets.
* syslog-ng autodetects RFC 3164 vs RFC 5424 and ships `syslog-ng-mod-http`
  in Ubuntu 26.04's universe repo (`rsyslog-omhttp` is not).
* Native RFC 3164 parser + native `http()` destination = single daemon,
  single config file, ~20 MB image.

## Architecture

```
UDM Pro ──UDP 1514──▶ syslog-ng (caelx004, 192.168.30.189)
                          │
                          ├─ /data/udm-pro/  (separate volume, 7-day rotate)
                          │
                          └─ http() POST ──▶ Loki in k3s cluster
                                            (192.168.30.217:3100
                                             via Tailnet if cluster down)
```

## What gets extracted (Loki labels)

| Loki label  | Source                                    |
|-------------|-------------------------------------------|
| `job`       | static: `udm-syslog`                      |
| `source`    | static: `udm-pro`                         |
| `host`      | `${HOST}` from the RFC 3164 header        |
| `app`       | `${PROGRAM}` from the RFC 3164 TAG        |
| `severity`  | `${LEVEL}` (info, warning, error, ...)    |
| `facility`  | `${FACILITY}`                             |

We deliberately do **not** parse `[CATEGORY-SUB]` from the message body in
syslog-ng. The UDM's bracketed category prefix is easier to pull out via a
LogQL regex in Grafana (`|~ "\\[(?P<cat>[A-Z_]+)(-(?P<sub>[A-Z_0-9-]+))?\\]"`)
or by piping through Vector later if we want it as Loki labels. Adding a
patterndb + python-parser to syslog-ng for this single enrichment is not
worth the operational cost.

## VM requirements

| Resource | Minimum         | Recommended         |
|----------|-----------------|---------------------|
| vCPU     | 1               | 1                   |
| RAM      | 512 MB          | 1 GB                |
| Disk     | 8 GB            | 16 GB (more history)|
| Network  | 192.168.30.0/24 | static IP `.189`    |
| OS       | Ubuntu 24.04+   | arm64 preferred     |

## Provisioning

1. **Create the VM in Proxmox.** ID `104` (matching the hostname `caelx004`).
   1 vCPU, 1 GiB RAM, 16 GiB OS disk is plenty.
2. **Attach a second disk for syslog data.** This is the volume the installer
   will write to. Recommended: **8 GiB minimum, ext4, VirtIO block**.
   Attaching in Proxmox (UI: *Hardware → Hard Disk → Add → SCSI/VirtIO
   Block, 8 GiB*; CLI: `qm set 104 --scsi1 local-lvm:8` then
   `qm rescan` if needed).
3. **Install Ubuntu 24.04 minimal.** In the installer, use the second disk
   as `/data` (NOT `/var/log`). Format ext4, no encryption — this is a lab
   box. If the second disk wasn't visible during install, attach it after
   boot and format + fstab it manually (see step 8).
4. Give the VM a **static IP on 192.168.30.0/24** (`192.168.30.189`).
   Easiest: DHCP reservation in the UDM (step 6).
5. Set the hostname (`caelx004`).
6. **Reserve `.189` in the UDM DHCP reservations** for the VM's MAC so it
   doesn't drift.
7. Make sure SSH key access works from your workstation
   (the install script materializes `~/.ssh/homelab-agent-util-server` from
   Infisical `LINUX_PVT_KEY` if missing).
8. **Verify the second disk is mounted at `/data`** (not on `/var/log`):
   ```bash
   lsblk                            # confirm sdb or vdb exists, not partitioned
   sudo mkfs.ext4 -L udm-data /dev/vdb
   echo "LABEL=udm-data /data ext4 defaults,noatime 0 2" | sudo tee -a /etc/fstab
   sudo mkdir -p /data
   sudo mount -a
   df -h /data                      # confirm ~8 GiB available, separate mount
   sudo mkdir -p /data/udm-pro      # the install script will create this too
   ```

   > **Why a separate mount?** syslog-ng writes the live spool + rotated logs
   > + a disk-buffer for Loki outages. Without a separate volume, a Loki
   > outage during a noisy UDM event burst can fill the OS volume and wedge
   > the VM.
   >
   > **Why not NFS?** This VM exists specifically so syslog survives the NAS
   > being unreachable. NFS would re-introduce that dependency.

## Install

From your workstation, with the VM up and `/data` mounted:

```bash
export REMOTE_HOST=192.168.30.189          # or caelx004.home once mDNS is up
export LOKI_URL=http://192.168.30.217:3100
export SUDO_PASS='...'                     # sudo password for the remote user
./infra/syslog-receiver/install-remote.sh
```

The installer is idempotent — safe to re-run. It scps the directory to the
host and runs `install.sh` over SSH. `install.sh` will REFUSE to run if
`/data` (`DATA_MOUNT`) is not a separate filesystem, or if `/data/udm-pro`
(`DATA_DIR`) resolves onto a different filesystem than `/data` — so the
volume really does need to exist and be mounted first.

## Post-install

1. **Point UDM at this host:**

   ```bash
   export UDM_HOST=192.168.250.1            # or unifi.home
   ./infra/syslog-receiver/udm-rsyslog-update.sh
   ```

   Issues a `PUT /api/s/default/rest/setting/rsyslogd` with
   `ip=192.168.30.189 port=1514 enabled=true`.

2. **Verify UDM packets land on caelx004:**

   ```bash
   ssh caelx004 'tail -f /data/udm-pro/*.log'
   ```

3. **Verify Loki receives them:**

   ```bash
   curl -sk -G 'https://loki.caehomelab.com/loki/api/v1/query_range' \
     --data-urlencode 'query={job="udm-syslog"}' --data-urlencode 'limit=5' \
     | jq '.data.result | length'
   ```

   Should be > 0 within a few seconds of the UDM sending.

## Local spool

Events land in `/data/udm-pro/udm.log` before being forwarded to Loki.
Rotation is daily, 7-day retention (`/etc/logrotate.d/udm-pro`). The spool
protects against Loki outages — even if the cluster is offline for hours,
no events are lost (the `disk-buffer()` on the http() destination in
`syslog-ng/udm-loki.conf` backs this up, also under `/data/udm-pro/`).

## Files

| File                          | Purpose                                                |
|-------------------------------|--------------------------------------------------------|
| `install.sh`                  | Hand-install: packages + syslog-ng config + logrotate + verify `/data` is a separate mount |
| `uninstall.sh`                | Reverses install.sh (stops syslog-ng, removes configs, keeps `/data/udm-pro`) |
| `install-remote.sh`           | scp + ssh installer for a remote host                  |
| `udm-rsyslog-update.sh`       | Push UDM syslog target setting via UniFi OS API        |
| `logrotate-udm-pro`           | `/etc/logrotate.d/udm-pro` template (substitutes `DATA_DIR`) |
| `syslog-ng/udm-loki.conf`    | syslog-ng 4.x config: network() + http() → Loki        |