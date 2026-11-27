#!/bin/sh
# Run a command with the TWL6040's vibra register writes (regmap 0-004b,
# 0x18-0x1b) traced, then print them. Root. Timestamps are CLOCK_MONOTONIC,
# the clock ff-update-test.py prints.
#   sudo ./trace-vibra.sh python3 ff-update-test.py
set -eu
T=/sys/kernel/tracing
[ -e $T/trace ] || T=/sys/kernel/debug/tracing
E=$T/events/regmap/regmap_reg_write
echo 0 > $T/tracing_on
echo > $T/trace
echo mono > $T/trace_clock
# A name == "0-004b" term matches nothing on 5.6.19; sed picks the device.
echo 'reg >= 0x18 && reg <= 0x1b' > $E/filter
echo 1 > $E/enable
echo 1 > $T/tracing_on
"$@" || true
echo 0 > $T/tracing_on
echo 0 > $E/enable
echo 0 > $E/filter
grep -v '^#' $T/trace | sed -n 's/.* \([0-9.]*\): regmap_reg_write: 0-004b /\1 /p'
# Changing the clock empties the buffer, so only after reading it.
echo local > $T/trace_clock
