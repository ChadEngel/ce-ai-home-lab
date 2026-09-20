# udm-thermal

SSH-based collector for the UDM Pro SoC thermal zone + fans.

## Why this exists

unpoller only captures the UniFi controller's board temps
(`temp_cpu / temp_phy / temp_local`) from the `temperatures[]` API.
The reading that actually spikes under load is the Linux kernel
thermal zone (`type=cpu-thermal / thermal_zone0`), which is only
reachable over SSH sysfs and is invisible to unpoller. That's the
gap this collector closes — and it's wired into a Grafana alert at
high thresholds (see `scripts/grafana/alerts/udm-*.json`).

## URLs

- (No public URL; an internal-only collector pod.)

## Deploy

```
./scripts/deploy-udm-thermal.sh
# Note: waits up to ~100s for the Infisical-synced secret to land
# before applying the Deployment, so it doesn't restart-loop on a
# missing $UDM_SSH_PASS / $INFLUXDB_TOKEN.
```

## Configuration

- **In the repo:** ConfigMap (`udm-thermal-poll` — the SSH+curl+write
  loop), Deployment (Recreate strategy).
- **Auth model:**
  - **UDM SSH:** root password in Infisical `UDM_SSH_PASS`, synced
    to K8s secret `udm-thermal-secrets`. sshpass reads it from
    `$SSHPASS` (never argv). Enable UDM SSH under
    **Settings → System → Advanced → SSH** (and set the root
    password).
  - **InfluxDB v2:** the write token (`INFLUXDB_TOKEN`) synced into
    the same secret. Same token unpoller uses.
- **Writes to:** InfluxDB bucket `network_metrics`, measurement
  `udm_thermal`.

## Why in k8s (not on the UDM)

Same reason as unpoller — UniFi OS wipes on-box packages on
firmware upgrade, so anything installed on the UDM eventually
disappears.

## Foot-guns

- **Needs UDM SSH enabled** with a known root password. If you change
  the UDM root password, update `UDM_SSH_PASS` in Infisical — the
  pod will retry, but it logs the auth failure every poll.
- **Single replica + Recreate** (like every other single-PVC pod in
  this lab). Don't try to scale.
- **The collector's polling cadence** is in the ConfigMap
  (`POLL_INTERVAL_SEC`). Default 15s; tightening it means more SSH
  sessions to the UDM.
