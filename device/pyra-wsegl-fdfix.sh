#!/bin/sh
# pyra-wsegl-fdfix.sh: patch the SGX driver's X11 window system (/lib/libpvrDRI3WSEGL.so) so it stops
# closing a descriptor it no longer owns. Shipwright report 10 §10.7.
#
# The bug: buffer creation exports each buffer as a dma-buf (PRIME_HANDLE_TO_FD), keeps the number in
# the buffer (offset 0x10), and passes it to xcb_dri3_pixmap_from_buffer_checked, which sends it to X
# and closes it: libxcb owns a descriptor once it is passed. Buffer destruction (0x1548) then calls
# close() on the stored number again. Whatever file was handed that number in between loses its
# descriptor: SoH's log in nearly every run, and once a save file (the logger's next write landed in it).
#
# The fix: the second close() becomes two Thumb NOPs (its result is unused). xcb's close is the only
# one left; a running game holds a flat descriptor count with no dma-buf descriptors piling up.
#
#   sudo pyra-wsegl-fdfix.sh install     patch, keeping the stock file as libpvrDRI3WSEGL.so.stock
#   sudo pyra-wsegl-fdfix.sh rollback    put the stock file back, and keep it (see below)
#   pyra-wsegl-fdfix.sh status
#   pyra-wsegl-fdfix.sh --root DIR ...   the same, on the image mounted at DIR (prep's fix 21)
#
# The file is replaced by rename, never written in place: running programs have it mapped. Programs
# started afterwards get the fix; restart the desktop session (or reboot) for the ones already running.
#
# A package run that reinstalls dri3wsegl-pyra puts the stock file back; pyra-wsegl-guard, a dpkg
# hook, then runs install again. rollback leaves /var/lib/pyra-wsegl-fdfix/rolled-back so the guard
# leaves a rolled-back machine alone; install removes it. (Not beside the library: ldconfig warns about
# an empty file in /usr/lib on every libc trigger.)
#
# The path is dpkg's (dri3wsegl-pyra 0.4); /lib links to usr/lib. Under --root the file is taken
# from DIR/usr/lib, never through DIR/lib, and a symlink is refused: either could lead off the image.
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
for f in "$LIB" "$STOCK" "$MARKDIR" "$MARK" "$LIB.fdfix.tmp" "$LIB.rollback.tmp"; do
    [ ! -L "$f" ] || { echo "${f#"$ROOT"} is a symlink; not touching it" >&2; exit 1; }
done
[ -f "$LIB" ] || { echo "no $NAME${ROOT:+ under $ROOT}" >&2; exit 1; }
SHA_STOCK=d852ce4d093ac6e80c7f9b2d9468a1a46e13b2a8de6d59075e0707884ee6daa0
SHA_FIXED=e431a3071009ae3022a07d7df6346ea31de1a27bdc02bd5263505d90b21b3f90

sha() { sha256sum "$1" | cut -d' ' -f1; }

state() {
    case "$(sha "$LIB")" in
    "$SHA_STOCK") echo stock ;;
    "$SHA_FIXED") echo fixed ;;
    *) echo unknown ;;
    esac
}

case "${1:-status}" in
status)
    echo "$NAME: $(state)"
    if [ -e "$STOCK" ]; then
        echo "$NAME.stock: $( [ "$(sha "$STOCK")" = "$SHA_STOCK" ] && echo stock || echo unknown)"
    fi
    if [ -e "$MARK" ]; then
        echo "rolled back on purpose: pyra-wsegl-guard will not re-patch (install undoes this)"
    fi
    ;;
install)
    s=$(state)
    [ "$s" = fixed ] && { rm -f "$MARK"; echo "already patched"; exit 0; }
    [ "$s" = stock ] || { echo "$NAME is not the known stock build (sha256 $(sha "$LIB")); not touching it" >&2; exit 1; }
    [ -e "$STOCK" ] || cp -p "$LIB" "$STOCK"
    tmp=$LIB.fdfix.tmp
    cp -p "$LIB" "$tmp"
    # 0x1548: blx close@plt (f7ff ef0c) -> nop; nop (bf00 bf00). The first LOAD maps offset 0 at vaddr 0.
    [ "$(od -An -tx1 -j $((0x1548)) -N4 "$tmp" | tr -d ' \n')" = fff70cef ] || { rm -f "$tmp"; echo "unexpected bytes at 0x1548" >&2; exit 1; }
    printf '\000\277\000\277' | dd of="$tmp" bs=1 seek=$((0x1548)) conv=notrunc status=none
    [ "$(sha "$tmp")" = "$SHA_FIXED" ] || { rm -f "$tmp"; echo "patched file has the wrong sha256" >&2; exit 1; }
    mv "$tmp" "$LIB"
    rm -f "$MARK"
    echo "patched; stock kept as $NAME.stock. Programs started from now on get the fix."
    ;;
rollback)
    [ -e "$STOCK" ] && [ "$(sha "$STOCK")" = "$SHA_STOCK" ] || { echo "no verified $NAME.stock" >&2; exit 1; }
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
