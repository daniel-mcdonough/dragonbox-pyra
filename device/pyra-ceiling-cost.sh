#!/bin/bash
#
# pyra-ceiling-cost.sh — measure what each rung of the thermal daemon's
# frequency ladder costs.
#
#   sudo ./pyra-ceiling-cost.sh            full run, about 16 minutes
#   sudo ./pyra-ceiling-cost.sh --quick    the same shape, about 6 minutes
#   sudo ./pyra-ceiling-cost.sh --restore  put the ceiling back and exit
#
# WHY THIS EXISTS
#
# `/usr/share/pyra/scripts/pyra-thermal.sh` caps the CPU on **battery**
# temperature as well as core temperature, and the battery branch is the one
# that fires in ordinary use on this machine:
#
#     battery > 44 C  ->  1250 MHz        core > 77 C  ->  1250 MHz
#     battery > 45 C  ->  1000 MHz        core > 82 C  ->  1000 MHz
#     battery > 47 C  ->   750 MHz        core > 87 C  ->   750 MHz
#
# The core has to reach 77 C before it gives up anything. The battery only has
# to reach 44 C, and it sits at 42-45 C in ordinary use, so the machine spends
# ordinary afternoons two or three steps below its own top speed.
#
# Before arguing about whether that ladder is right, it is worth knowing what
# it costs. "Two steps down" is 17% of the clock, but the clock is not what a
# person feels, and a governor that never reaches the ceiling anyway would make
# the cap free. This measures the rungs the battery branch actually selects.
#
# WHAT IT MEASURES, AND WHY BOTH
#
#   burst      how long a short unit of work takes, when work arrives in
#              bursts with idle between them. This is the interactive number.
#              A cap costs a burst nothing if the governor was not going to
#              reach the top of the table during it anyway.
#
#   sustained  a fixed quantity of work on one core, timed. This is the
#              throughput number, and it should track the clock ratio almost
#              exactly. It is here because the two answers differ, and which
#              one matters depends on what the machine is doing.
#
#   power      mean watts across each window, on battery only. A cap that
#              bought real battery life would be defensible even if it cost
#              speed, so the cost side has to be measured too.
#
# It runs with the machine's own governor and its own tunables, deliberately.
# The question is not what a ceiling costs in the abstract, it is what this
# ladder costs this machine as configured.
#
# HOW IT AVOIDS FOOLING ITSELF
#
# Repeats are interleaved and rotated, for the reasons written out at length in
# `pyra-governor-sweep.sh`: a machine drifts across a run, and blocked repeats
# fold that drift into whichever setting was being measured at the time.
#
# It stops the thermal daemon for the duration and sets the ceiling itself.
# That is the whole point — the daemon's own decisions are the thing under
# test, and a daemon moving the ceiling underneath the measurement is how the
# first governor sweep was voided. The ceiling is read back around every window
# and a window whose ceiling moved is discarded rather than reported.
#
# The daemon is started again on any exit, including Ctrl-C, a dropped SSH and
# a failed command. If it is ever killed hard enough to skip that, `--restore`
# puts the machine back without measuring anything.
#
set -uo pipefail

MODE=run
case "${1:-}" in
	--quick)   MODE=quick ;;
	--restore) MODE=restore ;;
	-h|--help) sed -n '3,64p' "$0" | sed 's/^# \?//'; exit 0 ;;
	"") ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
esac

CPUFREQ=/sys/devices/system/cpu/cpu0/cpufreq
STATS=$CPUFREQ/stats
BATT=/sys/class/power_supply/bq27421-0
THERMAL_UNIT=pyra-thermal

