# Proxmox provisioning for caelx004

Step-by-step for creating the standalone UDM Pro syslog receiver VM in
Proxmox. Run from the Proxmox host (the `pve` shell or via SSH to
`pve.home` / `192.168.30.5`).

This doc is intentionally copy-pastable. Each block is a single command.

## 0. Prereqs

* Proxmox node you create the VM on. The lab uses `pve` (homelab pve
  single-node).
* VM ID `104` — matches the hostname `caelx004`.
* The Proxmox ISO for Ubuntu 24.04 minimal, already uploaded to the
  `local` storage. (Or use cloud-init, see the alternative path at the
  bottom.)

## 1. Create the VM shell

```bash
VMID=104
NAME=caelx004
ISO=local:iso/ubuntu-24.04.2-live-server-amd64.iso   # adjust to your upload

qm create $VMID \
    --name $NAME \
    --memory 1024 \
    --cores 1 \
    --sockets 1 \
    --cpu host \
    --net0 virtio,bridge=vmbr0,firewall=1 \
    --ostype l26 \
    --scsihw virtio-scsi-single \
    --agent 1 \
    --tablet 0
```

## 2. Attach the OS disk (VirtIO SCSI, 16 GiB)

```bash
qm set $VMID --scsi0 local-lvm:16,iothread=1,discard=on,ssd=1
qm set $VMID --boot order=scsi0
qm set $VMID --scsihw virtio-scsi-single
```

## 3. Attach the data disk (the one syslog-ng writes to)

This is the volume `install.sh` requires to be mounted at `/data`.

```bash
qm set $VMID --scsi1 local-lvm:8,iothread=1,discard=on,ssd=1
qm set $VMID --disk "scsi1,iothread=1,discard=on,ssd=1,cache=writeback"
```

Verify the layout:

```bash
qm config $VMID | grep -E '^scsi[0-9]+'
# expected:
#   scsi0: local-lvm:vm-104-disk-0,iothread=1,discard=on,ssd=1,size=16G
#   scsi1: local-lvm:vm-104-disk-1,iothread=1,discard=on,ssd=1,size=8G
```

> **Why 8 GiB?** A typical UDM Pro emits ~5-50 events/sec at idle. At 50
> events/sec with ~200 bytes/event, that's ~14 MB/hour, or ~330 MB/day.
> 8 GiB holds ~7 days of rotated logs + a generous disk-buffer for Loki
> outages (multi-day).

## 4. Attach the Ubuntu ISO to the CDROM and start the install

```bash
qm set $VMID --ide2 local:iso/ubuntu-24.04.2-live-server-amd64.iso,media=cdrom
qm set $VMID --boot order='scsi0;ide2'
qm start $VMID
```

Watch the install via noVNC (Proxmox UI → VM → Console → noVNC). When
the installer asks about disk layout, **choose "Use entire disk" but
ONLY the first one (scsi0)**. Do NOT let the installer touch scsi1 —
that disk must be left untouched for `mount-data-disk.sh` to pick it up.

> The Ubuntu server installer labels disks by serial; you'll see the
> 16 GiB and 8 GiB disks clearly. Pick the 16 GiB one for the OS.

Install with these settings:

* Hostname: `caelx004`
* Username: `cengel`
* SSH: install OpenSSH server, **import your SSH public key**
  (paste `~/.ssh/homelab-agent-util-server.pub` content into the
  installer field)
* Skip snaps, skip server-snaps

After install completes, the VM reboots. Wait for it to come back, then
disable the CDROM:

```bash
qm set $VMID --ide2 none,media=cdrom
qm set $VMID --boot order=scsi0
```

## 5. Reserve the IP in UDM DHCP

Find the VM's MAC (from the Proxmox config, or `ip link` inside the
VM after first boot):

```bash
qm config $VMID | grep net0
# e.g.: net0: virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr0,firewall=1
```

In the UDM Network UI:

