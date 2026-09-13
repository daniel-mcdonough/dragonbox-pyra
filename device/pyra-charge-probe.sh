#!/bin/bash
#
# pyra-charge-probe.sh — find out what is actually limiting charging.
#
#   sudo ./pyra-charge-probe.sh            three arms, about 35 minutes
#   sudo ./pyra-charge-probe.sh --quick    the same shape, about 9 minutes
#   sudo ./pyra-charge-probe.sh --restore  put the daemon back and exit
#
# THE CHARGER MUST BE PLUGGED IN. It says so and stops if it is not.
#
# WHY THIS EXISTS
#
# `/usr/share/pyra/scripts/pyra-thermal.sh` sets the charger's input current
# limit from the same sensor it uses for the CPU ladder — `bq27421-0`, which is
# the fuel gauge reporting its own die temperature, not the cell:
#
#     gauge > 44 C  ->  500 mA          gauge > 43 C  ->  1 A
#     gauge > 42 C  ->    2 A           otherwise     ->  3 A
#
# This machine idles at 42.0-42.3 C on that sensor, so it starts inside the 2 A
# band before anything happens, and half a minute of one core puts it past 44 C
# where only 500 mA is allowed. The board then cools back through 44 C slowly —
# measured at 350 seconds — so the clamp outlives the work that caused it.
#
# 500 mA is less than this machine draws sitting idle. So the prediction is not
# merely that it charges slowly: it is that a warm Pyra plugged into a charger
# can sit there discharging.
#
# WHAT IT MEASURES
#
# Three arms, bracketed, because a charging battery is a moving target and the
# comparison has to survive that:
#
#   vendor     the daemon deciding, which is the machine as shipped
#   released   the daemon stopped and the limit set to 3 A, which is what the
#              daemon itself writes whenever the gauge is at or below 42 C.
#              This is the arm that turns correlation into causation: same
#              board temperature, same everything, one number different.
#   vendor     again, to show the first arm was not a transient
#
# 3 A is the vendor's own `maxCharge` default and is not an overdrive: it is
# what this daemon asks for on a cool machine. The daemon is started again on
# any exit, including Ctrl-C and a dropped SSH, and its next poll rewrites the
# limit within 20 seconds. `--restore` does it by hand if that is ever missed.
#
# Nothing here changes a charging voltage or a termination threshold. The only
# quantity touched is the input current limit, and only to a value the shipped
# daemon already uses.
#
set -uo pipefail

MODE=run
case "${1:-}" in
	--quick)   MODE=quick ;;
	--restore) MODE=restore ;;
	-h|--help) sed -n '3,49p' "$0" | sed 's/^# \?//'; exit 0 ;;
	"") ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
esac

BATT=/sys/class/power_supply/bq27421-0
CHG=/sys/class/power_supply/bq24297
LIMIT=/dev/usb_max_current
THERMAL_UNIT=pyra-thermal
CPUFREQ=/sys/devices/system/cpu/cpu0/cpufreq
VENDOR_MAX=3000000

die()  { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
say()  { printf '\n== %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

[ "$(id -u)" = 0 ] || die "run this with sudo: it stops $THERMAL_UNIT and writes $LIMIT"

if [ "$MODE" = restore ]; then
	systemctl start "$THERMAL_UNIT" 2>/dev/null \
		&& note "$THERMAL_UNIT started; its next poll owns $LIMIT again" \
		|| note "could not start $THERMAL_UNIT"
	exit 0
fi

[ -r "$BATT/status" ] || die "no fuel gauge at $BATT"
[ -w "$LIMIT" ] || die "no writable $LIMIT — is this a Pyra with pyra-hacks installed?"

online=$(cat "$CHG/online" 2>/dev/null || echo 0)
[ "$online" = 1 ] || die "the charger is not plugged in. This measures charging;
  plug it in and run it again."

if [ "$MODE" = quick ]; then A1=120; A2=240; A3=120; STEP=5
else                         A1=600; A2=900; A3=600; STEP=10; fi
A1=${CP_A1:-$A1}; A2=${CP_A2:-$A2}; A3=${CP_A3:-$A3}; STEP=${CP_STEP:-$STEP}

OUTDIR=${CP_OUT:-/tmp}
mkdir -p "$OUTDIR"
OUT=$OUTDIR/charge-probe-$(date +%Y%m%d-%H%M%S).tsv

GAUGE_DEV=; CHG_DEV=; CORE_DEV=
for z in /sys/class/thermal/thermal_zone*; do
	case "$(cat "$z/type" 2>/dev/null)" in
		bq27421*) GAUGE_DEV=$z/temp ;;
		bq24297*) CHG_DEV=$z/temp ;;
		core_thermal) CORE_DEV=$z/temp ;;
	esac
done

THERMAL_WAS_ACTIVE=0
CLEANED=0
cleanup_once() {
	[ "$CLEANED" = 1 ] && return 0
	CLEANED=1
	if [ "$THERMAL_WAS_ACTIVE" = 1 ]; then
		systemctl start "$THERMAL_UNIT" 2>/dev/null \
			&& note "$THERMAL_UNIT started again; it owns $LIMIT from its next poll" \
			|| note "COULD NOT RESTART $THERMAL_UNIT — run: sudo systemctl start $THERMAL_UNIT"
	fi
}
trap cleanup_once EXIT
trap 'cleanup_once; exit 130' INT TERM HUP

rd() { cat "$1" 2>/dev/null || echo ""; }

