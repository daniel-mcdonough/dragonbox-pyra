#!/bin/sh
# What does the stuck-on GPU cost at desktop idle? Upper bound, no build: with no GL
# client, unloading pvrsrvkm drops the probe-time runtime-PM reference that APM never can
# (docs/handoff/gpu-power-PROGRESS.md section 6), so PD_GPU is free to go OFF.
# Runs entirely on the device, run with sudo. It waits for the USB cable to come out,
# because the gauge only measures load on battery.
#   sudo ./gpuoff.sh            the ABBA measurement, about 14 min
#   sudo ./gpuoff.sh check      one unload/reload cycle, registers printed, no gauge
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
MOD=pvrsrvkm_omap5_sgx544_116
CPU=/sys/devices/system/cpu
PHASE=$DIR/gpuoff.phase
LOG=$DIR/gpuoff.log
GOV0=$(cat $CPU/cpu0/cpufreq/scaling_governor)
SAMPLER= AWAKE=

loaded()  { [ -d /sys/module/$MOD ]; }
unload()  { loaded && modprobe -r $MOD; }
load()    { loaded || modprobe $MOD; }
regs()    { python3 -c '
import mmap,os,struct
fd=os.open("/dev/mem",os.O_RDONLY|os.O_SYNC)
def rd(a):
    m=mmap.mmap(fd,4096,mmap.MAP_SHARED,mmap.PROT_READ,offset=a&~0xFFF); o=a&0xFFF
    return struct.unpack("<I",m[o:o+4])[0]
s=rd(0x4AE07504)
print("PWRSTST=%#x (%s) CLKSTCTRL=%#x CLKCTRL=%#x" % (s,["OFF","RET","INACTIVE","ON"][s&3],rd(0x4A009500),rd(0x4A009520)))'
    printf '  runtime_status=%s suspended_time=%s\n' \
      "$(cat /sys/bus/platform/devices/56000000.gpu/power/runtime_status)" \
      "$(cat /sys/bus/platform/devices/56000000.gpu/power/runtime_suspended_time)"; }
busy() { fuser -s /dev/dri/card2 /dev/dri/renderD130 /dev/pvrsrvkm 2>/dev/null; }

if [ "${1:-}" = check ]; then
  busy && { echo "the SGX is in use; close GL programs first"; exit 1; }
  echo "loaded:";   regs
  unload || exit 1; sleep 3
  echo "unloaded:"; regs
  load; sleep 2
  echo "reloaded:"; regs
  exit 0
fi

restore() {
  load
  for p in $CPU/cpu*/cpufreq; do [ -e $p/scaling_governor ] && echo $GOV0 > $p/scaling_governor; done
  [ -n "$SAMPLER$AWAKE" ] && kill $SAMPLER $AWAKE 2>/dev/null
  echo "$(date +%s) done, module loaded=$(loaded && echo 1 || echo 0), gov=$GOV0" >> "$LOG"
}
# A signal must end the run, not just restore and carry on without a sampler.
trap restore EXIT
trap 'exit 1' INT TERM HUP
phase() { echo "$1" > "$PHASE"; echo "$(date +%s) $1" >> "$LOG"; }

busy && { echo "the SGX is in use; close GL programs first"; exit 1; }
: > "$LOG"; phase start
python3 "$DIR/sample.py" "$DIR/gpuoff.csv" "$PHASE" &
SAMPLER=$!
# The first run lost its last block to MATE blanking the panel on battery after ten idle
# minutes, a 0.45 W step on its own. Reset X's idle timer every 20 s so that cannot
# happen, and log the monitor state so a run that still blanks says so.
X="sudo -u pyra env DISPLAY=:0 xset"
(
  while :; do
    $X s reset 2>/dev/null
    $X q 2>/dev/null | grep -q "Monitor is Off" && echo "$(date +%s) MONITOR-OFF" >> "$LOG"
    sleep 20
  done
) &
AWAKE=$!

phase wait-unplug
while [ "$(cat /sys/class/power_supply/bq24297/online)" = 1 ]; do sleep 2; done
sleep 30

# Pin the CPU so the governor cannot answer the change on its own
# (memory: pyra-thermal overrides min==max, so userspace + setspeed).
for p in $CPU/cpu*/cpufreq; do
  [ -e $p/scaling_governor ] || continue
  echo userspace > $p/scaling_governor; echo 1000000 > $p/scaling_setspeed
done

# ABBA, 90 s blocks: on = module loaded (GPU held ON), off = unloaded.
for s in on off off on on off off on; do
  if [ $s = on ]; then load; else unload; fi
  phase "gpu-$s"; sleep 90
done
phase end
