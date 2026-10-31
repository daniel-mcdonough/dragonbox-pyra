#!/usr/bin/env bash
# Exercise device/pyra-grow-root against throwaway cards on loop devices.
#
#   sudo ./pc/pyra-grow-root-selftest.sh [--quick] [/path/to/pyra-trixie-t1.img]
#
# Each case builds a small sparse "card" with the trixie image's geometry
# (MBR identifier 0x21a4c285, p1 at 2048, p2 at 526336) and a 1 GiB f2fs on p2
# holding a known file, runs the script on it the way the initramfs does, and
# checks the outcome and the bytes. Fake cards are device-mapper tables over a
# 3 GiB backing file: one that wraps writes past 3 GiB back onto the start,
# one that drops them and reads zeros, one whose upper range fails to read.
# A refused card must come back byte-identical, wrapped samples included.
#
# Unless --quick, a last case grows a copy of the real vendor image
# (pyra-trixie-t1.img at the top of the repository by default) on a 16 GiB
# sparse file, and checks the result mounts with its files intact.
#
# Runs the script under `busybox sh` when busybox is installed, which is the
# shell the initramfs runs it under; otherwise under sh, and says so. It runs
# on the Pyra too (copy the repository over; it needs f2fs-tools, dmsetup and
# util-linux, which the image has).
#
# Writes /proc/sys/vm/drop_caches, as the script does. Leaves its logs in a
# directory it names on the way out; set OUTDIR to choose one.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TOP=$(cd -- "$HERE/.." && pwd)
SCRIPT=$TOP/device/pyra-grow-root
QUICK=0
[[ ${1:-} == --quick ]] && { QUICK=1; shift; }
IMG=${1:-$TOP/pyra-trixie-t1.img}
REALCOPY=$TOP/pyra-trixie-t1-growtest.img
OUT=${OUTDIR:-}
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

GIB=2097152                 # sectors
P2_START=526336
P2_SIZE=$GIB                # the test cards' rootfs: 1 GiB
REAL=$((3 * GIB))           # a fake card's real capacity

