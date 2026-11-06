# Backing up and restoring the Pyra's SD card

> **Type: instructions.** Steps to follow.

The Pyra boots and runs from its SD card (`mmcblk1` on the Pyra). This is how to take a
file-level backup of a card on a Linux PC, and how to restore one. It works for a card
written from the trixie image and for the stock bookworm card.

A file-level backup is a few GB and takes minutes. A `dd` image of the whole card is the
card's full size, takes up to two hours, and compresses badly, because the free space
holds old data. Take a backup before experimenting on a card that works.

You need a Linux PC with `zstd`, `pv`, `f2fs-tools` (`mkfs.f2fs`, `dump.f2fs`,
`fsck.f2fs`) and an SD slot or card reader.

## Before you start

**Restore through a built-in SD slot if you can.** USB card readers have corrupted Pyra
cards. A laptop's built-in slot is usually an SD host controller, and the card shows up
as `/dev/mmcblk0`. Check with `lsblk` every time.

**A USB 3 reader is fine for backups**, once `pc/pyra-card-reader-test.sh` has passed on
it (see "Checking a card reader"). A backup only reads the card, and a good USB 3 reader
does it in half the time of a typical built-in slot. Restores through a USB reader are
untested.

**Keep the PC's desktop from mounting the card.** A desktop that auto-mounts the card
mounts it read-write, and the PC's much newer kernel then writes to it. On insertion it
runs f2fs's roll-forward recovery (`f2fs_recover_fsync_data` in the kernel log), writes
checkpoints, and may run background GC. I found this out when a desktop mounted a card
for a few minutes before a backup and moved its f2fs checkpoint on. Install
`pc/99-pyra-card-noauto.rules` on any PC a Pyra card goes into; the file says how. The
rule matches any card with this layout, not one card. If a card does get mounted,
`udisksctl unmount -b /dev/sdX2`.

## What the card holds

| region | what | how it is backed up |
|---|---|---|
| first 1 MiB | MBR: partition table and disk id; from 128 KiB, ~390 KB of raw bootloader data | `dd`, byte for byte |
| p1, 256 MB, ext2, label `boot` | kernels, initrds, dtbs, `extlinux/` (boot menu) | `dd` image, compressed |
| p2, rest of the card, f2fs, label `rootfs` | Debian; about 5 to 13 GB used | `tar`, compressed |

**How the Pyra finds its partitions:** by **PARTUUID**. The kernel command line has
`root=PARTUUID=<disk id>-02`, and `/etc/fstab` mounts `/` and `/boot` by PARTUUID. A
PARTUUID is the MBR's disk id plus the partition number, so it comes back with the first
1 MiB. The filesystem UUIDs don't matter for booting; the restore keeps them the same
anyway.

A card written from the trixie image has disk id `0x21a4c285` and rootfs UUID
`93b4acaf-6486-4f5b-8216-675e9c2aaced`, both from the image. The stock bookworm card has
its own: disk id `0x160ddd96` on the one measured here. Each backup's `.info` records the
card's values, and the restore uses them.

**The f2fs feature set matters.** The trixie image's root filesystem has `encrypt` as its
only feature. A newer `mkfs.f2fs` can enable features by default that the Pyra's 5.6
kernel cannot mount, so the restore passes the original's features and nothing else:
those in the backup's `.info`, or `encrypt` when there is no `.info`.

(`/etc/fstab` says `ext4` for `/boot`, which is really ext2. It came that way and is
harmless: the ext4 driver mounts ext2.)

## Taking a backup

Shut the Pyra down with `sudo poweroff` first. A card pulled from a running Pyra, or one
that wasn't shut down cleanly, has f2fs data that only a read-write mount recovers. A
read-only backup leaves that data out.

Then, with the card in the PC and nothing on it mounted:

    sudo ./pc/pyra-card-backup.sh /dev/mmcblk0 ~/pyra-backup           # built-in slot
    sudo -b ./pc/pyra-card-backup.sh /dev/sdb /mnt/disk/pyra-backup    # -b: survives closing the terminal

It refuses a card whose partitions aren't labelled `boot` and `rootfs`, or one that is
mounted. Before reading anything it sets the device and both partitions read-only, and it
mounts the rootfs `ro`. It names the backup after the release in the card's
`/etc/os-release`, `pyra-card-<release>-<date>`, with an optional tag as the third
argument. It writes:

