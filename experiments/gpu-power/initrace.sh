#!/bin/sh
# Load the GPU driver N times and count how often udev alone brings the SGX services up.
#   sudo ./initrace.sh <n> stock|fixed|both
# A cycle passes when "KM DDK ... match" appears within 5 s of the load with nothing run
# by hand. After a failed cycle the services are started by hand, so the next unload is clean.
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
MOD=pvrsrvkm_omap5_sgx544_116
matches() { dmesg | grep -c "KM DDK-.*match"; }
ok=0; fail=0
for i in $(seq 1 "$1"); do
  case $2 in both) [ $((i % 2)) = 0 ] && arm=fixed || arm=stock ;; *) arm=$2 ;; esac
  [ -d /sys/module/$MOD ] && { modprobe -r $MOD || rmmod $MOD; }
  sleep 1
  before=$(matches)
  if [ $arm = fixed ]; then insmod "$DIR/pvrsrvkm-apm.ko"; else modprobe $MOD; fi
  t=0; while [ "$(matches)" -le "$before" ] && [ $t -lt 50 ]; do sleep 0.1; t=$((t+1)); done
  if [ "$(matches)" -gt "$before" ]; then ok=$((ok+1)); r="ok after $((t * 100)) ms"
  else fail=$((fail+1)); r=FAILED; /opt/omap5-sgx-ddk-um-linux/bin/pvrsrvctl --start --no-module >/dev/null 2>&1; fi
  echo "cycle $i $arm: $r"
done
echo "passed $ok of $((ok+fail))"
[ -d /sys/module/$MOD ] && [ -n "$(cat /sys/module/$MOD/taint)" ] && { modprobe -r $MOD; modprobe $MOD; sleep 3; }
exit 0