PASS=0; FAIL=0; SKIP=0
p() { printf '\e[32mPASS\e[0m  %s\n' "$*"; PASS=$((PASS+1)); }
f() { printf '\e[31mFAIL\e[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
s() { printf '\e[33mSKIP\e[0m  %s\n' "$*"; SKIP=$((SKIP+1)); }
i() { printf '\e[36m----\e[0m  %s\n' "$*"; }

LOOPS=()
DMS=()
MNT=
WORK=
cleanup() {             # after each case: newest loop first, then dm, then the loops under dm
    set +e
    [[ -n $MNT ]] && mountpoint -q "$MNT" && umount "$MNT"
    local n d
    for ((n = ${#LOOPS[@]} - 1; n >= 0; n--)); do losetup -d "${LOOPS[n]}" 2>/dev/null; done
    udevadm settle 2>/dev/null
    for d in "${DMS[@]}"; do dmsetup remove --retry "$d" 2>/dev/null; done
    LOOPS=(); DMS=()
    set -e
}
finish() {
    local rc=$?
    cleanup
    set +e
    [[ -n $MNT ]] && rmdir "$MNT"
    [[ -n $WORK ]] && rm -rf "$WORK"
    rm -f "$REALCOPY"
    echo
    [[ -n $OUT ]] && i "logs in $OUT"
    printf '\e[1m%d passed, %d failed, %d skipped\e[0m\n' "$PASS" "$FAIL" "$SKIP"
    if [[ $rc -ne 0 && $FAIL -eq 0 ]]; then
        echo "TEST COMPLETE: FAIL (exited $rc with no assertion failure -- treat as incomplete)"
    elif [[ $FAIL -gt 0 ]]; then
        echo "TEST COMPLETE: FAIL"
    elif [[ $SKIP -gt 0 ]]; then
        echo "TEST COMPLETE: PASS, WITH $SKIP SKIPPED"
    else
        echo "TEST COMPLETE: PASS"
    fi
}
trap finish EXIT

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ -r $SCRIPT ]] || { echo "no $SCRIPT" >&2; exit 1; }
for t in sfdisk partx losetup dmsetup mkfs.f2fs fsck.f2fs resize.f2fs blockdev sha256sum truncate; do
    command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done
modprobe f2fs 2>/dev/null || true
modprobe dm_mod 2>/dev/null || true
[[ -n $OUT ]] || OUT=$(mktemp -d /tmp/pyra-grow-selftest.XXXXXX)
mkdir -p "$OUT"
WORK=$(mktemp -d /tmp/pyra-grow-work.XXXXXX)
MNT=$(mktemp -d /tmp/pyra-grow-mnt.XXXXXX)
if command -v busybox >/dev/null; then
    RUNSH=(busybox sh)
    i "running the script under busybox sh, as the initramfs does"
else
    RUNSH=(sh)
    s "no busybox here; running the script under $(readlink -f "$(command -v sh)"), not busybox sh"
fi

newloop() {             # FILE-OR-DEVICE -> L, a loop device with partitions scanned
    L=$(losetup --find --partscan --show "$1")
    LOOPS+=("$L")
}

# Lay the trixie geometry onto DEV, put an f2fs on p2, and leave a known file
# on it. Prints the file's sha256.
make_card() {
    local dev=$1 sum
    sfdisk -q --wipe always "$dev" >/dev/null <<EOF
label: dos
label-id: 0x21a4c285
start=2048, size=524288, type=83, bootable
start=$P2_START, size=$P2_SIZE, type=83
EOF
    partx -u "$dev" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    [[ -b ${dev}p2 ]] || { echo "no ${dev}p2 after partitioning" >&2; return 1; }
    mkfs.f2fs -q -f -l rootfs "${dev}p2" >/dev/null
    mount -t f2fs "${dev}p2" "$MNT"
    head -c 32M /dev/urandom > "$MNT/payload"
    mkdir -p "$MNT/etc" && echo trixie > "$MNT/etc/marker"
    sum=$(sha256sum < "$MNT/payload" | cut -d' ' -f1)
    umount "$MNT"
    echo "$sum"
}

# Run the script as the initramfs would; sets RC. CMDLINE text optional.
run() {             # NAME PARTITION [CMDLINE]
    local name=$1 part=$2
    printf '%s\n' "${3:-root=PARTUUID=21a4c285-02 rootwait}" > "$OUT/$name.cmdline"
    set +e
    PYRA_GROW_LOG=$OUT/$name.log PYRA_GROW_TMP=$WORK/tmp-$name \
        PYRA_GROW_CMDLINE=$OUT/$name.cmdline "${RUNSH[@]}" "$SCRIPT" "$part" > "$OUT/$name.out" 2>&1
    RC=$?
    set -e
}

fs_sectors() {      # from dump.f2fs, independent of the script's own reader
    dump.f2fs "$1" 2>/dev/null | sed -n 's/.*total FS sectors *= *\([0-9][0-9]*\).*/\1/p' | head -1
}

payload_ok() {      # PARTITION SHA
    local got
    mount -t f2fs -o ro "$1" "$MNT" || return 1
    got=$(sha256sum < "$MNT/payload" | cut -d' ' -f1)
    [[ -r $MNT/etc/marker ]] || got=missing
    umount "$MNT"
    [[ $got == "$2" ]]
}

expect_rc() {       # NAME WANT
    if [[ $RC -eq $2 ]]; then p "$1: exit $RC"; else f "$1: exit $RC, wanted $2 (see $OUT/$1.out)"; fi
}

########################################################################
i "genuine 4 GiB card"
########################################################################
truncate -s 4G "$WORK/genuine"
newloop "$WORK/genuine"
SUM=$(make_card "$L")
FS0=$(fs_sectors "${L}p2")
run genuine "${L}p2"
expect_rc genuine 10
DISK=$(blockdev --getsz "$L")
P2=$(blockdev --getsz "${L}p2")
FS1=$(fs_sectors "${L}p2")
[[ $((P2_START + P2)) -eq $DISK ]] && p "genuine: p2 reaches the end of the card" || f "genuine: p2 ends at $((P2_START + P2)) of $DISK"
[[ $(cat "/sys/class/block/${L##*/}p2/start") -eq $P2_START ]] && p "genuine: p2 start unchanged" || f "genuine: p2 start moved"
[[ $(sfdisk --disk-id "$L") == 0x21a4c285 ]] && p "genuine: disk identifier unchanged" || f "genuine: disk identifier changed"
WANT=$((P2 - 131072))
if [[ -n $FS1 && $FS1 -gt $FS0 && $FS1 -le $WANT && $FS1 -ge $((WANT - 8192)) ]]; then
    p "genuine: filesystem grown from $FS0 to $FS1 sectors (target $WANT)"
else
    f "genuine: filesystem $FS0 -> ${FS1:-?} sectors, target $WANT"
fi
fsck.f2fs -f --dry-run "${L}p2" >/dev/null 2>&1 && p "genuine: fsck clean after the grow" || f "genuine: fsck reports damage after the grow"
payload_ok "${L}p2" "$SUM" && p "genuine: files intact after the grow" || f "genuine: files changed by the grow"
grep -q 'capacity check passed' "$OUT/genuine.log" && p "genuine: capacity check ran and passed" || f "genuine: no passed capacity check in the log"
run genuine-again "${L}p2"
expect_rc genuine-again 0
grep -q 'nothing to do' "$OUT/genuine-again.log" && p "genuine-again: reports nothing to do" || f "genuine-again: did not report nothing to do"
[[ ! -s $OUT/genuine-again.out ]] && p "genuine-again: prints nothing on the console" || f "genuine-again: printed to the console"
cleanup

########################################################################
# Fake cards: a 3 GiB backing file behind a 12 GiB device-mapper table.
########################################################################
# The card is laid out on the backing loop first: sfdisk will not open a disk
# whose upper range fails to read. Sets SUM too.
fake_card() {       # NAME KIND -> L, a loop over the dm device; BACK, BL set
    local name=$1 kind=$2 dm=pyragrow-$1 tbl= off
    truncate -s 3G "$WORK/back-$name"
    BACK=$WORK/back-$name
    newloop "$BACK"; BL=$L
    SUM=$(make_card "$BL")
    sync; blockdev --flushbufs "$BL"
    case $kind in
    wrap)
        for off in 0 1 2 3; do tbl+="$((off * REAL)) $REAL linear $BL 0"$'\n'; done ;;
    drop)
        tbl="0 $REAL linear $BL 0"$'\n'"$REAL $((3 * REAL)) zero"$'\n' ;;
    error)
        tbl="0 $REAL linear $BL 0"$'\n'"$REAL $((3 * REAL)) error"$'\n' ;;
    esac
    printf '%s' "$tbl" | dmsetup create "$dm"
    DMS=("$dm" "${DMS[@]}")
    newloop "/dev/mapper/$dm"
}

