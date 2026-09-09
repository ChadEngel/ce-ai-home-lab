# CE AI Home Lab — Setup Log

Steps taken so far to get the lab up and running.

---

## Tailscale

Tailscale is set up to connect machines on the home network.

Both k3s nodes (`util-server`, `caelx002`) run Tailscale as an **HA subnet
router pair** advertising `192.168.30.0/24` — all `*.caehomelab.com` apps
(and the rest of the LAN) are reachable from any tailnet device, with
automatic failover. Full details:
[`docs/tailscale-subnet-router.md`](./docs/tailscale-subnet-router.md).

---

## Ollama (AIbeast)

Ollama is running on the **AIbeast** machine (`aibeasts-mac-studio`).

---

## util-server (Mac mini + Ubuntu VM)

A Mac mini runs **VMware Fusion** with an **Ubuntu** guest in **bridged mode** networking.

| Item | Value |
|------|-------|
| Hostname | `util-server.home` |
| Hypervisor | VMware Fusion (Mac mini) |
| Guest OS | Ubuntu |
| Networking | Bridged mode |

---

## Notes

## Open questions / TODO

- [x] Document Tailscale install and device list
  (subnet-router setup: [`docs/tailscale-subnet-router.md`](./docs/tailscale-subnet-router.md);
  tailnet device list lives in the Tailscale admin console)
- [ ] Document Ollama install and models on AIbeast
- [ ] Document util-server VM setup (Fusion config, Ubuntu install, bridged networking details)
