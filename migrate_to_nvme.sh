#!/usr/bin/env bash
set -euo pipefail

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- CONFIGURATION TARGETS ---
NVME_DEV="/dev/nvme0n1"
NVME_PART="/dev/nvme0n1p1"
PART_LABEL="nvme_root"
MNT_SSD="/mnt/ssd_root"
MNT_CUR="/mnt/current_root"

echo "=========================================================="
echo " Qualcomm Dragonwing / Ventuno Q: NVMe Rootfs Migration"
echo " (Safe Kernel Handoff Architecture)"
echo "=========================================================="

# 1. PRE-FLIGHT CHECKS
if [ "$EUID" -ne 0 ]; then
  echo "[-] ERROR: This script must be run as root (use sudo)." >&2
  exit 1
fi

CURRENT_ROOT=$(findmnt -n -o SOURCE /)
if [[ "$CURRENT_ROOT" == *"nvme"* ]]; then
  echo "[-] ERROR: Your system is ALREADY running from an NVMe drive ($CURRENT_ROOT)!" >&2
  exit 1
fi

if [ ! -b "$NVME_DEV" ]; then
  echo "[-] ERROR: Target SSD '$NVME_DEV' not found! Check your M.2 installation." >&2
  exit 1
fi

# Verify companion files exist in the same directory
if [ ! -f "$SCRIPT_DIR/sync-boot-emmc" ]; then
  echo "[-] ERROR: Companion file '$SCRIPT_DIR/sync-boot-emmc' not found!" >&2
  exit 1
fi

if [ ! -f "$SCRIPT_DIR/sync-boot-emmc.service" ]; then
  echo "[-] ERROR: Companion file '$SCRIPT_DIR/sync-boot-emmc.service' not found!" >&2
  exit 1
fi

# Ensure target SSD has enough capacity for current root
ROOT_USED_KB=$(df -k --output=used / | tail -n 1 | tr -d ' ')
DEV_SIZE_BYTES=$(blockdev --getsize64 "$NVME_DEV")
DEV_SIZE_KB=$((DEV_SIZE_BYTES / 1024))

if [ "$DEV_SIZE_KB" -le "$ROOT_USED_KB" ]; then
  echo "[-] ERROR: Target SSD is too small ($((DEV_SIZE_KB / 1024 / 1024)) GB) for current root usage ($((ROOT_USED_KB / 1024 / 1024)) GB)!" >&2
  exit 1
fi

echo "[+] Current Root is on: $CURRENT_ROOT"
echo "[+] Target NVMe Drive is: $NVME_DEV ($((DEV_SIZE_BYTES / 1024 / 1024 / 1024)) GB)"
echo "[+] Companion sync files found in: $SCRIPT_DIR"
echo ""
read -r -p "WARNING: ALL DATA ON $NVME_DEV WILL BE ERASED. Continue? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
  echo "[-] Aborted by user."
  exit 0
fi

# Cleanup trap in case of unexpected interruption
cleanup() {
  echo "[*] Cleaning up temporary mounts..."
  umount "$MNT_CUR" 2>/dev/null || true
  umount "$MNT_SSD" 2>/dev/null || true
  rmdir "$MNT_CUR" 2>/dev/null || true
  rmdir "$MNT_SSD" 2>/dev/null || true
}
trap cleanup EXIT ERR INT TERM

# 2. ENSURE INITRAMFS HAS NVME MODULES
echo ""
echo "[1/6] Ensuring NVMe driver is in initramfs..."
mkdir -p /etc/initramfs-tools

MODULES_TO_ADD=("nvme" "nvme_core")
for mod in "${MODULES_TO_ADD[@]}"; do
  if ! grep -qs "^${mod}$" /etc/initramfs-tools/modules; then
    echo "$mod" >> /etc/initramfs-tools/modules
    echo "[+] Added '$mod' to /etc/initramfs-tools/modules"
  fi
done
update-initramfs -u -k all

# 3. PARTITION & FORMAT NVME SSD
echo ""
echo "[2/6] Partitioning and formatting $NVME_DEV..."

# Unmount and disable swap if any existing partitions are active
swapoff -a 2>/dev/null || true
umount "${NVME_DEV}"* 2>/dev/null || true

wipefs -a "$NVME_DEV"
parted -s "$NVME_DEV" mklabel gpt
parted -s -a optimal "$NVME_DEV" mkpart "$PART_LABEL" ext4 1MiB 100%
udevadm settle
partprobe "$NVME_DEV" || true
sleep 1

mkfs.ext4 -F -L "$PART_LABEL" "$NVME_PART"
udevadm settle

NEW_UUID=$(blkid -s UUID -o value "$NVME_PART")
if [ -z "$NEW_UUID" ]; then
  echo "[-] ERROR: Failed to obtain UUID for $NVME_PART." >&2
  exit 1
fi
echo "[+] Formatted $NVME_PART with UUID: $NEW_UUID"

