# UDM Pro Syslog Receiver

Standalone syslog daemon (currently **syslog-ng**) that ingests syslog from a
UniFi Dream Machine Pro and forwards structured events to Loki.

> **Status: WIP.** The reference config (`syslog-ng/udm-loki.conf`) is the
> source of truth, but `install.sh` / `uninstall.sh` are still rsyslog-targeted
> (the pivot to syslog-ng hasn't been finished — `rsyslog-omhttp` isn't in
> Ubuntu 26.04's universe, but `syslog-ng-mod-http` is). Use the syslog-ng
> config as the design and either finish the installer or hand-install until
> then.

## Why a dedicated host?

* Lives **outside the k3s cluster** — cluster can be down or restarting and
  syslog keeps running.
* Native RFC 3164 parsing (syslog-ng autodetects) — no Promtail/Alloy/Vector
  workaround needed.
* Single daemon, single config directory, easy to snapshot.
* Tailscale sidecar so the box is reachable for management without a public
  DNS record.

## Architecture

```
UDM Pro ──UDP 1514──▶ syslog-ng (this VM)
                          │
                          ├─ /var/log/udm-pro/  (local spool, 7-day rotate)
                          │
                          └─ http() ──▶ Loki in k3s cluster
                                        (loki.ai.svc.cluster.local:3100
                                         via Tailnet if cluster down)
```

## VM requirements

| Resource | Minimum         | Recommended         |
|----------|-----------------|---------------------|
| vCPU     | 1               | 1                   |
| RAM      | 512 MB          | 1 GB                |
| Disk     | 8 GB            | 16 GB (more history)|
| Network  | 192.168.30.0/24 | static IP           |
| OS       | Debian 12       | arm64 preferred     |

## Provisioning

1. Create VM in Proxmox (whatever UI/CLI you use)
2. Install Debian 12 minimal
3. Give it a **static IP on 192.168.30.0/24** (suggested: `.222` if free)
4. Set hostname (e.g. `syslog`)
5. Make sure SSH key access works from your workstation

## Install

Once the VM is reachable over SSH:

```bash
# from workstation
scp -r infra/syslog-receiver syslog-host:/tmp/
ssh syslog-host 'sudo /tmp/syslog-receiver/install.sh'
```

The installer is idempotent — safe to re-run.

## Post-install

After the install script completes:

1. **Point UDM at this host.** Run from workstation:

   ```bash
   ./infra/syslog-receiver/udm-rsyslog-update.sh
   ```

   This issues a PUT to `/proxy/network/api/s/default/rest/setting/rsyslogd`
   on the UDM with `ip=192.168.30.222` and `port=1514`.

2. **Verify UDM packets land:**

   ```bash
   ssh syslog-host 'tail -f /var/log/udm-pro/*.log'
   ```

3. **Verify Loki:**

   ```bash
   curl -s 'https://loki.caehomelab.com/loki/api/v1/query?query={job="udm-syslog"}' \
     | jq '.data.result | length'
   ```

   Should be > 0 within a few seconds of UDM sending.

## Local spool

Events land in `/var/log/udm-pro/udm.log` before being forwarded to Loki.
Rotation is daily, 7-day retention (`/etc/logrotate.d/udm-pro`). The spool
buffer protects against Loki outages — even if the cluster is offline for
hours, no events are lost.

## Files

| File                          | Purpose                                      |
|-------------------------------|----------------------------------------------|
| `install.sh`                  | (rsyslog-targeted — needs rewrite for syslog-ng) |
| `uninstall.sh`                | (rsyslog-targeted — needs rewrite for syslog-ng) |
| `install-remote.sh`           | scp + ssh installer for a remote host        |
| `udm-rsyslog-update.sh`       | Push UDM setting via API (sets syslog target) |
| `syslog-ng/udm-loki.conf`    | syslog-ng 4.x config: network() + http() → Loki |
