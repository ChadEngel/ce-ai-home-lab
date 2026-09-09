# Tailscale HA Subnet Router (k3s nodes)

Both k3s nodes run Tailscale as an HA subnet-router pair, making the home LAN
(`192.168.30.0/24`) reachable from any device on the tailnet — at home or
remote. Tailscale automatically fails over between the two nodes; no manual
action is needed when one goes down.

Set up 2026-09-09.

## Topology

| Node | LAN IP | Tailscale IP | Role |
|------|--------|--------------|------|
| `util-server` (control-plane) | `192.168.30.217` | `100.85.106.29` | primary (actively routing) |
| `caelx002` (worker) | `192.168.30.60` | `100.103.142.4` | standby (auto-failover) |

- Tailscale version: `1.102.3` (official apt repo, `tailscale.list`)
- Advertised route (both nodes): **`192.168.30.0/24` only**
- Routes approved in the Tailscale admin console → **Machines** → `…` →
  *Edit route settings* for each node. Approving the same subnet on both
  nodes is what forms the HA pair: Tailscale picks one as primary and moves
  traffic to the other if it stops responding.
- Current primary is visible from any node:
  `sudo tailscale status --json | jq '.Self.PrimaryRoutes'`
  (the standby shows `null` — that is normal, it holds the same approved
  route and takes over on failure).

## What was done on each node

1. Installed Tailscale from the official repo:
   `curl -fsSL https://tailscale.com/install.sh | sudo bash`
2. Enabled IP forwarding persistently — `/etc/sysctl.d/99-tailscale.conf`:

   ```
   net.ipv4.ip_forward = 1
   net.ipv6.conf.all.forwarding = 1
   ```

3. Logged in and advertised the route:

   ```
   sudo tailscale up --advertise-routes=192.168.30.0/24
   ```

   (First `up` prints a `https://login.tailscale.com/a/…` auth URL — one-time
   browser login per node. Later flag changes use `tailscale set` / a repeat
   `tailscale up` with the same flags.)

4. Approved `192.168.30.0/24` for **both** nodes in
   <https://login.tailscale.com/admin/machines>.

## What tailnet devices can reach

- Every Traefik ingress with its existing public DNS + Let's Encrypt certs:
  `ai.`, `llm.`, `secrets.`, `search.`, `grafana.`, `influxdb.`, `loki.` —
  all `*.caehomelab.com` (public DNS → `192.168.30.217`, routed over the
  tailnet). No DNS or cert changes were needed.
- Other LAN devices: Mac Studio / Ollama (`aibeasts-mac-studio`), InfluxDB on
  `aiserver.home:8086`, UDM, etc.

### Not reachable (by design, for now)

- `10.43.0.0/16` (ClusterIP / service CIDR) is **not** advertised. Internal
  services (unpoller, pushover-bridge, mcpo) stay off the tailnet. If direct
  ClusterIP access is ever needed: `sudo tailscale up
  --advertise-routes=192.168.30.0/24,10.43.0.0/16` on both nodes + re-approve
  in the admin console.

## Known limitations

- **DNS single-point**: `*.caehomelab.com` A records point at
  `192.168.30.217` (util-server) only. If util-server dies, caelx002 still
  routes the subnet, but the hostnames break until DNS is updated. Traefik
  itself runs on both nodes (svclb), so pointing DNS at `192.168.30.60`
  (round-robin / failover records) is a possible future improvement.
- **UDP GRO**: both nodes log a throughput hint about UDP GRO on `enp2s0`
  (`tailscale.com/s/ethtool-config-udp-gro`). Cosmetic for LAN-speed links;
  apply the ethtool tuning only if tunnel throughput matters.

## Side effects of the install (2026-09-09)

- `influxdata.list` → `influxdata.list.disabled` on **both** nodes: that apt
  repo 404s on `apt update` (no Release file for the configured suite) and
  aborted Tailscale's install script. Renamed, not deleted; no installed
  package depends on it staying enabled.
- `caelx002` had an interrupted dpkg — completed via `sudo dpkg
  --configure -a` before installing Tailscale.

## Verification

```sh
# On a tailnet device:
ping 192.168.30.217                      # LAN IP through the tunnel
curl -I https://ai.caehomelab.com        # valid cert, Traefik answers

# On either node:
sudo tailscale status                    # both nodes online, see each other
sudo tailscale status --json | jq '.Self.PrimaryRoutes'   # route active here?
sudo tailscale ping 100.85.106.29        # node-to-node tunnel check
```