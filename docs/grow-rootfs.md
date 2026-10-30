# Growing the rootfs

> **Type: instructions.** Steps to follow.

Commands here are run from the repository root, on a PC, with the card in a
reader.

The image is 6 GiB and nothing grows it on boot, so on a 128 GB card about
113 GB sits unused. Growing it means extending partition 2 and running
`resize.f2fs`.

**This cannot be done on the Pyra.** f2fs online resize goes through
`F2FS_IOC_RESIZE_FS`, and the 5.6.19 kernel's implementation only shrinks — ask
it to grow and it returns `EINVAL`. Confirmed by calling the ioctl directly
against a throwaway loopback f2fs on the device, rather than inferring it.
`f2fs_io` in f2fs-tools 1.16.0 has no `resize` subcommand either, so there is no
userspace path to it regardless. And `resize.f2fs` is a symlink to `fsck.f2fs`,
which is an offline tool and will not operate on a mounted filesystem. Since the
filesystem in question is the rootfs, it cannot be unmounted in place.

---

## Before anything else: the reader will decide whether this works

**Do not do this through a cheap USB card reader.** The grow rewrites about
507 MB of f2fs metadata in one sustained write, and a USB bridge that mangles
that write corrupts the filesystem in a way nothing notices for days.

This happened on 2026-09-10, on the card this repository documents. A generic
USB reader spliced its own USB Bulk-Only Transport command wrappers into the
data it was writing. Eighty-five 4 KB metadata blocks ended up holding the
signature `USBC` and a transfer tag instead of filesystem structures: two in the
checkpoint packs, sixteen in the segment table, fifty-nine in the node address
table. The tags ran in one unbroken sequence, so it was a single write, and the
region hit was the metadata area of the grown filesystem rather than the
original.

The card then booted and ran normally for days, because the surviving entries
covered the files in daily use. It failed only on a cold mount after an unclean
shutdown, with `invalid crc_offset: 295978` and `Failed to get valid F2FS
checkpoint`, at which point the cause was a week and several reboots in the past
and looked like anything but a card reader.

**Use a machine with a real SD host controller.** A laptop's built-in slot on
`/dev/mmcblk*` is an SDHCI controller and is fine. A USB reader appears as
`/dev/sd*` on the `usb` transport and is a bridge chip of unknown quality.
`lsblk -o NAME,TRAN` tells them apart.

**Then verify, before the card goes near the Pyra:**

    sudo ./pc/pyra-verify-card-metadata.sh /dev/sdX2

It scans the metadata area for that signature and takes about a minute. Run it
after writing the image and again after growing. A clean result is not a
guarantee of a good reader, but a dirty one is proof of a bad one, and the check
is cheap enough to be unconditional.

---

So: power the Pyra down, move the card to a reader on a PC, and run

    sudo ./pc/pyra-trixie-grow.sh /dev/sdX

`pyra-trixie-grow.sh`, in the repository root, refuses to touch anything that is not
a Pyra trixie card. It checks the MBR disk identifier and both partition start
sectors, refuses a partition or a mounted device, and backs up the first 1 MiB
and the partition table before it writes. Before any write it runs
`fsck.f2fs -f --dry-run`, which reports and changes nothing; on damage it stops
with the card untouched (`troubleshooting.md`, "fsck finds damage before the
grow"). It never runs a repairing fsck. Partition 2's start sector does not
move, so the PARTUUIDs that `fstab` and `extlinux.conf` reference stay valid. It
is idempotent: run it on an already-grown card and it reports there is nothing
to do.

If the very last sectors of a card worry you, `RESIZE_MARGIN_SECTORS` leaves
slack at the end. It is applied through `resize.f2fs -t`, so it needs no second
write to the partition table:

    sudo RESIZE_MARGIN_SECTORS=131072 ./pc/pyra-trixie-grow.sh /dev/sdX   # 64 MiB

Then put the card back in the **left** slot, cold boot, and check with `df -h /`.

**Verify the card first.** Everything this procedure has touched up to now lives
in the first 6 GiB, so the rest of the card is completely untested and a
capacity-overstating card would not have shown up yet. Resizing onto space that
is not really there gives you a filesystem that looks healthy and then quietly
destroys data. `verify-card-capacity.sh`, in the repository root, writes unique
samples across the untested region only, never below the end of the existing
filesystem, reads them back, and runs a sustained transfer to shake out a flaky
reader:

    sudo ./pc/verify-card-capacity.sh /dev/sdX

Do this **before** growing the partition, not after.

Measured on a 128 GB SanDisk: partition 249473024 sectors, filesystem 249341952,
the difference being exactly the 64 MiB margin. `df` reports 119G with 115G
free.