for kind in wrap drop error; do
    i "fake 12 GiB card, 3 GiB real, upper range: $kind"
    fake_card "$kind" "$kind"
    sync; blockdev --flushbufs "$L"; blockdev --flushbufs "$BL"
    BEFORE=$(sha256sum < "$BACK" | cut -d' ' -f1)
    run "fake-$kind" "${L}p2"
    expect_rc "fake-$kind" 20
    sync; blockdev --flushbufs "$L"; blockdev --flushbufs "$BL"
    AFTER=$(sha256sum < "$BACK" | cut -d' ' -f1)
    [[ $BEFORE == "$AFTER" ]] && p "fake-$kind: card byte-identical afterwards" || f "fake-$kind: card changed"
    [[ $(blockdev --getsz "${L}p2") -eq $P2_SIZE ]] && p "fake-$kind: p2 not grown" || f "fake-$kind: p2 grown"
    payload_ok "${L}p2" "$SUM" && p "fake-$kind: files intact" || f "fake-$kind: files changed"
    case $kind in
    error) grep -q 'cannot read' "$OUT/fake-$kind.log" && p "fake-$kind: refused before writing" || f "fake-$kind: wrong reason" ;;
    *)     grep -q 'CAPACITY CHECK FAILED' "$OUT/fake-$kind.out" && p "fake-$kind: capacity check failure shown on the console" || f "fake-$kind: no capacity failure on the console" ;;
    esac
    cleanup
done

########################################################################
i "interrupted grow: partition already grown, filesystem not"
########################################################################
truncate -s 4G "$WORK/half"
newloop "$WORK/half"
SUM=$(make_card "$L")
echo ',+' | sfdisk -q --no-reread -N 2 "$L" >/dev/null 2>&1
partx -u --nr 2 "$L"
run half "${L}p2"
expect_rc half 10
! grep -q 'capacity' "$OUT/half.log" && p "half: no capacity check for a partition already grown" || f "half: ran a capacity check"
FS1=$(fs_sectors "${L}p2")
[[ -n $FS1 && $FS1 -gt $((P2_SIZE + GIB)) ]] && p "half: filesystem grown to $FS1 sectors" || f "half: filesystem is ${FS1:-?} sectors"
payload_ok "${L}p2" "$SUM" && p "half: files intact" || f "half: files changed"
cleanup

