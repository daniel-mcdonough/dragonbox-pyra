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
info "disk      $DISK_SECTORS sectors ($(( DISK_SECTORS / 2097152 )) GiB)"
info "p2 now    $P2_SECTORS_NOW sectors ($(( P2_SECTORS_NOW / 2097152 )) GiB)"
info "unused    $FREE sectors ($(( FREE / 2097152 )) GiB)"

if [[ $FREE -lt 2097152 ]]; then
    ok "less than 1 GiB unused — nothing worth doing"
    exit 0
fi

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

########################################################################
# Resize the filesystem
########################################################################
info "checking the filesystem before resizing"
fsck.f2fs -f "$P2" || die "fsck.f2fs reported a problem; not resizing"

info "resizing (metadata is rebuilt, this is not instant)"
resize.f2fs "$P2" || die "resize.f2fs failed — the partition is bigger but the filesystem is not; restore the table backup or re-run"

info "checking the filesystem after resizing"
fsck.f2fs -f "$P2" || warn "post-resize fsck reported a problem — inspect before booting"

echo
ok "done. Sanity check:"
dump.f2fs "$P2" 2>/dev/null | grep -iE "total|sector|volumn|volume" | head -10 || true
echo
info "put the card back in the LEFT slot and cold boot (hold power until both LEDs go green)"
info "then confirm with: df -h /"
