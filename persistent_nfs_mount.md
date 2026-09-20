# Persistent NFS Mount on Ubuntu Linux

## Overview

This guide configures a persistent NFSv4 mount from a NAS to a Linux VM using systemd automounts.

### Environment

| Item | Value |
|--------|--------|
| NAS IP | `192.168.30.121` |
| NFS Export | `/data/pod_data` |
| Local Mount Point | `/data` |
| Protocol | NFSv4 |

---

# 1. Install NFS Client

```bash
sudo apt update
sudo apt install -y nfs-common
```

Verify installation:

```bash
mount.nfs4 --version
```

---

# 2. Create the Mount Point

```bash
sudo mkdir -p /data
```

---

# 3. Verify Available NFS Exports

```bash
showmount -e 192.168.30.121
```

Expected output:

```text
Export list for 192.168.30.121:
/data/pod_data
...
```

---

# 4. Test Manual Mount

Mount the export manually:

```bash
sudo mount -t nfs4 192.168.30.121:/data/pod_data /data
```

Verify:

```bash
findmnt /data
ls /data
```

Expected output:

```text
TARGET SOURCE
/data 192.168.30.121:/data/pod_data
```

Unmount before configuring persistence:

```bash
sudo umount /data
```

---

# 5. Configure Persistent Mount

Edit `/etc/fstab`:

```bash
sudo nano /etc/fstab
```

Add the following entry:

```fstab
# Persistent NFS mount for container and application storage
192.168.30.121:/data/pod_data  /data  nfs4  rw,hard,timeo=600,retrans=2,_netdev,nofail,x-systemd.automount  0  0
```

### Mount Options

| Option | Purpose |
|----------|----------|
| `rw` | Read/write access |
| `hard` | Prevent silent I/O failures |
| `timeo=600` | NFS timeout |
| `retrans=2` | Retry count |
| `_netdev` | Network must be available before mounting |
| `nofail` | Allow boot if NAS is unavailable |
| `x-systemd.automount` | Mount on first access |

---

# 6. Reload Systemd

```bash
sudo systemctl daemon-reload
sudo systemctl reset-failed
```

---

# 7. Validate Configuration

```bash
sudo mount -a
```

Verify:

```bash
findmnt /data
```

---

# 8. Reboot Test

```bash
sudo reboot
```

After reboot:

```bash
findmnt /data
```

Expected output before access:

```text
TARGET SOURCE
/data  systemd-1
```

This indicates the automount is registered and waiting.

---

# 9. Trigger the Mount

Access the directory:

```bash
ls /data
```

Verify the NFS mount becomes active:

```bash
findmnt /data
```

Expected output:

```text
TARGET SOURCE
/data  systemd-1
/data  192.168.30.121:/data/pod_data
```

---

# Notes

The exported filesystem contains a nested directory:

```text
/data/data
```

Therefore application data currently resides under:

```bash
/ data/data
```

Verify:

```bash
ls -lah /data/data
```

---

# Final Working Configuration

```fstab
192.168.30.121:/data/pod_data  /data  nfs4  rw,hard,timeo=600,retrans=2,_netdev,nofail,x-systemd.automount  0  0
```

This configuration successfully survives reboots and mounts automatically when `/data` is accessed.