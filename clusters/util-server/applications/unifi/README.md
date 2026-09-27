# UniFi Network Application — DR standby

A **disaster-recovery standby** UniFi controller (UniFi Network Application +
its own MongoDB) in the `ai` namespace, in case the live controller on the UDM
Pro (`192.168.250.1`) is lost. It is **not** part of `deploy-all.sh` and is not
meant to manage devices during normal operation.

> **Normal state: idle.** No devices are adopted here and nothing depends on it.
> The UDM Pro remains the live controller; [unpoller](../unpoller/kustomization.yaml)
> keeps scraping it for metrics.

| Resource | Kind | Node | Storage | Why |
|---|---|---|---|---|
| `unifi` | Deployment (`hostNetwork`) | `caelx003` (192.168.30.251) | `nfs-client` PVC, 10Gi, `/config` | device-facing ports + stable inform IP at failover |
| `unifi-mongo` | StatefulSet | `util-server` | `local-path` PVC, 10Gi | MongoDB 4.4; DB must not live on NFS |

Image: `lscr.io/linuxserver/unifi-network-application:10.6.106-ls147` (pinned by
digest). Deploy with [`scripts/deploy-unifi.sh`](../../../../scripts/deploy-unifi.sh).

## DNS name

**`unifi.caehomelab.com`** — a **DNS-only** (not Cloudflare-proxied) public
record pointing directly at the `hostNetwork` node (`192.168.30.251`), so devices
and admins can use a stable name instead of the node IP:

| Use | URL |
|---|---|
| Web UI | `https://unifi.caehomelab.com:8443` |
| Inform (devices) | `http://unifi.caehomelab.com:8080/inform` |

> The record points at the **node**, not the Traefik LoadBalancer
> (`192.168.30.217`), because UniFi needs 8080/TCP + 3478/10001/1900 UDP on the
> controller node — Traefik only serves 80/443. It must also be DNS-only (a
> proxied record would resolve to Cloudflare and break inform), and it must live
> in **public DNS, not the UDM's DNS** — during a DR event the UDM (and its DNS)
> is what failed. Port `:8443` is required for the UI (no Ingress/443 for this
> app by design).

## Why MongoDB 4.4 (not latest)

UniFi Network 8.1+ supports MongoDB 3.6–7.0 (9.0 adds 8.0). We pin **4.4**
because the k3s nodes are QEMU VMs that do **not** expose the AVX CPU flag:

```console
$ kubectl exec -n ai deploy/grafana -- grep -m1 ^flags /proc/cpuinfo | tr ' ' '\n' | grep avx
(no output)
```

MongoDB **5.0+ requires AVX** on x86-64 and crashes with `Illegal instruction`
(SIGILL) on these hosts. 4.4 is EOL upstream but is the newest branch that runs
without AVX and is still accepted by the controller.

> To upgrade past 4.4 you must first expose AVX to the VMs (Proxmox: set the VM
> CPU type to `host`, or a named model with AVX), then `mongodump`/`mongorestore`
> into the newer DB and bump `setFeatureCompatibilityVersion` — MongoDB never
> auto-upgrades between major versions.

## Warm vs cold standby

The controller is deployed `replicas: 1` (warm): it stays booted so you can log
in and confirm it works, and so first-boot Mongo initialization is already done.
Cost is roughly 0.5–1 GiB RAM on `caelx003`.

For a **cold** standby that consumes nothing until needed:

```sh
kubectl scale deployment/unifi -n ai --replicas=0      # park it
kubectl scale deployment/unifi -n ai --replicas=1      # wake it (failover)
```

MongoDB (`unifi-mongo`) should stay up in both cases — it is tiny and its data
must persist. If you also scale Mongo down, remember `local-path` pins it to
`util-server`.

## Failover runbook

Use this when the UDM Pro's controller is lost and you need to manage the
network from here.

1. **Have a recent backup.** The controller's config is what matters. Back up
   the UDM regularly (see *Backups* below) so it is not lost with the hardware.
2. **Bring the standby up:**
   ```sh
   kubectl scale deployment/unifi -n ai --replicas=1
   kubectl rollout status deployment/unifi -n ai --timeout=600s
   ```
3. **Restore the backup:** open `https://unifi.caehomelab.com:8443`, choose
   **Restore from backup** in the first-run wizard (or `Settings → System →
   Restore` once set up) and upload the UDM backup file.
4. **Set the inform address:** **Settings → System → Advanced → Inform Host
   Override** → `unifi.caehomelab.com` (or `192.168.30.251`).
5. **Re-point devices** at the new controller:
   ```sh
   ssh ubnt@<device-ip>          # default device password: ubnt
   set-inform http://unifi.caehomelab.com:8080/inform
   ```
   Devices fall back to the inform URL in their config; re-running `set-inform`
   (or DHCP option 43 / DNS discovery) accelerates it.
6. Once the UDM is back, reverse: restore/re-adopt there and `set-inform` back
   to the UDM. Only one controller manages a device at a time.

### Device-facing ports

| Port | Proto | Purpose |
|---|---|---|
| 8080 | TCP | device inform / adoption |
| 8443 | TCP | web admin UI |
| 3478 | UDP | STUN |
| 10001 | UDP | AP discovery |
| 1900 | UDP | "discoverable on L2" |
| 8843 / 8880 | TCP | guest portal redirects |
| 6789 | TCP | mobile throughput test |
| 5514 | UDP | remote syslog |

If `caelx003` is ever replaced, update the `nodeSelector` in
[`kustomization.yaml`](./kustomization.yaml) **and repoint the
`unifi.caehomelab.com` A record** to the new node. That record is what devices
cache, so a static DHCP lease (or the DNS name) for the node is strongly
recommended.

## Backups

The /config PVC holds this standby's own state; the **source of truth is the
UDM's controller backup**. Recommended: export from the UDM on a schedule
(**Settings → System → Backup → Download Backup**, or the `backup` API), store
it on the NAS, and restore it here at failover (step 3).

A portable snapshot of this instance (if you ever adopt devices here and want
to move them back to the UDM):

```sh
kubectl exec -n ai unifi-mongo-0 -- sh -c \
  'mongodump --username root --password "$MONGO_INITDB_ROOT_PASSWORD" \
     --authenticationDatabase admin --db unifi --archive' > unifi-mongo.archive
```

Restore into a fresh `unifi-mongo-0` with `mongorestore --archive`.

## Secrets

`unifi-secrets[MONGO_ROOT_PASSWORD]` and `[MONGO_PASS]` are generated and stored
in Infisical on first deploy by the script — never committed. Mongo init runs
only once (when `/data/db` is empty), so **do not regenerate** these after first
boot.

## Verification

```sh
kubectl get pods -n ai -l app=unifi -o wide
kubectl get pod -n ai -l app=unifi-mongo -o wide
curl -kI https://unifi.caehomelab.com:8443
```
