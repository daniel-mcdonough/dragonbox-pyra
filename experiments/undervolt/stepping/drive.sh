#!/bin/bash
# Undervolt stepping at 750 MHz (2026-09-28). drive.sh runs step.sh per voltage (set, stress-ng --verify,
# the Market fixture in mode 2 as six segments of one process with SOH_BENCH_DUMP), then fetch.sh +
# cmp2.py (every segment must draw the same frozen frame). Needs pyra-local.conf, ~/git/Shipwright,
# and on the device ~/undervolt (this directory's parent) and stress-ng (run with LD_PRELOAD of glvnd's
# libEGL: the DDK's lacks eglCreatePlatformWindowSurface). Output in ./out.
S=$(cd "$(dirname "$0")" && pwd)
for V in ${VOLTS:-940000 930000 920000 910000 900000 890000 880000 870000 860000 850000}; do
  $S/step.sh $V > $S/out/step-$V.log 2>&1; rc=$?
  cat $S/out/step-$V.log
  [ $rc = 2 ] && { echo "STOP $V: device unreachable"; exit 2; }
  grep -q 'passed: 2: cpu' $S/out/step-$V.log && grep -q ' failed: 0' $S/out/step-$V.log || { echo "STOP $V: stress-ng"; exit 3; }
  grep -q 'bench rc=0' $S/out/step-$V.log || { echo "STOP $V: bench"; exit 4; }
  [ "$(grep -c 'cpu_min_mhz=750 cpu_max_mhz=750' $S/out/step-$V.log)" = 6 ] || { echo "STOP $V: off pin"; exit 5; }
  $S/fetch.sh $V > $S/out/cmp-$V.log 2>&1; rc=$?; cat $S/out/cmp-$V.log
  [ $rc = 0 ] || { echo "STOP $V: dump"; exit 6; }
  echo "PASS $V"
done
echo ALLPASS
