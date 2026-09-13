#!/bin/bash
#
# pyra-thermal-probe.sh — log every temperature sensor and the CPU ceiling
# through a load cycle, twice: once with the thermal daemon deciding, and once
# with it out of the way.
#
#   sudo ./pyra-thermal-probe.sh              both arms, about 22 minutes
#   sudo ./pyra-thermal-probe.sh --arm vendor  only the daemon's arm
#   sudo ./pyra-thermal-probe.sh --arm pinned  only the pinned arm
#   sudo ./pyra-thermal-probe.sh --restore     put the machine back and exit
#
# WHY THIS EXISTS
#
# `pyra-thermal.sh` decides the CPU ceiling from two sensors. One of them it
# calls the battery. Two questions follow, and neither can be answered by
# reading the script:
#
#   Is that sensor measuring a battery?  A cell has an enormous thermal mass
#       and nothing to heat it when the machine is discharging gently. A chip
#       on the mainboard does not and has. So: load one core, and watch how
#       fast the sensor moves. This is the vendor arm, and it also records what
#       the daemon does about it, which is the fault itself.
#
#   Where does that sensor actually sit when the machine is genuinely hot?
#       The daemon's own ladder gets in the way of answering that, because it
#       caps the CPU and so limits the heat. So the second arm stops the daemon,
#       pins the ceiling at the top of the table and loads one core, and logs
#       where every sensor settles. That is the number any sane threshold for
#       this sensor has to be derived from.
#
# ONE CORE BY DEFAULT, NOT TWO. Two cores flat out took this machine seven
# degrees past its 100 C passive trip in under two minutes, back when the
# daemon could not apply a cap at all; that is a finding about a fanless case
# and not about a ladder, it is already recorded, and it is not worth
# reproducing on every run. One core reaches the top of the frequency table
# perfectly well, which is all the questions above need.
#
# PROBE_CORES=2 loads both, and exists for one specific question: after
# changing a thermal ladder, does the machine still keep itself under control
# under the heaviest load it can be given? Only run it in the `vendor` arm,
# with a working daemon. Two cores in the `pinned` arm is the exact
# configuration that reached 107 C, because the pinned arm deliberately has no
# userspace thermal control; the script refuses that combination rather than
# leaving it to be discovered.
#
# Both arms abort at ABORT_C and report the peak either way.
#
# The pinned arm stops the daemon and is therefore running the machine with no
# userspace thermal control at all, which is exactly the state every trixie
# Pyra was in before `pyra-thermal-fix.sh`. The kernel's step_wise governor and
# the 100 C passive trip are still there. The daemon is started again on any
# exit, including Ctrl-C, a dropped SSH and a failed command; `--restore` puts
# it back if it is ever killed hard enough to skip that.
#
# Output is one tab-separated file per arm, written where --out says, plus a
# summary on stdout.
#
set -uo pipefail

ARM=both
OUTDIR=${PROBE_OUT:-/tmp}
while [ $# -gt 0 ]; do
	case "$1" in
		--arm) ARM=${2:-}; shift 2 ;;
		--out) OUTDIR=${2:-}; shift 2 ;;
		--restore) ARM=restore; shift ;;
		-h|--help) sed -n '3,57p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
case "$ARM" in both|vendor|pinned|restore) ;; *) echo "--arm must be vendor, pinned or both" >&2; exit 2 ;; esac

CPUFREQ=/sys/devices/system/cpu/cpu0/cpufreq
BATT=/sys/class/power_supply/bq27421-0
THERMAL_UNIT=pyra-thermal

die()  { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
say()  { printf '\n== %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

CORES=${PROBE_CORES:-1}

case "$CORES" in 1|2) ;; *) die "PROBE_CORES must be 1 or 2" ;; esac
if [ "$CORES" = 2 ] && { [ "$ARM" = pinned ] || [ "$ARM" = both ]; }; then
	die "PROBE_CORES=2 with the pinned arm is the configuration that reached
  107 C on this machine: both cores flat out and no userspace thermal control.
  Run it as --arm vendor, with a daemon that can actually cap."
fi

[ "$(id -u)" = 0 ] || die "run this with sudo: the pinned arm stops $THERMAL_UNIT"
[ -d "$CPUFREQ" ] || die "no cpufreq policy at $CPUFREQ"

TOP=$(tr ' ' '\n' < "$CPUFREQ/scaling_available_frequencies" | sort -n | tail -1)

set_ceiling() {
	local f=$1 c
	for c in /sys/devices/system/cpu/cpu[0-9]/cpufreq/scaling_max_freq; do
		[ -w "$c" ] && echo "$f" > "$c" 2>/dev/null
	done
}

if [ "$ARM" = restore ]; then
	set_ceiling "$TOP"
	systemctl start "$THERMAL_UNIT" 2>/dev/null \
		&& note "$THERMAL_UNIT started; its next poll owns the ceiling again" \
		|| note "could not start $THERMAL_UNIT"
	exit 0
fi

