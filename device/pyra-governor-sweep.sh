#!/bin/bash
#
# pyra-governor-sweep.sh — measure what each cpufreq governor setting buys.
#
#   sudo ./pyra-governor-sweep.sh              full run, about 30 minutes
#   sudo ./pyra-governor-sweep.sh --quick      the same shape, about 12 minutes
#   sudo ./pyra-governor-sweep.sh --restore    put the governor back and exit
#
# WHY THIS EXISTS
#
# Item 1 of docs/improvements.md says the governor is misconfigured and names
# four settings to try. It has never been measured, because until the thermal
# daemon was fixed on 2026-09-12 there was no margin to spend: a heavy load sat
# on the 100 C passive trip, so raising up_threshold would have been paid for
# in throttling rather than in speed. With the daemon capping, the same load
# peaks at 84 C, and the question becomes answerable.
#
# WHAT IT MEASURES, AND WHY THOSE THINGS
#
#   burst   how long a short unit of work takes, when work arrives in bursts
#           with idle between them. This is the number item 1 is about: a
#           governor that will not step up until a core is 95% busy across
#           20 ms is a governor that ordinary interactive work never wakes.
#           The tail matters more than the mean, which is why p90 and p99 are
#           printed — "sluggish" is a description of a tail.
#
#   idle    where the machine sits with nothing to do, as frequency residency.
#           This is the cost side. Every change that makes the governor keener
#           to step up also makes it keener to step up over nothing, and on a
#           handheld that is battery. Watts are printed too, but only on
#           battery: on the charger the battery current measures the charger.
#
#   temps   before and after every window, because the risk in item 1 is
#           thermal and an unwatched thermal experiment is not an experiment.
#
# HOW IT AVOIDS FOOLING ITSELF
#
# Repeats are interleaved, not blocked. Every configuration is measured once,
# then every configuration again, rather than doing all the repeats of one
# before moving on. A machine that warms up, or a stray background task, drifts
# across a run; blocked repeats would fold that drift into whichever setting
# happened to be measured while it was happening, and interleaving spreads it
# across all of them instead.
#
# Each configuration is one knob away from stock, so what is measured is that
# knob rather than a bundle. `tuned` is the exception and is deliberate: it is
# the combination, to catch knobs that only pay off together. `performance` is
# the upper bound. If tuned ondemand lands near it, there is nothing left to
# win and item 1 can be closed.
#
# WHAT IT CHANGES, AND FOR HOW LONG
#
# The governor and its tunables, for the length of the run. It records every
# value it is about to change, restores them on any exit including Ctrl-C and
# a failed command, and verifies the restore before it prints the summary. If
# it is ever killed hard enough to skip that, `--restore` puts back the stock
# values without measuring anything.
#
# It also stops the thermal daemon for the duration, and pins scaling_max_freq
# at the top of the table. That is a change of mind from the first version of
# this script, which left the daemon alone on the reasoning that it owns
# scaling_max_freq now that fix 6 works and a sweep fighting it for the same
# file would be measuring the fight. That reasoning was right and the
# conclusion was wrong: leaving it alone does not avoid the fight, it just
# makes the fight invisible.
#
# The run of 2026-09-13 proved it. The vendor ladder branches on BATTERY
# temperature as well as core, and the battery branch is the one that fires on
# this machine:
#
#     elif [ ${battery_temp} -gt 44000 ]; then setMaxFreq 1250
#
# The battery sits at 42-45 C on an ordinary charging handheld, so it crossed
# 44 C partway through the run and the ceiling fell from 1500 to 1250 MHz with
# the CPU at 59 C — nothing to do with CPU heat. Every configuration measured
# after that point was measured under a lower ceiling than the ones before it,
# which showed up as the second pass being uniformly slower than the first and
# as the performance governor, which runs last, appearing slower than tuned
# ondemand. Both are artefacts.
#
# So the daemon is stopped and the ceiling pinned, and the kernel`s own
# step_wise thermal governor is left as the protection — which is what actually
# protects this machine anyway, the daemon being a 20-second poll on top. The
# windows here are light: the first run peaked at 71 C on a 100 C trip. The
# temperature is still checked before every window and the run aborts if it
# climbs, and the daemon is started again on every exit path.
#
set -uo pipefail

CPUFREQ=/sys/devices/system/cpu/cpu0/cpufreq
POLICY=/sys/devices/system/cpu/cpufreq/policy0
OD=/sys/devices/system/cpu/cpufreq/ondemand
STATS=$CPUFREQ/stats

