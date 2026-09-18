#!/bin/bash
#
# pyra-governor-tune.sh — apply the one cpufreq governor setting that is worth
# applying on this machine.
#
#   sudo ./pyra-governor-tune.sh --check   say what the state is, change nothing
#   sudo ./pyra-governor-tune.sh           apply it, and verify it took
#   sudo ./pyra-governor-tune.sh --undo    put the stock value back
#
# It is also what pyra-governor-tune.service runs at boot, which is what makes
# the setting survive a reboot. Applying it by hand and enabling the unit are
# the same operation through the same code, so there is no second opinion about
# what the value should be.
#
# WHAT IT CHANGES, AND WHY THIS ONE
#
#     /sys/devices/system/cpu/cpufreq/ondemand/sampling_down_factor   1 -> 10
#
# Stock is 1, which means the governor drops the clock at the first idle
# sample. Work that arrives in bursts therefore pays the ramp back up on every
# single unit. 10 means it waits ten sampling periods before stepping down, so
# a burst pays the ramp once.
#
# Measured 2026-09-13, two interleaved passes per configuration with the
# thermal daemon stopped and the frequency ceiling pinned, pass-to-pass spread
# 0.0-2.3%. Numbers in experiments/governor/README.md:
#
#     burst latency, mean     53.8 ms -> 41.2 ms    -23.4%
#     burst latency, median   53.5 ms -> 36.0 ms    -32.7%
#     idle mean frequency     421 MHz -> 444 MHz     +5.4%
#
# The other three settings item 1 of docs/improvements.md names — up_threshold,
# io_is_busy and the frequency floor — were measured at the same time and are
# worth about 1% each. Setting all four together is 24.5% against this one
# setting's 23.4%, a difference inside the spread, so this script sets one
# value and leaves the rest at stock. That also avoids their cost: all four
# together raise idle frequency 46% and put an idle machine at 1.5 GHz a tenth
# of the time, where this alone costs 5.4% and 3.5%.
#
# WHAT IT DOES NOT FIX
#
# The tail. p99 improves 6.4% against 32.7% at the median, because the clock is
# held up between units of a burst but the first unit after genuine idle still
# pays the full ramp. If the machine feels slow after it has been sitting, this
# is not the thing that fixes it.
#
# It also does not touch scaling_max_freq, which the thermal daemon owns, or
# the governor itself. When this was written the daemon capped the CPU on what it
# called the BATTERY temperature — 1250 MHz above 44 C, 1000 MHz above 45 C,
# while the core had to reach 77 C to cap anything — so a warm battery cost more
# top-end than this setting buys in ramp.
#
# That sensor is the fuel gauge's own die rather than the cell, and that ladder
# was corrected later the same day by pyra-thermal-ladder.sh, which ships as
# fix 7: the board rungs move to 54-62 C and both ladders get a 5 C band. An idle
# Pyra reads 42 C on that sensor, so with fix 7 applied nothing pre-caps the
# machine and the ramp this script shortens is the ramp you actually get. On an
# image WITHOUT fix 7 the sentence above still holds, and the pre-cap will mask
# most of what this setting buys.
#
set -uo pipefail

OD=/sys/devices/system/cpu/cpufreq/ondemand
KNOB=$OD/sampling_down_factor
WANT=10
STOCK=1

die()  { echo "FAILED: $*" >&2; exit 1; }
note() { echo "  $*"; }

MODE=apply
case "${1:-}" in
	--check)   MODE=check ;;
	--undo)    MODE=undo ;;
	-h|--help) sed -n '3,50p' "$0" | sed 's/^# \?//'; exit 0 ;;
	"")        ;;
	*)         die "unknown option: $1" ;;
esac

# The ondemand tunables exist only while a policy is actually using ondemand.
# On a machine running some other governor there is nothing here to set, and
# that is a fact to report rather than an error to fail on — the unit runs at
# boot on every machine and must not turn a different governor into a failed
# service.
if [ ! -d "$OD" ]; then
	gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)
	echo "the ondemand governor is not in use (current: $gov), so there is"
	echo "nothing to tune. Leaving everything alone."
	exit 0
fi
[ -r "$KNOB" ] || die "no $KNOB, though $OD exists"

NOW=$(cat "$KNOB")

if [ "$MODE" = check ]; then
	echo "sampling_down_factor : $NOW  (stock $STOCK, wanted $WANT)"
	echo "governor             : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
	echo "up_threshold         : $(cat "$OD/up_threshold")  (stock 95, deliberately unchanged)"
	echo "io_is_busy           : $(cat "$OD/io_is_busy")  (stock 0, deliberately unchanged)"
	echo "scaling_min_freq     : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq) kHz  (stock 250000, deliberately unchanged)"
	echo "scaling_max_freq     : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq) kHz  (the thermal daemon owns this)"
	if [ "$NOW" = "$WANT" ]; then
		echo
		echo "applied."
	else
		echo
		echo "not applied. Apply it with: sudo $0"
	fi
	exit 0
fi

[ "$(id -u)" = 0 ] || die "needs root to write $KNOB. Run it with sudo."

TARGET=$WANT
[ "$MODE" = undo ] && TARGET=$STOCK

if [ "$NOW" = "$TARGET" ]; then
	note "sampling_down_factor is already $TARGET, nothing to do"
	exit 0
fi

echo "$TARGET" > "$KNOB" 2>/dev/null || die "could not write $KNOB"

# Read it back. A governor tunable can accept a write and clamp it, and a
# setting that was silently refused is worse than one that was never made,
# because everything downstream then believes it is in effect.
GOT=$(cat "$KNOB")
[ "$GOT" = "$TARGET" ] || die "asked for $TARGET, got $GOT"

note "sampling_down_factor $NOW -> $GOT"
[ "$MODE" = undo ] && note "back to stock" || note "applied"
