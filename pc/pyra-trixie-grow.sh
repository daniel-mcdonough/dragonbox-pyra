#!/usr/bin/env bash
# Grow the Pyra trixie card's rootfs to fill the card.
#
#   sudo ./pyra-trixie-grow.sh /dev/sdX [--yes]
#
# Run on the PC, with the card in a reader and NOT mounted. This cannot be done
# on the Pyra: f2fs online resize needs F2FS_IOC_RESIZE_FS to accept a larger
# size, and the 5.6.19 kernel's implementation only shrinks -- a grow request
# returns EINVAL. Verified on the device against a throwaway loopback f2fs.
#
# What it does: extends partition 2 to the end of the disk, then runs
# resize.f2fs. Partition 1 and the U-Boot SPL in the raw sectors before it are
# never touched, and p2's start sector does not move, so the PARTUUIDs that
# fstab and extlinux.conf reference stay valid.

set -euo pipefail

DEV=${1:-}
ASSUME_YES=${2:-}

# The image's own MBR disk identifier and partition geometry. These are the
# real guard: they identify a Pyra trixie card and nothing else.
WANT_DISKID="0x21a4c285"
WANT_P1_START=2048
WANT_P2_START=526336

die()  { printf '\e[31mERROR\e[0m  %s\n' "$*" >&2; exit 1; }
warn() { printf '\e[33mWARN\e[0m   %s\n' "$*" >&2; }
ok()   { printf '\e[32mOK\e[0m     %s\n' "$*"; }
info() { printf '\e[36mINFO\e[0m   %s\n' "$*"; }

[[ -n $DEV ]] || die "usage: $0 /dev/sdX [--yes]"
[[ $EUID -eq 0 ]] || die "must run as root"
[[ -b $DEV ]] || die "$DEV is not a block device"

for t in sfdisk partprobe blkid resize.f2fs fsck.f2fs dump.f2fs; do
    command -v "$t" >/dev/null || die "missing required tool: $t"
done

BASE=$(basename "$DEV")

# The canonical test for "is this a partition": the kernel exports a
# `partition` attribute only for partition devices. Do not go by the name --
# mmcblk0, nvme0n1 and loop0 are whole disks whose names end in a digit.
if [[ -e /sys/class/block/$BASE/partition ]]; then
    die "$DEV is a partition; pass the whole disk"
fi

# Partition naming differs by device class: sda -> sda1, but mmcblk0, nvme0n1
# and loop0 -> mmcblk0p1, nvme0n1p1, loop0p1.
if [[ $BASE =~ [0-9]$ ]]; then PSEP=p; else PSEP=""; fi
P1=${DEV}${PSEP}1
P2=${DEV}${PSEP}2
[[ -b $P1 ]] || die "expected partition 1 at $P1 — is this the right device?"
[[ -b $P2 ]] || die "expected partition 2 at $P2 — is this the right device?"

########################################################################
# Refuse anything that is not obviously the Pyra card
########################################################################
MOUNTED=$(lsblk -nro MOUNTPOINT "$DEV" | grep -c . || true)
[[ $MOUNTED -eq 0 ]] || die "$DEV has $MOUNTED mounted partition(s); unmount them first"

RM=$(cat "/sys/block/$BASE/removable" 2>/dev/null || echo 0)
[[ $RM == 1 ]] || warn "$DEV does not report itself removable — check you have the right disk"

DISKID=$(sfdisk --disk-id "$DEV" 2>/dev/null || echo "")
[[ ${DISKID,,} == "${WANT_DISKID,,}" ]] || \
    die "disk identifier is '${DISKID:-unknown}', expected $WANT_DISKID — this is not a Pyra trixie card"
ok "disk identifier $DISKID matches the trixie image"

NPARTS=$(sfdisk -l "$DEV" | grep -cE "^${DEV}${PSEP}[0-9]+ " || true)
[[ $NPARTS -eq 2 ]] || die "expected exactly 2 partitions, found $NPARTS"

P1_START=$(sfdisk -l -o Device,Start "$DEV" | awk -v d="$P1" '$1==d{print $2}')
P2_START=$(sfdisk -l -o Device,Start "$DEV" | awk -v d="$P2" '$1==d{print $2}')
[[ $P1_START == "$WANT_P1_START" ]] || die "p1 starts at $P1_START, expected $WANT_P1_START"
[[ $P2_START == "$WANT_P2_START" ]] || die "p2 starts at $P2_START, expected $WANT_P2_START"
ok "partition starts match the image ($P1_START, $P2_START)"

P2_FS=$(blkid -o value -s TYPE "$P2" || echo "")
[[ $P2_FS == "f2fs" ]] || die "$P2 is '$P2_FS', expected f2fs"
P2_LABEL=$(blkid -o value -s LABEL "$P2" || echo "")
[[ $P2_LABEL == "rootfs" ]] || warn "$P2 label is '$P2_LABEL', expected 'rootfs'"
ok "$P2 is f2fs labelled '${P2_LABEL:-none}'"

DISK_SECTORS=$(blockdev --getsz "$DEV")
P2_SECTORS_NOW=$(blockdev --getsz "$P2")
FREE=$(( DISK_SECTORS - WANT_P2_START - P2_SECTORS_NOW ))

# The filesystem's own idea of its size, which is not the same thing as the
# partition's. These can disagree: growing the partition and resizing the
# filesystem are two separate steps, and a run that grows the partition and
# then fails can leave exactly that state behind.
FS_DUMP=$(dump.f2fs "$P2" 2>/dev/null || true)
FS_SECTORS=$(printf '%s\n' "$FS_DUMP" | sed -n 's/.*total FS sectors *= *\([0-9][0-9]*\).*/\1/p' | sed -n '1p')
[[ -n ${FS_SECTORS:-} ]] || die "could not read the filesystem size from dump.f2fs $P2"

