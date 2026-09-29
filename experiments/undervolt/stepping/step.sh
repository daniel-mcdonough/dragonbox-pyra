#!/bin/bash
# one undervolt step at 750 MHz: set, stress-ng --verify (heats the die), Market dump in mode 2
set -uo pipefail
V=$1                          # uV
TAG=${2:-$V}
OUT=$(cd "$(dirname "$0")" && pwd)/out
cd "$(dirname "$0")/../../.."; . ./pyra-local.conf >/dev/null
echo "== step $V $(date +%T)"
ssh -o BatchMode=yes -o ServerAliveInterval=5 -o ServerAliveCountMax=3 $PYRA_HOST "sync; cd ~/undervolt && ./undervolt.sh set 750000 $V | tail -2; echo die \$(cat /sys/class/thermal/thermal_zone0/temp); \
  LD_PRELOAD=/usr/lib/arm-linux-gnueabihf/libEGL.so.1 stress-ng --cpu 2 --cpu-method all --verify -t ${STRESS_S:-180}s 2>&1 | grep -E 'passed|failed|fail|error|untrust'; \
  echo die \$(cat /sys/class/thermal/thermal_zone0/temp) cur \$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq); grep -E '^ *750000' /sys/module/pyra_undervolt/parameters/table; \
  rm -rf ~/soh-bench2/uv/$TAG; mkdir -p ~/soh-bench2/uv/$TAG" || { echo "SSH FAILED at $V (device hung?)"; exit 2; }
cd "${SHIPWRIGHT:-$HOME/git/Shipwright}"
MARKET="SOH_BENCH_ENTRANCE=0x00B1 SOH_BENCH_POS=-122.7,0.0,72.1 SOH_BENCH_YAW=0xD5A6 SOH_BENCH_EYE=0.0,64.0,0.0 SOH_BENCH_AT=-134.5,64.0,79.0 SOH_BENCH_SETTLE=400"
PYRA_PIN_FREQ=750000 ./scripts/pyra/bench.sh ab gSettings.LeanSwap 0 0 $MARKET SOH_BENCH_REPS=3 SOH_BENCH_DUMP=uv/$TAG > $OUT/bench-$TAG.txt 2>&1; rc=$?
echo "bench rc=$rc"
ssh -o BatchMode=yes $PYRA_HOST "grep -o 'BENCH segment.*' ~/soh-bench2/run.log; grep -ciE 'error|abort|segfault' ~/soh-bench2/run.log; ls ~/soh-bench2/uv/$TAG | grep -c ppm$; echo die \$(cat /sys/class/thermal/thermal_zone0/temp) gov \$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor) cur \$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq); cat /sys/class/regulator/regulator.*/name | paste - - - - - - - - - - | head -0; for r in /sys/class/regulator/regulator.*; do [ \$(cat \$r/name) = smps123 ] && echo rail \$(cat \$r/microvolts); done"
echo "== end $V $(date +%T)"
