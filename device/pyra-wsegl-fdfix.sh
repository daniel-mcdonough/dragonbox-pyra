#!/bin/sh
# pyra-wsegl-fdfix.sh: patch the SGX driver's X11 window system (/lib/libpvrDRI3WSEGL.so) so it stops
# closing a descriptor it no longer owns. Shipwright report 10 §10.7.
#
# The bug: buffer creation exports each buffer as a dma-buf (PRIME_HANDLE_TO_FD), keeps the number in
# the buffer (offset 0x10), and passes it to xcb_dri3_pixmap_from_buffer_checked, which sends it to X
# and closes it: libxcb owns a descriptor once it is passed. Buffer destruction (destroy_buffer,
# dri3_ws.c:324) then calls close() on the stored number again. Whatever file was handed that number in
# between loses its descriptor: SoH's log in nearly every run, and once a save file (the logger's next
# write landed in it). mupen64plus lost PulseAudio's wakeup pipe.
#
# The fix: the second close() becomes two Thumb NOPs (its result is unused). xcb's close is the only
# one left; a running game holds a flat descriptor count with no dma-buf descriptors piling up.
#
# The builds it knows (BUILDS below), each disassembled against its dbgsym package: the close is the
# blx after PVRSRVUnmapDmaBuf in destroy_buffer, its stub resolves to close@GLIBC_2.4, and r0 is
# reloaded right after it. In every build the first LOAD maps offset 0 at vaddr 0, so the file offset
# is the address. bookworm's and bullseye's 0.5 come from the same source but are different builds.
#
#   sudo pyra-wsegl-fdfix.sh install     patch, keeping the stock file as libpvrDRI3WSEGL.so.stock
#   sudo pyra-wsegl-fdfix.sh rollback    put the stock file back, and keep it (see below)
#   pyra-wsegl-fdfix.sh status
#   pyra-wsegl-fdfix.sh --root DIR ...   the same, on the image mounted at DIR (prep's fix 21)
#
# The file is replaced by rename, never written in place: running programs have it mapped. Programs
# started afterwards get the fix; restart the desktop session (or reboot) for the ones already running.
#
# .stock is always the stock copy of the build that is installed: install refreshes it when a package
# brought a different known build (0.4 replaced by 0.5), and rollback refuses a .stock of another build,
# which would put a library under a package it did not come from.
#
# A package run that reinstalls dri3wsegl-pyra puts the stock file back; pyra-wsegl-guard, a dpkg
# hook, then runs install again. rollback leaves /var/lib/pyra-wsegl-fdfix/rolled-back so the guard
# leaves a rolled-back machine alone; install removes it. (Not beside the library: ldconfig warns about
# an empty file in /usr/lib on every libc trigger.)
#
# The path is dpkg's (dri3wsegl-pyra); /lib links to usr/lib. Under --root the file is taken from
# DIR/usr/lib, never through DIR/lib, and a symlink is refused: either could lead off the image.
set -eu
ROOT=
if [ "${1:-}" = --root ]; then
    [ $# -ge 2 ] || { echo "--root needs a directory" >&2; exit 2; }
    ROOT=${2%/}
    shift 2
    [ -d "$ROOT/usr/lib" ] || { echo "$ROOT/usr/lib is not a directory; is the image mounted there?" >&2; exit 2; }
fi
NAME=/usr/lib/libpvrDRI3WSEGL.so
LIB=$ROOT$NAME
STOCK=$LIB.stock
MARKDIR=$ROOT/var/lib/pyra-wsegl-fdfix
MARK=$MARKDIR/rolled-back
for f in "$LIB" "$STOCK" "$MARKDIR" "$MARK" "$LIB.fdfix.tmp" "$LIB.stock.tmp" "$LIB.rollback.tmp"; do
    [ ! -L "$f" ] || { echo "${f#"$ROOT"} is a symlink; not touching it" >&2; exit 1; }
done
[ -f "$LIB" ] || { echo "no $NAME${ROOT:+ under $ROOT}" >&2; exit 1; }

# build         stock sha256                                                     fixed sha256                                                     close   stock bytes (blx close@plt)
BUILDS='
0.4-trixie      d852ce4d093ac6e80c7f9b2d9468a1a46e13b2a8de6d59075e0707884ee6daa0 e431a3071009ae3022a07d7df6346ea31de1a27bdc02bd5263505d90b21b3f90 0x1548 fff70cef
0.5-bookworm    1b3fa32673ab4ebcb2b59c9d360102882cb3decae73a7eb3a83bab930dbf6a64 52922bcb656ac2b7346ed9c52f1a80950a0de44c8e8c8ba816dbea768bb86c20 0x165e fff766ee
0.5-bullseye    8e37577c893f299c0ef4aee97310647e290a69c27b7d3233e95000dc1dd3bdeb 2ac44d73211b5aa5aafc4c836bd2ff787bcf18040efbf1b906c4545536a55596 0x1662 fff764ee
'

sha() { sha256sum "$1" | cut -d' ' -f1; }

# The BUILDS row and the state (stock or fixed) of a file, or nothing for a build the script does not know.
lookup() {
    s=$(sha "$1")
    printf '%s' "$BUILDS" | while read -r b st fx off by; do
        [ -n "$b" ] || continue
        [ "$s" = "$st" ] && { echo "stock $b $st $fx $off $by"; break; }
        [ "$s" = "$fx" ] && { echo "fixed $b $st $fx $off $by"; break; }
    done || :   # no match leaves the loop's status non-zero, which set -e would act on inside $(...)
}

state() { r=$(lookup "$1"); echo "${r%% *}" | sed 's/^$/unknown/'; }
build() { r=$(lookup "$1"); set -- $r; echo "${2:-}"; }

case "${1:-status}" in
status)
    echo "$NAME: $(state "$LIB")"
    if [ -e "$STOCK" ]; then
        echo "$NAME.stock: $( [ "$(state "$STOCK")" = stock ] && echo stock || echo unknown)"
        b=$(build "$LIB"); bs=$(build "$STOCK")
        if [ -n "$b" ] && [ -n "$bs" ] && [ "$b" != "$bs" ]; then
            echo "the library is dri3wsegl-pyra $b, but .stock is $bs: $( [ "$(state "$LIB")" = stock ] \
                && echo "install refreshes it" || echo "rollback refuses it until the $b package is reinstalled")"
        fi
    fi
    if [ -e "$MARK" ]; then
        echo "rolled back on purpose: pyra-wsegl-guard will not re-patch (install undoes this)"
    fi
    ;;
