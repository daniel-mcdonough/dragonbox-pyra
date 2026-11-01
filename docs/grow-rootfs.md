# Growing the rootfs

> **Type: instructions.** Steps to follow.

Commands here are run from the repository root, on a PC, with the card in a
reader.

The image is 6 GiB, so on a 128 GB card about 113 GB sits unused. Growing it
means extending partition 2 and running `resize.f2fs`. There are two ways: a
card prepped with `--grow-on-boot` grows itself from the initramfs on its first
boot (next section), and any card can be grown from a PC (the rest of this
page).

**This cannot be done on a running Pyra.** f2fs online resize goes through
`F2FS_IOC_RESIZE_FS`, and the 5.6.19 kernel's implementation only shrinks — ask
it to grow and it returns `EINVAL`. Confirmed by calling the ioctl directly
against a throwaway loopback f2fs on the device, rather than inferring it.
`f2fs_io` in f2fs-tools 1.16.0 has no `resize` subcommand either, so there is no
userspace path to it regardless. And `resize.f2fs` is a symlink to `fsck.f2fs`,
which is an offline tool and will not operate on a mounted filesystem. Since the
filesystem in question is the rootfs, it cannot be unmounted in place. The
initramfs runs before root is mounted, which is what the first-boot grow uses.

---

## On the first boot: `--grow-on-boot`

`pc/pyra-trixie-prep.sh --grow-on-boot` installs three files and puts them in
fix 14's initrds:

- `device/pyra-grow-root`, as `/usr/local/sbin/pyra-grow-root`: does the work.
- `device/etc/initramfs-tools/scripts/local-premount/pyra-grow-root`: finds
  the root device, waits up to 30 s for the card to appear, and runs it, before
  root is mounted. It has to resolve the device itself: initramfs-tools 0.148
  runs `local-premount` once, from `mount_premount`, before `mountroot`. At that
  point `ROOT` is still the command line's `PARTUUID=21a4c285-02`, and the card
  may not have been probed yet. Found on the first card booted with it
  (2026-10-31): the hook was handed the `PARTUUID=` string and did nothing.
- `device/etc/initramfs-tools/hooks/pyra-grow-root`: copies it, `sfdisk`,
  `partx` and `resize.f2fs` into the initrd. Busybox supplies the rest.

On each boot the script compares partition 2, the card and the filesystem from
sysfs and the f2fs superblock, and exits if fewer than 1 GiB are unused. Once a
card is grown, that is all it ever does. Otherwise, stopping at the first thing
that is not as expected:

1. **Only a Pyra trixie card**: p2 at sector 526336, exactly two partitions,
   MBR identifier `0x21a4c285`, f2fs on p2. Anything else is left alone.
   `pyra.nogrow` on the kernel command line also leaves it alone.
2. **A capacity check.** The script writes a 4 KiB sample every 256 MiB across
   the unused space, plus one at the last sector, then reads them all back past
   the page cache. A card that drops writes beyond its real size reads back
   zeros or errors. A card that wraps writes onto lower addresses lands two
   samples in the same block. That is guaranteed when its real size is a
   multiple of 256 MiB, which fakes, being built on power-of-two flash,
   normally are. Each sample's block is read and saved first and put back on
   failure, so whatever a wrapping card's samples landed on is put back. This
   check writes about 4 MB where `verify-card-capacity.sh` writes far more, so
   it is a filter, not a proof.
3. **`fsck.f2fs -f --dry-run`.** On damage, no grow.
4. **Partition 2 extended** to the end of the card, start unchanged, so the
   PARTUUIDs stay valid. The kernel learns the new size through `partx`.
5. **`resize.f2fs`**, leaving the 64 MiB margin measured below, then a second
   dry run.

The screen says what is happening, and not to switch off during step 5.
Measured 2026-10-31 on a 256 GB SanDisk (SA256): capacity check 931 samples,
about 8 s; each fsck dry run 68 s; `resize.f2fs` 513 s; about 11 minutes in all.
Root came up at 239 G with 234 G free. A 256 GB card from the release image
(2026-11-01) took 64 s and 67 s for the fsck runs and 486 s for the resize. That
card's userspace, the greeter included, started about 11 minutes after the
kernel.

The first mount after the grow logs `F2FS-fs (mmcblk1p2): invalid crc_offset: 0`
once. That is expected, not damage. `resize.f2fs` writes its new checkpoint into
one of the two checkpoint packs and zeroes the other, so nothing can roll back
to the old geometry. The kernel picks the valid pack, and its next checkpoint
rewrites the zeroed one. Checked on that card by reading both pack headers
afterwards: versions 1130324925 and 1130324926, both with `crc_offset` 4092.
Compare 2026-09-10 below, where the offset was garbage (`295978`) and *neither*
pack was valid.
Everything goes to `/run/initramfs/pyra-grow-root.log`, which survives into the
running system. Power lost between steps 4 and 5 is harmless: the next boot
finds the partition grown and does only step 5. Power lost during step 5 can
damage the filesystem. Whatever the script reports, the boot carries on and
mounts root.

The grow goes through the Pyra's own SD controller, so the USB reader failures
in the next section cannot happen.

