#!/bin/bash
#
# pyra-verify-card-metadata.sh — check the card's f2fs metadata for the
# signature of a card reader that corrupted what it wrote.
#
#   sudo ./pyra-verify-card-metadata.sh /dev/sdX2
#
# Run this after writing the image and after growing the rootfs, before the
# card ever goes in the Pyra. It reads and reports; it changes nothing.
#
# WHY THIS EXISTS
#
# A cheap USB card reader spliced its own USB Bulk-Only Transport command
# wrappers into the data it was writing. Eighty-five 4 KB blocks of f2fs
# metadata ended up containing the four-byte signature "USBC" followed by a
# transfer tag, instead of filesystem structures. The tags ran in one unbroken
# sequence, so it happened during a single sustained write, and the region hit
# was the metadata area of the grown filesystem. The rootfs grow is what wrote
# it.
#
# The card then worked for days, because the surviving entries covered the
# files in daily use. It only failed on a cold mount after an unclean
# shutdown, by which point the cause was two weeks and several reboots in the
# past and looked like anything but a card reader.
#
# The check itself costs about a minute and needs no privileges beyond reading
# the device.
#
set -uo pipefail

DEV=${1:-}
[ -n "$DEV" ] || { echo "usage: $0 /dev/sdX2   (the f2fs rootfs partition)" >&2; exit 2; }
[ -b "$DEV" ] || { echo "$DEV is not a block device" >&2; exit 1; }

python3 - "$DEV" <<'PY'
import struct, sys

dev = sys.argv[1]
BLK = 4096
f = open(dev, 'rb')

f.seek(1024)
sb = f.read(4096)
magic, = struct.unpack_from('<I', sb, 0)
if magic != 0xF2F52010:
    print(f"not an f2fs filesystem: magic 0x{magic:08X}")
    sys.exit(1)

fields = struct.unpack_from('<16I', sb, 44)
(_, _, _, seg_sit, seg_nat, _, _, _,
 cp_blk, sit_blk, nat_blk, ssa_blk, main_blk, root_ino, _, _) = fields

print(f"f2fs metadata spans blocks 0 to {main_blk} ({main_blk * BLK // (1024*1024)} MB)")
print(f"  checkpoint {cp_blk}, segment table {sit_blk}, node table {nat_blk}, "
      f"summaries {ssa_blk}, data from {main_blk}")
print()

regions = [
    ("superblock+cp", 0,        sit_blk),
    ("segment table", sit_blk,  nat_blk),
    ("node table",    nat_blk,  ssa_blk),
    ("summaries",     ssa_blk,  main_blk),
]

bad = []
f.seek(0)
for blk in range(main_blk):
    b = f.read(BLK)
    if len(b) < 4:
        break
    if b[:4] == b'USBC':
        tag, = struct.unpack_from('<I', b, 4)
        bad.append((blk, tag))

if not bad:
    print("CLEAN. No USB command wrappers found in the metadata area.")
    sys.exit(0)

print(f"CORRUPT. {len(bad)} metadata blocks contain USB command wrappers.")
print()
for name, lo, hi in regions:
    n = [x for x in bad if lo <= x[0] < hi]
    if n:
        print(f"  {name:14} blocks {lo}-{hi}: {len(n)} corrupt")

tags = sorted(t for _, t in bad)
print()
print(f"  transfer tags run 0x{tags[0]:x} to 0x{tags[-1]:x}")
if tags[-1] - tags[0] < len(tags) * 20:
    print("  they are consecutive, so this was one sustained write, not slow decay")
print()
print("Do not use this card. Rewrite it from a machine with a real SD host")
print("controller, not a USB bridge, and run this check again afterwards.")
sys.exit(1)
PY