die()  { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
say()  { printf '\n== %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# The rungs the battery branch of the vendor ladder selects, in kHz. 1500000 is
# not a rung, it is the absence of one, and it is the baseline everything else
# is measured against. 500 and 250 MHz are in the ladder too, above 49 C and
# 50 C, and are left out: a battery that hot is a different conversation and
# the sustained phase at 250 MHz would take a quarter of an hour by itself.
CEILINGS=(1500000 1250000 1000000 750000)

[ "$(id -u)" = 0 ] || die "run this with sudo: it sets scaling_max_freq and stops $THERMAL_UNIT"
[ -d "$CPUFREQ" ] || die "no cpufreq policy at $CPUFREQ"

TOP=$(tr ' ' '\n' < "$CPUFREQ/scaling_available_frequencies" | sort -n | tail -1)

set_ceiling() {
	local f=$1 c
	for c in /sys/devices/system/cpu/cpu[0-9]/cpufreq/scaling_max_freq; do
		[ -w "$c" ] && echo "$f" > "$c" 2>/dev/null
	done
	[ "$(cat "$CPUFREQ/scaling_max_freq")" = "$f" ]
}

# ------------------------------------------------------------- restore -------
# Before every other check, so that a machine left mid-run by a dropped SSH can
# always be put back. It must not depend on anything the run set up.
if [ "$MODE" = restore ]; then
	set_ceiling "$TOP" && note "ceiling set to $TOP kHz"
	systemctl start "$THERMAL_UNIT" 2>/dev/null \
		&& note "$THERMAL_UNIT started" \
		|| note "could not start $THERMAL_UNIT"
	note "the daemon's next poll decides the ceiling from here, which is right"
	exit 0
fi

command -v python3 >/dev/null || die "python3 is needed for the burst phase"
[ -r "$STATS/time_in_state" ] || note "no cpufreq stats; residency will not be printed"

if [ "$MODE" = quick ]; then
	BURST_N=${CC_BURST_N:-150}; SUST_LOOPS=${CC_SUST_LOOPS:-250}; REPEATS=${CC_REPEATS:-2}
else
	# 900 loops is about 30 seconds at the top of the table and about a
	# minute at 750 MHz, which is long enough to be a throughput measurement
	# and long enough for the board to reach the temperature this run exists
	# to record. Shorter windows measure the ramp, not the steady state.
	BURST_N=${CC_BURST_N:-400}; SUST_LOOPS=${CC_SUST_LOOPS:-900}; REPEATS=${CC_REPEATS:-2}
fi
SETTLE_S=${CC_SETTLE_S:-3}
START_MAX_C=${CC_START_MAX_C:-85}
ABORT_C=${CC_ABORT_C:-100}

TMP=$(mktemp -d)
RESULTS=$TMP/results.tsv
: > "$RESULTS"

THERMAL_WAS_ACTIVE=0
STOCK_MAX=$(cat "$CPUFREQ/scaling_max_freq")
CLEANED=0

cleanup_once() {
	[ "$CLEANED" = 1 ] && return 0
	CLEANED=1
	set_ceiling "$TOP" >/dev/null 2>&1
	if [ "$THERMAL_WAS_ACTIVE" = 1 ]; then
		systemctl start "$THERMAL_UNIT" 2>/dev/null \
			&& note "$THERMAL_UNIT started again" \
			|| note "COULD NOT RESTART $THERMAL_UNIT — run: sudo systemctl start $THERMAL_UNIT"
	else
		set_ceiling "$STOCK_MAX" >/dev/null 2>&1
	fi
	rm -rf "$TMP"
}
trap cleanup_once EXIT
trap 'cleanup_once; exit 130' INT TERM HUP

cpu_c()  { echo $(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 )); }
ceil()   { cat "$CPUFREQ/scaling_max_freq"; }

# The fuel gauge zone, by type rather than by number: it is the sensor the
# thermal daemon throttles on, and what it reads while a known load runs at a
# known ceiling is what any threshold for it has to be derived from.
GAUGE_DEV=
for _z in /sys/class/thermal/thermal_zone*; do
	case "$(cat "$_z/type" 2>/dev/null)" in bq27421*) GAUGE_DEV=$_z/temp ;; esac
done
gauge_c() { [ -n "$GAUGE_DEV" ] && echo $(( $(cat "$GAUGE_DEV") / 1000 )) || echo "-"; }

temps() {
	local z n
	for z in /sys/class/thermal/thermal_zone*; do
		n=$(cat "$z/type" 2>/dev/null) || continue
		printf '%s=%s ' "${n%%_*}" "$(( $(cat "$z/temp") / 1000 ))"
	done
	echo
}

