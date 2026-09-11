#!/bin/bash
#
# Step 1 of recovering the card: look at it read-only, then image it.
# Nothing here writes to the card. Run as root.
#
set -uo pipefail
CARD=${1:-}
OUT=${2:-$PWD/card-image}
PROBE=$(mktemp -d /tmp/pyra-probe.XXXXXX)

[ -n "$CARD" ] || { echo "usage: $0 /dev/sdX [output-directory]" >&2; exit 2; }
[ -b "$CARD" ] || { echo "$CARD is not a block device" >&2; exit 2; }
for t in zstd pv sfdisk; do
	command -v $t >/dev/null || { echo "missing tool: $t" >&2; exit 2; }
done

echo "=== confirming this is the Pyra card"
lsblk -o NAME,SIZE,FSTYPE,LABEL "$CARD"
if [ "$(lsblk -no LABEL ${CARD}2 | tr -d ' ')" != "rootfs" ]; then
	echo "REFUSING: ${CARD}2 is not labelled rootfs" >&2; exit 1
fi
if [ "$(lsblk -no LABEL ${CARD}1 | tr -d ' ')" != "boot" ]; then
	echo "REFUSING: ${CARD}1 is not labelled boot" >&2; exit 1
fi

echo
echo "=== read-only probe of the rootfs"
# norecovery stops the kernel replaying the journal, so this cannot write.
if mount -o ro,norecovery "${CARD}2" "$PROBE" 2>/tmp/pyra-probe.err; then
	echo "MOUNTED read-only. The filesystem is readable."
	echo "--- /lib:"
	ls -ld "$PROBE/lib" 2>&1
	ls -A "$PROBE/lib" 2>&1 | head
	echo "--- kernels present in usr/lib/modules:"
	ls -d "$PROBE"/usr/lib/modules/* 2>&1
	echo "--- interpreter reachable through usr/lib:"
	ls -l "$PROBE/usr/lib/ld-linux-armhf.so.3" 2>&1
	echo "--- home:"
	du -sh "$PROBE/home" 2>/dev/null
	umount "$PROBE"
else
	echo "read-only mount FAILED:"
	cat /tmp/pyra-probe.err
fi

echo
echo "=== imaging, compressed. The boot partition first, it is small."
mkdir -p "$OUT"
dd if="${CARD}1" bs=4M status=none | zstd -T0 -3 -f -o "$OUT/boot-p1.img.zst"
echo "boot partition imaged: $(du -h "$OUT/boot-p1.img.zst" | cut -f1)"

echo
echo "=== imaging the rootfs. Expect roughly an hour for a 128 GB card over USB 2.0."
SIZE=$(blockdev --getsize64 "${CARD}2")
dd if="${CARD}2" bs=4M 2>/dev/null | pv -s "$SIZE" | zstd -T0 -3 -f -o "$OUT/rootfs-p2.img.zst"
echo "rootfs imaged: $(du -h "$OUT/rootfs-p2.img.zst" | cut -f1)"

echo
sfdisk -d "$CARD" > "$OUT/partition-table.sfdisk" 2>/dev/null
[ -z "${SUDO_USER:-}" ] || chown -R "$SUDO_USER" "$OUT"
rmdir "$PROBE" 2>/dev/null || true
ls -la "$OUT"
echo
echo "done. Nothing was written to the card."
