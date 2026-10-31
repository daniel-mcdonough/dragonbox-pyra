#!/usr/bin/env bash
# Write a prepared image to an SD card, then read the card back and check it.
#
#   sudo ./pyra-image-write.sh IMAGE /dev/sdX [--yes]
#
# Self-contained: pyra-image-push.sh copies it next to the image on the machine
# with the card reader, and it needs nothing else from the repository.
#
# EVERYTHING ON THE CARD IS DESTROYED. Before writing it checks the image
# against its .sha256 and refuses:
#   - a partition (pass the whole card), or anything that is not a block device
#   - a disk that is neither removable nor on an MMC controller, so internal
#     drives and USB hard disks are refused
#   - the disk holding /, or any disk with a mounted partition
#   - a card smaller than the image
# then shows what is on the card and asks for its name to be typed (--yes skips
# only that question).
#
# The write uses direct I/O. Then the card's first <image size> bytes are read
# back, again with direct I/O, and their SHA-256 must equal the image's. Direct
# I/O on both sides matters with cheap USB readers: one has served stale
# buffered reads of a card (docs/troubleshooting.md, "fsck finds damage before
# the grow"), and one has corrupted a sustained write (docs/grow-rootfs.md).

set -euo pipefail

die()  { printf '\e[31mERROR\e[0m  %s\n' "$*" >&2; exit 1; }
warn() { printf '\e[33mWARN\e[0m   %s\n' "$*" >&2; }
ok()   { printf '\e[32mOK\e[0m     %s\n' "$*"; }
info() { printf '\e[36mINFO\e[0m   %s\n' "$*"; }

IMG=${1:-}
DEV=${2:-}
YES=${3:-}
[[ -n $IMG && -n $DEV ]] || { sed -n '2,23p' "$0"; exit 1; }
[[ $EUID -eq 0 ]] || die "must run as root"
[[ -r $IMG ]] || die "no image at $IMG"
SUMS=${IMG%.img}.sha256
[[ -r $SUMS ]] || die "no $SUMS beside the image"
[[ -b $DEV ]] || die "$DEV is not a block device"
for t in lsblk blockdev sha256sum dd findmnt; do command -v "$t" >/dev/null || die "missing tool: $t"; done

DEV=$(readlink -f "$DEV")
NAME=${DEV##*/}
SYS=/sys/class/block/$NAME
[[ ! -e $SYS/partition ]] || die "$DEV is a partition; pass the whole card (e.g. /dev/sdc, /dev/mmcblk0)"

RM=$(cat "$SYS/removable" 2>/dev/null || echo 0)
TRAN=$(lsblk -dno TRAN "$DEV" 2>/dev/null | tr -d ' ')
[[ $RM == 1 || $NAME == mmcblk* ]] ||
    die "$DEV is not removable and not an MMC device (transport '${TRAN:-?}'); refusing in case it is a disk you need"
ROOTSRC=$(findmnt -no SOURCE /)
ROOTDISK=$(lsblk -no PKNAME "${ROOTSRC%%\[*}" 2>/dev/null | head -1)     # btrfs: /dev/sda2[/@]
[[ $NAME != "$ROOTDISK" ]] || die "$DEV holds this machine's root filesystem"
MOUNTED=$(lsblk -nro MOUNTPOINTS "$DEV" 2>/dev/null | grep -v '^$' || lsblk -nro MOUNTPOINT "$DEV" | grep -v '^$' || true)
[[ -z $MOUNTED ]] || die "$DEV has mounted partitions:
$MOUNTED
       unmount them first (udisksctl unmount -b /dev/${NAME}1, or umount)"

IMG_SZ=$(stat -c %s "$IMG")
DEV_SZ=$(blockdev --getsize64 "$DEV")
[[ $DEV_SZ -ge $IMG_SZ ]] || die "$DEV is $((DEV_SZ / 1048576)) MiB, the image needs $((IMG_SZ / 1048576)) MiB"
(( IMG_SZ % 4194304 == 0 )) || die "the image is not a whole number of 4 MiB blocks; this script expects the 6 GiB trixie image"

info "checking $(basename "$IMG") against $(basename "$SUMS")"
WANT=$(awk '{print $1; exit}' "$SUMS")
( cd "$(dirname "$IMG")" && sha256sum -c --quiet "$(basename "$SUMS")" ) || die "the image does not match its .sha256"
ok "image checksum good"

echo
echo "  card:   $DEV  $((DEV_SZ / 1000000000)) GB  $(lsblk -dno VENDOR,MODEL "$DEV" 2>/dev/null | xargs)  (${TRAN:-?})"
echo "  now on it:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID "$DEV" | sed 's/^/    /'
if [[ $(dd if="$DEV" bs=1 skip=440 count=4 status=none 2>/dev/null | od -An -tx4 | tr -d ' ') == 21a4c285 ]]; then
    warn "this card already holds a Pyra trixie system. If it is the card you use, everything on it"
    warn "(kernel, home directory, saves) is about to be lost. Back it up first if you need any of it."
fi
echo "  image:  $(basename "$IMG")  $((IMG_SZ / 1048576)) MiB"
[[ -r ${IMG%.img}.info ]] && sed 's/^/          /' "${IMG%.img}.info"
echo
if [[ $YES != --yes ]]; then
    read -r -p "Type '$NAME' to erase $DEV and write the image: " answer
    [[ $answer == "$NAME" ]] || die "aborted; nothing written"
fi

info "writing (a few minutes; the reader sets the pace)"
dd if="$IMG" of="$DEV" bs=4M oflag=direct conv=fsync status=progress
sync
ok "written"

info "reading the card back with direct I/O"
GOT=$(dd if="$DEV" bs=4M iflag=direct count=$((IMG_SZ / 4194304)) status=progress | sha256sum | cut -d' ' -f1)
[[ $GOT == "$WANT" ]] || die "READ-BACK MISMATCH: the card does not hold the image (got $GOT).
       Do not boot it. Try another reader or card, and write again."
ok "the card reads back identical to the image"

blockdev --rereadpt "$DEV" 2>/dev/null || true
echo
info "next:"
info "  remove the card (udisksctl power-off -b $DEV, or just pull it if nothing mounted it)"
info "  put it in the Pyra's LEFT slot and hold power until both LEDs go green"
info "  first boot: the screen shows the capacity check and the resize; do not switch off"
info "  then: cat /run/initramfs/pyra-grow-root.log; df -h /"
