#!/bin/bash
# Take a file-level backup of a Pyra SD card (docs/card-backup-restore.md), timed.
#
#   sudo ./pyra-card-backup.sh <device> <backup-dir> [tag]
#   sudo ./pyra-card-backup.sh /dev/mmcblk0 ~/pyra-backup
#   sudo -b ./pyra-card-backup.sh /dev/sdb /mnt/disk/pyra-backup      # survives logging out
#
# Read-only on the card: the device and both partitions are set read-only before anything
# reads them, and the rootfs is mounted ro. The card is named after the Debian release on it
# (its /etc/os-release), so the files are <backup-dir>/pyra-card-<release>-<date>[-tag].*:
#   first1MiB.bin, sfdisk, p1-boot.img.zst, p2-root.tar.zst   what pyra-card-restore.sh needs
#   info       release, kernels, disk id, UUIDs and f2fs features; the restore reads it
#   log        this run, with timings
# and their checksums are appended to <backup-dir>/SHA256SUMS.
# Check the reader afterwards with pyra-card-reader-test.sh.
set -uo pipefail

die() { echo "error: $*" >&2; exit 1; }
[ $# -ge 2 ] || { sed -n '2,15p' "$0"; exit 1; }
DEV=$1 OUTDIR=$2 TAG=${3:-}
[ "$(id -u)" = 0 ] || die "run as root"
[ -b "$DEV" ] || die "$DEV is not a block device"
for t in zstd pv sfdisk blkid dump.f2fs; do command -v $t >/dev/null || die "missing tool: $t"; done
# Partition names: mmcblk0 -> mmcblk0p1, sdb -> sdb1
case $DEV in *[0-9]) P1=${DEV}p1 P2=${DEV}p2 ;; *) P1=${DEV}1 P2=${DEV}2 ;; esac
# Probe the card itself (-p), not the udev database.
[ "$(blkid -p -s LABEL -o value $P1)" = boot ] || die "$P1 is not labelled boot: not a Pyra card"
[ "$(blkid -p -s LABEL -o value $P2)" = rootfs ] || die "$P2 is not labelled rootfs: not a Pyra card"
[ "$(blkid -p -s TYPE -o value $P2)" = f2fs ] || die "$P2 is not f2fs"
grep -q "^$DEV" /proc/mounts && die "$DEV or one of its partitions is mounted; unmount it first"

MNT=$(mktemp -d /tmp/pyra-backup.XXXXXX) P=
cleanup() { umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null
	blockdev --setrw $DEV $P1 $P2
	[ -n "${SUDO_USER:-}" ] && [ -n "$P" ] && chown "$SUDO_USER": "$OUTDIR" "$OUTDIR/$P".* "$OUTDIR/SHA256SUMS" 2>/dev/null; }
trap cleanup EXIT
blockdev --setro $DEV $P1 $P2
mountro() { mount -o ro -t f2fs $P2 "$MNT" 2>/dev/null || mount -o ro,norecovery -t f2fs $P2 "$MNT"; }

# Which card: the release on its rootfs.
sync; echo 3 > /proc/sys/vm/drop_caches
mountro || die "cannot mount $P2 read-only"
REL=$(sed -n 's/^VERSION_CODENAME=//p' "$MNT/etc/os-release" | tr -cd 'a-z0-9')
REL=${REL:-unknown}
KERNELS=$(ls "$MNT/usr/lib/modules" 2>/dev/null | xargs)
umount "$MNT"
P=pyra-card-$REL-$(date +%F)${TAG:+-$TAG}
mkdir -p "$OUTDIR" && cd "$OUTDIR" || die "cannot use $OUTDIR"
[ -e $P.p2-root.tar.zst ] && die "$OUTDIR/$P.p2-root.tar.zst exists; pass a tag"

# Log to the file and the terminal; a closed terminal (sudo -b, ssh dropped) stops neither.
trap '' HUP
exec > >(trap '' HUP; exec tee --output-error=warn -a "$P.log") 2>&1

t() { date +%s.%N; }
el() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", a-b}'; }
FEAT=$(dump.f2fs $P2 2>/dev/null | sed -n 's/.*superblock features = [0-9a-fx]* : *//p' | head -1 | xargs | tr ' ' ,)
DISKID=$(sfdisk --disk-id $DEV 2>/dev/null)
echo "=== $(date)  $(uname -r)  $DEV ($(lsblk -dno SIZE,TRAN,MODEL $DEV | xargs)), read-only: $(blockdev --getro $DEV)"
echo "card: $REL, kernels: $KERNELS"
echo "disk id $DISKID, f2fs features: ${FEAT:-?}"
blkid $P1 $P2

echo; echo "=== backup to $OUTDIR/$P.*"
sync; echo 3 > /proc/sys/vm/drop_caches
T0=$(t)
sfdisk -d $DEV > $P.sfdisk
dd if=$DEV of=$P.first1MiB.bin bs=1M count=1 status=none
dd if=$P1 bs=4M status=none | zstd -q -T0 -o $P.p1-boot.img.zst
T1=$(t)
mountro || die "cannot mount $P2 read-only"
USED=$(df -B1 --output=used "$MNT" | tail -1)
echo "rootfs used: $((USED/1000000)) MB"
T2=$(t)
TIMEFORMAT='  tar|zstd: %R s wall, %U s user, %S s sys, %P%% CPU'
time { tar -C "$MNT" --numeric-owner --xattrs --xattrs-include='*' --acls -cpf - . \
	| pv -f -i 60 -t -b -r \
	| zstd -q -T0 -3 -o $P.p2-root.tar.zst; }
T3=$(t)
umount "$MNT"
T4=$(t)
cat > $P.info <<EOF
RELEASE=$REL
KERNELS=$KERNELS
DISK_ID=$DISKID
BOOT_UUID=$(blkid -p -s UUID -o value $P1)
ROOT_UUID=$(blkid -p -s UUID -o value $P2)
F2FS_FEATURES=$FEAT
CARD_BYTES=$(blockdev --getsize64 $DEV)
ROOT_USED_BYTES=$USED
TAKEN=$(date -Is)
EOF
zstd -t -q $P.p2-root.tar.zst || die "zstd -t fails on $P.p2-root.tar.zst"
sha256sum $P.first1MiB.bin $P.sfdisk $P.info $P.*.zst >> SHA256SUMS

echo; echo "=== done"
ls -l $P.*
echo "MBR + boot partition : $(el $T1 $T0) s"
echo "root tar | zstd      : $(el $T3 $T2) s, $(awk -v u=$USED -v a=$T3 -v b=$T2 'BEGIN{printf "%.1f", u/1e6/(a-b)}') MB/s of rootfs data"
echo "card read, total     : $(awk -v a=$T4 -v b=$T0 'BEGIN{printf "%.1f", (a-b)/60}') min"
echo "zstd -t: OK. Nothing was written to the card."
echo "restore: sudo ./pyra-card-restore.sh $OUTDIR $P /dev/<card>"
