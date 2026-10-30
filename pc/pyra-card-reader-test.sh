#!/bin/bash
# Does this card reader return errors, or read the card back differently? Checked against a
# backup that pyra-card-backup.sh took through the same reader (docs/card-backup-restore.md).
#
#   sudo ./pyra-card-reader-test.sh <device> <backup-dir> <prefix>
#   sudo -b ./pyra-card-reader-test.sh /dev/sdb /mnt/disk/pyra-backup pyra-card-trixie-2026-10-29
#   SKIP_SURFACE=1 ...      skips the read of every sector (about 25 min for 128 GB at 90 MB/s)
#
# Read-only on the card. Four checks:
#   1. every file read again and compared with the archive (tar -d)
#   2. the boot partition read twice and the first 1 MiB once, O_DIRECT, against the backup
#   3. every sector of the card read once, O_DIRECT
#   4. the SCSI error counter (USB readers) and the kernel's messages for this device
# A reader that returns the same wrong data every time passes all four, because the backup came
# through it too. To rule that out, run check 1 once with the card in a different reader.
set -uo pipefail

die() { echo "error: $*" >&2; exit 1; }
[ $# -ge 3 ] || { sed -n '2,16p' "$0"; exit 1; }
DEV=$1 DIR=$2 P=$3
[ "$(id -u)" = 0 ] || die "run as root"
[ -b "$DEV" ] || die "$DEV is not a block device"
case $DEV in *[0-9]) P1=${DEV}p1 P2=${DEV}p2 ;; *) P1=${DEV}1 P2=${DEV}2 ;; esac
[ "$(blkid -p -s LABEL -o value $P1)" = boot ] || die "$P1 is not labelled boot: not a Pyra card"
[ "$(blkid -p -s LABEL -o value $P2)" = rootfs ] || die "$P2 is not labelled rootfs: not a Pyra card"
grep -q "^$DEV" /proc/mounts && die "$DEV or one of its partitions is mounted; unmount it first"
cd "$DIR" || die "cannot use $DIR"
for f in first1MiB.bin p1-boot.img.zst p2-root.tar.zst; do
	[ -s "$P.$f" ] || die "missing $DIR/$P.$f"
done
# The backup has to be of this card.
[ "$(sfdisk --disk-id $DEV)" = "$(sed -n 's/^label-id: //p' $P.sfdisk)" ] || die "$DEV is not the card $P was taken from (disk id)"