info "disk         $DISK_SECTORS sectors ($(( DISK_SECTORS / 2097152 )) GiB)"
info "p2 partition $P2_SECTORS_NOW sectors ($(( P2_SECTORS_NOW / 2097152 )) GiB)"
info "p2 filesystem $FS_SECTORS sectors ($(( FS_SECTORS / 2097152 )) GiB)"
info "unused disk  $FREE sectors ($(( FREE / 2097152 )) GiB)"

# Read-only check, before anything is written. Plain `fsck.f2fs -f` repairs:
# it unlinks damaged inodes into lost_found, which destroys the evidence of
# what went wrong and leaves a filesystem that only looks clean. --dry-run
# reports and changes nothing (exit 0 clean, non-zero otherwise).
info "checking the filesystem (read-only)"
if ! fsck.f2fs -f --dry-run "$P2"; then
    die "fsck.f2fs found damage; nothing was written. Image the card before any repair (docs/troubleshooting.md, \"fsck finds damage before the grow\")"
fi
ok "filesystem is clean"

GROW_PART=0
GROW_FS=0
[[ $FREE -ge 2097152 ]] && GROW_PART=1
# 1 GiB of slack, since resize.f2fs does not use every last sector.
[[ $(( P2_SECTORS_NOW - FS_SECTORS )) -ge 2097152 ]] && GROW_FS=1

if [[ $GROW_PART -eq 0 && $GROW_FS -eq 0 ]]; then
    ok "partition fills the disk and the filesystem fills the partition — nothing to do"
    exit 0
fi
[[ $GROW_PART -eq 1 ]] && info "will grow the partition"
[[ $GROW_FS -eq 1 || $GROW_PART -eq 1 ]] && info "will resize the filesystem"

if [[ $ASSUME_YES != "--yes" ]]; then
    echo
    echo "About to extend $P2 to the end of $DEV and resize the filesystem."
    echo "The Pyra must be powered off with this card out of it."
    read -r -p "Type YES to proceed: " answer
    [[ $answer == "YES" ]] || die "aborted"
fi

########################################################################
# Back up, then grow
########################################################################
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=${BACKUP_DIR:-$PWD}
dd if="$DEV" of="$BACKUP_DIR/pyra-card-first-1MiB-$STAMP.bin" bs=1M count=1 status=none
sfdisk --dump "$DEV" > "$BACKUP_DIR/pyra-card-parttable-$STAMP.sfdisk"
ok "backed up first 1 MiB and partition table to $BACKUP_DIR (restore with: sfdisk $DEV < the .sfdisk file)"

if [[ $GROW_PART -eq 1 ]]; then
    # ",+" keeps p2's start and type, and takes all remaining space.
    echo ",+" | sfdisk --no-reread -N 2 "$DEV"
    partprobe "$DEV"
    sleep 2

    P2_SECTORS_NEW=$(blockdev --getsz "$P2")
    [[ $P2_SECTORS_NEW -gt $P2_SECTORS_NOW ]] || die "partition did not grow ($P2_SECTORS_NEW sectors)"
    ok "p2 grown to $P2_SECTORS_NEW sectors ($(( P2_SECTORS_NEW / 2097152 )) GiB)"

    NEW_P2_START=$(sfdisk -l -o Device,Start "$DEV" | awk -v d="$P2" '$1==d{print $2}')
    [[ $NEW_P2_START == "$WANT_P2_START" ]] || die "p2 start moved to $NEW_P2_START — restore the backup"
    ok "p2 start unchanged, PARTUUIDs still valid"
else
    ok "partition already fills the disk, leaving it alone"
fi

########################################################################
# Resize the filesystem
########################################################################
# Optional slack at the end of the partition. Costs almost nothing on a card
# this size and avoids relying on the very last sectors, which are the ones
# most likely to be marginal. Set RESIZE_MARGIN_SECTORS=0 to use every sector.
MARGIN=${RESIZE_MARGIN_SECTORS:-0}
P2_SECTORS_FINAL=$(blockdev --getsz "$P2")
if [[ $MARGIN -gt 0 ]]; then
    TARGET=$(( P2_SECTORS_FINAL - MARGIN ))
    [[ $TARGET -gt $FS_SECTORS ]] || die "margin of $MARGIN sectors leaves no room to grow"
    info "resizing to $TARGET sectors, leaving $MARGIN sectors ($(( MARGIN / 2048 )) MiB) unused at the end"
    info "metadata is rebuilt, this is not instant"
    resize.f2fs -t "$TARGET" "$P2" || die "resize.f2fs failed — partition is bigger but the filesystem is not; re-run, or restore the table backup"
else
    info "resizing to fill the partition (metadata is rebuilt, this is not instant)"
    resize.f2fs "$P2" || die "resize.f2fs failed — partition is bigger but the filesystem is not; re-run, or restore the table backup"
fi

info "checking the filesystem after resizing"
fsck.f2fs -f --dry-run "$P2" || warn "post-resize fsck (read-only) reported a problem — inspect before booting"

echo
ok "done. Sanity check:"
dump.f2fs "$P2" 2>/dev/null | grep -iE "total|sector|volumn|volume" | head -10 || true
echo
info "put the card back in the LEFT slot and cold boot (hold power until both LEDs go green)"
info "then confirm with: df -h /"
