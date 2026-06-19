# CE AI Home Lab

Documentation for my personal AI home lab — how the machines are connected, what's running, and repeatable setup steps as I build it out.

## Lab overview

| Machine | Role |
|---------|------|
| **AIbeast** (`aibeasts-mac-studio` / `aiserver.home`) | Ollama LLM server |
| **util-server** (`util-server.home`) | Mac mini running VMware Fusion with Ubuntu (bridged networking) |
| **Dev workstation** | Cursor IDE, connected to local Ollama via Tailscale |

Machines are linked over **Tailscale**. Cursor is configured to use only the local `qwen3.5:35B` model on AIbeast — no cloud models for agent conversations.

## Documentation

### [SETUP.md](./SETUP.md)

**What it covers:** A living log of lab infrastructure as it comes online.

- Tailscale networking between home machines
- Ollama on AIbeast
- util-server — Mac mini + Ubuntu VM in bridged mode

**Why it exists:** Central place to record what has been stood up and what still needs documenting. Updated incrementally as the lab grows.

### [persistant_nfs_mount.md](./persistant_nfs_mount.md)

**What it covers:** Step-by-step guide to mount NAS storage on the Ubuntu VM at `util-server.home`.

- NFSv4 client install on Ubuntu
- Persistent mount via `/etc/fstab` and systemd automount
- NAS export `192.168.30.121:/data/pod_data` → local `/data`
- Reboot validation and troubleshooting notes

**Why it exists:** The Ubuntu VM needs shared storage from the NAS for container and application data. This documents the working mount configuration so it can be reproduced or recovered after a rebuild.

## Repo

https://github.com/ChadEngel/ce-ai-home-lab
