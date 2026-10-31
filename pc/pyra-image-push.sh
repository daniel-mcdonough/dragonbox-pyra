#!/usr/bin/env bash
# Copy a prepared image to the machine with the card reader, with the script
# that writes it, and check it arrived intact.
#
#   ./pc/pyra-image-push.sh [IMAGE] [user@host]
#
# IMAGE defaults to the newest pyra-trixie-prepped-*.img in
# PYRA_BUILD_DIR/images/ (pyra-image-build.sh's output). The host defaults to
# PYRA_WRITER, which pyra-local.conf can set. Everything lands in ~/pyra-images/
# on the host: the image, its .sha256 and .info, and pyra-image-write.sh. The
# image goes by rsync with --sparse, so a re-push after an interrupted one
# resumes, and the copy keeps its holes. The checksum is then verified on the
# host. Then, on the host:
#
#   cd ~/pyra-images && sudo ./pyra-image-write.sh <image> /dev/sdX

set -euo pipefail

die()  { printf '\e[31mERROR\e[0m  %s\n' "$*" >&2; exit 1; }
ok()   { printf '\e[32mOK\e[0m     %s\n' "$*"; }
info() { printf '\e[36mINFO\e[0m   %s\n' "$*"; }

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TOP=$(cd -- "$HERE/.." && pwd)
BUILD_DIR=${PYRA_BUILD_DIR:-$(cd -- "$TOP/.." && pwd)/dragonbox-pyra-build}
WRITE=$HERE/pyra-image-write.sh

IMG=${1:-}
HOST=${2:-${PYRA_WRITER:-}}
if [[ -z $IMG ]]; then
    IMG=$(ls -1t "$BUILD_DIR"/images/pyra-trixie-prepped-*.img 2>/dev/null | head -1) ||
        true
    [[ -n $IMG ]] || die "no pyra-trixie-prepped-*.img in $BUILD_DIR/images; build one with pyra-image-build.sh"
fi
[[ -n $HOST ]] || die "no host: pass user@host, or set PYRA_WRITER (pyra-local.conf)"
[[ -r $IMG ]] || die "no image at $IMG"
BASE=${IMG%.img}
NAME=$(basename "$IMG")
for f in "$BASE.sha256" "$WRITE"; do [[ -r $f ]] || die "missing $f"; done
SENDS=("$IMG" "$BASE.sha256" "$WRITE")
[[ -r $BASE.info ]] && SENDS+=("$BASE.info")

info "checking $NAME before sending"
( cd "$(dirname "$IMG")" && sha256sum -c --quiet "$(basename "$BASE.sha256")" ) || die "$NAME does not match its .sha256"
info "sending to $HOST:pyra-images/"
ssh "$HOST" 'mkdir -p ~/pyra-images'
rsync --sparse --partial --progress --chmod=F644 "${SENDS[@]}" "$HOST:pyra-images/"
ssh "$HOST" 'chmod 755 ~/pyra-images/pyra-image-write.sh'
info "verifying on $HOST"
ssh "$HOST" "cd ~/pyra-images && sha256sum -c --quiet '$(basename "$BASE.sha256")'" ||
    die "the copy on $HOST does not match; push again"
ok "$NAME is on $HOST and matches"
info "on $HOST:  cd ~/pyra-images && sudo ./pyra-image-write.sh $NAME /dev/sdX"