t0=$(date +%s)
sample() {
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$(( $(date +%s) - t0 ))" "$1" \
		"$(rd "$GAUGE_DEV")" "$(rd "$CHG_DEV")" "$(rd "$CORE_DEV")" \
		"$(rd "$BATT/status")" "$(rd "$BATT/current_now")" "$(rd "$BATT/voltage_now")" \
		"$(rd "$BATT/capacity")" \
		"$(rd "$CHG/status")" "$(rd "$CHG/input_current_limit")" "$(rd "$CHG/current_now")" \
		"$(rd "$LIMIT")" "$(rd "$CPUFREQ/scaling_max_freq")" >> "$OUT"
}

run_arm() {
	local arm=$1 secs=$2 i
	say "arm: $arm, ${secs}s"
	if [ "$arm" = released ]; then
		if systemctl is-active --quiet "$THERMAL_UNIT" 2>/dev/null; then
			THERMAL_WAS_ACTIVE=1
			systemctl stop "$THERMAL_UNIT" 2>/dev/null || note "could not stop $THERMAL_UNIT"
		fi
		echo "$VENDOR_MAX" > "$LIMIT"
		note "daemon stopped, $LIMIT set to $VENDOR_MAX (the vendor's own maxCharge)"
		sleep 2
		note "charger now reports input_current_limit $(rd "$CHG/input_current_limit")"
	else
		systemctl start "$THERMAL_UNIT" 2>/dev/null || true
		THERMAL_WAS_ACTIVE=1
		note "daemon running and deciding $LIMIT, which is the machine as shipped"
		sleep 2
	fi
	for ((i = 0; i < secs; i += STEP)); do sample "$arm"; sleep "$STEP"; done
}

echo "kernel   : $(uname -r)"
echo "charger  : online=$(rd "$CHG/online") status=$(rd "$CHG/status") input_current_limit=$(rd "$CHG/input_current_limit")"
echo "battery  : $(rd "$BATT/status") $(rd "$BATT/capacity")% $(rd "$BATT/current_now") uA"
echo "gauge    : $(( $(rd "$GAUGE_DEV") / 1000 )) C   core: $(( $(rd "$CORE_DEV") / 1000 )) C"
echo "$LIMIT : $(rd "$LIMIT")"
echo "writing  : $OUT"

printf 't\tarm\tgauge\tchgzone\tcore\tbstatus\tbatt_ua\tbatt_uv\tcapacity\tcstatus\tilim\tchg_ua\tusbmax\tmaxfreq\n' > "$OUT"

run_arm vendor   "$A1"
run_arm released "$A2"
run_arm vendor   "$A3"

cleanup_once

say "results"
python3 - "$OUT" <<'PY'
import sys, collections

rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
head, rows = rows[0], [r for r in rows[1:] if len(r) == len(rows[0])]
c = {n: i for i, n in enumerate(head)}

def num(r, n):
    try: return int(r[c[n]])
    except Exception: return None

arms = collections.OrderedDict()
for r in rows:
    arms.setdefault(r[c["arm"]], []).append(r)

# Arms repeat by name; split them into runs so the bracket is visible.
runs, prev, cur = [], None, []
for r in rows:
    a = r[c["arm"]]
    if a != prev and cur:
        runs.append((prev, cur)); cur = []
    prev = a; cur.append(r)
if cur: runs.append((prev, cur))

print()
print("  %-10s %7s %9s %9s %9s %9s %8s %s" % (
    "arm", "samples", "gauge C", "ilim mA", "batt mA", "cap %", "core C", "battery status"))
for name, rs in runs:
    def mean(n):
        v = [num(r, n) for r in rs if num(r, n) is not None]
        return sum(v) / len(v) if v else 0
    st = collections.Counter(r[c["bstatus"]] for r in rs).most_common(1)[0][0]
    cap0, cap1 = num(rs[0], "capacity"), num(rs[-1], "capacity")
    print("  %-10s %7d %9.1f %9.0f %+9.0f %5d->%-3d %8.1f %s" % (
        name, len(rs), mean("gauge") / 1000.0, mean("ilim") / 1000.0,
        mean("batt_ua") / 1000.0, cap0, cap1, mean("core") / 1000.0, st))

print()
print("  batt mA is positive when the pack is being charged and negative when")
print("  it is being drained. A negative figure on a plugged-in machine means")
print("  the charger was not allowed to supply even what the machine idles at.")

# The point: same board temperature, different limit, different outcome.
v = [r for r in rows if r[c["arm"]] == "vendor"]
rl = [r for r in rows if r[c["arm"]] == "released"]
if v and rl:
    def m(rs, n):
        x = [num(r, n) for r in rs if num(r, n) is not None]
        return sum(x) / len(x) if x else 0
    print()
    print("  vendor arms  : gauge %.1f C, limit %.0f mA, battery %+.0f mA" % (
        m(v, "gauge") / 1000.0, m(v, "ilim") / 1000.0, m(v, "batt_ua") / 1000.0))
    print("  released arm : gauge %.1f C, limit %.0f mA, battery %+.0f mA" % (
        m(rl, "gauge") / 1000.0, m(rl, "ilim") / 1000.0, m(rl, "batt_ua") / 1000.0))
    dg = abs(m(rl, "gauge") - m(v, "gauge")) / 1000.0
    print()
    print("  The two differ by %.1f C on the sensor the limit is derived from." % dg)
    print("  If that is small and the charging outcome is not, then the board")
    print("  temperature was never the thing standing between this machine and")
    print("  a charge — the threshold was.")
PY

echo
echo "charger  : status=$(rd "$CHG/status") input_current_limit=$(rd "$CHG/input_current_limit")"
echo "battery  : $(rd "$BATT/status") $(rd "$BATT/capacity")%"
echo "wrote $OUT"
echo "done at $(date -Is)"
