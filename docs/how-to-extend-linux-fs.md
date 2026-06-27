# How to Extend Linux Filesystem (Step-by-Step)

This guide provides step-by-step instructions for extending the logical volume and filesystem on a Linux system. Essential for adding storage capacity to your Kubernetes node when you need more disk space.

---

## Overview

This document covers:
- Understanding Linux storage layout
- Extending a logical volume (LVM)
- Expanding the filesystem
- Identifying available disk space
- Troubleshooting common issues

**Use this when:**
- Your root filesystem is running out of space
- You need more disk space for containers, images, or applications
- The VM or disk has been expanded externally

---

## Prerequisites

- **Root/sudo access** to the Linux system
- **Disk space available** in LVM or on physical volume
- **Shutdown capability** (some operations may require reboot)

---

## Before You Begin

### Check Current Disk Usage

```bash
df -h
du -sh /*
```

If your root partition shows low available space (less than 5GB free), consider extending the filesystem.

### Check LVM Configuration

```bash
# View logical volume status
sudo lvdisplay

# View volume group status
sudo vgdisplay

# Check physical volumes
sudo pvdisplay

# Check storage space
sudo pvs
```

---

## Understanding the Scenario

### Scenario A: Disk Already Expanded (Most Common for VMs)

When using VMs (VirtualBox, VMWare, KVM, Cloud), the virtual disk often gets expanded **before** the OS sees it. In this case:

1. The disk itself has been increased in the hypervisor
2. LVM has free space on the physical volume
3. You just need to extend the logical volume and filesystem

### Scenario B: New Disk Available

If you have an additional physical disk to add to your LVM.

---

## Step-by-Step Instructions

### Step 1: Identify Your Storage Layout

First, understand what you're working with:

```bash
# View partition table
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT

# View LVM structure
sudo lsblk -f

# View disk information
sudo fdisk -l
```

You'll see entries like:
```
NAME   SIZE TYPE MOUNTPOINT
nvme0n1 100G disk
└─nvme0n1p3                50G part /boot/efi
└─nvme0n1p2               50G part /
```

### Step 2: Check Available Disk Space

```bash
# See if disk has been expanded
sudo fdisk -l

# See LVM free space
sudo pvs
```

### Step 3: Extend Partition (If Needed)

If the partition itself hasn't been resized yet:

```bash
# Check partition sizes (example: nvme0n1p2)
sudo fdisk /dev/nvme0n1

Commands:
  p - Print partition table
  n - Create new partition (advanced)
  d - Delete partition
  t - Change type
  l - List partition types
  m - Show menu
  w - Write changes and exit

Note: For most systems, use growpart instead.
```

**For Ubuntu/Debian with GPT: growpart**

```bash
sudo apt install cloud-guest-utils
sudo growpart /dev/nvme0n1 3  # Part number 3 typically
```

**For older systems:**
```bash
sudo fdisk /dev/nvme0n1
# Use the 'p' command to print, then follow prompts
```

### Step 4: Extend the Physical Volume

Tell LVM about the new partition space:

```bash
# Refresh the physical volume
sudo pvresize /dev/nvme0n1p3
```

You should see output like:
```
  Physical volume "/dev/nvme0n1p3" changed
  1 new physical volume(s) of 15.00 GiB PV
  AVAILABLE
```

### Step 5: Extend the Logical Volume

Add the extra space to your logical volume:

```bash
# Show your volume group name
sudo vgs

# Extend the logical volume
# Syntax: sudo lvextend -l +100%FREE -r /dev/vg_name/lv_name

# Most common path for Ubuntu 22.04/24.04:
sudo lvextend -l +100%FREE -r /dev/ubuntu-vg/ubuntu-lv

# For different VG/lv names (adjust accordingly):
sudo lvextend -l +100%FREE -r /dev/mapper/ubuntu--vg--root

# Verify the change
sudo lvdisplay
```

This will show an output like:
```
  Logical volume successfully extended
  /dev/ubuntu-vg/ubuntu-lv: logical volume size increased from 10 GB to 50 GB
```

**Key flags:**
- `-l +100%FREE`: Add all available free space
- `-r`: Automatically resize the filesystem (convenience flag)

### Step 6: Verify the Extension

```bash
# Check disk usage
df -h

# Should show increased capacity
# Filesystem                         Size  Used Avail Use% Mounted on
# /dev/mapper/ubuntu--vg--ubuntu--lv  50G   10G   35G  22% /
```

Your filesystem should now show the increased size.

---

## Alternative Methods

### Method 1: For Filesystems Without -r flag

If the `-r` flag doesn't work (older systems):

1. Extend the logical volume:
```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
```

2. Extend the filesystem separately:

**For ext4 filesystems:**
```bash
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
```

**For XFS filesystems:**
```bash
sudo xfs_growfs /
```

### Method 2: When Physical Volume Size Didn't Change