# 4. CONFIGURE GRUB DROP-IN (Created once on eMMC; rsync will mirror it to SSD)
echo ""
echo "[3/6] Configuring GRUB handoff drop-in..."
mkdir -p /etc/default/grub.d
cat << EOF > /etc/default/grub.d/zz-nvme-root.cfg
# Dragonwing NVMe root handoff
GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX} root=UUID=${NEW_UUID} rootdelay=2"
EOF
echo "[+] Created /etc/default/grub.d/zz-nvme-root.cfg"

# 5. CLONE ROOTFS TO SSD
echo ""
echo "[4/6] Cloning rootfs to NVMe SSD (this will take 2-4 minutes)..."
mkdir -p "$MNT_SSD" "$MNT_CUR"
mount "$NVME_PART" "$MNT_SSD"
mount --bind / "$MNT_CUR"

# Copy rootfs without traversing into /boot/efi or /var/persist
rsync -axHAWX --numeric-ids --info=progress2 "$MNT_CUR/" "$MNT_SSD/"

# Ensure mountpoint directories exist on the SSD
mkdir -p "$MNT_SSD"/{dev,proc,sys,run,tmp,mnt,media,boot/efi,var/persist}
chmod 1777 "$MNT_SSD/tmp"

umount "$MNT_CUR"
rmdir "$MNT_CUR"

# 6. UPDATE FSTAB & CONFIGURE AUTO-SYNC ON SSD
echo ""
echo "[5/6] Configuring SSD rootfs (fstab, power masks, auto-sync service)..."

# 6a. Replace the root (/) entry in fstab
sed -i "s|^LABEL=writable.*|UUID=${NEW_UUID}   /   ext4   discard,errors=remount-ro,noatime   0   1|" "$MNT_SSD/etc/fstab"
echo "[+] Updated /etc/fstab on SSD:"
cat "$MNT_SSD/etc/fstab"

# 6b. Mask sleep targets on SSD to avoid PCIe bus dropouts on idle
mkdir -p "$MNT_SSD/etc/systemd/system"
for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  ln -sf /dev/null "$MNT_SSD/etc/systemd/system/$target"
done
echo "[+] Masked systemd sleep targets on SSD"

# 6c. Install sync-boot-emmc script onto SSD
mkdir -p "$MNT_SSD/usr/local/sbin"
cp "$SCRIPT_DIR/sync-boot-emmc" "$MNT_SSD/usr/local/sbin/sync-boot-emmc"
chmod +x "$MNT_SSD/usr/local/sbin/sync-boot-emmc"
echo "[+] Installed /usr/local/sbin/sync-boot-emmc on SSD"

# 6d. Install and enable systemd shutdown sync service on SSD
cp "$SCRIPT_DIR/sync-boot-emmc.service" "$MNT_SSD/etc/systemd/system/sync-boot-emmc.service"
systemctl --root="$MNT_SSD" enable sync-boot-emmc.service 2>/dev/null || {
  mkdir -p "$MNT_SSD/etc/systemd/system/reboot.target.wants" \
           "$MNT_SSD/etc/systemd/system/shutdown.target.wants" \
           "$MNT_SSD/etc/systemd/system/poweroff.target.wants"
  ln -sf /etc/systemd/system/sync-boot-emmc.service "$MNT_SSD/etc/systemd/system/reboot.target.wants/"
  ln -sf /etc/systemd/system/sync-boot-emmc.service "$MNT_SSD/etc/systemd/system/shutdown.target.wants/"
  ln -sf /etc/systemd/system/sync-boot-emmc.service "$MNT_SSD/etc/systemd/system/poweroff.target.wants/"
}
echo "[+] Installed and enabled sync-boot-emmc.service on SSD"

# 6e. Install APT post-invoke hook on SSD
mkdir -p "$MNT_SSD/etc/apt/apt.conf.d"
cat << 'EOF' > "$MNT_SSD/etc/apt/apt.conf.d/99-sync-boot-emmc"
DPkg::Post-Invoke {
    "if [ -x /usr/local/sbin/sync-boot-emmc ]; then /usr/local/sbin/sync-boot-emmc; fi";
};
EOF
echo "[+] Installed APT post-invoke hook on SSD"

umount "$MNT_SSD"
rmdir "$MNT_SSD"

# 7. UPDATE GRUB ON eMMC FOR INITIAL BOOT
echo ""
echo "[6/6] Updating GRUB on eMMC..."
update-grub

sync

# Clear trap on normal completion
trap - EXIT ERR INT TERM

echo ""
echo "=========================================================="
echo " [SUCCESS] Migration complete!"
echo " The EFI stub remains safe on eMMC, and the kernel"
echo " will hand over rootfs to your NVMe SSD on boot."
echo " Future kernel updates will auto-sync to eMMC seamlessly."
echo " Reboot now to boot from your NVMe SSD."
echo "=========================================================="