#!/bin/sh
# Where does the power go while SoH runs? Runs entirely on the device so that dropping USB
# networking (to get the gauge off USB power) does not stop it. Needs the machine on battery.
#
#   ./thermcost.sh [cost]   2026-09-25: idle floor, CPU clock 1000/1500, both backlights (README)
#   ./thermcost.sh clock    2026-09-26: the lowest clock that holds the game (Shipwright NEXT.md 0T):
#                           ABBA watts at 30 fps (1000/875/750) and 20 fps (750/625/500), then
#                           10-minute holds for die temperature
#   ./thermcost.sh twocore  2026-09-28: Shipwright report 11's GL thread (RenderThread 2) at 30/750
#                           and 30/625 against mode 0 at 30/750, 30/1000 and 20/625
#   ./thermcost.sh undervolt 2026-09-28: 30/750 in mode 2 (the build's default), the 750 MHz point at
#                           its table 950 mV against UV_MV (default 870), one process; needs
#                           experiments/undervolt's module and undervolt.sh in UV_DIR (~/undervolt)
#
# SOH_DIR: the SoH install to run (default: this script's directory). Output lands next to the
# script: thermcost[-MODE].csv (one row a second), .log (phase changes), -run*.log (the game's log,
# with a BENCH split line every 100 ticks: fps, render CPU, clock).
set -u
MODE=${1:-cost}
DIR=$(cd "$(dirname "$0")" && pwd)
SOH_DIR=${SOH_DIR:-$DIR}
PS=/sys/class/power_supply/bq27421-0
CPU=/sys/devices/system/cpu/cpu0/cpufreq
BL=/sys/class/backlight/backlight/brightness
# The keyboard backlight moved from the backlight class to leds in the kbdled kernels.
KBL=/sys/class/backlight/keyboard-backlight/brightness
[ -e "$KBL" ] || KBL=/sys/class/leds/pyra::kbd_backlight/brightness
SUF=; [ "$MODE" = cost ] || SUF=-$MODE
CSV=$DIR/thermcost$SUF.csv
LOG=$DIR/thermcost$SUF.log
CFG=$SOH_DIR/shipofharkinian.json
PHASE=start