die() { echo "FAILED: $*" >&2; exit 1; }
note() { echo "$*" >&2; }

# ---------------------------------------------------------------- stock ------
# The values this machine boots with. They are read at start rather than
# hardcoded, so the script restores what was actually there; the numbers in
# the comments are what they were on 2026-09-12.
STOCK_GOV=        # ondemand
STOCK_UP=         # 95
STOCK_IO=         # 0
STOCK_SDF=        # 1
STOCK_RATE=       # 20000
STOCK_MIN=        # 250000

read_stock() {
	STOCK_GOV=$(cat "$CPUFREQ/scaling_governor")
	STOCK_MIN=$(cat "$CPUFREQ/scaling_min_freq")
	if [ -d "$OD" ]; then
		STOCK_UP=$(cat "$OD/up_threshold")
		STOCK_IO=$(cat "$OD/io_is_busy")
		STOCK_SDF=$(cat "$OD/sampling_down_factor")
		STOCK_RATE=$(cat "$OD/sampling_rate")
	fi
}

# Write a value and confirm it landed. A governor tunable can accept a write
# and clamp it — sampling_rate has a hardware floor — so every write is read
# back. A silently clamped setting would be measured as though it had been
# applied, which is the one way this script could print a confident wrong
# number.
put() {
	local file=$1 val=$2 got
	[ -w "$file" ] || { note "  cannot write $file"; return 1; }
	echo "$val" > "$file" 2>/dev/null
	got=$(cat "$file" 2>/dev/null)
	if [ "$got" != "$val" ]; then
		note "  $file: asked for $val, got $got"
		return 1
	fi
	return 0
}

set_governor() {
	local g=$1 c
	for c in /sys/devices/system/cpu/cpu[0-9]/cpufreq/scaling_governor; do
		[ -w "$c" ] && echo "$g" > "$c" 2>/dev/null
	done
	[ "$(cat "$CPUFREQ/scaling_governor")" = "$g" ]
}

set_min_freq() {
	local f=$1 c ok=0
	for c in /sys/devices/system/cpu/cpu[0-9]/cpufreq/scaling_min_freq; do
		[ -w "$c" ] && echo "$f" > "$c" 2>/dev/null
	done
	[ "$(cat "$CPUFREQ/scaling_min_freq")" = "$f" ] && ok=1
	[ "$ok" = 1 ]
}

THERMAL_UNIT=pyra-thermal
THERMAL_WAS_ACTIVE=0
STOCK_MAX=

# Stop the daemon and pin the ceiling. Recorded first, so the release puts back
# what was there rather than what this script assumes was there.
hold_ceiling() {
	STOCK_MAX=$(cat "$CPUFREQ/scaling_max_freq")
	if systemctl is-active --quiet "$THERMAL_UNIT" 2>/dev/null; then
		THERMAL_WAS_ACTIVE=1
		systemctl stop "$THERMAL_UNIT" 2>/dev/null \
			|| note "could not stop $THERMAL_UNIT; the ceiling may move under the run"
	fi
	local top
	top=$(tr " " "\n" < "$CPUFREQ/scaling_available_frequencies" | sort -n | tail -1)
	local c
	for c in /sys/devices/system/cpu/cpu[0-9]/cpufreq/scaling_max_freq; do
		[ -w "$c" ] && echo "$top" > "$c" 2>/dev/null
	done
	CEILING=$(cat "$CPUFREQ/scaling_max_freq")
	[ "$CEILING" = "$top" ] || note "asked for a $top kHz ceiling, got $CEILING"
}

release_ceiling() {
	[ -n "$STOCK_MAX" ] || return 0
	local c
	for c in /sys/devices/system/cpu/cpu[0-9]/cpufreq/scaling_max_freq; do
		[ -w "$c" ] && echo "$STOCK_MAX" > "$c" 2>/dev/null
	done
	# Starting the daemon again matters more than the value written above:
	# its next poll overwrites scaling_max_freq anyway, which is the point of
	# it. The write is here for the case where the daemon does not come back.
	if [ "$THERMAL_WAS_ACTIVE" = 1 ]; then
		systemctl start "$THERMAL_UNIT" 2>/dev/null \
			&& note "$THERMAL_UNIT started again" \
			|| note "COULD NOT RESTART $THERMAL_UNIT — run: sudo systemctl start $THERMAL_UNIT"
	fi
}