| file | contents |
|---|---|
| `<prefix>.first1MiB.bin` | first 1 MiB of the card |
| `<prefix>.sfdisk` | the partition table as text, to check the MBR against |
| `<prefix>.p1-boot.img.zst` | boot partition image (~150 MB) |
| `<prefix>.p2-root.tar.zst` | root filesystem (2 to 3 GB for 11 to 13 GB used) |
| `<prefix>.info` | the release, kernels, disk id, both UUIDs and the f2fs features. The restore takes its `mkfs.f2fs -U` and `-O` from this file. |
| `<prefix>.log` | the run, with its timings |

It appends the checksums to `SHA256SUMS` in the backup directory and runs `zstd -t` on
the root tar. When it finishes it prints the restore command for that backup.

How long it takes:

| reader | raw read | backup | rootfs data rate |
|---|---|---|---|
| ThinkPad X220 built-in slot | ~20 MB/s | ~10 min for an 11 GB root (estimate, not timed) | ~18 MB/s |
| USB 3 reader, Realtek `0bda:0316` | 87–90 MB/s | 5.1 min for a 12.7 GB root (timed) | 42 MB/s |

The card sets the rootfs data rate, not the CPU. The `tar | zstd` pipeline used 75% of one
core on a 4-core Celeron N4100, and swung between 11 MiB/s on runs of small files and
75 MiB/s on large ones. For comparison, a `dd` image of a 128 GB card takes ~1¾ hours at
20 MB/s, or ~24 minutes at 90 MB/s.

### By hand

The steps the script runs:

    # on the Pyra
    sudo poweroff
    # on the PC, card in the slot, nothing mounted
    DEV=/dev/mmcblk0 P=pyra-card-$(date +%F)
    mkdir -p ~/pyra-backup && cd ~/pyra-backup
    sudo sfdisk -d $DEV > $P.sfdisk
    sudo dd if=$DEV of=$P.first1MiB.bin bs=1M count=1
    sudo dd if=${DEV}p1 bs=4M | zstd -T0 -o $P.p1-boot.img.zst
    sudo mount -o ro -t f2fs ${DEV}p2 /mnt
    sudo tar -C /mnt --numeric-owner --xattrs --xattrs-include='*' --acls -cpf - . | zstd -T0 -3 -o $P.p2-root.tar.zst
    sudo umount /mnt
    zstd -t $P.p2-root.tar.zst && sha256sum $P.first1MiB.bin $P.sfdisk $P.*.zst >> SHA256SUMS

A backup taken by hand has no `.info`, so the restore falls back to the trixie image's
rootfs UUID and `-O encrypt`. Check `blkid ${DEV}p2` and
`sudo dump.f2fs ${DEV}p2 | grep features` first. If either differs (a bookworm card,
say), pass the card's own values to the restore as `ROOT_UUID=<uuid>` and
`F2FS_FEATURES=<a,b>`.

## Restoring

Everything on the target card is destroyed. The restore takes about 15 minutes through a
built-in slot.

1. Put the card in the PC. If the desktop auto-mounts its partitions, unmount them
   (`sudo umount /dev/mmcblk0p*`).
2. Confirm which device it is, by size and transport (`mmc` for a built-in slot):

       lsblk -o NAME,SIZE,TRAN,FSTYPE,LABEL

3. Dry run. It checks the files and the card's size, prints the plan, and writes nothing:

       sudo ./pc/pyra-card-restore.sh ~/pyra-backup <prefix> /dev/mmcblk0

