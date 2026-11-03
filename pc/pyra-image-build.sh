#!/usr/bin/env bash
# Build a prepared card image: the vendor trixie image with pyra-trixie-prep.sh
# applied, ready to write to a card with pyra-image-write.sh.
#
#   sudo ./pc/pyra-image-build.sh [--out FILE] [--user NAME] [-- PREP-OPTIONS...]
#
# Starts from the vendor archive, never from an image that has been mounted or
# booted: pyra-trixie-t1-brokenxorg.7z at the top of the repository (PYRA_VENDOR_7Z
# names another), checked against the archive's SHA-256 and the unpacked image's,
# both pinned in pyra-vendor-image.sh. Nothing from this machine or any card can reach the result
# except what prep writes and the options given to it.
#
# Without PREP-OPTIONS, prep runs with
#     --grow-on-boot --set-password --kernel <m4-kbdled tarball>
# so the card grows itself on its first boot, boots the shipped kernel, and the
# user (--user, default the image's own 'pyra') gets a password prep asks for
# here. The tarball is PYRA_BUILD_DIR/kernel/m4-kbdled-kernel.tar.gz
# (dragonbox-pyra-build beside the repository by default) or
# PYRA_KERNEL_TARBALL. PREP-OPTIONS replace all of those options; the user
# stays --user's. An --ssh-key passed here goes into the image.
#
# Writes, by default into PYRA_BUILD_DIR/images/:
#   pyra-trixie-prepped-<UTC stamp>.img      the image (sparse)
#   pyra-trixie-prepped-<UTC stamp>.sha256   its checksum, for sha256sum -c
#   pyra-trixie-prepped-<UTC stamp>.info     repository commit, prep options,
#                                            kernel tarball checksum
# owned by the user who ran sudo. Needs qemu-user with binfmt, as prep does.

set -euo pipefail

die()  { printf '\e[31mERROR\e[0m  %s\n' "$*" >&2; exit 1; }
ok()   { printf '\e[32mOK\e[0m     %s\n' "$*"; }
info() { printf '\e[36mINFO\e[0m   %s\n' "$*"; }

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TOP=$(cd -- "$HERE/.." && pwd)
PREP=$HERE/pyra-trixie-prep.sh
BUILD_DIR=${PYRA_BUILD_DIR:-$(cd -- "$TOP/.." && pwd)/dragonbox-pyra-build}
KTAR=${PYRA_KERNEL_TARBALL:-$BUILD_DIR/kernel/m4-kbdled-kernel.tar.gz}
# shellcheck source=pyra-vendor-image.sh
. "$HERE/pyra-vendor-image.sh"

