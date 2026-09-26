# Backing up and restoring the Pyra's SD card

The Pyra boots and runs from a 128 GB SD card (`mmcblk1` on the Pyra). This is how
to restore it from a file-level backup taken on the X220, and how to take a new one.

**Use the X220's built-in SD slot for both.** USB card readers have corrupted
Pyra cards. On the X220 the card is `/dev/mmcblk0`: check with `lsblk` every time.

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

**The f2fs feature set matters.** The root filesystem was created on a Raspberry Pi
with `encrypt` as its only feature. A newer `mkfs.f2fs` can enable features by
default that the Pyra's 5.6 kernel cannot mount, so the restore passes
`-O encrypt` and nothing else.

(`/etc/fstab` says `ext4` for `/boot`, which is really ext2. That was already the
case and is harmless: the ext4 driver mounts ext2.)

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
2. Confirm which device it is, by size (128 GB) and transport (`mmc`):

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
   - runs `mkfs.f2fs -l rootfs -O encrypt -U 93b4acaf-…` on p2;
   - untars the root with numeric owners, xattrs and ACLs (file capabilities, such as
     `gst-ptp-helper`'s, live in xattrs);
   - runs `fsck.f2fs`.

   It stops at the first failure.
5. `sync`, remove the card, and boot the Pyra. The boot menu is the one from backup
   time: l5 default, l4 fallback.

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

About 10 minutes for an 11 GB root on the X220's slot. `dd` of the whole card
takes ~1¾ hours at the slot's 20 MB/s, and the compressed image can be much larger
than 11 GB: the free space holds old data. Back up the files instead:

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

Check `blkid ${DEV}p2` first. If the root UUID has changed, pass the new one to
the restore as `ROOT_UUID=<uuid>`. If the f2fs features have changed (`sudo
dump.f2fs ${DEV}p2 | grep features`), change `-O` to match.
