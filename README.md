# Qualcomm Dragonwing / Ventuno Q: NVMe Rootfs Migration

An automated migration script to clone the root filesystem (`/`) of an **Arduino Ventuno Q / Qualcomm Dragonwing (QCS8275 / IQ8)** from the internal 64 GB eMMC to an M.2 NVMe SSD.

This project implements a **Safe Kernel Handoff Architecture**:

* The UEFI firmware, bootloader, device trees, and hardware calibration partition (`/var/persist`) remain safely on the eMMC.
* The Linux kernel hands over userspace root (`/`) to the NVMe SSD during early boot.
* The original eMMC root filesystem is never erased, providing an instant, risk-free rollback path.

📖 **Full Technical Deep Dive:**
Read the complete hardware breakdown and architecture post:
[Qualcomm Dragonwing NVMe Migration: Safe Kernel Handoff Explained]("https://martincerven.com/posts/ventuno_ssd_install/")

---

## Prerequisites

1. An M.2 NVMe SSD installed on the board.
2. The board must be currently running from the internal eMMC (`/dev/mmcblk0p71`).
3. Root access (`sudo`).

---

## Usage

### 1. Download & Prepare the Script

Save the migration script as `migrate_to_nvme.sh` and make it executable:

```bash
chmod +x migrate_to_nvme.sh
```

### 2. Execute Migration

Run the script as root:

```bash
sudo ./migrate_to_nvme.sh
```

The script will automatically:

* Verify disk space and partition boundaries.
* Ensure required storage modules (`nvme`, `nvme_core`) are in the initramfs.
* Format the NVMe SSD with optimal 1 MiB alignment.
* Clone the live rootfs via an isolated bind mount (`rsync -axHAWX`).
* Update `/etc/fstab` on the SSD while preserving calibration partitions (`/var/persist`).
* Configure GRUB on the eMMC (`zz-nvme-root.cfg`) to append the root UUID handoff while preserving all board hardware flags.

### 3. Reboot

Once the script prints `[SUCCESS]`, reboot the system:

```bash
sudo reboot
```

---

## Verification

After rebooting, confirm the active root filesystem:

```bash
findmnt /
```

Expected output:

```text
TARGET SOURCE         FSTYPE OPTIONS
/      /dev/nvme0n1p1 ext4   rw,noatime,discard,errors=remount-ro
```

Confirm available storage capacity:

```bash
df -h /
```

---

## Post-Migration: Automatic Kernel Sync

> ⚠️ **Unverified — not yet tested.** The steps in this section are a design proposal only and have **not been validated on hardware**. See [TODO](#todo) below.

Because GRUB loads the initial kernel binary from the eMMC, future kernel upgrades (`apt upgrade`) need to mirror updated `/boot` files back to the eMMC.

To automate this, set up the sync script and service:

1. Create `/usr/local/sbin/sync-boot-emmc` (included in the [blog guide]({{< ref "posts/qualcomm-dragonwing-nvme-migration.md" >}})).
2. Enable the systemd shutdown service:

   ```bash
   sudo systemctl enable sync-boot-emmc.service
   ```

3. Test manual sync at any time:

   ```bash
   sudo /usr/local/sbin/sync-boot-emmc
   ```

---

## Emergency Rollback

If you ever need to revert to booting from the internal eMMC:

* **From terminal:**

  ```bash
  sudo rm /etc/default/grub.d/zz-nvme-root.cfg
  sudo update-grub
  sudo reboot
  ```

* **From the GRUB menu (serial console / HDMI):**

  1. Interrupt the 3-second boot countdown.
  2. Press <kbd>e</kbd> on the default entry.
  3. Remove `root=UUID=... rootdelay=2` from the `linux` command line.
  4. Press <kbd>Ctrl</kbd>+<kbd>X</kbd> to boot directly into eMMC.

---

## TODO

- [ ] **Post-Migration: Automatic Kernel Sync — untested.**
  Neither `sync-boot-emmc` nor `sync-boot-emmc.service` has been run or verified.
  Before documenting this as a supported workflow, confirm:
  - [ ] The shutdown service still has the eMMC blocks writable and mounted at the point it runs (ordering vs. `umount.target`).
  - [ ] The correct eMMC partition(s) are mirrored (`/boot`, `/boot/efi`, DTB/overlay paths) and that there is enough free space after several kernel generations.
  - [ ] The sync survives a real `apt upgrade` that installs a new kernel + initramfs, and that the board boots the new kernel afterwards.
  - [ ] Rollback via [`zz-nvme-root.cfg`](#emergency-rollback) still works after a sync has run.
  - [ ] Whether an APT/`dpkg` hook (e.g. `/etc/apt/apt.conf.d/` or a `kernel_postinst` hook) is a safer trigger than a shutdown unit.

  **Workaround until verified:** run `sudo /usr/local/sbin/sync-boot-emmc` manually after every kernel/initramfs update.
- [ ] Add the tested sync script and unit file to this repo (currently only shown in the blog post).
