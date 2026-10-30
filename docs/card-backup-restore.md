# Backing up and restoring the Pyra's SD card

> **Type: instructions.** Steps to follow.

The Pyra boots and runs from an SD card (`mmcblk1` on the Pyra). There are two: the
modified trixie card (128 GB) and the stock bookworm card (256 GB). This is how to
take a file-level backup of either, and how to restore one.

**Restore on the X220's built-in SD slot.** USB card readers have corrupted Pyra
cards. The X220's slot is an SD host controller, and the card is `/dev/mmcblk0`
there: check with `lsblk` every time.

**Backups can also go through a USB 3 card reader**, once
`pc/pyra-card-reader-test.sh` has passed on it (see "Checking a card reader"). A
backup only reads the card. One reader has passed so far: a Realtek `0bda:0316`
built into a second PC, where the card is `/dev/sdb`. It takes a backup in half
the X220's time. Restores through it are untested.

**Keep the PC's desktop from mounting the card.** A desktop that auto-mounts the
card mounts it read-write, and the PC's much newer kernel then writes to it. On
insertion it runs f2fs's roll-forward recovery (`f2fs_recover_fsync_data` in the
kernel log) and writes checkpoints, and background GC can run. Install `pc/99-pyra-card-noauto.rules` on any
PC a Pyra card goes into; how is in the file. The rule matches any card with this
layout, not one card. If a card does get mounted, `udisksctl unmount -b /dev/sdX2`.

## What the card holds

| region | what | how it is backed up |
|---|---|---|
| first 1 MiB | MBR: partition table and disk id `0x21a4c285`; from 128 KiB, ~390 KB of raw bootloader data | `dd`, byte for byte |
| p1, 256 MB, ext2, label `boot` | kernels, initrds, dtbs, `extlinux/` (boot menu) | `dd` image, compressed |
| p2, 119 GB, f2fs, label `rootfs` | Debian 13; ~11 GB used | `tar`, compressed |

**How the Pyra finds its partitions:** by **PARTUUID**. The kernel command line has
`root=PARTUUID=21a4c285-02`, and `/etc/fstab` mounts `/` and `/boot` by PARTUUID. A
PARTUUID is the MBR's disk id plus the partition number, so it comes back with
the first 1 MiB. The filesystem UUIDs don't matter for booting; the restore
keeps them the same anyway.

**The f2fs feature set matters.** The trixie card's root filesystem was created on
a Raspberry Pi with `encrypt` as its only feature. A newer `mkfs.f2fs` can enable
features by default that the Pyra's 5.6 kernel cannot mount, so the restore passes
the original's features and nothing else: those in the backup's `.info`, or
`encrypt` when there is no `.info`.

(`/etc/fstab` says `ext4` for `/boot`, which is really ext2. That was already the
case and is harmless: the ext4 driver mounts ext2.)

**The table describes the trixie card.** The bookworm card has the same two
partitions on 256 GB, with p2 at 238 GB. It has its own disk id, `0x160ddd96`, so
its PARTUUIDs are `160ddd96-01` and `160ddd96-02`, and its own filesystem UUIDs.
It runs Debian 12 with the `5.6.19-pyradef` and `5.6.19-jack` kernels, and about
4.6 GB of its root is used. Each backup's `.info` records that card's values, and
the restore uses them.

## The backups of 2026-10-29 (current)

On the second backup PC, on its external disk in `pyra-backup/`, taken through its
USB 3 reader with `pc/pyra-card-backup.sh`. Each is the file set below plus an
`.info` file.

| prefix | card | root tar | boot image | checked |
|---|---|---|---|---|
| `pyra-card-trixie-2026-10-29` | trixie, 12.7 GB of root used | 2.68 GB | 170 MB | `zstd -t`; the reader test (every file compared with the card) |

The trixie card's disk id, UUIDs and f2fs features (`encrypt` only) are unchanged, so
the restore below works with that prefix. Neither backup has been test-restored.