# The card's kernel names, for picking its messages out of the journal: sdb, host2, 2:0:0:0
# and the USB port 2-1 for a USB reader; mmc0 for an SD host controller.
K=${DEV#/dev/}
SYSDEV=$(readlink -f /sys/block/$K)
IDS=$(echo "$SYSDEV" | grep -o -E '/(host[0-9]+|[0-9]+:[0-9]+:[0-9]+:[0-9]+|[0-9]+-[0-9.]+|mmc[0-9]+)(/|$)' | tr -d / | sort -u | xargs)
PAT="\\b(${K}p?[0-9]*$(for i in $IDS; do printf '|%s' "$i"; done))\\b|I/O error"
SYS=/sys/block/$K/device
cnt() { [ -r $SYS/$1 ] && echo $(( $(cat $SYS/$1) )) || echo 0; }
ERR0=$(cnt ioerr_cnt)
counters() { [ -r $SYS/ioerr_cnt ] || return 0
	printf '  [scsi %s: requests %d, errors %d (+%d)]\n' "$1" $(cnt iorequest_cnt) $(cnt ioerr_cnt) $(( $(cnt ioerr_cnt) - ERR0 )); }

MNT=$(mktemp -d /tmp/pyra-reader.XXXXXX)
cleanup() { umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null
	blockdev --setrw $DEV $P1 $P2
	[ -z "${SUDO_USER:-}" ] || chown "$SUDO_USER": "$DIR/$P".reader-test.* 2>/dev/null; }
trap cleanup EXIT
blockdev --setro $DEV $P1 $P2
mountro() { mount -o ro -t f2fs $P2 "$MNT" 2>/dev/null || mount -o ro,norecovery -t f2fs $P2 "$MNT"; }
dropc() { sync; echo 3 > /proc/sys/vm/drop_caches; }
t() { date +%s.%N; }
el() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", a-b}'; }
O=$P.reader-test
START=$(date '+%F %T')
FAIL=()

trap '' HUP
exec > >(trap '' HUP; exec tee --output-error=warn -a "$O.log") 2>&1
echo "=== $START  $(uname -r)  $DEV ($(lsblk -dno SIZE,TRAN,MODEL $DEV | xargs)), read-only: $(blockdev --getro $DEV)$(blockdev --getro $P1)$(blockdev --getro $P2)"
echo "backup $P; kernel names watched: $K $IDS"
counters start

echo; echo "=== 1. every file read again and compared with the archive (tar -d)"
dropc; mountro || die "cannot mount $P2 read-only"
T0=$(t)
zstd -dc -q $P.p2-root.tar.zst | tar -d -C "$MNT" --numeric-owner -f - > $O.compare.txt 2>&1
RC=$?
T1=$(t)
umount "$MNT"
N=$(wc -l < $O.compare.txt)
echo "  tar -d exit $RC, $N difference lines ($O.compare.txt), $(el $T1 $T0) s"
head -40 $O.compare.txt
[ "$RC" = 0 ] || FAIL+=("tar -d: $N difference lines")
counters "after 1"

echo; echo "=== 2. boot partition read twice and first 1 MiB once, O_DIRECT, against the backup"
H0=$(zstd -dc -q $P.p1-boot.img.zst | sha256sum | cut -c1-16)
dropc; H1=$(dd if=$P1 bs=4M iflag=direct status=none | sha256sum | cut -c1-16)
dropc; H2=$(dd if=$P1 bs=4M iflag=direct status=none | sha256sum | cut -c1-16)
echo "  boot: image $H0, read 1 $H1, read 2 $H2"
[ "$H0" = "$H1" ] && [ "$H1" = "$H2" ] || FAIL+=("boot partition reads differ")
H3=$(sha256sum < $P.first1MiB.bin | cut -c1-16)
H4=$(dd if=$DEV bs=1M count=1 iflag=direct status=none | sha256sum | cut -c1-16)
echo "  first 1 MiB: backup $H3, card $H4"
[ "$H3" = "$H4" ] || FAIL+=("first 1 MiB differs")
counters "after 2"

if [ "${SKIP_SURFACE:-0}" != 1 ]; then
	echo; echo "=== 3. every sector of the card, O_DIRECT"
	SIZE=$(blockdev --getsize64 $DEV)
	T2=$(t)
	dd if=$DEV of=/dev/null bs=4M iflag=direct conv=noerror 2> $O.surface.txt
	RC=$?
	T3=$(t)
	tail -1 $O.surface.txt
	N=$(grep -c -i error $O.surface.txt)
	echo "  dd exit $RC, $N error lines, $(el $T3 $T2) s, $(awk -v n=$SIZE -v a=$T3 -v b=$T2 'BEGIN{printf "%.1f", n/1e6/(a-b)}') MB/s"
	[ "$RC" = 0 ] && [ "$N" = 0 ] || FAIL+=("surface read: exit $RC, $N error lines")
	counters "after 3"
else
	echo; echo "=== 3. skipped (SKIP_SURFACE=1)"
fi

echo; echo "=== 4. kernel messages for this device since $START"
journalctl -k --since "$START" --no-pager -o short-monotonic | grep -E -i "$PAT" > $O.kernel.txt
cat $O.kernel.txt
N=$(grep -c -i -E 'error|reset|critical|sense|timeout|disconnect|offline' $O.kernel.txt)
[ "$N" = 0 ] || FAIL+=("$N kernel error/reset lines")
D=$(( $(cnt ioerr_cnt) - ERR0 ))
[ "$D" = 0 ] || FAIL+=("SCSI ioerr_cnt rose by $D")

echo; echo "=== result"
if [ ${#FAIL[@]} = 0 ]; then echo "READER: no errors, no misreads"
else echo "READER PROBLEMS:"; printf '  - %s\n' "${FAIL[@]}"; fi
echo "done $(date). Nothing was written to the card."
[ ${#FAIL[@]} = 0 ]
