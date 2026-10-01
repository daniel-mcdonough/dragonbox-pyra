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
#   sudo pyra-wsegl-fdfix.sh rollback    put the stock file back
#   pyra-wsegl-fdfix.sh status
#
# The file is replaced by rename, never written in place: running programs have it mapped. Programs
# started afterwards get the fix; restart the desktop session (or reboot) for the ones already running.
set -eu
LIB=/lib/libpvrDRI3WSEGL.so
STOCK=$LIB.stock
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
    echo "$LIB: $(state)"
    [ -e "$STOCK" ] && echo "$STOCK: $( [ "$(sha "$STOCK")" = "$SHA_STOCK" ] && echo stock || echo unknown)"
    ;;
install)
    s=$(state)
    [ "$s" = fixed ] && { echo "already patched"; exit 0; }
    [ "$s" = stock ] || { echo "$LIB is not the known stock build (sha256 $(sha "$LIB")); not touching it" >&2; exit 1; }
    [ -e "$STOCK" ] || cp -p "$LIB" "$STOCK"
    tmp=$LIB.fdfix.tmp
    cp -p "$LIB" "$tmp"
    # 0x1548: blx close@plt (f7ff ef0c) -> nop; nop (bf00 bf00). The first LOAD maps offset 0 at vaddr 0.
    [ "$(od -An -tx1 -j $((0x1548)) -N4 "$tmp" | tr -d ' \n')" = fff70cef ] || { rm -f "$tmp"; echo "unexpected bytes at 0x1548" >&2; exit 1; }
    printf '\000\277\000\277' | dd of="$tmp" bs=1 seek=$((0x1548)) conv=notrunc status=none
    [ "$(sha "$tmp")" = "$SHA_FIXED" ] || { rm -f "$tmp"; echo "patched file has the wrong sha256" >&2; exit 1; }
    mv "$tmp" "$LIB"
    echo "patched; stock kept as $STOCK. Programs started from now on get the fix."
    ;;
rollback)
    [ -e "$STOCK" ] && [ "$(sha "$STOCK")" = "$SHA_STOCK" ] || { echo "no verified $STOCK" >&2; exit 1; }
    cp -p "$STOCK" "$LIB.rollback.tmp"
    mv "$LIB.rollback.tmp" "$LIB"
    echo "stock restored"
    ;;
*)
    echo "usage: $0 install|rollback|status" >&2
    exit 2
    ;;
esac