restore() {
	release_ceiling
	[ -n "$STOCK_GOV" ] || return 0
	set_governor "$STOCK_GOV" || note "restore: governor did not go back to $STOCK_GOV"
	if [ -d "$OD" ]; then
		put "$OD/up_threshold" "$STOCK_UP" >/dev/null 2>&1
		put "$OD/io_is_busy" "$STOCK_IO" >/dev/null 2>&1
		put "$OD/sampling_down_factor" "$STOCK_SDF" >/dev/null 2>&1
		put "$OD/sampling_rate" "$STOCK_RATE" >/dev/null 2>&1
	fi
	set_min_freq "$STOCK_MIN" || note "restore: scaling_min_freq did not go back to $STOCK_MIN"
}

# Report whether the machine is back where it started, by reading it rather
# than by trusting that restore() ran.
verify_restored() {
	local bad=0
	[ "$(cat "$CPUFREQ/scaling_governor")" = "$STOCK_GOV" ] || { note "STILL CHANGED: governor"; bad=1; }
	[ "$(cat "$CPUFREQ/scaling_min_freq")" = "$STOCK_MIN" ] || { note "STILL CHANGED: scaling_min_freq"; bad=1; }
	if [ -d "$OD" ]; then
		[ "$(cat "$OD/up_threshold")" = "$STOCK_UP" ] || { note "STILL CHANGED: up_threshold"; bad=1; }
		[ "$(cat "$OD/io_is_busy")" = "$STOCK_IO" ] || { note "STILL CHANGED: io_is_busy"; bad=1; }
		[ "$(cat "$OD/sampling_down_factor")" = "$STOCK_SDF" ] || { note "STILL CHANGED: sampling_down_factor"; bad=1; }
	fi
	return $bad
}

# ------------------------------------------------------------ the configs ----
# name | governor | up_threshold | io_is_busy | sampling_down_factor | min_kHz
#
# "-" means leave the stock value. Each row is one knob from stock except
# `tuned`, which is the combination, and `performance`, which is the ceiling.
CONFIGS=(
	"stock|ondemand|-|-|-|-"
	"up80|ondemand|80|-|-|-"
	"up70|ondemand|70|-|-|-"
	"io1|ondemand|-|1|-|-"
	"sdf10|ondemand|-|-|10|-"
	"min500|ondemand|-|-|-|500000"
	"min750|ondemand|-|-|-|750000"
	"tuned|ondemand|70|1|10|500000"
	"performance|performance|-|-|-|-"
)

apply_config() {
	local spec=$1 name gov up io sdf min
	IFS='|' read -r name gov up io sdf min <<< "$spec"

	# Back to stock first, so a config only carries the knobs it names and
	# not whatever the previous one left behind.
	set_governor "$STOCK_GOV" || return 1
	if [ -d "$OD" ]; then
		put "$OD/up_threshold" "$STOCK_UP" || return 1
		put "$OD/io_is_busy" "$STOCK_IO" || return 1
		put "$OD/sampling_down_factor" "$STOCK_SDF" || return 1
	fi
	set_min_freq "$STOCK_MIN" || return 1

	[ "$min" = "-" ] || set_min_freq "$min" || return 1

	if [ "$gov" != "$STOCK_GOV" ]; then
		set_governor "$gov" || return 1
		return 0        # performance has no tunables to set
	fi
	[ "$up"  = "-" ] || put "$OD/up_threshold" "$up" || return 1
	[ "$io"  = "-" ] || put "$OD/io_is_busy" "$io" || return 1
	[ "$sdf" = "-" ] || put "$OD/sampling_down_factor" "$sdf" || return 1
	return 0
}

describe_config() {
	local spec=$1 name gov up io sdf min out=
	IFS='|' read -r name gov up io sdf min <<< "$spec"
	[ "$gov" = "$STOCK_GOV" ] || out="$out governor=$gov"
	[ "$up"  = "-" ] || out="$out up_threshold=$up"
	[ "$io"  = "-" ] || out="$out io_is_busy=$io"
	[ "$sdf" = "-" ] || out="$out sampling_down_factor=$sdf"
	[ "$min" = "-" ] || out="$out scaling_min_freq=$((min / 1000))MHz"
	[ -n "$out" ] || out=" stock, as the machine boots"
	echo "${out# }"
}

# ------------------------------------------------------------ measurement ----
snapshot() { cat "$STATS/time_in_state"; }