backlight() {
	local b
	for b in /sys/class/backlight/*/brightness; do
		[ -r "$b" ] && { cat "$b"; return; }
	done
	echo "-"
}

on_battery() { [ "$(cat $BATT/status 2>/dev/null)" = Discharging ]; }

watts_mw() {
	local uv ua
	on_battery || return 1
	uv=$(cat $BATT/voltage_now 2>/dev/null) || return 1
	ua=$(cat $BATT/current_now 2>/dev/null) || return 1
	[ "$ua" -lt 0 ] && ua=$(( -ua ))
	echo $(( uv / 1000 * ua / 1000000 ))
}

# Split in three on purpose. A command substitution is a subshell and cannot
# reap a background job started by its parent, so a power_stop that both killed
# the sampler and printed the mean would leave the sampler running into the
# next window and log it against the wrong ceiling.
POWER_PID=
POWER_LOG=
power_start() {
	POWER_LOG=$TMP/power.$1
	: > "$POWER_LOG"
	( while :; do watts_mw >> "$POWER_LOG" 2>/dev/null; sleep 1; done ) &
	POWER_PID=$!
}
power_stop() {
	[ -n "${POWER_PID:-}" ] && kill "$POWER_PID" 2>/dev/null
	wait "$POWER_PID" 2>/dev/null
	POWER_PID=
}
power_mean() {
	if [ -s "${POWER_LOG:-/nonexistent}" ]; then
		awk '{s+=$1; n++} END {if (n) printf "%.2f", s/n/1000}' "$POWER_LOG"
	else
		echo ""
	fi
}

# Identical to the burst in pyra-governor-sweep.sh and pyra-freq-profile.sh, on
# purpose: the numbers are only worth having if they sit beside the others.
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

# A fixed quantity of work, timed, on one core. One core and not two: two cores
# flat out take this machine seven degrees past its passive trip in under two
# minutes, which is a finding about the case and not about a ceiling.
#
# Watched while it runs. An earlier version of this script checked the
# temperature before starting and then never looked again, which is not a
# thermal guard, it is a thermal guess — this machine can cross 30 C in under
# twenty seconds. If the window is abandoned the caller gets an empty result
# and drops the row rather than recording a truncated one as a measurement.
sust_run() {
	local loops=$1 out peak=0 c pid
	out=$TMP/sust.out
	: > "$out"
	taskset -c 1 python3 - "$loops" > "$out" 2>/dev/null <<-'PY' &
		import sys, time
		loops = int(sys.argv[1])
		def work():
		    s = 0
		    for i in range(120000):
		        s += i * i
		    return s
		work()
		t = time.perf_counter()
		for _ in range(loops):
		    work()
		print("%.2f" % (time.perf_counter() - t))
	PY
	pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		c=$(cpu_c)
		[ "$c" -gt "$peak" ] && peak=$c
		if [ "$c" -ge "$ABORT_C" ]; then
			note "  ABANDONED the sustained window at ${c} C, at or above ${ABORT_C} C"
			kill "$pid" 2>/dev/null
			wait "$pid" 2>/dev/null
			SUST_PEAK=$peak
			return 1
		fi
		sleep 1
	done
	wait "$pid" 2>/dev/null
	SUST_PEAK=$peak
	cat "$out"
}

cool_to_start() {
	local c waited=0
	c=$(cpu_c)
	[ "$c" -le "$START_MAX_C" ] && return 0
	note "waiting for the CPU to come below ${START_MAX_C} C (now ${c} C)"
	while [ "$(cpu_c)" -gt "$START_MAX_C" ] && [ "$waited" -lt 300 ]; do
		sleep 10; waited=$((waited + 10))
	done
}

# ------------------------------------------------------------------ run ------
echo "kernel        : $(uname -r)"
echo "governor      : $(cat $CPUFREQ/scaling_governor)"
if [ -d /sys/devices/system/cpu/cpufreq/ondemand ]; then
	echo "ondemand      : up_threshold=$(cat /sys/devices/system/cpu/cpufreq/ondemand/up_threshold) io_is_busy=$(cat /sys/devices/system/cpu/cpufreq/ondemand/io_is_busy) sampling_down_factor=$(cat /sys/devices/system/cpu/cpufreq/ondemand/sampling_down_factor)"
fi
echo "min freq      : $(cat $CPUFREQ/scaling_min_freq) kHz"
echo "top of table  : $TOP kHz"
echo "ceiling now   : $STOCK_MAX kHz"
echo "temps         : $(temps)"
echo "backlight     : $(backlight)"
echo "on battery    : $(on_battery && echo yes || echo 'no — power figures will be blank, the charger is what the battery current measures')"
echo "burst units   : $BURST_N per window, sustained loops: $SUST_LOOPS, repeats: $REPEATS"

say "stopping $THERMAL_UNIT for the duration"
if systemctl is-active --quiet "$THERMAL_UNIT" 2>/dev/null; then
	THERMAL_WAS_ACTIVE=1
	systemctl stop "$THERMAL_UNIT" 2>/dev/null \
		&& note "stopped, and it will be started again at the end" \
		|| note "could not stop it; the ceiling may move under the run"
else
	note "it was not running, so nothing to stop"
fi

measure_one() {
	local f=$1 rep=$2
	cool_to_start

	set_ceiling "$f" || { note "  could not set the ceiling to $f kHz — skipped"; return 1; }
	sleep "$SETTLE_S"

	local c_before c_after bl_before bl_after
	c_before=$(ceil); bl_before=$(backlight)

	local b_mean b_min b_p50 b_p90 b_p99
	power_start "burst.$f.$rep"
	read -r b_mean b_min b_p50 b_p90 b_p99 < <(burst_run "$BURST_N")
	power_stop
	local b_pow; b_pow=$(power_mean)

	local s_secs
	SUST_PEAK=0
	power_start "sust.$f.$rep"
	s_secs=$(sust_run "$SUST_LOOPS") || s_secs=""
	power_stop
	local s_pow; s_pow=$(power_mean)

	c_after=$(ceil); bl_after=$(backlight)

	if [ -z "${b_mean:-}" ] || [ -z "${s_secs:-}" ]; then
		note "  $f kHz rep $rep: a window produced nothing or was abandoned — not recorded"
		return 1
	fi
	if [ "$c_before" != "$c_after" ] || [ "$c_before" != "$f" ]; then
		note "  $f kHz rep $rep: VOID — the ceiling moved ($c_before -> $c_after)"
		return 1
	fi
	if [ "$bl_before" != "$bl_after" ]; then
		note "  $f kHz rep $rep: backlight changed ($bl_before -> $bl_after); power figure dropped"
		b_pow=""; s_pow=""
	fi

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$f" "$rep" "$b_mean" "$b_p50" "$b_p90" "$b_p99" "${b_pow:--}" \
		"$s_secs" "${s_pow:--}" "$(cpu_c)" "$(gauge_c)" >> "$RESULTS"

	printf '  %7s kHz rep %s   burst mean %6s  p50 %6s  p99 %6s   sustained %7s s   core %s C (peak %s)  gauge %s C\n' \
		"$f" "$rep" "$b_mean" "$b_p50" "$b_p99" "$s_secs" "$(cpu_c)" "${SUST_PEAK:-?}" "$(gauge_c)"
	return 0
}

n=${#CEILINGS[@]}
for ((rep = 1; rep <= REPEATS; rep++)); do
	# Rotate the order every pass. Interleaving alone fixes drift between
	# passes but leaves each ceiling in a fixed slot within a pass, which is
	# its own confound: the first slot is always the coolest.
	ordered=()
	for ((k = 0; k < n; k++)); do
		ordered+=("${CEILINGS[$(( (k + rep - 1) % n ))]}")
	done
	say "pass $rep of $REPEATS"
	note "order this pass: ${ordered[*]}"
	for f in "${ordered[@]}"; do
		measure_one "$f" "$rep"
	done
done

# --------------------------------------------------------------- report ------
say "results"
[ -s "$RESULTS" ] || die "nothing was measured"

python3 - "$RESULTS" <<'PY'
import sys, collections

rows = []
for line in open(sys.argv[1]):
    p = line.rstrip("\n").split("\t")
    if len(p) < 11:
        continue
    rows.append(dict(
        khz=int(p[0]), rep=int(p[1]),
        b_mean=float(p[2]), b_p50=float(p[3]), b_p90=float(p[4]), b_p99=float(p[5]),
        b_pow=(None if p[6] == "-" else float(p[6])),
        s=float(p[7]),
        s_pow=(None if p[8] == "-" else float(p[8])),
        core=(None if p[9] == "-" else float(p[9])),
        gauge=(None if p[10] == "-" else float(p[10])),
    ))

by = collections.OrderedDict()
for r in rows:
    by.setdefault(r["khz"], []).append(r)

def mean(v):
    v = [x for x in v if x is not None]
    return sum(v) / len(v) if v else None

order = sorted(by, reverse=True)
base = by[order[0]] if order else None
b_base = mean([r["b_mean"] for r in base]) if base else None
s_base = mean([r["s"] for r in base]) if base else None

print()
print("  Spread across passes first. A ceiling whose passes disagree by more")
print("  than the difference being claimed has not measured anything.")
print()
for k in order:
    v = [r["b_mean"] for r in by[k]]
    sp = (max(v) - min(v)) / (sum(v) / len(v)) * 100 if len(v) > 1 and sum(v) else 0.0
    print("    %7d kHz   burst mean %s   spread %.1f%%" % (
        k, "  ".join("%.1f" % x for x in v), sp))

print()
print("  %-9s %9s %8s %8s %8s %9s %9s" % (
    "ceiling", "burst", "vs top", "p50", "p99", "sustained", "vs top"))
print("  %-9s %9s %8s %8s %8s %9s %9s" % (
    "MHz", "mean ms", "", "ms", "ms", "seconds", ""))
for k in order:
    v = by[k]
    bm, p50, p99, ss = (mean([r["b_mean"] for r in v]), mean([r["b_p50"] for r in v]),
                        mean([r["b_p99"] for r in v]), mean([r["s"] for r in v]))
    bd = "baseline" if k == order[0] else "%+.1f%%" % ((bm - b_base) / b_base * 100)
    sd = "baseline" if k == order[0] else "%+.1f%%" % ((ss - s_base) / s_base * 100)
    print("  %-9d %9.1f %8s %8.1f %8.1f %9.2f %9s" % (k // 1000, bm, bd, p50, p99, ss, sd))

print()
print("  clock ratio for reference — what the cap would cost if work always")
print("  ran at the ceiling:")
for k in order[1:]:
    print("    %4d MHz is %+.1f%% of clock against %d MHz" % (
        k // 1000, (order[0] / k - 1) * 100, order[0] // 1000))

pw = [(k, mean([r["b_pow"] for r in by[k]]), mean([r["s_pow"] for r in by[k]])) for k in order]
if any(b is not None or s is not None for _, b, s in pw):
    print()
    print("  %-9s %12s %12s" % ("ceiling", "burst W", "sustained W"))
    for k, b, s in pw:
        print("  %-9d %12s %12s" % (
            k // 1000,
            "%.2f" % b if b is not None else "-",
            "%.2f" % s if s is not None else "-"))
    print()
    print("  If a lower ceiling does not buy meaningfully fewer watts on the")
    print("  sustained window, then it is costing speed for nothing, which is")
    print("  the whole question this script exists to answer.")

print()
print("  %-9s %12s %12s" % ("ceiling", "core C", "gauge C"))
print("  (at the end of the sustained window, which is the hottest this gets)")
for k in order:
    c = mean([r["core"] for r in by[k]])
    g = mean([r["gauge"] for r in by[k]])
    print("  %-9d %12s %12s" % (
        k // 1000,
        "%.1f" % c if c is not None else "-",
        "%.1f" % g if g is not None else "-"))
print()
print("  The gauge figure against the TOP ceiling is the one that matters: it")
print("  is where the sensor the thermal daemon throttles on actually sits when")
print("  the machine is working at full speed and nothing is capping it. Any")
print("  threshold on that sensor has to be above it, or it is not a thermal")
print("  limit, it is a speed limit.")
PY

echo
echo "temps at the end: $(temps)"
echo "done at $(date -Is)"