1. Settings → Networks → (your LAN, probably `LAN_LOCAL`)
2. Expand "DHCP Static IP" or "DHCP Reservation"
3. Add: MAC `AA:BB:CC:DD:EE:FF`, IP `192.168.30.189`, name `caelx004`
4. Save

Reboot the VM so it picks up the static lease:

```bash
qm reboot $VMID
```

## 6. SSH in and verify

From your workstation:

```bash
ssh cengel@192.168.30.189   # or `caelx004.home` once mDNS settles
```

Confirm the OS disk and the data disk are both visible:

```bash
lsblk
# NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINT
# sda      8:0    0   16G  0 disk
# ├─sda1   8:1    0   16G  0 part /
# sdb      8:0    0    8G  0 disk          <-- unmounted, no partitions
```

## 7. Format + mount the data disk

```bash
# On caelx004, copy mount-data-disk.sh there first:
#   scp infra/syslog-receiver/provisioning/mount-data-disk.sh cengel@caelx004:/tmp/

sudo bash /tmp/mount-data-disk.sh
```

This:

1. Picks `/dev/sdb` (the 8 GiB disk)
2. Creates a GPT label + one ext4 partition
3. Labels the filesystem `udm-data`
4. Adds `LABEL=udm-data /data ext4 defaults,noatime,nofail 0 2` to `/etc/fstab`
5. Mounts it at `/data`
6. Creates `/data/udm-pro/disk-buffer`

Verify:

```bash
df -h /data
# expected: /dev/sdb1   7.8G  ...   /data
mountpoint /data   # /data is a mountpoint
```

## 8. Install the receiver

From your workstation (back on the repo root):

```bash
export REMOTE_HOST=192.168.30.189   # or caelx004.home
export LOKI_URL=http://192.168.30.217:3100
export SUDO_PASS='...'              # sudo password for cengel on caelx004
./infra/syslog-receiver/install-remote.sh
```

`install.sh` will refuse to run if `/data` is not on a separate filesystem —
it checks the mount root first, then confirms `/data/udm-pro` resolves to the
same filesystem. So if you got this far, it'll proceed and set up syslog-ng +
logrotate + the systemd unit.

## 9. Point the UDM at the receiver

```bash
export UDM_HOST=192.168.250.1       # or unifi.home
./infra/syslog-receiver/udm-rsyslog-update.sh
```

## 10. Verify end-to-end

```bash
# On caelx004, watch the local spool file:
ssh cengel@caelx004 'tail -f /data/udm-pro/udm.log'

# In the cluster, query Loki for the stream:
kubectl -n ai exec -l app=loki -c loki -- \
    wget -qO- --header='X-Scope-OrgID: fake' \
    'http://localhost:3100/loki/api/v1/query?query={job="udm-syslog"}' | jq .
```

If both show UDM events within ~10s of step 9, you're done.

## Cloud-init alternative

If you'd rather not use the noVNC installer, replace step 4 with:

```bash
# Create a cloud-init drive and template
qm set $VMID --ide2 local-lvm:cloudinit
qm set $VMID --boot order='scsi0;ide2'
qm set $VMID --agent 1
qm set $VMID --ciuser cengel
qm set $VMID --sshkeys ~/.ssh/authorized_keys
qm set $VMID --ipconfig0 ip=192.168.30.189/24,gw=192.168.30.1
qm set $VMID --nameserver '192.168.30.1 1.1.1.1'
qm set $VMID --searchdomain home
qm set $VMID --ciupgrade 1

# Then attach the cloud-init-ready Ubuntu cloud image instead of the ISO:
#   qm set $VMID --scsi0 local-lvm:32,import-from=local:iso/ubuntu-24.04-server-cloudimg-amd64.img
```

The cloud-init path is faster (no installer) but requires an Ubuntu
**cloud** image, not the server ISO. Both work; pick the one that
matches what you've already uploaded to Proxmox.