BL0=$(cat $BL); KBL0=$(cat $KBL); GOV0=$(cat $CPU/scaling_governor)
# A killed run can leave the A/B CVar saved in the game's config: keep a copy to put back.
cp "$CFG" "$DIR/thermcost-cfg.json" 2>/dev/null
stop_soh() { pkill -x soh.elf 2>/dev/null; sleep 3; pkill -9 -x soh.elf 2>/dev/null; sleep 1; }
restore() {
  stop_soh
  for p in /sys/devices/system/cpu/cpu*/cpufreq; do
    [ -e "$p/scaling_governor" ] || continue
    sudo sh -c "echo $GOV0 > $p/scaling_governor"
  done
  sudo sh -c "echo $BL0 > $BL"; sudo sh -c "echo $KBL0 > '$KBL'"
  [ -e "$DIR/thermcost-cfg.json" ] && cp "$DIR/thermcost-cfg.json" "$CFG"
  kill "$SAMPLER" 2>/dev/null
  echo "$(date +%s) done, restored gov=$GOV0 bl=$BL0 kbl=$KBL0 cfg" >> "$LOG"
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
# The Market fixture, logic running, the game's frame cap. $1: a name for the run's files;
# $2 (optional): InterpolationFPS, applied through the harness's A/B CVar with one value.
# $3 (optional): another CVar for that one-valued A/B instead, as NAME=VALUE (only one at a time).
# The harness applies it after the settle, in a running game: that is how gSettings.RenderThread 2
# must be turned on (Shipwright report 11: launching with it in the config races the ImGui atlas).
start_soh() {
  fps_env=
  [ -n "${2:-}" ] && fps_env="SOH_BENCH_AB_CVAR=gSettings.InterpolationFPS SOH_BENCH_AB_VALUES=$2,$2 SOH_BENCH_REPS=1"
  [ -n "${3:-}" ] && fps_env="SOH_BENCH_AB_CVAR=${3%%=*} SOH_BENCH_AB_VALUES=${3#*=},${3#*=} SOH_BENCH_REPS=1"
  (cd "$SOH_DIR" && env SDL_VIDEO_X11_FORCE_EGL=1 \
    SDL_VIDEO_GL_DRIVER=/opt/omap5-sgx-ddk-um-linux/lib/libGLESv2.so.1 DISPLAY=:0 \
    SOH_BENCH=1 SOH_BENCH_OUT="$DIR/thermcost-bench-$1.txt" SOH_BENCH_ENTRANCE=0x00B1 \
    SOH_BENCH_POS=-122.7,0.0,72.1 SOH_BENCH_YAW=0xD5A6 SOH_BENCH_EYE=0.0,64.0,0.0 \
    SOH_BENCH_AT=-134.5,64.0,79.0 SOH_BENCH_SETTLE=400 SOH_BENCH_STATIC=0 SOH_BENCH_UNCAP=0 \
    SOH_BENCH_FRAMES=200000 SOH_BENCH_SPLIT=100 SOH_BENCH_EXIT=0 $fps_env \
    nohup ./soh.elf > "$DIR/thermcost-run-$1.log" 2>&1 < /dev/null &)
}
# ABBA blocks of 60 s over a list of clocks in kHz: "a b c" runs a b c c b a.
abba() {
  rev=; for f in "$@"; do rev="$f $rev"; done
  for f in "$@" $rev; do setspeed "$f"; phase "$PREFIX-$((f/1000))"; sleep 60; done
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
      "$(cat $BL)" "$(cat "$KBL")" "$(cat /sys/class/power_supply/bq24297/online)" >> "$CSV"
    sleep 1
  done
) &
SAMPLER=$!

# Wait for the cable to come out rather than measuring a charger.
phase wait-unplug
while [ "$(cat /sys/class/power_supply/bq24297/online)" = 1 ]; do sleep 2; done
sleep 20

if [ "$MODE" = undervolt ]; then
  # 2026-09-28, Shipwright NEXT.md 0T (6): the shipped 30/750 in mode 2 with the 750 MHz point
  # undervolted. The voltage changes live (undervolt.sh set steps the CPU to 875 and back, <1 s),
  # so both arms run in one game process: ABBA twice in 60 s blocks, then 10-minute holds
  # stock, undervolted, stock (the second stock hold measures the run's drift).
  UV_DIR=${UV_DIR:-$HOME/undervolt}; UV=${UV_MV:-870}
  uvset() { (cd "$UV_DIR" && ./undervolt.sh set 750000 $(($1 * 1000)) >> "$LOG" 2>&1); }
  uvrestore() { (cd "$UV_DIR" && ./undervolt.sh restore >> "$LOG" 2>&1); }
  trap 'uvrestore; restore' EXIT INT TERM
  (cd "$UV_DIR" && ./undervolt.sh load >> "$LOG" 2>&1)
  ondemand;        phase idle-ondemand; sleep 120
  setspeed 750000; uvset 950; start_soh uv; phase start30-750; sleep 60
  phase soh30-warm; sleep 180
  for v in 950 $UV $UV 950 950 $UV $UV 950; do uvset $v; phase "soh30uv-$v"; sleep 60; done
  uvset 950; phase hold30-750-950;    sleep 600
  uvset $UV; phase hold30-750-$UV;    sleep 600
  uvset 950; phase hold30-750-950b;   sleep 600
  stop_soh
  uvrestore
  phase idle-hot; sleep 120
  phase end
  exit 0
fi

if [ "$MODE" = twocore ]; then
  # 2026-09-28, Shipwright report 11 task 2: does the GL thread (gSettings.RenderThread 2, ~+2 ms of
  # machine CPU a frame) save watts through a lower clock? All 30 fps except the 20/625 reference.
  RT=gSettings.RenderThread=2
  ondemand;        phase idle-ondemand; sleep 120

  # 1. Warm at 30/1000 in mode 0, then the mode itself at 750, ABBA by process (a restart per arm;
  #    the first 60 s of each is its own phase, for the load and the settle).
  setspeed 1000000; start_soh m0warm; phase soh30-warm; sleep 240
  stop_soh
  setspeed 750000
  n=0
  for m in 0 2 2 0; do
    n=$((n+1))
    if [ $m = 2 ]; then start_soh "ab$n-m2" "" "$RT"; else start_soh "ab$n-m0"; fi
    phase "start30-750-m$m"; sleep 60
    phase "soh30-750-m$m";   sleep 180
    stop_soh
  done

  # 2. Mode 2 by clock, 750 against 625, ABBA twice in one process.
  start_soh m2clk "" "$RT"; phase start30-m2; sleep 60
  PREFIX=soh30m2; abba 750000 625000; abba 750000 625000
  # 3. Holds for die temperature, and misses over 10 minutes (the BENCH split lines).
  setspeed 625000; phase hold30-625-m2; sleep 600
  setspeed 750000; phase hold30-750-m2; sleep 600
  stop_soh
  setspeed 1000000; start_soh m0hold; phase start30-1000-m0; sleep 30
  phase hold30-1000-m0; sleep 600
  stop_soh
  setspeed 625000; start_soh fps20 20; phase start20-625-m0; sleep 30
  phase hold20-625-m0; sleep 600
  stop_soh
  phase idle-hot-625; sleep 120
  phase end
  exit 0
fi

if [ "$MODE" = clock ]; then
  # 1. Idle floor at the two ends of the range the game will use.
  ondemand;        phase idle-ondemand; sleep 120
  setspeed 1000000; phase idle-1000;    sleep 90
  setspeed 500000;  phase idle-500;     sleep 90

  # 2. 30 fps: warm at 1000, watts by clock (ABBA twice), then holds for temperature.
  setspeed 1000000; start_soh fps30; phase soh30-warm; sleep 240
  PREFIX=soh30; abba 1000000 875000 750000; abba 1000000 875000 750000
  setspeed 1000000; phase hold30-1000; sleep 600
  setspeed 750000;  phase hold30-750;  sleep 600

  # 3. 20 fps: the same process can't switch, so restart with InterpolationFPS=20.
  stop_soh
  setspeed 750000; start_soh fps20 20; phase soh20-warm; sleep 60
  phase hold20-750; sleep 600
  setspeed 500000; phase hold20-500; sleep 600
  PREFIX=soh20; abba 750000 625000 500000; abba 750000 625000 500000

  # 4. Back to 30 fps at 1000: how far the die drifted over the run for the same load.
  stop_soh
  setspeed 1000000; start_soh fps30b; phase hold30-1000b; sleep 600
  stop_soh
  phase idle-hot-1000; sleep 120
  phase end
  exit 0
fi

# 1. Idle floor: desktop, screen as the user has it, governor as shipped.
ondemand
phase idle-ondemand;  sleep 150
setspeed 1250000
phase idle-1250;      sleep 90

# 2. The game: Market fixture, logic running, 30 fps cap, 1250 MHz.
setspeed 1250000
start_soh cost
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
  sudo sh -c "echo $k > '$KBL'"; phase "soh-kbl-$k"; sleep 60
done
sudo sh -c "echo $KBL0 > '$KBL'"

# 6. Game gone, machine hot: the idle floor again, to see what temperature alone costs.
stop_soh
phase idle-hot-1250;  sleep 120
phase end
