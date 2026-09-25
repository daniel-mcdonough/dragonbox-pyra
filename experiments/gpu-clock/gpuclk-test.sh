#!/bin/sh
# Fill rate with the GPU on its current source (DPLL_CORE H14), then on DPLL_PER H14 (384 MHz),
# then back. A watchdog restores the core source after 150 s whatever happens to this script.
set -u
cd "$(dirname "$0")"
export SDL_VIDEO_X11_FORCE_EGL=1 SDL_VIDEO_GL_DRIVER=/opt/omap5-sgx-ddk-um-linux/lib/libGLESv2.so.1 DISPLAY=:0
FILL=$HOME/pyra-probe/fill

temps() { echo "temps cpu/gpu/core: $(cat /sys/class/thermal/thermal_zone0/temp) $(cat /sys/class/thermal/thermal_zone1/temp) $(cat /sys/class/thermal/thermal_zone2/temp)"; }
fills() {
  for args in "1280 720 8" "640 360 8" "1280 720 2"; do
    timeout 20 "$FILL" $args 2>&1 | grep -E "Mpix|shader|rror" || echo "fill $args: no result (exit $?)"
  done
}

sudo python3 ./gpumux.py get
( sleep 150; sudo python3 ./gpumux.py set core; echo "WATCHDOG restored core source" ) &
WD=$!

echo "== baseline"; temps; fills
echo "== switch to per"; sudo python3 ./gpumux.py set per; sudo python3 ./gpumux.py get; temps
fills; temps
echo "== switch back to core"; sudo python3 ./gpumux.py set core; sudo python3 ./gpumux.py get
fills; temps
kill $WD 2>/dev/null
sudo python3 ./gpumux.py get