`pc/pyra-grow-root-selftest.sh` (root, on a PC or a Pyra) runs it against
throwaway loop-device cards:
- a genuine card
- three device-mapper fakes: wrapping, dropping writes, and an upper range that fails to read
- an interrupted grow
- p2 missing from the kernel for a moment after the grow, and for good
- zeroed checkpoints
- the opt-out and the guards
- a copy of the real vendor image on a 16 GiB card. It must match the pin in
  `pc/pyra-vendor-image.sh`; any other image is skipped, and the skip is counted
  in the verdict (`PASS, WITH n SKIPPED`), not passed

A refused card must come back byte-identical.

The real-image case hashes the image once, before copying it. A wrong image
costs no 7 GiB copy.

**A partition node that vanishes after the grow.** In one of three PC
selftest runs on 2026-11-01, `/sys/class/block/loop0p2/start` did not exist
for a moment after `sfdisk` and `partx -u`. The script then read nothing,
reported `partition 2 start moved; restore the partition table` and exited 1.
The table was fine: the next run finished the grow as an interrupted one. The
likely cause is udev re-reading the table when the disk is closed after a
write, which drops and re-adds the partition nodes. The initramfs runs udev
too, so the same could happen on a Pyra. Now the script:
- holds a `flock` on the disk from just before the capacity check's first
  write until it exits, so the check's one-sector writes and `sfdisk` are all
  covered. udev does not re-read a locked disk (`sfdisk(8)`, `--lock`). The
  hook copies `flock` into the initrd; without it the script runs unlocked.
  Only a grow that extends the partition takes it, since that is the only one
  that writes to the whole disk.
- waits up to 10 s for p2's device node, start and size. If they never
  appear, it says the next boot will finish the grow and exits 1.
- reports a moved start only when it read a start that differs, and names
  the sector.

The selftest forces both shapes through a test hook in the script
(`PYRA_GROW_TEST_DROP`, which takes p2 away from the kernel right after
`partx -u`): back after 3 s (the grow must finish), and never back (exit 1,
then the next run finishes).

**What a Pyra initrd carries** (the R42 release card, 2026-11-01, trixie,
`update-initramfs -u -k 5.6.19-m4-kbdled` after installing this script and
hook, inspected with `lsinitramfs` and `unmkinitramfs`):
- `usr/bin/flock`, util-linux 2.41, runs in the unpacked initrd. Before the new
  hook the initrd had none: busybox there has no `flock` applet, so `flock`
  is present only because the hook copies it.
- `usr/lib/udev/rules.d/60-block.rules` with `OPTIONS+="watch"` on line 13.
  The vendor's udev hook copies it, so it was there before the change too.
  udevd starts in `init-top` and is stopped in `init-bottom`, so it's still running
  at `local-premount`, where the grow runs. The re-read that the lock guards
  against can happen on a Pyra as well as on a PC.
- `usr/sbin/pyra-grow-root`, byte-identical to this script.

The boot after the rebuild (already grown, from `l5`) logged
`nothing to do: disk 500006912, partition 499480576, filesystem 499349504
sectors`, and root mounted at 7.2 s (dmesg).

**A grow with the lock on a Pyra** (2026-11-01, a `--release` image built
from f45b0b9, first boot, `verification-log.md`): `done: the root filesystem
is now 238 GiB`, with no wait message and no moved start; root mounted at
653 s. udev did re-read the table on that boot: 80 times in 6 s, during the
capacity check, whose one-sector writes each close the disk after writing.
That is before `sfdisk` and the lock, while the table is still unchanged, so
the partition nodes it drops come back unchanged. dmesg shows no re-read after
`sfdisk`. Since then the lock is taken before the capacity check (below).
The grow's messages go to `/dev/console`, which is the LCD (`console=tty0` is
last on the command line); the serial console shows only the kernel's lines,
and a gap while the grow runs.

**The lock from the capacity check on** (PC, 2026-11-01,
`pyra-grow-root-selftest.sh --quick` with each run of the script marked in
dmesg, and the `loopN: p1 p2` lines between the marks counted): with the lock
taken at `sfdisk`, the script's 14 runs made 26 table re-reads, up to 9 in one
run. With the lock taken before the capacity check they made none. The
selftest's own card setup, outside the script, made 24 and 23. The full
selftest, real image included, passes with the new scope. Not yet run on a
Pyra.

**Booted on a Pyra three times.** First on 2026-10-31 (the card above, through
`pyra-image-build.sh`; the hook fix described above was applied on the card
before that boot). The boots after it log `nothing to do` and print nothing; root
mounted at 8.2 s on the next one (serial console, 2026-11-01). Then on
2026-11-01, from a `--release` image: the grow ran on the first boot, with no
reboot, and ended `done: the root filesystem is now 238 GiB` (`verification-log.md`).
Then again on 2026-11-01 from a `--release` image with the lock, the same way
(above).

---

## Before anything else: the reader will decide whether this works

**Do not do this through a cheap USB card reader.** On 2026-10-30 a generic USB
reader also served stale data from before a card swap to fsck's buffered reads,
so a healthy card looked damaged (`troubleshooting.md`, "fsck finds damage
before the grow"). A built-in laptop SD slot had neither problem. The grow rewrites about
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

