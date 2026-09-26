#!/bin/bash
# Restore a Pyra SD card from a file-level backup (docs/card-backup-restore.md).
#
#   sudo ./pyra-card-restore.sh <backup-dir> <prefix> <device> [--yes]
#   sudo ./pyra-card-restore.sh ~/pyra-backup pyra-card-2026-09-26-0034 /dev/mmcblk0 --yes
#
# <device> is the whole card (/dev/mmcblk0), or a loop device for a test restore.
# Everything on it is destroyed. Without --yes it only checks and prints the plan.
#
# The backup is five files, <prefix>.*:
#   first1MiB.bin      MBR (partition table, disk id -> the PARTUUIDs the kernel boots by)
#                      and the raw bootloader at 128 KiB
#   sfdisk             the partition table as text, to check the MBR against
#   p1-boot.img.zst    the ext2 boot partition, as an image
#   p2-root.tar.zst    the f2fs root filesystem, as a tar (numeric owners, xattrs, ACLs)
#   SHA256SUMS         checksums of all of them
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
say() { echo "== $*"; }

[ $# -ge 3 ] || { sed -n '2,17p' "$0"; exit 1; }
DIR=$1 PFX=$2 DEV=$3 GO=${4:-}
[ "$(id -u)" = 0 ] || die "run as root"
cd "$DIR"
for f in first1MiB.bin sfdisk p1-boot.img.zst p2-root.tar.zst; do
	[ -f "$PFX.$f" ] || die "missing $DIR/$PFX.$f"
done
[ -b "$DEV" ] || die "$DEV is not a block device"
command -v mkfs.f2fs >/dev/null || die "mkfs.f2fs not found (f2fs-tools)"
command -v zstd >/dev/null || die "zstd not found"

# Partition names: mmcblk0 -> mmcblk0p1, loop0 -> loop0p1, sdb -> sdb1
case $DEV in *[0-9]) P1=${DEV}p1 P2=${DEV}p2 ;; *) P1=${DEV}1 P2=${DEV}2 ;; esac

# The card has to hold the saved table: p2 ends at start + size sectors.
need=$(awk -F'[=,]' '/p2 :/ {gsub(/ /,""); print ($2 + $4) * 512}' "$PFX.sfdisk")
have=$(blockdev --getsize64 "$DEV")
[ "$have" -ge "$need" ] || die "$DEV is $have bytes; the saved table needs $need. Edit the sfdisk file for a smaller card (docs/card-backup-restore.md)."
if grep -q "^$DEV" /proc/mounts; then
	die "$DEV or one of its partitions is mounted; unmount it first"
fi

# The kernel and fstab find partitions by PARTUUID (from the MBR's disk id), not by this;
# it is kept the same so nothing that reads it notices the restore.
UUID=${ROOT_UUID:-93b4acaf-6486-4f5b-8216-675e9c2aaced}

say "plan"
echo "  device   $DEV ($have bytes): $(lsblk -dno MODEL,TRAN "$DEV" 2>/dev/null | xargs)"
echo "  1. check the SHA256SUMS"
echo "  2. dd $PFX.first1MiB.bin -> first 1 MiB (table + bootloader)"
echo "  3. dd $PFX.p1-boot.img.zst -> $P1"
echo "  4. mkfs.f2fs -l rootfs -O encrypt -U $UUID $P2"
echo "  5. untar $PFX.p2-root.tar.zst into it, fsck.f2fs"
[ "$GO" = --yes ] || { echo "nothing written; add --yes to do it"; exit 0; }

say "1. checksums"
# .log and .sh are left out: the log was still being written when the sums were taken.
if [ -f SHA256SUMS ]; then
	grep "  $PFX\." SHA256SUMS | grep -v '\.log$\|\.sh$' | sha256sum -c --quiet || die "checksum mismatch"
	echo "  ok"
else
	echo "  no SHA256SUMS; skipped"
fi

say "2. MBR and bootloader"
dd if="$PFX.first1MiB.bin" of="$DEV" bs=1M count=1 conv=fsync status=none
blockdev --rereadpt "$DEV" 2>/dev/null || partprobe "$DEV" 2>/dev/null || true
udevadm settle 2>/dev/null || true
[ -b "$P1" ] && [ -b "$P2" ] || die "no $P1/$P2 after writing the table"
table() { grep -E '^label-id|start=' | sed 's/^.* : //'; }
[ "$(sfdisk -d "$DEV" | table)" = "$(table < "$PFX.sfdisk")" ] \
	&& echo "  table matches $PFX.sfdisk" || die "the table on $DEV does not match $PFX.sfdisk"

say "3. boot partition"
zstd -dc "$PFX.p1-boot.img.zst" | dd of="$P1" bs=4M conv=fsync status=none
echo "  $(blkid "$P1")"

say "4. root filesystem"
# Only 'encrypt', as on the original: newer defaults could leave a filesystem the Pyra's
# 5.6 kernel will not mount.
mkfs.f2fs -f -q -l rootfs -O encrypt -U "$UUID" "$P2"
echo "  $(blkid "$P2")"

say "5. files"
MNT=$(mktemp -d)
trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT"' EXIT
mount -t f2fs "$P2" "$MNT"
zstd -dc "$PFX.p2-root.tar.zst" | tar -C "$MNT" --numeric-owner --xattrs --xattrs-include='*' --acls -xpf -
sync
echo "  $(find "$MNT" -xdev | wc -l) entries, $(du -sh "$MNT" | cut -f1)"
umount "$MNT"
fsck.f2fs "$P2" >/dev/null && echo "  fsck.f2fs clean" || die "fsck.f2fs reports problems on $P2"
sync
say "done: $DEV holds $PFX"
