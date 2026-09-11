#!/bin/bash
#
# Does this reader return the same bytes twice for the SAME block?
#
# The f2fs checkpoint blocks came back containing USB Bulk-Only Transport
# command wrappers with sequentially incrementing tags. That is the USB bridge
# splicing its own protocol structures into the data phase. If a re-read of the
# same block comes back clean, or comes back differently, nothing is wrong with
# the card or the filesystem and this whole problem is a bad reader.
#
# iflag=direct is essential. Without it the page cache hands back the first
# read's bytes and every comparison looks stable.
#
# Read-only.
#
set -uo pipefail
CARD=${1:-}
[ -n "$CARD" ] || { echo "usage: $0 /dev/sdX   (the whole card, not a partition)" >&2; exit 2; }
[ -b "$CARD" ] || { echo "$CARD is not a block device" >&2; exit 2; }

blkhash() { # partition, block number
	dd if="$1" bs=4096 skip="$2" count=1 iflag=direct 2>/dev/null | sha256sum | cut -c1-24
}
blkhead() {
	dd if="$1" bs=4096 skip="$2" count=1 iflag=direct 2>/dev/null | head -c 8 | xxd -p
}

for blk in 512 1024 519 1031; do
	echo "=== rootfs block $blk, five direct re-reads"
	for i in 1 2 3 4 5; do
		h=$(blkhash "${CARD}2" $blk); f=$(blkhead "${CARD}2" $blk)
		tag=""; [ "${f:0:8}" = "55534243" ] && tag="  <-- USBC, corrupt"
		echo "  read $i: $h  first8 $f$tag"
	done
done

echo
echo "=== the same two blocks pulled out of one large sequential read"
dd if="${CARD}2" bs=1M count=8 iflag=direct 2>/dev/null > /tmp/seq.bin
for blk in 512 1024; do
	off=$((blk * 4096))
	f=$(dd if=/tmp/seq.bin bs=1 skip=$off count=8 2>/dev/null | xxd -p)
	tag=""; [ "${f:0:8}" = "55534243" ] && tag="  <-- USBC, corrupt"
	echo "  block $blk first8 $f$tag"
done
rm -f /tmp/seq.bin

echo
echo "=== does fsck agree, on a fresh direct read"
fsck.f2fs --dry-run "${CARD}2" 2>&1 | grep -i -E "invalid|checkpoint|valid" | head -6