Before this backup, the backup PC's desktop auto-mounted the trixie card read-write
for a few minutes, under kernel 7.2. That wrote to it: its f2fs checkpoint went
from version `435ff2c5` at that mount to `435ff2cd` at the backup's read-only
mount. The backup is of the card in that state. Whether the Pyra had shut it down
cleanly before that isn't known. The read-only mounts after it found nothing left
to recover.

Taking this one took 5.1 minutes from the card. Its `.info` was written afterwards,
from the run's log, and has no `KERNELS` line.

## The backup of 2026-09-28

On the X220, in `~/pyra-backup/`, as `pyra-card-2026-09-28-twocore.*` (same file set as below;
root tar 2.11 GB, boot image 142 MB). Taken with `~/pyra-backup/take-2026-09-28.sh`, the
steps under "Taking a new backup". The card's state: the 09-26 state plus SoH's two-core
build in `~/soh-pyra`, `pyra-soh` and `pyra-cpu-pin` in `/usr/local`, and the
`/etc/sudoers.d/pyra-cpu-pin` rule (all installed 09-28 18:14). Disk id, UUIDs and f2fs
features (`encrypt` only) are unchanged, so the restore below works as written with
`pyra-card-2026-09-28-twocore` as the prefix. Checked: both archives pass `zstd -t`, and the
root tar lists the files above. Not test-restored (the 09-26 test covers the method).

## The backup of 2026-09-26

On the X220, in `~/pyra-backup/`, about 2.2 GB:

| file | contents |
|---|---|
| `pyra-card-2026-09-26-0034.first1MiB.bin` | first 1 MiB of the card |
| `pyra-card-2026-09-26-0034.sfdisk` | the partition table as text (to check the MBR against) |
| `pyra-card-2026-09-26-0034.p1-boot.img.zst` | boot partition image (142 MB) |
| `pyra-card-2026-09-26-0034.p2-root.tar.zst` | root filesystem (2.07 GB, from 11 GB) |
| `SHA256SUMS` | checksums (the `.log` entry is stale: the log was still being written) |
| `pyra-card-restore.sh` | a copy of `pc/pyra-card-restore.sh` |

The card's state at backup time:
- kernel `5.6.19-m4-kbdled` as the default (l5);
- the GPU fix 0034 installed in its `updates/` directory;
- fix 11 installed.

Taken with the Pyra shut down cleanly (`sudo poweroff`) and the root partition
mounted read-only on the X220.

## Tested

On 2026-09-26, `pyra-card-restore.sh` restored this backup, on the X220, into a
sparse file the card's exact size attached as a loop device
(`~/pyra-backup/restore-test-2026-09-26.log`):
- checksums passed, and the table matched;
- the first 1 MiB, bootloader included, came back byte-identical;
- PARTUUIDs, labels and UUIDs came back as on the card;
- the root filesystem has `encrypt` as its only feature, and `fsck.f2fs` found it clean;
- the one file capability (`gst-ptp-helper`) came back.

Compared with the live Pyra (owner, group, mode and type of every path outside
`/var/log`, `/tmp`, `/var/tmp` and `/home/pyra`), all but 42 of ~170,000 lines matched.
All 42 are expected:
- files in `/dev` and `/run` that sit on the disk under the filesystems a running
  system mounts there;
- the modes of the `/proc` and `/sys` mount points;
- four `/var/backups` files rotated after the backup.

Not tested: booting a restored card.

## Restoring

Everything on the target card is destroyed.

1. Put the card in the X220's built-in slot. If the desktop auto-mounts its
   partitions, unmount them (`sudo umount /dev/mmcblk0p*`).
2. Confirm which device it is, by size (128 GB for trixie, 256 GB for bookworm) and
   transport (`mmc`):

       lsblk -o NAME,SIZE,TRAN,FSTYPE,LABEL

3. Dry run: it checks the files and the card's size, prints the plan and writes nothing:

       cd ~/pyra-backup
       sudo ./pyra-card-restore.sh ~/pyra-backup pyra-card-2026-09-26-0034 /dev/mmcblk0

