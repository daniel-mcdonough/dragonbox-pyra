#!/bin/bash
#
# pyra-freq-profile.sh — compare two kernels' cpufreq behaviour on this machine.
#
#   ./pyra-freq-profile.sh            full run, about seven minutes
#   ./pyra-freq-profile.sh --quick    the same shape, about two minutes
#
# WHY THIS EXISTS
#
# `5.6.19-freq` adds five operating points between the six the board ships
# with, without changing the ceiling. Whether that is worth anything cannot be
# answered by looking at the table: the steps plainly exist, and the question
# is whether the governor does anything useful with them. So this runs the same
# three phases on whichever kernel is booted and prints numbers that can be put
# side by side.
#
# Three phases, because they ask different questions:
#
#   idle       where does the machine sit when nothing is happening
#   burst      how long does a short unit of work take, when work arrives in
#              bursts with idle between them — this is the one the extra steps
#              are supposed to help, because it is the ramp that item 1 of
#              improvements.md complains about
#   sustained  does throughput at the top of the table change at all — it
#              should not, and a difference here would be a regression. One
#              core only; see the thermal note below
#
# It changes nothing. It does not touch the governor, the thermal daemon or the
# frequency limits: a comparison is only worth having if both kernels are
# running the machine's ordinary configuration. It needs no privileges.
#
# Power is reported only while the battery is discharging. On a charging
# machine the battery current measures the charger, not the workload, so it is
# printed as unavailable rather than printed wrong.
#
# The sustained phase runs on ONE core, not two. Two cores flat out took this
# machine to 107 C, seven degrees past its passive trip, in under two minutes.
# That is a finding about the thermal design rather than about either kernel,
# it is recorded in improvements.md item 2, and it is not worth reproducing on
# every run. One core reaches the top of the frequency table just as well,
# which is all this phase needs. It refuses to start above START_MAX_C and
# stops at ABORT_C, and reports the peak either way.
#
set -uo pipefail

QUICK=0
case "${1:-}" in
	--quick) QUICK=1 ;;
	-h|--help) sed -n '3,33p' "$0" | sed 's/^# \?//'; exit 0 ;;
	"") ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
esac

CPUFREQ=/sys/devices/system/cpu/cpu0/cpufreq
STATS=$CPUFREQ/stats

die() { echo "FAILED: $*" >&2; exit 1; }

[ -d "$CPUFREQ" ] || die "no cpufreq policy at $CPUFREQ"
[ -r "$STATS/time_in_state" ] || die "no cpufreq stats; CONFIG_CPU_FREQ_STAT is off"
command -v python3 >/dev/null || die "python3 is needed for the burst phase"

if [ "$QUICK" = 1 ]; then IDLE_S=20; BURST_N=200; else IDLE_S=120; BURST_N=1200; fi

# Read the residency table into "khz jiffies" pairs.
snapshot() { cat "$STATS/time_in_state"; }
trans()    { cat "$STATS/total_trans"; }

temps() {
	local z n
	for z in /sys/class/thermal/thermal_zone*; do
		n=$(cat "$z/type" 2>/dev/null) || continue
		case "$n" in cpu_thermal|core_thermal|gpu_thermal)
			printf '%s=%s ' "${n%%_*}" "$(( $(cat "$z/temp") / 1000 ))" ;;
		esac
	done
	echo
}

START_MAX_C=85          # refuse to start the hot phase above this
ABORT_C=100             # the passive trip. Measured 2026-09-12: both cores
                        # flat out walks straight through it to 107 C, because
                        # step_wise gives up one cooling state per poll and the
                        # heat arrives faster than that. So the hot phase is
                        # single-threaded and this limit is the trip itself,
                        # rather than a number above it.

BATT=/sys/class/power_supply/bq27421-0

cpu_c() { echo $(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 )); }

on_battery() { [ "$(cat $BATT/status 2>/dev/null)" = Discharging ]; }

# Milliwatts, positive meaning drawn from the battery. Empty when charging.
watts_mw() {
	local uv ua
	on_battery || return 1
	uv=$(cat $BATT/voltage_now 2>/dev/null) || return 1
	ua=$(cat $BATT/current_now 2>/dev/null) || return 1
	[ "$ua" -lt 0 ] && ua=$(( -ua ))
	echo $(( uv / 1000 * ua / 1000000 ))
}

# Average power across a window, sampled once a second in the background.
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
	if [ -s "${POWER_LOG:-/nonexistent}" ]; then
		awk '{s+=$1; n++} END {if (n) printf "    power      : %.2f W mean over %d samples\n", s/n/1000, n}' "$POWER_LOG"
	else
		echo "    power      : not measured (the machine is on the charger)"
	fi
}

# Print the residency difference between two snapshots as a percentage of the
# window, which is the only form in which two runs of different length can be
# compared at all.
report_residency() {
	local before=$1 after=$2
	python3 - "$before" "$after" <<-'PY'
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
		    print("  (no residency recorded)")
		    raise SystemExit
		mean = sum(k * v for k, v in delta.items()) / total
		for k in sorted(delta):
		    pct = 100.0 * delta[k] / total
		    bar = "#" * int(pct / 2)
		    print("    %7d kHz  %5.1f%%  %s" % (k, pct, bar))
		print("    mean frequency while the window ran: %.0f kHz" % mean)
	PY
}