OUT=
USERNAME=pyra
while [[ $# -gt 0 ]]; do
    case $1 in
    --out)   [[ $# -ge 2 ]] || die "--out needs a file"; OUT=$2; shift 2 ;;
    --out=*) OUT=${1#--out=}; shift ;;
    --user)  [[ $# -ge 2 ]] || die "--user needs a name"; USERNAME=$2; shift 2 ;;
    --user=*) USERNAME=${1#--user=}; shift ;;
    --)      shift; break ;;
    *)       die "unknown option: $1 (prep options go after --)" ;;
    esac
done
PREP_ARGS=("$@")

[[ $EUID -eq 0 ]] || die "must run as root (loop devices and mounts)"
[[ -x $PREP ]] || die "no $PREP"
[[ -r $VENDOR_7Z ]] || die "no vendor archive at $VENDOR_7Z
       download $VENDOR_URL"
if [[ ${#PREP_ARGS[@]} -eq 0 ]]; then
    [[ -r $KTAR ]] || die "no kernel tarball at $KTAR (./pc/pyra-crossbuild.sh kernel-m4-kbdled, or set PYRA_KERNEL_TARBALL)"
    PREP_ARGS=(--grow-on-boot --set-password --kernel "$KTAR")
fi

STAMP=$(date -u +%Y%m%d-%H%M%S)
[[ -n $OUT ]] || OUT=$BUILD_DIR/images/pyra-trixie-prepped-$STAMP.img
[[ $OUT == *.img ]] || die "--out must end in .img"
[[ ! -e $OUT ]] || die "$OUT already exists"
BASE=${OUT%.img}
OWNER=${SUDO_UID:-0}:${SUDO_GID:-0}
mkdir -p "$(dirname "$OUT")"
[[ -d $BUILD_DIR/images && $OUT == "$BUILD_DIR/images/"* ]] && chown "$OWNER" "$BUILD_DIR/images"
TMP=$OUT.part
MNT=$(mktemp -d /tmp/pyra-image-build.XXXXXX)
LOOP=

cleanup() {
    set +e
    for d in boot ""; do mountpoint -q "$MNT/$d" && umount "$MNT/$d"; done
    [[ -n $LOOP ]] && losetup -d "$LOOP"
    rmdir "$MNT" 2>/dev/null
    rm -f "$TMP"
}
trap cleanup EXIT

info "checking and unpacking $VENDOR_7Z (about half a minute)"
vendor_unpack "$TMP" || die "no usable vendor image"
ok "vendor archive and its image match their pinned SHA-256s"

modprobe f2fs 2>/dev/null || true
LOOP=$(losetup --find --partscan --show "$TMP")
[[ -b ${LOOP}p2 ]] || die "no ${LOOP}p2: partition scan failed"
mount -t f2fs "${LOOP}p2" "$MNT"
mount "${LOOP}p1" "$MNT/boot"
ok "mounted on $LOOP"

info "running prep: ${PREP_ARGS[*]} <image> $USERNAME"
set +e
"$PREP" "${PREP_ARGS[@]}" "$MNT" "$USERNAME" 2>&1 | tee "$BASE.prep.log"
RC=${PIPESTATUS[0]}
set -e
[[ $RC -eq 0 ]] || die "prep exited $RC; see $BASE.prep.log. No image written"

sync
umount "$MNT/boot"
umount "$MNT"
fsck.f2fs -f --dry-run "${LOOP}p2" > "$BASE.fsck.log" 2>&1 || die "fsck.f2fs reports damage after prep; see $BASE.fsck.log"
ok "fsck.f2fs clean after prep"
losetup -d "$LOOP"; LOOP=

info "checksumming"
mv "$TMP" "$OUT"
( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" ) > "$BASE.sha256"
# The manifest travels with the image, so files are named by basename only: a
# full path would carry this machine's home directory and user name.
# safe.directory: git refuses a repository owned by another user, and this runs
# as root.
git_() { git -c safe.directory="$TOP" -C "$TOP" "$@"; }
OPTS=()
for a in "${PREP_ARGS[@]}"; do
    if [[ -f $a ]]; then OPTS+=("$(basename "$a")"); else OPTS+=("$a"); fi
done
{
    echo "built_utc=$STAMP"
    echo "vendor_img_sha256=$SHA_IMG"
    echo "repo_commit=$(git_ rev-parse HEAD 2>/dev/null || echo unknown)"
    if git_ diff --quiet HEAD -- pc device 2>/dev/null; then echo "repo_dirty=no"; else echo "repo_dirty=yes"; fi
    echo "prep_options=${OPTS[*]}"
    echo "user=$USERNAME"
    for a in "${PREP_ARGS[@]}"; do
        if [[ -f $a && $a == *.tar.gz ]]; then
            echo "kernel_tarball=$(basename "$a") sha256=$(sha256sum < "$a" | cut -d' ' -f1)"
        elif [[ -f $a && $a == *.deb ]]; then
            echo "backlight_deb=$(basename "$a") sha256=$(sha256sum < "$a" | cut -d' ' -f1)"
        fi
    done
} > "$BASE.info"
chown "$OWNER" "$OUT" "$BASE.sha256" "$BASE.info" "$BASE.prep.log" "$BASE.fsck.log"
ok "image:    $OUT"
ok "checksum: $(cut -d' ' -f1 "$BASE.sha256")"
info "next: ./pc/pyra-image-push.sh $OUT"
