#!/bin/sh
# Item F's whole chain on the panel: one VT switch away from X, `kmsprobe chain plane` (SGX frame -> dma-buf ->
# GC320 clockwise rotate -> 360x640 omapdrm bo on a plane scaled 2x), and back to VT 7 whatever happens. The
# probe exits (giving up master) before the switch back: X cannot take master back from a live holder.
# Usage: chaintest.sh [SECS] [LOAD] [SYNC]. What to see: the colour cycling about once a second (60 frames),
# and a green block in the panel corner that is top-left when the Pyra is held as a landscape handheld.
SECS=${1:-8}; LOAD=${2:-200}; SYNC=${3:-none}
cd ~/kmsprobe
back() { sudo pkill -x kmsprobe; sleep 1; sudo chvt 7; }
trap back EXIT INT TERM
sudo dmesg -C
sudo chvt 2; sleep 2
E="LD_LIBRARY_PATH=$HOME/kmsprobe/tigbm GBM_BACKEND=/opt/omap5-sgx-ddk-um-linux/lib/libpvrGBMWSEGL.so.1"
sudo env $E KMSPROBE_LOAD=$LOAD timeout $((SECS + 20)) ./kmsprobe chain plane $SECS $SYNC > chain.txt 2>&1 &
sleep 3
echo "=== plane state mid-run"
sudo grep -A14 -E "^plane\[" /sys/kernel/debug/dri/0/state | grep -E "^plane|crtc=|fb=|crtc-pos|src-pos|rotation|size=" | grep -B1 -A5 "crtc=crtc" | head -30
wait
grep -v -E "^plane [0-9]* type|^(EGL|GL) extensions" chain.txt
back; trap - EXIT
sleep 3
echo "=== after: dmesg"; sudo dmesg | grep -v "dmtimer posted" | tail -15
sudo fgconsole
