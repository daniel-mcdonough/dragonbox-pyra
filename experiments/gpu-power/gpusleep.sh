#!/bin/sh
# Suspend and resume with the fixed pvrsrvkm (0034), against the stock one as a baseline,
# using device/pyra-sleep-test.sh (RTC wake, freeze then mem) for each suspend.
# Runs on the device with sudo, detached, since wifi goes down with each suspend:
#   sudo setsid nohup ./gpusleep.sh > gpusleep.out 2>&1 < /dev/null &
# Result: gpusleep.log, and the sleep test's own log for each case as sleep-<case>.log.
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
MOD=pvrsrvkm_omap5_sgx544_116
FIXED=$DIR/pvrsrvkm-apm.ko
LOG=$DIR/gpusleep.log
GLENV="SDL_VIDEO_X11_FORCE_EGL=1 SDL_VIDEO_GL_DRIVER=/opt/omap5-sgx-ddk-um-linux/lib/libGLESv2.so.1 DISPLAY=:0"
FILL=/home/pyra/pyra-probe/fill
say() { echo "$(date +%s) $*" >> "$LOG"; }
matches() { dmesg | grep -c "KM DDK-.*match"; }
errs() { dmesg | grep -ciE "l3_custom|l3_interrupt|external abort|PVR_K:\(Error|HWRecovery|lockup"; }

use() {
  i=0; while [ "$(cat /sys/module/$MOD/refcnt 2>/dev/null || echo 0)" != 0 ] && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
  [ -d /sys/module/$MOD ] && { modprobe -r $MOD || rmmod $MOD; }
  before=$(matches)
  if [ "$1" = fixed ]; then insmod "$FIXED"; else modprobe $MOD; fi
  sleep 4
  [ "$(matches)" -gt "$before" ] || /opt/omap5-sgx-ddk-um-linux/bin/pvrsrvctl --start --no-module
  say "loaded $1: taint='$(cat /sys/module/$MOD/taint)' init=$([ "$(matches)" -gt "$before" ] && echo ok || echo FAILED)"
}
state() {
  D=/sys/bus/platform/devices/56000000.gpu/power
  s=$(python3 -c '
import mmap,os,struct
fd=os.open("/dev/mem",os.O_RDONLY|os.O_SYNC)
m=mmap.mmap(fd,4096,mmap.MAP_SHARED,mmap.PROT_READ,offset=0x4AE07000)
print(["OFF","RET","INACTIVE","ON"][struct.unpack("<I",m[0x504:0x508])[0]&3])')
  say "  $1: rpm=$(cat $D/runtime_status) usage=$(cat $D/runtime_usage) pd_gpu=$s errors=$(errs)"
}
glcheck() {
  out=$(sudo -u pyra env $GLENV timeout 15 $FILL 1280 720 8 2>&1 | tail -1)
  say "  GL after resume: $out"
  sleep 1; state "$1 +1s"
}
sleeptest() {
  "$DIR/pyra-sleep-test.sh" --seconds 20 > /dev/null 2>&1; rc=$?
  cp /var/log/pyra-sleep-test.log "$DIR/sleep-$1.log"
  say "  sleep test rc=$rc: $(grep '^RESULT' /var/log/pyra-sleep-test.log | tr '\n' ' ')"
}

: > "$LOG"
say "start, errors so far=$(errs)"
for c in stock fixed-idle fixed-gl; do
  say "=== $c"
  case $c in stock) use stock ;; fixed-idle) use fixed ;; esac
  sleep 3; state before
  GL=
  if [ $c = fixed-gl ]; then
    sudo -u pyra env $GLENV sh -c "while :; do $FILL 1280 720 8; done" > "$DIR/gl-loop.out" 2>&1 &
    GL=$!; sleep 3; state "rendering"
  fi
  sleeptest $c
  if [ -n "$GL" ]; then
    sleep 3; state "rendering after resume"
    say "  fill runs during the case: $(grep -c Mpix "$DIR/gl-loop.out"), last: $(grep Mpix "$DIR/gl-loop.out" | tail -1)"
    pkill -f "while :; do $FILL" ; pkill -x fill; sleep 2
  fi
  glcheck $c
done
use stock
say "done, errors=$(errs)"