4. The restore, about 15 minutes:

       sudo ./pyra-card-restore.sh ~/pyra-backup pyra-card-2026-09-26-0034 /dev/mmcblk0 --yes

   In order, it:
   - checks the checksums;
   - writes the first 1 MiB and confirms the partition table matches `.sfdisk`;
   - writes the boot partition;
   - runs `mkfs.f2fs -l rootfs -O <features> -U <uuid>` on p2, taking both from the
     backup's `.info`. A backup with no `.info`, such as those before 2026-10-29,
     gets the trixie card's `-O encrypt -U 93b4acaf-…`;
   - untars the root with numeric owners, xattrs and ACLs (file capabilities, such as
     `gst-ptp-helper`'s, live in xattrs);
   - runs `fsck.f2fs`.

   It stops at the first failure.
5. `sync`, remove the card, and boot the Pyra. The boot menu is the one from backup
   time: l5 default, l4 fallback.
6. Log in at the desktop as pyra and reapply the desktop settings set after the
   backup (the power manager's popups, which knock the game out of fullscreen):

       ./pyra-desktop-settings.sh          # from device/ in this repo, as pyra, not root

### By hand, if the script is not at hand

    DEV=/dev/mmcblk0 P=pyra-card-2026-09-26-0034
    sha256sum -c --ignore-missing SHA256SUMS            # ignore a mismatch on the .log
    sudo dd if=$P.first1MiB.bin of=$DEV bs=1M count=1 conv=fsync
    sudo blockdev --rereadpt $DEV
    sudo sfdisk -d $DEV                                 # compare with $P.sfdisk
    zstd -dc $P.p1-boot.img.zst | sudo dd of=${DEV}p1 bs=4M conv=fsync
    sudo mkfs.f2fs -f -l rootfs -O encrypt -U 93b4acaf-6486-4f5b-8216-675e9c2aaced ${DEV}p2
    sudo mount ${DEV}p2 /mnt
    zstd -dc $P.p2-root.tar.zst | sudo tar -C /mnt --numeric-owner --xattrs --xattrs-include='*' --acls -xpf -
    sudo umount /mnt && sudo fsck.f2fs ${DEV}p2 && sync

### A smaller card

The saved table ends p2 at sector 249,999,359 (128.0 GB), so a smaller card
refuses it. Restore with the script's steps by hand, but between the MBR and the
boot partition, rewrite the table from an edited `.sfdisk`:
- keep `label-id: 0x21a4c285`, which keeps the PARTUUIDs;
- keep p1 as it is;
- remove `size=` from p2, so it takes the rest of the card.

Then `sudo sfdisk $DEV < edited.sfdisk`. The root needs ~11 GB, so any card of 16 GB
or more holds it. Rewriting the table leaves the bootloader at 128 KiB alone.

## Taking a new backup

Shut the Pyra down with `sudo poweroff` first. A card pulled from a running Pyra,
or one that wasn't shut down cleanly, has f2fs data that only a read-write mount
recovers. A read-only backup leaves that data out.

Then, with the card in the reader and nothing on it mounted:

    sudo ./pc/pyra-card-backup.sh /dev/mmcblk0 ~/pyra-backup           # the X220
    sudo -b ./pc/pyra-card-backup.sh /dev/sdb /mnt/disk/pyra-backup    # -b: survives closing the terminal

It refuses a card whose partitions aren't labelled `boot` and `rootfs`, or one that
is mounted. Before reading anything it sets the device and both partitions
read-only, and it mounts the rootfs `ro`. It names the backup after the release in
the card's `/etc/os-release`, `pyra-card-<release>-<date>`, with an optional tag as
the third argument. It writes the four files the restore needs, plus:
- `.info`: the release, kernels, disk id, both UUIDs and the f2fs features. The
  restore takes its `mkfs.f2fs -U` and `-O` from this file.
- `.log`: the run, with its timings.

It appends the checksums to `SHA256SUMS` and runs `zstd -t` on the root tar.

How long it takes, for the trixie card:

| reader | raw read | backup | rootfs data rate |
|---|---|---|---|
| X220 built-in slot | ~20 MB/s | ~10 min for an 11 GB root (estimate, not timed) | ~18 MB/s |
| USB 3 reader, Realtek `0bda:0316` | 87–90 MB/s | 5.1 min for a 12.7 GB root (timed) | 42 MB/s |

The rootfs data rate is set by the card, not the CPU. The `tar | zstd` pipeline
used 75% of one core on a 4-core Celeron N4100, and its speed swung between
11 MiB/s on runs of small files and 75 MiB/s on large ones. A `dd` image of the
whole card takes ~1¾ hours at 20 MB/s, or ~24 minutes at 90 MB/s. The compressed
image can also be much larger than the root's used space, because the free space
holds old data.

The steps the script runs, by hand:

    # on the Pyra
    sudo poweroff
    # on the X220, card in the built-in slot, nothing mounted
    DEV=/dev/mmcblk0 P=pyra-card-$(date +%F)
    mkdir -p ~/pyra-backup && cd ~/pyra-backup
    sudo sfdisk -d $DEV > $P.sfdisk
    sudo dd if=$DEV of=$P.first1MiB.bin bs=1M count=1
    sudo dd if=${DEV}p1 bs=4M | zstd -T0 -o $P.p1-boot.img.zst
    sudo mount -o ro -t f2fs ${DEV}p2 /mnt
    sudo tar -C /mnt --numeric-owner --xattrs --xattrs-include='*' --acls -cpf - . | zstd -T0 -3 -o $P.p2-root.tar.zst
    sudo umount /mnt
    zstd -t $P.p2-root.tar.zst && sha256sum $P.first1MiB.bin $P.sfdisk $P.*.zst >> SHA256SUMS

A backup taken by hand has no `.info`, so the restore uses the trixie card's
rootfs UUID and `-O encrypt`. Check `blkid ${DEV}p2` and `sudo dump.f2fs ${DEV}p2 |
grep features` first. If either differs, pass the card's own values to the restore
as `ROOT_UUID=<uuid>` and `F2FS_FEATURES=<a,b>`.

## Checking a card reader

Before trusting a reader with backups, take one backup through it, then run:

    sudo -b ./pc/pyra-card-reader-test.sh /dev/sdb /mnt/disk/pyra-backup pyra-card-trixie-2026-10-29

It sets the card read-only, refuses a card whose disk id differs from the backup's,
and checks four things:
1. it reads every file again and compares it with the archive (`tar -d`);
2. it reads the boot partition twice and the first 1 MiB once, bypassing the page
   cache, and compares them with the backup;
3. it reads every sector of the card once, bypassing the page cache (about 25
   minutes for 128 GB; `SKIP_SURFACE=1` skips this);
4. it checks the SCSI error counter (`/sys/block/sdX/device/ioerr_cnt`, USB readers
   only) and the kernel log's lines for this card, its SCSI host and its USB port.

It ends with `READER: no errors, no misreads` or a list of what went wrong. A
reader that misreads the same way every time passes, because the backup came
through it too. Running check 1 once more with the card in a different reader
rules that out.

**The Realtek `0bda:0316`, 2026-10-29, trixie card: passed.**
- `tar -d`: 0 differences, about 345,000 SCSI commands.
- Boot partition and first 1 MiB identical.
- All 128 GB read at 90.2 MB/s, 0 errors.
- No new SCSI errors, and no kernel errors, resets or timeouts.

The counter already stood at 36 before the tests, and nothing the tests did added
to it. Those 36 date from boot, while the slot was polled with no card in it
(`[sdb] Media removed, stopped polling`). Count only the increase during a test.

The same-way-every-time case is not yet ruled out: the archive hasn't been checked
against the card in the X220's slot.