########################################################################
i "damaged filesystem: both checkpoint packs zeroed"
########################################################################
truncate -s 4G "$WORK/damaged"
newloop "$WORK/damaged"
make_card "$L" >/dev/null
# cp_blkaddr is word 19 of the superblock at byte 1024; two segments of 2 MiB.
CP=$(dd if="${L}p2" bs=1024 skip=1 count=1 2>/dev/null | od -An -tu4 -j76 -N4 | tr -d ' ')
dd if=/dev/zero of="${L}p2" bs=4096 seek="$CP" count=1024 conv=notrunc status=none
sync
P2SUM=$(sha256sum < "${L}p2" | cut -d' ' -f1)
run damaged "${L}p2"
expect_rc damaged 20
[[ $(blockdev --getsz "${L}p2") -eq $P2_SIZE ]] && p "damaged: p2 not grown" || f "damaged: p2 grown"
[[ $(sha256sum < "${L}p2" | cut -d' ' -f1) == "$P2SUM" ]] && p "damaged: filesystem untouched" || f "damaged: filesystem changed"
cleanup

########################################################################
i "opt-out and guards"
########################################################################
truncate -s 4G "$WORK/guard"
newloop "$WORK/guard"
make_card "$L" >/dev/null
sync
G0=$(sha256sum < "$WORK/guard" | cut -d' ' -f1)
unchanged() { [[ $(sha256sum < "$WORK/guard" | cut -d' ' -f1) == "$G0" ]]; }

run nogrow "${L}p2" "root=PARTUUID=21a4c285-02 rootwait pyra.nogrow"
expect_rc nogrow 20
unchanged && p "nogrow: card untouched" || f "nogrow: card changed"

run p1 "${L}p1"
expect_rc p1 0
unchanged && p "p1: card untouched" || f "p1: card changed"

sfdisk -q --disk-id "$L" 0x12345678 >/dev/null 2>&1
G0=$(sha256sum < "$WORK/guard" | cut -d' ' -f1)
run diskid "${L}p2"
expect_rc diskid 0
unchanged && p "diskid: another card's identifier, untouched" || f "diskid: card changed"
sfdisk -q --disk-id "$L" 0x21a4c285 >/dev/null 2>&1

echo "start=$((P2_START + P2_SIZE + 2048)), size=$GIB, type=83" | sfdisk -q --append "$L" >/dev/null 2>&1
partx -u "$L" 2>/dev/null || true
G0=$(sha256sum < "$WORK/guard" | cut -d' ' -f1)
run p3 "${L}p2"
expect_rc p3 0
unchanged && p "p3: card with a third partition untouched" || f "p3: card changed"
cleanup

########################################################################
i "the real vendor image on a 16 GiB card"
########################################################################
if [[ $QUICK -eq 1 ]]; then
    s "real image: --quick"
elif [[ ! -r $IMG ]]; then
    s "real image: none at $IMG"
else
    cp --sparse=always "$IMG" "$REALCOPY"
    truncate -s 16G "$REALCOPY"
    newloop "$REALCOPY"
    run real "${L}p2"
    expect_rc real 10
    fsck.f2fs -f --dry-run "${L}p2" >/dev/null 2>&1 && p "real: fsck clean after the grow" || f "real: fsck reports damage"
    FS1=$(fs_sectors "${L}p2")
    [[ -n $FS1 && $FS1 -gt $((14 * GIB)) ]] && p "real: filesystem now $FS1 sectors" || f "real: filesystem ${FS1:-?} sectors"
    if mount -t f2fs -o ro "${L}p2" "$MNT"; then
        grep -q 'VERSION_CODENAME=trixie' "$MNT/etc/os-release" && p "real: mounts, /etc/os-release reads trixie" || f "real: /etc/os-release wrong"
        umount "$MNT"
    else
        f "real: grown filesystem does not mount"
    fi
    cleanup
fi
