#!/usr/bin/env bash
# Verify the Pyra card's real capacity and link stability BEFORE growing the
# filesystem onto space we have never used.
#
# Writes ONLY above sector 12582912 (6 GiB), which is past the end of the
# existing 5.7 GiB filesystem and currently holds nothing. The rootfs and /boot
# are never touched. Refuses to run if anything on the card is mounted.
#
#   sudo ./verify-card-capacity.sh /dev/sdX

set -euo pipefail

DEV=${1:-}
FLOOR_SECTORS=12582912          # end of the existing filesystem
SAMPLE_BYTES=$((1024 * 1024))   # 1 MiB per sample
SAMPLES=40
WANT_DISKID="0x21a4c285"

die()  { printf '\e[31mERROR\e[0m  %s\n' "$*" >&2; exit 1; }
# Any unhandled failure must announce itself; a silent exit reads as success.
set -E
trap 'rc=$?; printf "\e[31m\nTEST ABORTED\e[0m at line $LINENO with status $rc — this is NOT a pass\n" >&2' ERR
ok()   { printf '\e[32mOK\e[0m     %s\n' "$*"; }
bad()  { printf '\e[31mBAD\e[0m    %s\n' "$*"; }
info() { printf '\e[36mINFO\e[0m   %s\n' "$*"; }

LOG=${LOG:-/tmp/pyra-card-verify.log}
exec > >(tee "$LOG") 2>&1

[[ -n $DEV ]] || die "usage: $0 /dev/sdX"
[[ $EUID -eq 0 ]] || die "must run as root"
[[ -b $DEV ]] || die "$DEV is not a block device"
BASE=$(basename "$DEV")
[[ -e /sys/class/block/$BASE/partition ]] && die "$DEV is a partition; pass the whole disk"

DISKID=$(sfdisk --disk-id "$DEV" 2>/dev/null || echo "")
[[ ${DISKID,,} == "${WANT_DISKID,,}" ]] || die "disk identifier '${DISKID:-unknown}' is not the Pyra card"
MOUNTED=$(lsblk -nro MOUNTPOINT "$DEV" | grep -c . || true)
[[ $MOUNTED -eq 0 ]] || die "$DEV has mounted partitions; unmount first"

TOTAL=$(blockdev --getsz "$DEV")
info "device reports $TOTAL sectors ($(( TOTAL / 2097152 )) GiB)"
LAST=$(( TOTAL - SAMPLE_BYTES / 512 - 1 ))
[[ $LAST -gt $FLOOR_SECTORS ]] || die "device too small to test"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILED=0

info "writing $SAMPLES unique $((SAMPLE_BYTES / 1024)) KiB samples across sectors $FLOOR_SECTORS..$LAST"
for i in $(seq 0 $((SAMPLES - 1))); do
    off=$(( FLOOR_SECTORS + (LAST - FLOOR_SECTORS) * i / (SAMPLES - 1) ))
    # Unique content per sample. A card that wraps writes will clobber earlier
    # samples and the readback below catches it. No pipeline here on purpose:
    # a consumer exiting early SIGPIPEs its producer, and under pipefail that
    # would kill this script mid-test.
    dd if=/dev/urandom of="$TMP/s.$i" bs=512 count=$((SAMPLE_BYTES / 512)) status=none
    if ! dd if="$TMP/s.$i" of="$DEV" bs=512 seek="$off" conv=notrunc,fsync status=none 2>"$TMP/err.$i"; then
        bad "write failed at sector $off: $(cat "$TMP/err.$i")"
        FAILED=1
    fi
    printf '\r  written %d/%d' $((i + 1)) "$SAMPLES"
done
echo
sync
blockdev --flushbufs "$DEV" 2>/dev/null || true
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

info "reading them back"
for i in $(seq 0 $((SAMPLES - 1))); do
    off=$(( FLOOR_SECTORS + (LAST - FLOOR_SECTORS) * i / (SAMPLES - 1) ))
    if ! dd if="$DEV" of="$TMP/r.$i" bs=512 skip="$off" count=$((SAMPLE_BYTES / 512)) status=none 2>"$TMP/rerr.$i"; then
        bad "read failed at sector $off ($(( off / 2097152 )) GiB in): $(cat "$TMP/rerr.$i")"
        FAILED=1
        continue
    fi
    if cmp -s "$TMP/s.$i" "$TMP/r.$i"; then
        printf '\r  verified %d/%d' $((i + 1)) "$SAMPLES"
    else
        echo
        bad "MISMATCH at sector $off ($(( off / 2097152 )) GiB in) — data did not survive"
        FAILED=1
    fi
done
echo

info "sustained 256 MiB write+read at the 60 GiB mark, to test link stability"
MID=$(( TOTAL / 2 ))
if dd if=/dev/urandom of="$TMP/big" bs=1M count=256 status=none \
   && dd if="$TMP/big" of="$DEV" bs=1M seek=$(( MID / 2048 )) conv=notrunc,fsync status=none \
   && { echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true; } \
   && dd if="$DEV" of="$TMP/bigback" bs=1M skip=$(( MID / 2048 )) count=256 status=none \
   && cmp -s "$TMP/big" "$TMP/bigback"; then
    ok "sustained 256 MiB round trip clean"
else
    bad "sustained transfer failed — link is unstable or the card is faulty"
    FAILED=1
fi

echo
if [[ $FAILED -eq 0 ]]; then
    ok "card verified: $(( TOTAL / 2097152 )) GiB is real and the link held. Safe to resize."
    echo "=== TEST COMPLETE: PASS ==="
else
    bad "DO NOT RESIZE. Check dmesg: link resets mean try another port/reader; mismatches mean the card is not the size it claims."
    echo "=== TEST COMPLETE: FAIL ==="
    exit 1
fi
echo "full log: $LOG"