IDLE1=${PROBE_IDLE1:-60}
LOAD=${PROBE_LOAD:-420}
IDLE2=${PROBE_IDLE2:-180}
STEP=${PROBE_STEP:-5}
ABORT_C=${PROBE_ABORT_C:-100}
START_MAX_C=${PROBE_START_MAX_C:-70}

# Name every zone once, by type, so the log's columns do not depend on the
# order the kernel happened to register them in.
ZONES=()
ZNAMES=()
for z in /sys/class/thermal/thermal_zone*; do
	[ -r "$z/temp" ] || continue
	ZONES+=("$z/temp")
	ZNAMES+=("$(cat "$z/type" 2>/dev/null || basename "$z")")
done
[ "${#ZONES[@]}" -gt 0 ] || die "no readable thermal zones"

cpu_c() { echo $(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 )); }

THERMAL_WAS_ACTIVE=0
CLEANED=0
LOADPID=
cleanup_once() {
	[ "$CLEANED" = 1 ] && return 0
	CLEANED=1
	# shellcheck disable=SC2086
	[ -n "${LOADPID:-}" ] && kill $LOADPID 2>/dev/null
	set_ceiling "$TOP"
	if [ "$THERMAL_WAS_ACTIVE" = 1 ]; then
		systemctl start "$THERMAL_UNIT" 2>/dev/null \
			&& note "$THERMAL_UNIT started again" \
			|| note "COULD NOT RESTART $THERMAL_UNIT — run: sudo systemctl start $THERMAL_UNIT"
	fi
}
trap cleanup_once EXIT
trap 'cleanup_once; exit 130' INT TERM HUP

cool_to_start() {
	local waited=0
	[ "$(cpu_c)" -le "$START_MAX_C" ] && return 0
	note "waiting for the CPU to come below ${START_MAX_C} C (now $(cpu_c) C)"
	while [ "$(cpu_c)" -gt "$START_MAX_C" ] && [ "$waited" -lt 600 ]; do
		sleep 10; waited=$((waited + 10))
	done
	note "starting at $(cpu_c) C after ${waited}s"
}

run_arm() {
	local arm=$1 out=$2 t0 peak=0 z
	cool_to_start

	THERMAL_WAS_ACTIVE=0
	if [ "$arm" = pinned ]; then
		if systemctl is-active --quiet "$THERMAL_UNIT" 2>/dev/null; then
			THERMAL_WAS_ACTIVE=1
			systemctl stop "$THERMAL_UNIT" 2>/dev/null || note "could not stop $THERMAL_UNIT"
		fi
		set_ceiling "$TOP"
		note "daemon stopped, ceiling pinned at $(cat $CPUFREQ/scaling_max_freq) kHz"
	else
		systemctl start "$THERMAL_UNIT" 2>/dev/null || true
		systemctl is-active --quiet "$THERMAL_UNIT" \
			&& note "daemon running and deciding the ceiling, which is the point of this arm" \
			|| note "WARNING: the daemon is not running, so this arm measures nothing it is supposed to"
	fi

	{ printf 't\tphase'; for z in "${ZNAMES[@]}"; do printf '\t%s' "$z"; done
	  printf '\tmaxfreq\tcurfreq\tbatt_ua\tbatt_uv\n'; } > "$out"

	t0=$(date +%s)
	sample() {
		local c
		printf '%s\t%s' "$(( $(date +%s) - t0 ))" "$1" >> "$out"
		for z in "${ZONES[@]}"; do printf '\t%s' "$(cat "$z" 2>/dev/null)" >> "$out"; done
		printf '\t%s\t%s\t%s\t%s\n' \
			"$(cat $CPUFREQ/scaling_max_freq)" "$(cat $CPUFREQ/scaling_cur_freq)" \
			"$(cat $BATT/current_now 2>/dev/null)" "$(cat $BATT/voltage_now 2>/dev/null)" >> "$out"
		c=$(cpu_c); [ "$c" -gt "$peak" ] && peak=$c
	}

	local i
	for ((i = 0; i < IDLE1; i += STEP)); do sample idle1; sleep "$STEP"; done

	LOADPIDS=
	local c
	for ((c = 0; c < CORES; c++)); do
		taskset -c "$c" sh -c 'while :; do :; done' &
		LOADPIDS="$LOADPIDS $!"
	done
	LOADPID=$LOADPIDS
	for ((i = 0; i < LOAD; i += STEP)); do
		sample load
		if [ "$(cpu_c)" -ge "$ABORT_C" ]; then
			note "ABORTED at $(cpu_c) C, at or above the ${ABORT_C} C limit"
			break
		fi
		sleep "$STEP"
	done
	# shellcheck disable=SC2086
	kill $LOADPIDS 2>/dev/null; wait $LOADPIDS 2>/dev/null; LOADPID=; LOADPIDS=

	for ((i = 0; i < IDLE2; i += STEP)); do sample idle2; sleep "$STEP"; done

	note "peak CPU zone this arm: ${peak} C"

	if [ "$arm" = pinned ] && [ "$THERMAL_WAS_ACTIVE" = 1 ]; then
		systemctl start "$THERMAL_UNIT" 2>/dev/null && note "$THERMAL_UNIT started again"
		THERMAL_WAS_ACTIVE=0
	fi
}