install)
    set -- $(lookup "$LIB")
    [ "${1:-}" = fixed ] && { rm -f "$MARK"; echo "already patched"; exit 0; }
    [ "${1:-}" = stock ] || { echo "$NAME is not a known stock build (sha256 $(sha "$LIB")); not touching it" >&2; exit 1; }
    b=$2 fx=$4 off=$5 by=$6
    if [ ! -e "$STOCK" ] || [ "$(sha "$STOCK")" != "$3" ]; then
        cp -p "$LIB" "$LIB.stock.tmp"
        mv "$LIB.stock.tmp" "$STOCK"
    fi
    tmp=$LIB.fdfix.tmp
    cp -p "$LIB" "$tmp"
    # destroy_buffer: blx close@plt -> nop; nop (bf00 bf00).
    [ "$(od -An -tx1 -j $((off)) -N4 "$tmp" | tr -d ' \n')" = "$by" ] || { rm -f "$tmp"; echo "unexpected bytes at $off" >&2; exit 1; }
    printf '\000\277\000\277' | dd of="$tmp" bs=1 seek=$((off)) conv=notrunc status=none
    [ "$(sha "$tmp")" = "$fx" ] || { rm -f "$tmp"; echo "patched file has the wrong sha256" >&2; exit 1; }
    mv "$tmp" "$LIB"
    rm -f "$MARK"
    echo "patched dri3wsegl-pyra $b; stock kept as $NAME.stock. Programs started from now on get the fix."
    ;;
rollback)
    [ -e "$STOCK" ] && [ "$(state "$STOCK")" = stock ] || { echo "no verified $NAME.stock" >&2; exit 1; }
    b=$(build "$LIB"); bs=$(build "$STOCK")
    [ "$b" = "$bs" ] || { echo "$NAME.stock is dri3wsegl-pyra $bs, but the installed library is ${b:-a build this script does not know}; not restoring it" >&2; exit 1; }
    cp -p "$STOCK" "$LIB.rollback.tmp"
    mv "$LIB.rollback.tmp" "$LIB"
    mkdir -p "$MARKDIR"
    : > "$MARK"
    echo "stock restored"
    ;;
*)
    echo "usage: $0 [--root DIR] install|rollback|status" >&2
    exit 2
    ;;
esac
