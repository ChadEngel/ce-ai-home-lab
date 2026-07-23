# How To: Add a worker node to the k3s cluster

The homelab k3s cluster runs a single control-plane node (`util-server`,
`192.168.30.217`, embedded SQLite datastore) plus one or more **worker
(agent)** nodes. This doc covers adding a worker node in one command.

> **HA / second control-plane server:** not supported by the current
> single-server SQLite install. A second server would require converting the
> cluster to embedded etcd (`--cluster-init`) or an external datastore.
> That's out of scope here — this doc is for **workers only**.

## Prerequisites

On the machine you run the script from (e.g. your Mac):

- `kubectl` configured for the cluster (`kubectl get nodes` works).
- The Infisical agent is set up (`scripts/infisical-agent-setup.sh` ran once;
  `infs get INFLUXDB_TOKEN` works) using the `homelab-agent` Machine Identity.
- These Infisical secrets exist in `secret-management` / `prod` / `/`:
  - `LINUX_USER` — SSH username on the new node (e.g. `cengel`)
  - `LINUX_PVT_KEY` — SSH private key for that user (raw PEM, or base64-encoded PEM)
  - `K3S_NODE_TOKEN` — the k3s node-token (see [Refreshing the
    node-token](#refreshing-the-node-token) below if it's missing)

On the new node:

- Ubuntu (any recent LTS), `x86_64` or `arm64`.
- On the same LAN as `util-server` and able to reach
  `https://192.168.30.217:6443` (`curl -k https://192.168.30.217:6443/readyz`
  → `401` means reachable).
- `curl` installed, and **passwordless `sudo`** for `LINUX_USER`.
- A fresh install (no existing `k3s`), unless you pass `FORCE=1`.
- Resolvable from your Mac by hostname or IP (e.g. `caelx003` or
  `192.168.30.60`). Note: some homelab hosts resolve as a **bare** name
  (`caelx002`) but not with the `.home` suffix — use whichever resolves.

## Add a node (one command)

```bash
./scripts/add-k3s-node.sh caelx003
```

That's it. The script:

1. Auto-detects the API server URL (from your kubeconfig) and the k3s version
   (from the control-plane node's `kubeletVersion`) so the agent is **pinned
   to match the server** — agents must not be newer than the server.
2. Pulls `LINUX_USER`, `LINUX_PVT_KEY`, and `K3S_NODE_TOKEN` from Infisical.
3. Materializes the SSH key to a 0600 temp file (handling raw or base64 PEM).
4. Runs **pre-flight** over SSH: OS/arch, `curl`, passwordless `sudo`,
   existing k3s, free ports 6443/8080, and API reachability. Aborts if
   `curl`/`sudo` are missing, k3s is already present (unless `FORCE=1`), or
   the API is unreachable.
5. Installs the k3s **agent** with `K3S_URL=https://192.168.30.217:6443` and
   `K3S_TOKEN=<node-token>`. The token is staged on the node as a 0600 file
   (`/tmp/k3s.tok`) over SSH, read by the installer, and **deleted before
   the installer runs** — it is never printed or left on disk.
6. Polls `kubectl get node <name>` until `Ready` (up to ~90s), then prints the
   node table.

Explicit overrides (optional):

```bash
./scripts/add-k3s-node.sh 192.168.30.60 https://192.168.30.217:6443 v1.35.5+k3s1
FORCE=1 ./scripts/add-k3s-node.sh caelx003      # re-install even if k3s present
```

The new node shows up with role `<none>` (worker); only `util-server` has the
`control-plane` role.

## Refreshing the node-token

The token lives on the control-plane node at
`/var/lib/rancher/k3s/server/node-token`. If `K3S_NODE_TOKEN` is missing from
Infisical (or you want to refresh it), grab it from `util-server` and store
it:

```bash
# from a machine with the Infisical agent + util-server SSH access:
source scripts/infisical-agent.sh
ssh util-server 'sudo cat /var/lib/rancher/k3s/server/node-token' \
  | infs set K3S_NODE_TOKEN="$(cat)"
```

(Or non-interactively: `infs set "K3S_NODE_TOKEN=$(ssh util-server 'sudo cat /var/lib/rancher/k3s/server/node-token')"`.)

## Removing a node

To gracefully remove a worker:

```bash
NODE=caelx002
kubectl cordon  $NODE          # stop scheduling new pods
kubectl drain  $NODE --ignore-daemonsets --delete-emptydir-data   # evict pods
kubectl delete node $NODE
# then on the node itself, uninstall k3s:
ssh <user>@$NODE 'sudo /usr/local/bin/k3s-agent-uninstall.sh'
```

## Verifying

```bash
kubectl get nodes -o wide
kubectl get pods -A --field-selector spec.nodeName=caelx002   # pods on the new node
```