phase_header() { printf '\n== %s\n' "$*"; }

echo "kernel        : $(uname -r)"
echo "governor      : $(cat $CPUFREQ/scaling_governor)"
echo "limits        : $(cat $CPUFREQ/scaling_min_freq) .. $(cat $CPUFREQ/scaling_max_freq) kHz"
echo "steps offered : $(cat $CPUFREQ/scaling_available_frequencies)"
echo "step count    : $(wc -w < $CPUFREQ/scaling_available_frequencies)"
echo "temps at start: $(temps)"
echo "charger       : $(cat /sys/class/power_supply/bq24297/online 2>/dev/null || echo '?') (1 means power figures would be meaningless, so none are printed)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- idle -------
phase_header "idle, ${IDLE_S}s — where the machine sits with nothing to do"
snapshot > "$TMP/idle.before"; t0=$(trans); power_start idle
sleep "$IDLE_S"
snapshot > "$TMP/idle.after";  t1=$(trans)
report_residency "$TMP/idle.before" "$TMP/idle.after"
echo "    transitions: $((t1 - t0))"
power_stop
echo "    temps      : $(temps)"

# --------------------------------------------------------------- burst -------
# A fixed unit of work, then idle, repeated. The number that matters is how
# long the unit took, not how many ran: bursty work is where a slow ramp is
# felt, and the tail of that distribution is what someone means by "sluggish".
phase_header "burst, ${BURST_N} units — how long a short unit of work takes"
snapshot > "$TMP/burst.before"; t0=$(trans); power_start burst
python3 - "$BURST_N" > "$TMP/burst.out" <<'PY'
import sys, time

n = int(sys.argv[1])

def work():
    # Roughly 15-25 ms of integer work at this machine's clocks. Deliberately
    # plain arithmetic: no libraries, nothing that could dispatch differently
    # between two kernels built from the same source.
    s = 0
    for i in range(120000):
        s += i * i
    return s

# One untimed unit so the interpreter is warm and the first sample is not
# measuring import and bytecode setup.
work()
time.sleep(0.2)

lat = []
for _ in range(n):
    t = time.perf_counter()
    work()
    lat.append((time.perf_counter() - t) * 1000.0)
    time.sleep(0.06)        # long enough for the governor to want to step down

lat.sort()
def pct(p):
    return lat[min(len(lat) - 1, int(len(lat) * p / 100.0))]
print("%.1f %.1f %.1f %.1f %.1f" % (
    sum(lat) / len(lat), lat[0], pct(50), pct(90), pct(99)))
PY
read -r B_MEAN B_MIN B_P50 B_P90 B_P99 < "$TMP/burst.out"
snapshot > "$TMP/burst.after"; t1=$(trans)
echo "    unit latency, milliseconds:"
echo "      mean $B_MEAN   best $B_MIN   p50 $B_P50   p90 $B_P90   p99 $B_P99"
report_residency "$TMP/burst.before" "$TMP/burst.after"
echo "    transitions: $((t1 - t0))"
power_stop
echo "    temps      : $(temps)"

# ----------------------------------------------------------- sustained -------
# Both kernels top out at the same frequency, so this should not move. It is
# here to catch the case where it does.
phase_header "sustained — throughput at the top of the table, both cores"
if ! command -v 7z >/dev/null; then
	echo "    7z is not installed, so throughput is not measured"
elif [ "$(cpu_c)" -gt "$START_MAX_C" ]; then
	echo "    SKIPPED: the CPU is already at $(cpu_c) C, above the ${START_MAX_C} C"
	echo "    start limit. Let it cool and run this phase again; starting hot"
	echo "    measures the trip, not the kernel."
else
	snapshot > "$TMP/sust.before"; t0=$(trans); power_start sust
	# One thread: see the note at the top about two cores and the trip.
	if [ "$QUICK" = 1 ]; then SEVEN="7z b -mmt1"; else SEVEN="7z b 2 -mmt1"; fi

	# Watch the temperature while it runs, and record the peak. The passive
	# trip at 100 C should hold it; ABORT_C is for the case where it does
	# not, which is a fanless case with both cores flat out.
	PEAK=0
	$SEVEN > "$TMP/7z.out" 2>/dev/null &
	SEVEN_PID=$!
	while kill -0 "$SEVEN_PID" 2>/dev/null; do
		c=$(cpu_c)
		[ "$c" -gt "$PEAK" ] && PEAK=$c
		if [ "$c" -ge "$ABORT_C" ]; then
			echo "    ABORTED at ${c} C, above the ${ABORT_C} C limit"
			kill "$SEVEN_PID" 2>/dev/null
			break
		fi
		sleep 2
	done
	wait "$SEVEN_PID" 2>/dev/null

	# 7z's own columns are not in fixed positions across versions, so print
	# its summary lines as it wrote them rather than relabelling fields.
	grep -E '^(Avr|Tot):' "$TMP/7z.out" | sed 's/^/    7z  /' || echo "    7z produced no summary"

	snapshot > "$TMP/sust.after"; t1=$(trans)
	report_residency "$TMP/sust.before" "$TMP/sust.after"
	echo "    transitions: $((t1 - t0))"
	power_stop
	echo "    peak CPU   : ${PEAK} C"
	echo "    temps      : $(temps)"
fi

echo
echo "done on $(uname -r) at $(date -Is)"
