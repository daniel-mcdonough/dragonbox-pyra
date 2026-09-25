#!/bin/sh
# Stock pvrsrvkm against the one with 0034 (pvrsrvkm-apm.ko, from build-module.sh), both
# loaded: at desktop idle, and under Ship of Harkinian's Market fixture at its 30 fps cap.
# Runs on the device with sudo, on battery; it waits for bq24297/online to read 0.
#   sudo ./apmcompare.sh          about 22 min
#   sudo ./apmcompare.sh soh      the game half only, about 11 min
# Output: apmcompare.csv (sample.py), apmcompare.log (phases), apmcompare-soh-<n>-<arm>.log
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
MOD=pvrsrvkm_omap5_sgx544_116
FIXED=$DIR/pvrsrvkm-apm.ko
SOH=/home/pyra/soh-bench2
CPU=/sys/devices/system/cpu
PHASE=$DIR/apmcompare.phase
LOG=$DIR/apmcompare.log
GOV0=$(cat $CPU/cpu0/cpufreq/scaling_governor)
SAMPLER= AWAKE=

matches() { dmesg | grep -c "KM DDK-.*match"; }
# Swap the loaded module for the named arm and make sure the user-space half of the
# driver initialised: the udev rule that runs pvrsrvctl races the probe and loses about
# half the time, with the stock module as well as the fixed one.
#
# The game takes several seconds to exit and holds the module until it has. The first run
# of this script swapped after 2 s, every game-block swap failed with "in use", and all four
# game blocks ran the stock module. So wait for the game and the refcount, and check what
# is loaded afterwards: the fixed module is unsigned, so its taint reads E.
use() {
  pkill -x soh.elf 2>/dev/null
  i=0; while pgrep -x soh.elf >/dev/null && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
  pkill -9 -x soh.elf 2>/dev/null
  i=0; while [ -d /sys/module/$MOD ] && [ "$(cat /sys/module/$MOD/refcnt)" != 0 ] && [ $i -lt 30 ]; do
    sleep 1; i=$((i+1)); done
  [ -d /sys/module/$MOD ] && { modprobe -r $MOD || rmmod $MOD; }
  before=$(matches)
  if [ "$1" = fixed ]; then insmod "$FIXED"; else modprobe $MOD; fi
  sleep 4
  [ "$(matches)" -gt "$before" ] || /opt/omap5-sgx-ddk-um-linux/bin/pvrsrvctl --start --no-module
  [ "$(matches)" -gt "$before" ] || echo "$(date +%s) INIT-FAILED $1" >> "$LOG"
  case "$1:$(cat /sys/module/$MOD/taint 2>/dev/null)" in
    fixed:*E*|stock:) ;;
    *) echo "$(date +%s) WRONG-MODULE wanted $1" >> "$LOG" ;;
  esac
}
soh() {
  cd "$SOH"
  sudo -u pyra env SDL_VIDEO_X11_FORCE_EGL=1 SDL_VIDEO_GL_DRIVER=/opt/omap5-sgx-ddk-um-linux/lib/libGLESv2.so.1 DISPLAY=:0 \
    SOH_BENCH=1 SOH_BENCH_ENTRANCE=0x00B1 \
    SOH_BENCH_POS=-122.7,0.0,72.1 SOH_BENCH_YAW=0xD5A6 SOH_BENCH_EYE=0.0,64.0,0.0 \
    SOH_BENCH_AT=-134.5,64.0,79.0 SOH_BENCH_SETTLE=400 SOH_BENCH_STATIC=0 SOH_BENCH_UNCAP=0 \
    SOH_BENCH_FRAMES=100000 SOH_BENCH_SPLIT=100 SOH_BENCH_EXIT=0 \
    nohup ./soh.elf > "$1" 2>&1 < /dev/null &
  cd "$DIR"
}
restore() {
  pkill -x soh.elf 2>/dev/null; sleep 2; pkill -9 -x soh.elf 2>/dev/null
  use stock
  for p in $CPU/cpu*/cpufreq; do [ -e $p/scaling_governor ] && echo $GOV0 > $p/scaling_governor; done
  [ -n "$SAMPLER$AWAKE" ] && kill $SAMPLER $AWAKE 2>/dev/null
  echo "$(date +%s) done, stock module back, gov=$GOV0" >> "$LOG"
}
trap restore EXIT
trap 'exit 1' INT TERM HUP
phase() { echo "$1" > "$PHASE"; echo "$(date +%s) $1" >> "$LOG"; }

[ -f "$FIXED" ] || { echo "no $FIXED"; exit 1; }
: > "$LOG"; phase start
python3 "$DIR/sample.py" "$DIR/apmcompare.csv" "$PHASE" &
SAMPLER=$!
X="sudo -u pyra env DISPLAY=:0 xset"
( while :; do
    $X s reset 2>/dev/null
    $X q 2>/dev/null | grep -q "Monitor is Off" && echo "$(date +%s) MONITOR-OFF" >> "$LOG"
    sleep 20
  done ) &
AWAKE=$!

phase wait-unplug
while [ "$(cat /sys/class/power_supply/bq24297/online)" = 1 ]; do sleep 2; done
for p in $CPU/cpu*/cpufreq; do
  [ -e $p/scaling_governor ] || continue
  echo userspace > $p/scaling_governor; echo 1000000 > $p/scaling_setspeed
done
sleep 20

# 1. Desktop idle, ABBA twice, 75 s blocks.
[ "${1:-}" = soh ] || for a in stock fixed fixed stock stock fixed fixed stock; do
  use $a; phase "idle-$a"; sleep 75
done

# 2. The game, ABBA once, 150 s per arm, the game restarted in each.
n=0
for a in stock fixed fixed stock; do
  n=$((n+1)); use $a; phase "soh-$a"; soh "$DIR/apmcompare-soh-$n-$a.log"; sleep 150
done
phase end
