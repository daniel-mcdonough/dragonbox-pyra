#!/bin/sh
# One VT switch away from X, the plane tests, and back to VT 7 whatever happens. Each probe exits (and
# so gives up master) before the switch back: X cannot take master back from a live holder.
cd ~/kmsprobe
back() { sudo pkill -x kmsprobe; sleep 1; sudo chvt 7; }
trap back EXIT INT TERM
sudo dmesg -C
sudo chvt 2; sleep 2
E="LD_LIBRARY_PATH=$HOME/kmsprobe/tigbm GBM_BACKEND=/opt/omap5-sgx-ddk-um-linux/lib/libpvrGBMWSEGL.so.1"
for t in "dumb 1" "dumb 8" "tiled 8" "egl 1" "egl 8"; do
  echo "=== $t"
  sudo env $E timeout 20 ./kmsprobe plane $t 4 > run.txt 2>&1 &
  sleep 2.5
  sudo sed -n '/^plane\[37\]/,/^plane\[42\]/p' /sys/kernel/debug/dri/0/state | grep -E "crtc=|fb=|crtc-pos|src-pos|rotation|size=|modifier"
  wait
  grep -v -E "^plane [0-9]* type|^(EGL|GL) extensions" run.txt
done
back; trap - EXIT
sleep 3
echo "=== after: dmesg"; sudo dmesg | grep -v "dmtimer posted" | tail -15
echo "=== X plane-0"; sudo sed -n '/^plane\[32\]/,/^plane\[37\]/p' /sys/kernel/debug/dri/0/state | grep -E "fb=|crtc-pos|allocated"
sudo cat /sys/kernel/debug/dri/0/clients
sudo fgconsole