If `pvresize` reports no change:

```bash
# Check disk size
lsblk

# If disk is still original size, you need to:
# 1. Shutdown the VM
# 2. Expand the disk in hypervisor
# 3. Boot and try again
```

### Method 3: Adding New Disk

```bash
# 1. Identify new disk
sudo lsblk

# 2. Create partition
sudo fdisk /dev/sdb
# n - new, default for primary, default start, default end
# p - print
# t - type (Linux, type L)
# w - write

# 3. Create PV
sudo pvcreate /dev/sdb1

# 4. Add to VG
sudo vgextend ubuntu-vg /dev/sdb1

# 5. Extend logical volume
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
```

---

## Common Issues and Troubleshooting

### Issue 1: pvresize says "No changes"

**Problem:**
```
  ERROR: physical volume "/dev/nvme0n1p3" cannot be resized
```

**Solution:**
- Check if disk was expanded in hypervisor
- Verify partition needs resizing
- Try rebooting the system
- Run: `sudo pvscan --cache`

### Issue 2: lvextend fails

**Problem:**
```
  Invalid device: /dev/ubuntu-vg/ubuntu-lv
```

**Solution:**
- Check device name: `sudo lvdisplay`
- Use correct path: `sudo lvdisplay | grep LV Name`
- Try full path: `sudo lvextend -l +100%FREE -r $(findmnt -n -o SOURCE /)`

### Issue 3: Filesystem doesn't resize

**Problem:**
Disk size shows increased, but `df -h` still shows old capacity.

**Solution:**
```bash
# Check filesystem type
sudo blkid

# Resize based on type:
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv  # ext4
sudo xfs_growfs /                         # xfs
```

### Issue 4: growpart not found

**Problem:**
```
growpart: command not found
```

**Solution:**
```bash
# Install (Ubuntu/Debian):
sudo apt install cloud-guest-utils

# For other systems, install from your package manager
# Or use fdisk manual method

# Alternative: use fdisk
sudo fdisk /dev/nvme0n1
# Delete old partition (d - select - number)
# Create new (n - same number - start - end, same or larger)
# w - write
```

### Issue 5: Disk still not expanded

**Check:**
1. VM has been powered off
2. Disk was expanded in hypervisor settings
3. Disk is properly attached after power-on
4. Partition was resized

**Check disk in hypervisor:**
- VMWare: VM Settings → Hard Disk → Size
- VirtualBox: Settings → Storage → Hard Disk → Size
- AWS EC2: EBS volume size in console
- Google Cloud: Instance settings → Disks

---

## Quick Reference

### Complete Command Sequence (Example for Ubuntu)

```bash
# 1. Check current status
df -h
sudo pvdisplay
sudo lvdisplay

# 2. Expand partition (if needed)
sudo growpart /dev/nvme0n1 3

# 3. Resize physical volume
sudo pvresize /dev/nvme0n1p3

# 4. Extend logical volume
sudo lvextend -l +100%FREE -r /dev/ubuntu-vg/ubuntu-lv

# 5. Verify
df -h
```

### Common Device Paths

| Distribution | VG Name | LV Name | Device Path |
|---|-----|-----|----|
| **Ubuntu 22.04+** | ubuntu-vg | ubuntu-lv | `/dev/ubuntu-vg/ubuntu-lv` |
| **Ubuntu Server** | ubuntu-vg | root | `/dev/ubuntu-vg/root` |
| **Debian** | debian-vg | root | `/dev/debian-vg/root` |
| **Custom** | Your VG | Your LV | `/dev/your-vg/your-lv` |

---

## Post-Extension Tasks

After extending, consider:

1. **Monitor disk usage:**
```bash
watch -n 30 "df -h"
```

2. **Check for large files:**
```bash
sudo du -ah / | sort -rh | head -20
```

3. **Clean up unused space:**
```bash
# Flush disk on Ubuntu/Debian
sudo apt clean

# Remove kernel images (keep last 2)
sudo apt install purge-kernel-images

# Clean container cache
docker system prune -a
```

---

## Safety Notes

- **Always backup** before making storage changes
- **Test in staging** if possible
- **Have console access** (not SSH only) in case something fails
- **Don't edit configuration files** (like fstab) during this process unless instructed
- **If uncertain about steps**, consult system administrator

---

## Related Documentation

- [Ubuntu LVM Guide](https://help.ubuntu.com/community/LVM)
- [Red Hat LVM Docs](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/managing_storage_devices_using_lvm/understanding-lvm-concepts_managing-storage-devices-using-lvm)
- [resize2fs man page](https://manpages.ubuntu.com/manpages/jammy/en/man8/resize2fs.8.html)
- [xfs_growfs man page](https://linux.die.net/man/8/xfs_growfs)

---

After completing these steps, your filesystem should have the additional space available for your Kubernetes applications!
