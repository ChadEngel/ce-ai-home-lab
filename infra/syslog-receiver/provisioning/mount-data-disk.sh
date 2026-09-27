#!/usr/bin/env bash
# mount-data-disk.sh — second-disk volume setup for the UDM Pro syslog receiver.
#
# Run on caelx004 AFTER the VM has been created in Proxmox with a second
# VirtIO/SCSI disk attached. Do NOT run if `/data` is already mounted, or if
# you already have data on the candidate device — this script formats the
# disk unconditionally (only the 1st unused disk matching the candidate
# pattern is targeted).
#
# What it does:
#   1. Find an unmounted, unpartitioned disk (no existing partition table)
#   2. Create a single ext4 partition
#   3. Label the filesystem `udm-data`
#   4. Add an fstab entry so it survives reboots
#   5. Mount it and create `/data/udm-pro/`
#
# Required: sudo. No interactive prompts — safe to run from deploy scripts.
#
# Override defaults via env:
#   TARGET_DEVICE   default /dev/vdb  (VirtIO block) or /dev/sdb (SCSI)
#   MOUNT_POINT     default /data

set -euo pipefail

MOUNT_POINT="${MOUNT_POINT:-/data}"
LABEL="${LABEL:-udm-data}"

# Reject if /data is already mounted (we don't want to nuke an existing vol)
if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    echo "ERROR: $MOUNT_POINT is already mounted -- refusing to overwrite"
    echo "       (if you really mean to reformat, unmount and pass MOUNT_POINT=/somewhere-else first)"
    mount | grep -E "[[:space:]]$MOUNT_POINT[[:space:]]"
    exit 1
fi

# Find the candidate disk: prefer /dev/vdb (VirtIO), then /dev/sdb (SCSI),
# else the first unmounted, partitionless block device we can see.
pick_disk() {
    for d in "${TARGET_DEVICE:-}" /dev/vdb /dev/sdb; do
        [ -b "$d" ] || continue
        # Reject if already partitioned
        if ! lsblk -n -o PTTYPE "$d" 2>/dev/null | grep -qiE 'gpt|dos|mac|bsd'; then
            # Reject if any of its partitions are mounted
            if ! lsblk -n -o MOUNTPOINT "$d" 2>/dev/null | grep -vq '^$'; then
                echo "$d"
                return 0
            fi
        fi
    done
    return 1
}

TARGET_DISK="$(pick_disk || true)"
if [ -z "$TARGET_DISK" ]; then
    echo "ERROR: no candidate disk found (looked for /dev/vdb, /dev/sdb, then any partitionless block dev)"
    echo "       Attach a second disk to the VM in Proxmox first."
    echo
    echo "Hint: lsblk output:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,PTTYPE
    exit 1
fi

DISK_SIZE_BYTES="$(lsblk -b -n -o SIZE "$TARGET_DISK" | head -1)"
DISK_SIZE_GIB=$(( DISK_SIZE_BYTES / 1024 / 1024 / 1024 ))

echo "==> mount-data-disk.sh"
echo "    TARGET_DISK  = $TARGET_DISK  (${DISK_SIZE_GIB} GiB)"
echo "    MOUNT_POINT  = $MOUNT_POINT"
echo "    LABEL        = $LABEL"
echo
echo "    This will CREATE A NEW PARTITION TABLE on $TARGET_DISK."
echo "    All data on the disk will be ERASED."
echo

if [ -t 0 ]; then
    read -r -p "    Continue? [y/N] " ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "aborted"; exit 2 ;;
    esac
fi

# 1. partition table + one ext4 partition
echo "==> partitioning $TARGET_DISK"
sudo sfdisk --quiet --label gpt "$TARGET_DISK" <<EOF
label: gpt
label-id: 0xC957A94D-1E15-4E2A-8B57-1B2E8E0F2A20
unit: sectors
first-lba: 2048
part1 : start=2048, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=udm-data, uuid=$(cat /proc/sys/kernel/random/uuid)
EOF

# sfdisk writes the partition; the partition node may take a beat to appear
sleep 1
PART="${TARGET_DISK}1"
if [ ! -b "$PART" ]; then
    # Some kernels expose partitions as e.g. /dev/vdb1 vs /dev/disk/by-id/...
    PART="$(lsblk -n -o PATH "${TARGET_DISK}" | awk 'NR==2{print $1}')"
fi
echo "    partition: $PART"

# 2. format ext4
echo "==> formatting $PART as ext4 (label: $LABEL)"
sudo mkfs.ext4 -L "$LABEL" "$PART"

# 3. fstab
echo "==> adding fstab entry"
FSTAB_LINE="LABEL=$LABEL $MOUNT_POINT ext4 defaults,noatime,nofail 0 2"
if grep -qE "^LABEL=$LABEL\b" /etc/fstab; then
    echo "    fstab already has LABEL=$LABEL -- leaving it"
else
    echo "$FSTAB_LINE" | sudo tee -a /etc/fstab >/dev/null
fi

# 4. mount + subdir
echo "==> mounting"
sudo mkdir -p "$MOUNT_POINT"
sudo mount "$MOUNT_POINT"

# 5. syslog subdir (the receiver install.sh also creates this; no harm in
#    doing it here so the user can ssh in and see the layout immediately)
sudo mkdir -p "$MOUNT_POINT/udm-pro/disk-buffer"
sudo chown syslog:adm "$MOUNT_POINT/udm-pro" 2>/dev/null || true

echo
echo "==> done"
df -h "$MOUNT_POINT"
echo
echo "Next: run infra/syslog-receiver/install-remote.sh from your workstation"
echo "       It will refuse to run unless $MOUNT_POINT is a separate mountpoint."