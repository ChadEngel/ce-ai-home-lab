# CE AI Home Lab — Setup Log

Steps taken so far to get the lab up and running.

---

## Tailscale

Tailscale is set up to connect machines on the home network.

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

- [ ] Document Tailscale install and device list
- [ ] Document Ollama install and models on AIbeast
- [ ] Document util-server VM setup (Fusion config, Ubuntu install, bridged networking details)
