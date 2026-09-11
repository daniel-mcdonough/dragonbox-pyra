#!/bin/bash
#
# Is the card failing, or is the reader dropping the link? Different problems,
# different responses, and a cheap USB reader dying under sustained transfer is
# far more common than a card going bad at two places at once.
#
# Read-only. Takes about a minute.
#
#   sudo ./pc/pyra-card-diagnose.sh /dev/sdX
#
set -uo pipefail
CARD=${1:-}
[ -n "$CARD" ] || { echo "usage: $0 /dev/sdX   (the whole card, not a partition)" >&2; exit 2; }
[ -b "$CARD" ] || { echo "$CARD is not a block device" >&2; exit 2; }

echo "=== kernel's account of the failures"
dmesg | grep -i -E "sdi|usb 1-4|I/O error|reset .*device|EXT4|f2fs" | tail -30

echo
echo "=== is the device still there and the right size"
lsblk -b -o NAME,SIZE,FSTYPE,LABEL "$CARD" 2>&1

echo
echo "=== re-read the exact spot that failed on the boot partition"
# dd stopped at 8 MiB. If this read succeeds now, the failure was transient,
# which means the link, not the medium.
for attempt in 1 2 3; do
	if dd if="${CARD}1" bs=1M skip=8 count=4 of=/dev/null 2>/dev/null; then
		echo "attempt $attempt at 8 MiB: OK"
	else
		echo "attempt $attempt at 8 MiB: FAILED"
	fi
done

echo
echo "=== re-read the spot that failed on the rootfs, around 10.1 GiB"
for attempt in 1 2 3; do
	if dd if="${CARD}2" bs=1M skip=10340 count=4 of=/dev/null 2>/dev/null; then
		echo "attempt $attempt at 10.1 GiB: OK"
	else
		echo "attempt $attempt at 10.1 GiB: FAILED"
	fi
done

echo
echo "=== can we still read the very start of each partition"
dd if="${CARD}1" bs=1M count=1 of=/dev/null 2>&1 | tail -1
dd if="${CARD}2" bs=1M count=1 of=/dev/null 2>&1 | tail -1

echo
echo "=== f2fs superblock, both copies"
dump.f2fs "${CARD}2" 2>&1 | grep -i -E "superblock|checkpoint|valid|error" | head -20

echo
echo "=== reading a scattered sample across the whole card"
# If only one region is bad, most of these succeed. If the link is dropping,
# failures cluster after a few seconds of transfer regardless of position.
fails=0
for gb in 1 5 15 30 50 70 90 110; do
	if dd if="$CARD" bs=1M skip=$((gb * 1024)) count=2 of=/dev/null 2>/dev/null; then
		echo "  ${gb}G: OK"
	else
		echo "  ${gb}G: FAILED"; fails=$((fails + 1))
	fi
done
echo "sample failures: $fails of 8"