4. The restore:

       sudo ./pc/pyra-card-restore.sh ~/pyra-backup <prefix> /dev/mmcblk0 --yes

   In order, it:
   - checks the checksums;
   - writes the first 1 MiB and confirms the partition table matches `.sfdisk`;
   - writes the boot partition;
   - runs `mkfs.f2fs -l rootfs -O <features> -U <uuid>` on p2, taking both from the
     backup's `.info` (or the trixie image's `-O encrypt -U 93b4acaf-…` when there is
     none);
   - untars the root with numeric owners, xattrs and ACLs (file capabilities, such as
     `gst-ptp-helper`'s, live in xattrs);
   - runs `fsck.f2fs`.

   It stops at the first failure.
5. `sync`, remove the card, and boot the Pyra. The boot menu is the one the card had at
   backup time.
6. Anything changed after the backup is gone, desktop settings included. If you use
   `device/pyra-desktop-settings.sh` (it turns off the power manager's popups, which knock
   a fullscreen game out of fullscreen), log in at the desktop and run it again as your
   user, not root.

### By hand

For a trixie card with no `.info`; otherwise take the UUID and features from the `.info`:

    DEV=/dev/mmcblk0 P=<prefix>
    sha256sum -c --ignore-missing SHA256SUMS
    sudo dd if=$P.first1MiB.bin of=$DEV bs=1M count=1 conv=fsync
    sudo blockdev --rereadpt $DEV
    sudo sfdisk -d $DEV                                 # compare with $P.sfdisk
    zstd -dc $P.p1-boot.img.zst | sudo dd of=${DEV}p1 bs=4M conv=fsync
    sudo mkfs.f2fs -f -l rootfs -O encrypt -U 93b4acaf-6486-4f5b-8216-675e9c2aaced ${DEV}p2
    sudo mount ${DEV}p2 /mnt
    zstd -dc $P.p2-root.tar.zst | sudo tar -C /mnt --numeric-owner --xattrs --xattrs-include='*' --acls -xpf -
    sudo umount /mnt && sudo fsck.f2fs ${DEV}p2 && sync

### Restoring to a smaller card

The saved table ends p2 where the original card ended, so the script refuses a smaller
card. Restore by hand as above, but between the MBR and the boot partition, rewrite the
table from an edited `.sfdisk`:
- keep `label-id:`, which keeps the PARTUUIDs;
- keep p1 as it is;
- remove `size=` from p2, so it takes the rest of the card.

Then `sudo sfdisk $DEV < edited.sfdisk`. Rewriting the table leaves the bootloader at
128 KiB alone. The card needs room for the root's used space; any card of 16 GB or more
holds a typical one.

## What has been tested

A restore of a trixie backup into a sparse file the card's exact size, attached as a loop
device (2026-09-26):
- checksums passed, and the table matched;
- the first 1 MiB, bootloader included, came back byte-identical;
- PARTUUIDs, labels and UUIDs came back as on the card;
- the root filesystem had `encrypt` as its only feature, and `fsck.f2fs` found it clean;
- the one file capability (`gst-ptp-helper`) came back.

Compared with the live Pyra (owner, group, mode and type of every path outside
`/var/log`, `/tmp`, `/var/tmp` and the home directory), all but 42 of ~170,000 lines
matched. All 42 were expected:
- files in `/dev` and `/run` that sit on the disk under the filesystems a running system
  mounts there;
- the modes of the `/proc` and `/sys` mount points;
- four `/var/backups` files rotated after the backup.

Not tested: booting a restored card, and restoring through a USB reader.

## Checking a card reader

Before trusting a reader with backups, take one backup through it, then run:

    sudo -b ./pc/pyra-card-reader-test.sh /dev/sdb ~/pyra-backup <prefix>

It sets the card read-only, refuses a card whose disk id differs from the backup's, and
checks four things:
1. it reads every file again and compares it with the archive (`tar -d`);
2. it reads the boot partition twice and the first 1 MiB once, bypassing the page cache,
   and compares them with the backup;
3. it reads every sector of the card once, bypassing the page cache (about 25 minutes for
   128 GB; `SKIP_SURFACE=1` skips this);
4. it checks the SCSI error counter (`/sys/block/sdX/device/ioerr_cnt`, USB readers only)
   and the kernel log's lines for this card, its SCSI host and its USB port.

It ends with `READER: no errors, no misreads` or a list of what went wrong.

One gap: a reader that misreads the same way every time passes, because the backup came
through it too. Running check 1 again with the card in a different reader rules that out.

**Count only the increase in the SCSI error counter.** It can already be non-zero before
the test. On the reader below it stood at 36 from boot, while the slot was polled with no
card in it (`[sdb] Media removed, stopped polling`), and the tests added nothing.

**Readers that have passed:**

| reader | date | result |
|---|---|---|
| Realtek `0bda:0316` (USB 3, built into a PC) | 2026-10-29 | `tar -d`: 0 differences over ~345,000 SCSI commands. Boot partition and first 1 MiB identical. All 128 GB read at 90.2 MB/s, 0 errors. No new SCSI errors, and no kernel errors, resets or timeouts. Not yet cross-checked in a second reader. |