cpu_c() { echo $(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 )); }

temps() {
	local z n
	for z in /sys/class/thermal/thermal_zone*; do
		n=$(cat "$z/type" 2>/dev/null) || continue
		case "$n" in cpu_thermal|core_thermal|gpu_thermal)
			printf '%s=%s ' "${n%%_*}" "$(( $(cat "$z/temp") / 1000 ))" ;;
		esac
	done
}

BATT=/sys/class/power_supply/bq27421-0
on_battery() { [ "$(cat $BATT/status 2>/dev/null)" = Discharging ]; }

# The backlight, because it is worth more than anything measured here. A step
# from full to dim is about 0.45 W on this machine, and the idle dimmer will
# take one by itself partway through a run if nobody touches the screen. In
# the run of 2026-09-13 two adjacent windows came out 0.45 W below their own
# first pass with nothing else to explain it, which is the size of exactly
# that step and could not be settled afterwards. Recording it does not stop
# the dimmer; it makes a run where the dimmer moved say so.
backlight() {
	local b
	for b in /sys/class/backlight/*/brightness; do
		[ -r "$b" ] || continue
		printf '%s ' "$(cat "$b")"
	done
}
watts_mw() {
	local uv ua
	on_battery || return 1
	uv=$(cat $BATT/voltage_now 2>/dev/null) || return 1
	ua=$(cat $BATT/current_now 2>/dev/null) || return 1
	[ "$ua" -lt 0 ] && ua=$(( -ua ))
	echo $(( uv / 1000 * ua / 1000000 ))
}
power_start() {
	POWER_LOG=$TMP/power
	: > "$POWER_LOG"
	( while :; do watts_mw >> "$POWER_LOG" 2>/dev/null; sleep 1; done ) &
	POWER_PID=$!
}
# Stopping and reading are two calls on purpose. The mean is read in a command
# substitution, which is a subshell, and a subshell cannot reap the parent's
# background sampler — doing both in one function left a sampler running into
# the next window, where it would have logged the wrong configuration's power.
power_stop() {
	if [ -n "${POWER_PID:-}" ]; then
		kill "$POWER_PID" 2>/dev/null
		wait "$POWER_PID" 2>/dev/null
		POWER_PID=
	fi
}
# Mean watts across the window just measured, or empty on the charger.
power_mean() {
	if [ -s "${POWER_LOG:-/nonexistent}" ]; then
		awk '{s+=$1; n++} END {if (n) printf "%.2f", s/n/1000}' "$POWER_LOG"
	fi
}

# Mean frequency in kHz across a window, and the share of it spent at the top
# step. Those two say most of what residency says, in a form that fits in a
# table; the full table is printed per configuration in the verbose log.
residency_summary() {
	python3 - "$1" "$2" <<-'PY'
		import sys
		def read(p):
		    d = {}
		    for line in open(p):
		        k, v = line.split()
		        d[int(k)] = int(v)
		    return d
		a, b = read(sys.argv[1]), read(sys.argv[2])
		delta = {k: b[k] - a.get(k, 0) for k in b}
		total = sum(delta.values())
		if total <= 0:
		    print("0 0 0")
		    raise SystemExit
		mean = sum(k * v for k, v in delta.items()) / total
		top = max(delta)
		bottom = min(delta)
		print("%.0f %.1f %.1f" % (
		    mean, 100.0 * delta[top] / total, 100.0 * delta[bottom] / total))
	PY
}

residency_table() {
	python3 - "$1" "$2" <<-'PY'
		import sys
		def read(p):
		    d = {}
		    for line in open(p):
		        k, v = line.split()
		        d[int(k)] = int(v)
		    return d
		a, b = read(sys.argv[1]), read(sys.argv[2])
		delta = {k: b[k] - a.get(k, 0) for k in b}
		total = sum(delta.values())
		if total <= 0:
		    print("      (no residency recorded)")
		    raise SystemExit
		for k in sorted(delta):
		    pct = 100.0 * delta[k] / total
		    if pct < 0.05:
		        continue
		    print("      %7d kHz  %5.1f%%  %s" % (k, pct, "#" * int(pct / 2)))
	PY
}

# The burst workload. Deliberately identical to the one in
# pyra-freq-profile.sh — same iteration count, same gap between units — so
# these numbers can be put beside the kernel comparison of 2026-09-12 rather
# than only beside each other. Plain integer arithmetic, no libraries: nothing
# here can dispatch differently between two governor settings.
burst_run() {
	local n=$1
	python3 - "$n" <<-'PY'
		import sys, time

		n = int(sys.argv[1])

		def work():
		    s = 0
		    for i in range(120000):
		        s += i * i
		    return s

		work()                  # warm the interpreter, untimed
		time.sleep(0.2)

		lat = []
		for _ in range(n):
		    t = time.perf_counter()
		    work()
		    lat.append((time.perf_counter() - t) * 1000.0)
		    time.sleep(0.06)    # long enough for the governor to want to step down

		lat.sort()
		def pct(p):
		    return lat[min(len(lat) - 1, int(len(lat) * p / 100.0))]
		print("%.1f %.1f %.1f %.1f %.1f" % (
		    sum(lat) / len(lat), lat[0], pct(50), pct(90), pct(99)))
	PY
}

# One configuration, one repeat: idle window, then burst window. Appends one
# tab-separated line to $RESULTS and prints the detail to the log.
measure_one() {
	local spec=$1 rep=$2 name
	name=${spec%%|*}

	local c
	c=$(cpu_c)
	if [ "$c" -gt "$START_MAX_C" ]; then
		echo "    waiting for the CPU to come below ${START_MAX_C} C (now ${c} C)"
		local waited=0
		while [ "$(cpu_c)" -gt "$START_MAX_C" ] && [ "$waited" -lt 300 ]; do
			sleep 10; waited=$((waited + 10))
		done
	fi

	apply_config "$spec" || { echo "    SKIPPED: could not apply $name"; return 1; }

	# Let the governor settle into the new setting before measuring it.
	sleep "$SETTLE_S"

	# --- idle ---
	local i_mean i_top i_bot i_pow bl_before bl_after
	bl_before=$(backlight)
	snapshot > "$TMP/idle.before"
	power_start
	sleep "$IDLE_S"
	snapshot > "$TMP/idle.after"
	bl_after=$(backlight)
	power_stop
	i_pow=$(power_mean)
	read -r i_mean i_top i_bot < <(residency_summary "$TMP/idle.before" "$TMP/idle.after")

	# --- burst ---
	local b_mean b_min b_p50 b_p90 b_p99 b_rmean b_rtop b_pow t_before t_after
	t_before=$(cpu_c)
	snapshot > "$TMP/burst.before"
	power_start
	read -r b_mean b_min b_p50 b_p90 b_p99 < <(burst_run "$BURST_N")
	power_stop
	b_pow=$(power_mean)
	snapshot > "$TMP/burst.after"
	t_after=$(cpu_c)
	if [ -z "${b_mean:-}" ]; then
		echo "    SKIPPED: the burst phase produced no result for $name"
		return 1
	fi
	read -r b_rmean b_rtop _ < <(residency_summary "$TMP/burst.before" "$TMP/burst.after")

	# The ceiling is read again at the end of the measurement. If it moved,
	# something overrode the pin — the daemon came back, or a thermal
	# governor stepped in — and this measurement was taken under a moving
	# limit. Recording it is what lets the summary say so instead of
	# quietly averaging it in.
	local ceil_after
	ceil_after=$(cat "$CPUFREQ/scaling_max_freq")

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$name" "$rep" "$b_mean" "$b_min" "$b_p50" "$b_p90" "$b_p99" \
		"$b_rmean" "$b_rtop" "$i_mean" "$i_top" "$i_bot" \
		"${i_pow:-}" "${b_pow:-}" "$CEILING" "$ceil_after" >> "$RESULTS"

	if [ "$ceil_after" != "$CEILING" ]; then
		echo "    WARNING: the ceiling moved during this measurement,"
		echo "             ${CEILING} -> ${ceil_after} kHz. Treat it as void."
	fi

	echo "    burst  : mean ${b_mean}ms  best ${b_min}  p50 ${b_p50}  p90 ${b_p90}  p99 ${b_p99}"
	echo "             mean freq ${b_rmean} kHz, ${b_rtop}% at the top step${b_pow:+, ${b_pow} W}"
	echo "    idle   : mean freq ${i_mean} kHz, ${i_top}% at the top step, ${i_bot}% at the bottom${i_pow:+, ${i_pow} W}"
	if [ "$bl_before" != "$bl_after" ]; then
		echo "    WARNING: the backlight changed during the idle window,"
		echo "             [$bl_before] -> [$bl_after]. That is worth more than"
		echo "             any governor setting, so treat this power figure as void."
	elif [ -n "$bl_before" ]; then
		echo "    backlight: $bl_before (unchanged across the window)"
	fi
	echo "             residency:"
	residency_table "$TMP/idle.before" "$TMP/idle.after"
	echo "    temps  : ${t_before} C before the burst, ${t_after} C after  ($(temps))"
	return 0
}

# ------------------------------------------------------------------ main -----
QUICK=0
RESTORE_ONLY=0
case "${1:-}" in
	--quick)   QUICK=1 ;;
	--restore) RESTORE_ONLY=1 ;;
	-h|--help) sed -n '3,60p' "$0" | sed 's/^# \?//'; exit 0 ;;
	"") ;;
	*) die "unknown option: $1" ;;
esac

[ -d "$CPUFREQ" ] || die "no cpufreq policy at $CPUFREQ"
[ "$(id -u)" = 0 ] || die "needs root to write the governor tunables. Run it with sudo."

read_stock

# --restore is handled before the ondemand check on purpose. The situation it
# exists for is a run interrupted hard enough to skip its own cleanup, and the
# worst version of that leaves the machine on the performance governor — at
# which point /sys/devices/system/cpu/cpufreq/ondemand/ does not exist at all,
# because that directory only lives as long as some policy is using ondemand.
# Checking for it first would make the escape hatch refuse to open in exactly
# the case it is for. restore() sets the governor before it writes any tunable,
# which is what makes the directory come back.
if [ "$RESTORE_ONLY" = 1 ]; then
	# --restore cannot know what the machine booted with, because it reads
	# the live values like everything else. What it can do is put back the
	# documented stock configuration, which is the only thing worth having
	# after an interrupted run.
	STOCK_GOV=ondemand STOCK_UP=95 STOCK_IO=0 STOCK_SDF=1 STOCK_RATE=20000 STOCK_MIN=250000
	restore
	echo "governor      : $(cat "$CPUFREQ/scaling_governor")"
	echo "up_threshold  : $(cat "$OD/up_threshold" 2>/dev/null)"
	echo "io_is_busy    : $(cat "$OD/io_is_busy" 2>/dev/null)"
	echo "sampling_down : $(cat "$OD/sampling_down_factor" 2>/dev/null)"
	echo "scaling_min   : $(cat "$CPUFREQ/scaling_min_freq")"
	exit 0
fi

[ -d "$OD" ] || die "no ondemand tunables at $OD; is ondemand built in?"
command -v python3 >/dev/null || die "python3 is needed for the burst phase"

[ "$STOCK_GOV" = ondemand ] || die "the governor is $STOCK_GOV, not ondemand.
  This sweep measures ondemand's tunables against the machine's stock setting,
  and it cannot know what stock is if the machine is not in it. Put it back
  with --restore, or boot it fresh, and run this again."

START_MAX_C=85
if [ "$QUICK" = 1 ]; then
	IDLE_S=20;  BURST_N=200;  SETTLE_S=5;  REPEATS=2
else
	IDLE_S=30;  BURST_N=600;  SETTLE_S=10; REPEATS=2
fi
IDLE_S=${SWEEP_IDLE_S:-$IDLE_S}
BURST_N=${SWEEP_BURST_N:-$BURST_N}
REPEATS=${SWEEP_REPEATS:-$REPEATS}

TMP=$(mktemp -d)
RESULTS=$TMP/results.tsv
: > "$RESULTS"

# Restore on every exit path, including Ctrl-C and a failed command, and say
# so, because a script that silently leaves the governor somewhere else is
# worse than one that never ran.
cleanup() {
	echo
	echo "restoring the stock governor settings"
	restore
	if verify_restored; then
		echo "restored: governor $(cat "$CPUFREQ/scaling_governor"), up_threshold $(cat "$OD/up_threshold" 2>/dev/null), io_is_busy $(cat "$OD/io_is_busy" 2>/dev/null), sampling_down_factor $(cat "$OD/sampling_down_factor" 2>/dev/null), min $(cat "$CPUFREQ/scaling_min_freq") kHz"
	else
		echo "RESTORE INCOMPLETE — run: sudo $0 --restore"
	fi
	[ -n "${POWER_PID:-}" ] && kill "$POWER_PID" 2>/dev/null
	rm -rf "$TMP"
}
# INT, TERM and HUP exit rather than returning, so the run stops where it was
# interrupted; CLEANED guards against the EXIT trap then doing it all again.
# HUP is in the list because this is normally started over ssh, and a dropped
# connection must not leave the machine on a governor it did not boot with.
CLEANED=0
cleanup_once() { [ "$CLEANED" = 1 ] && return 0; CLEANED=1; cleanup; }
trap cleanup_once EXIT
trap 'cleanup_once; exit 130' INT TERM HUP

echo "kernel        : $(uname -r)"
echo "governor      : $STOCK_GOV (up_threshold $STOCK_UP, io_is_busy $STOCK_IO, sampling_down_factor $STOCK_SDF, sampling_rate $STOCK_RATE)"
echo "limits        : $STOCK_MIN .. $(cat "$CPUFREQ/scaling_max_freq") kHz"
echo "steps offered : $(wc -w < "$CPUFREQ/scaling_available_frequencies") — $(cat "$CPUFREQ/scaling_available_frequencies")"
echo "thermal daemon: $(systemctl is-active pyra-thermal 2>/dev/null || echo unknown)"
echo "temps at start: $(temps)"
if on_battery; then
	echo "power         : on battery, so watts are measured ($(cat $BATT/capacity 2>/dev/null)% charge)"
else
	echo "power         : ON THE CHARGER, so watts are not measured. Latency and"
	echo "                residency below are unaffected; only the W columns are"
	echo "                missing. Unplug and re-run if the battery cost is the"
	echo "                question."
fi
hold_ceiling
if [ "$THERMAL_WAS_ACTIVE" = 1 ]; then
	echo "thermal daemon: STOPPED for this run, and started again at the end."
	echo "                It caps on battery temperature as well as core, and"
	echo "                the battery crosses its 44 C threshold during an"
	echo "                ordinary run, which moves the ceiling underneath the"
	echo "                measurement. The kernel's step_wise governor is still"
	echo "                the protection and is untouched."
fi
echo "ceiling       : pinned at ${CEILING} kHz (was ${STOCK_MAX})"
echo "configs       : ${#CONFIGS[@]}, ${REPEATS} interleaved repeats each, order rotated per pass"
echo "windows       : ${IDLE_S}s idle + ${BURST_N} burst units per measurement"
echo

# Interleaved: every configuration once, then every configuration again. See
# the note at the top about why this is not blocked by configuration.
for rep in $(seq 1 "$REPEATS"); do
	echo "=============================================================="
	echo "pass $rep of $REPEATS"
	echo "=============================================================="
	# Rotate by one place per pass, so a configuration that ran last this
	# time runs first next time. Without this, a drift inside a single pass
	# is indistinguishable from an effect of whatever was measured late in
	# it — which is exactly how the first run made the performance governor,
	# always measured last, look slower than tuned ondemand.
	ordered=()
	n=${#CONFIGS[@]}
	for ((k = 0; k < n; k++)); do
		ordered+=("${CONFIGS[$(( (k + rep - 1) % n ))]}")
	done
	echo "  order this pass: $(for o in "${ordered[@]}"; do printf '%s ' "${o%%|*}"; done)"

	for spec in "${ordered[@]}"; do
		name=${spec%%|*}
		echo
		echo "-- $name  ($(describe_config "$spec"))"
		measure_one "$spec" "$rep"
	done
done

# --------------------------------------------------------------- summary -----
echo
echo "=============================================================="
echo "summary — every number is the mean of $REPEATS interleaved passes"
echo "=============================================================="
python3 - "$RESULTS" <<'PY'
import sys
from collections import defaultdict

rows = defaultdict(list)
order = []
voided = []
for line in open(sys.argv[1]):
    f = line.rstrip("\n").split("\t")
    if len(f) < 16:
        continue
    # A measurement taken under a ceiling that moved is not a measurement of
    # the governor, so it is dropped here rather than averaged in and
    # explained away in the prose afterwards.
    if f[14] != f[15]:
        voided.append((f[0], f[1], f[14], f[15]))
        continue
    name = f[0]
    if name not in rows:
        order.append(name)
    rows[name].append(f)

def mean(name, idx):
    vals = [float(r[idx]) for r in rows[name] if r[idx] not in ("", "-")]
    return sum(vals) / len(vals) if vals else None

M_MEAN, M_MIN, M_P50, M_P90, M_P99 = 2, 3, 4, 5, 6
M_BFREQ, M_BTOP, M_IFREQ, M_ITOP, M_IBOT, M_IPOW, M_BPOW = 7, 8, 9, 10, 11, 12, 13
M_CEIL_A, M_CEIL_B = 14, 15

if voided:
    print()
    print("VOID — the frequency ceiling moved while these were being measured,")
    print("so they say nothing about the governor and are excluded:")
    for name, rep, a, b in voided:
        print("    %-12s pass %s   %s -> %s kHz" % (name, rep, a, b))

if not rows:
    print()
    print("Every measurement was void. Nothing here can be compared. The usual")
    print("cause is the thermal daemon running: it caps on battery temperature")
    print("as well as core and will move the ceiling under the whole run.")
    raise SystemExit

ceilings = set(r[M_CEIL_A] for rs in rows.values() for r in rs)
if len(ceilings) > 1:
    print()
    print("WARNING: not every measurement ran under the same ceiling (%s kHz)." % (
        ", ".join(sorted(ceilings))))
    print("Configurations measured under different ceilings are not comparable.")

base = "stock"
if base not in rows:
    print("no stock baseline was measured; nothing to compare against")
    raise SystemExit

b_mean = mean(base, M_MEAN)
b_p99 = mean(base, M_P99)
b_ifreq = mean(base, M_IFREQ)

print()
print("burst latency, milliseconds per unit of work — lower is better")
print("%-12s %8s %8s %8s %8s %8s   %s" % (
    "config", "mean", "best", "p50", "p90", "p99", "vs stock"))
for name in order:
    m = mean(name, M_MEAN)
    d = 100.0 * (m - b_mean) / b_mean
    tag = "baseline" if name == base else ("%+.1f%%" % d)
    print("%-12s %8.1f %8.1f %8.1f %8.1f %8.1f   %s" % (
        name, m, mean(name, M_MIN), mean(name, M_P50),
        mean(name, M_P90), mean(name, M_P99), tag))

print()
print("the tail — p99, which is what 'sluggish' actually describes")
for name in order:
    p = mean(name, M_P99)
    d = 100.0 * (p - b_p99) / b_p99
    tag = "baseline" if name == base else ("%+.1f%%" % d)
    print("%-12s %8.1f ms   %s" % (name, p, tag))

print()
print("idle cost — where the machine sits with nothing to do")
print("%-12s %10s %9s %9s %8s   %s" % (
    "config", "mean kHz", "%top", "%bottom", "W", "vs stock"))
for name in order:
    f = mean(name, M_IFREQ)
    p = mean(name, M_IPOW)
    d = 100.0 * (f - b_ifreq) / b_ifreq
    tag = "baseline" if name == base else ("%+.1f%%" % d)
    print("%-12s %10.0f %9.1f %9.1f %8s   %s" % (
        name, f, mean(name, M_ITOP), mean(name, M_IBOT),
        ("%.2f" % p) if p is not None else "-", tag))

print()
print("spread across passes — a config whose passes disagree by more than the")
print("difference being claimed has not measured anything. If the spreads below")
print("are the size of the differences above, the run is noise: lengthen the")
print("windows with SWEEP_BURST_N, or add passes with SWEEP_REPEATS.")
for name in order:
    vals = [float(r[M_MEAN]) for r in rows[name]]
    if len(vals) > 1:
        spread = 100.0 * (max(vals) - min(vals)) / (sum(vals) / len(vals))
        print("%-12s  burst mean %s   spread %.1f%%" % (
            name, "  ".join("%.1f" % v for v in vals), spread))

print()
best = min((n for n in order if n != "performance"),
           key=lambda n: mean(n, M_MEAN))
perf = mean("performance", M_MEAN) if "performance" in rows else None
print("fastest ondemand configuration on burst mean: %s (%.1f ms, %+.1f%% vs stock)" % (
    best, mean(best, M_MEAN), 100.0 * (mean(best, M_MEAN) - b_mean) / b_mean))
if perf is not None:
    gap = 100.0 * (mean(best, M_MEAN) - perf) / perf
    print("performance governor: %.1f ms, the upper bound. %s is %+.1f%% of it." % (
        perf, best, gap))
    print()
    if abs(gap) < 3:
        print("That is within noise of the ceiling, so there is nothing left for")
        print("governor tuning to win and item 1 can be closed on this number.")
    else:
        print("There is still %.1f%% between the best ondemand setting and the" % gap)
        print("ceiling, so the remaining gap is real and worth one more look.")
PY

echo
echo "done on $(uname -r) at $(date -Is)"
