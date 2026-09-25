#!/bin/sh
# Where does the power go while SoH runs? Runs entirely on the device so that dropping USB
# networking (to get the gauge off USB power) does not stop it. Needs the machine on battery.
# Output: thermcost.csv (one row a second) and thermcost.log (phase changes).
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
PS=/sys/class/power_supply/bq27421-0
CPU=/sys/devices/system/cpu/cpu0/cpufreq
BL=/sys/class/backlight/backlight/brightness
KBL=/sys/class/backlight/keyboard-backlight/brightness
CSV=$DIR/thermcost.csv
LOG=$DIR/thermcost.log
PHASE=start

BL0=$(cat $BL); KBL0=$(cat $KBL); GOV0=$(cat $CPU/scaling_governor)
restore() {
  pkill -x soh.elf 2>/dev/null; sleep 3; pkill -9 -x soh.elf 2>/dev/null
  for p in /sys/devices/system/cpu/cpu*/cpufreq; do
    [ -e "$p/scaling_governor" ] || continue
    sudo sh -c "echo $GOV0 > $p/scaling_governor"
  done
  sudo sh -c "echo $BL0 > $BL"; sudo sh -c "echo $KBL0 > $KBL"
  kill "$SAMPLER" 2>/dev/null
  echo "$(date +%s) done, restored gov=$GOV0 bl=$BL0 kbl=$KBL0" >> "$LOG"
}
trap restore EXIT INT TERM

phase() { PHASE=$1; echo "$PHASE" > "$DIR/thermcost.phase"; echo "$(date +%s) $PHASE" >> "$LOG"; }
setspeed() {
  for p in /sys/devices/system/cpu/cpu*/cpufreq; do
    [ -e "$p/scaling_governor" ] || continue
    sudo sh -c "echo userspace > $p/scaling_governor; echo $1 > $p/scaling_setspeed"
  done
}
ondemand() {
  for p in /sys/devices/system/cpu/cpu*/cpufreq; do
    [ -e "$p/scaling_governor" ] || continue
    sudo sh -c "echo ondemand > $p/scaling_governor"
  done
}

: > "$LOG"
echo "t,phase,current_ua,voltage_uv,cpu_mc,gpu_mc,core_mc,batt_dc,cur_khz,bl,kbl,online" > "$CSV"
phase start
(
  while :; do
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date +%s)" "$(cat "$DIR/thermcost.phase")" \
      "$(cat $PS/current_now)" "$(cat $PS/voltage_now)" \
      "$(cat /sys/class/thermal/thermal_zone0/temp)" "$(cat /sys/class/thermal/thermal_zone1/temp)" \
      "$(cat /sys/class/thermal/thermal_zone2/temp)" "$(cat $PS/temp)" "$(cat $CPU/scaling_cur_freq)" \
      "$(cat $BL)" "$(cat $KBL)" "$(cat /sys/class/power_supply/bq24297/online)" >> "$CSV"
    sleep 1
  done
) &
SAMPLER=$!

# Wait for the cable to come out rather than measuring a charger.
phase wait-unplug
while [ "$(cat /sys/class/power_supply/bq24297/online)" = 1 ]; do sleep 2; done
sleep 20

# 1. Idle floor: desktop, screen as the user has it, governor as shipped.
ondemand
phase idle-ondemand;  sleep 150
setspeed 1250000
phase idle-1250;      sleep 90

# 2. The game: Market fixture, logic running, 30 fps cap, 1250 MHz.
setspeed 1250000
cd "$DIR"
SDL_VIDEO_X11_FORCE_EGL=1 SDL_VIDEO_GL_DRIVER=/opt/omap5-sgx-ddk-um-linux/lib/libGLESv2.so.1 DISPLAY=:0 \
  SOH_BENCH=1 SOH_BENCH_OUT="$DIR/thermcost-bench.txt" SOH_BENCH_ENTRANCE=0x00B1 \
  SOH_BENCH_POS=-122.7,0.0,72.1 SOH_BENCH_YAW=0xD5A6 SOH_BENCH_EYE=0.0,64.0,0.0 \
  SOH_BENCH_AT=-134.5,64.0,79.0 SOH_BENCH_SETTLE=400 SOH_BENCH_STATIC=0 SOH_BENCH_UNCAP=0 \
  SOH_BENCH_FRAMES=100000 SOH_BENCH_SPLIT=100 SOH_BENCH_EXIT=0 \
  nohup ./soh.elf > "$DIR/thermcost-run.log" 2>&1 < /dev/null &
phase soh-warm;       sleep 240

# 3. CPU clock, ABBA in 60 s blocks. Both arms hold 30 fps in this fixture.
for f in 1000000 1500000 1500000 1000000 1000000 1500000 1500000 1000000; do
  setspeed $f; phase "soh-cpu-$((f/1000))"; sleep 60
done
setspeed 1250000

# 4. Screen backlight: 1 against 15, ABBA.
for b in 1 15 15 1; do
  sudo sh -c "echo $b > $BL"; phase "soh-bl-$b"; sleep 60
done
sudo sh -c "echo $BL0 > $BL"

# 5. Keyboard backlight: off against full, ABBA.
for k in 0 8 8 0; do
  sudo sh -c "echo $k > $KBL"; phase "soh-kbl-$k"; sleep 60
done
sudo sh -c "echo $KBL0 > $KBL"

# 6. Game gone, machine hot: the idle floor again, to see what temperature alone costs.
pkill -x soh.elf; sleep 3; pkill -9 -x soh.elf
phase idle-hot-1250;  sleep 120
phase end