summarise() {
	python3 - "$@" <<'PY'
import sys

for path in sys.argv[1:]:
    rows = [l.rstrip("\n").split("\t") for l in open(path) if l.strip()]
    head, rows = rows[0], [r for r in rows[1:] if len(r) == len(rows[0])]
    if not rows:
        print("  %s: nothing logged" % path); continue
    col = {n: i for i, n in enumerate(head)}
    def g(r, n):
        try: return int(r[col[n]])
        except Exception: return None

    core = "core_thermal" if "core_thermal" in col else head[2]
    gauge = next((n for n in head if n.startswith("bq27421")), None)
    other = next((n for n in head if n.startswith("bq24297")), None)

    print()
    print("  %s" % path)
    phases = {}
    for r in rows:
        phases.setdefault(r[col["phase"]], []).append(r)

    for ph in ("idle1", "load", "idle2"):
        rs = phases.get(ph)
        if not rs: continue
        def rng(n):
            v = [g(r, n) for r in rs if g(r, n) is not None]
            return (min(v) / 1000.0, max(v) / 1000.0) if v else (None, None)
        clo, chi = rng(core)
        glo, ghi = rng(gauge) if gauge else (None, None)
        print("    %-6s %3d samples   core %.1f-%.1f C   %s %.1f-%.1f C" % (
            ph, len(rs), clo, chi, (gauge or "-"), glo or 0, ghi or 0))

    # How fast did the gauge move once load started? A cell cannot move fast.
    load_rows = phases.get("load", [])
    if gauge and load_rows:
        t0 = int(load_rows[0][col["t"]]); g0 = g(load_rows[0], gauge)
        for r in load_rows:
            t, v = int(r[col["t"]]), g(r, gauge)
            if v is not None and g0 is not None and v - g0 >= 2000:
                print("    %s rose 2.0 C within %d s of the load starting" % (gauge, t - t0))
                break

    if other:
        v = set(g(r, other) for r in rows)
        if len(v) == 1:
            # Not evidence of a dead sensor. This zone reads 22.5 C with the
            # charger offline and something quite different with it plugged
            # in, so it is constant within a run whose charger state did not
            # change, which is most runs. Say what was seen, not what it means.
            print("    %s did not vary within this run: %.1f C on all %d samples"
                  % (other, v.pop() / 1000.0, len(rows)))
            print("      (it tracks charger state, not load; constant here is expected)")

    # Ceiling changes, which is where the flapping shows.
    changes, prev = [], None
    for r in rows:
        m = g(r, "maxfreq")
        if prev is not None and m != prev:
            changes.append((int(r[col["t"]]), prev, m, g(r, gauge) if gauge else None))
        prev = m
    if changes:
        print("    ceiling moved %d times:" % len(changes))
        for t, a, b, gv in changes[:14]:
            print("      t=%-5s %7d -> %-7d kHz   %s %s" % (
                t, a, b, (gauge or ""), ("%.1f C" % (gv / 1000.0)) if gv else ""))
        if len(changes) > 14:
            print("      ... and %d more" % (len(changes) - 14))
    else:
        print("    ceiling never moved")

    # Where the gauge sits when the core is at the daemon's own first rung.
    if gauge:
        pairs = [(g(r, core), g(r, gauge)) for r in rows if g(r, core) and g(r, gauge)]
        hot = [gv for cv, gv in pairs if cv >= 75000]
        if hot:
            print("    with the core at 75 C or above, %s ran %.1f-%.1f C (mean %.1f)" % (
                gauge, min(hot) / 1000.0, max(hot) / 1000.0, sum(hot) / len(hot) / 1000.0))
        top = max(gv for _, gv in pairs)
        print("    %s peak across the whole arm: %.1f C" % (gauge, top / 1000.0))
PY
}

mkdir -p "$OUTDIR"
STAMP=$(date +%Y%m%d-%H%M%S)
OUTS=()

echo "kernel      : $(uname -r)"
echo "governor    : $(cat $CPUFREQ/scaling_governor)"
echo "zones       : ${ZNAMES[*]}"
echo "top of table: $TOP kHz"
echo "phases      : idle ${IDLE1}s, load ${LOAD}s, idle ${IDLE2}s, sampled every ${STEP}s"
echo "load        : ${CORES} core(s)"

for arm in vendor pinned; do
	[ "$ARM" = both ] || [ "$ARM" = "$arm" ] || continue
	say "arm: $arm"
	out=$OUTDIR/probe-$arm-$STAMP.tsv
	run_arm "$arm" "$out"
	note "wrote $out"
	OUTS+=("$out")
done

say "summary"
summarise "${OUTS[@]}"
echo
echo "done at $(date -Is)"
