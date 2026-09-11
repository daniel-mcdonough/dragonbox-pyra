#!/bin/bash
#
# pyra-anno1602-test.sh — run Anno 1602 (1602 A.D.) under box86 and x86 Wine
# as a repeatable load test, with a thermal guard and a liveness check.
#
# This is the heaviest sustained load documented for this machine. docs/box86.md
# measured 95 C on cpu_thermal against a 100 C passive trip, so the run is
# bounded by time and aborts on temperature rather than trusting the trip.
#
#   ./pyra-anno1602-test.sh                # 120 s run
#   ./pyra-anno1602-test.sh -d 300         # 5 minutes
#   ./pyra-anno1602-test.sh -d 300 -p      # and profile the X server alongside
#   ./pyra-anno1602-test.sh -t 92          # stop if cpu_thermal passes 92 C
#
# The game draws on the live desktop at DISPLAY=:0 inside an 800x600 Wine
# virtual desktop. Everything is shut down with wineserver -k on exit, including
# on Ctrl-C or a thermal abort.

set -u

DURATION=120
TEMP_LIMIT=98
PROFILE=0
SETTLE=20

BOX86TEST="$HOME/box86test"
WINE="$BOX86TEST/wine/bin/wine"
WINESERVER="$BOX86TEST/wine/bin/wineserver"
GAMEDIR="$BOX86TEST/game/1602 A.D"
GAMEEXE="1602.exe"

usage() { sed -n '2,/^$/s/^# \?//p' "$0"; exit "${1:-0}"; }

while getopts "d:t:ph" o; do
	case "$o" in
	d) DURATION=$OPTARG ;;
	t) TEMP_LIMIT=$OPTARG ;;
	p) PROFILE=1 ;;
	h) usage 0 ;;
	*) usage 1 ;;
	esac
done

export WINEPREFIX="$BOX86TEST/prefix"
export WINEDLLOVERRIDES="mscoree,mshtml="
export BOX86_NOBANNER=1
export DISPLAY="${DISPLAY:-:0}"

die() { echo "error: $*" >&2; exit 1; }

# --- preconditions, all of them, before anything is launched ---------------
[ -x "$WINE" ]        || die "no x86 wine at $WINE"
[ -x "$WINESERVER" ]  || die "no wineserver at $WINESERVER"
[ -d "$WINEPREFIX" ]  || die "no wine prefix at $WINEPREFIX"
[ -f "$GAMEDIR/$GAMEEXE" ] || die "no $GAMEEXE under $GAMEDIR"
command -v box86 >/dev/null || die "box86 not installed (apt-get install box86-pyra)"
command -v gl4es >/dev/null || die "gl4es not installed"
xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 || die "no X server on $DISPLAY"

# The GDI renderer is not optional. With Wine's GL renderer the game creates a
# window and then hangs at 0% CPU, because this image has no GLX. See
# docs/box86.md section 5.
if ! grep -q '"renderer"="gdi"' "$WINEPREFIX/user.reg" 2>/dev/null; then
	echo "setting Direct3D renderer=gdi in the prefix (one time)"
	gl4es box86 "$WINE" reg add "HKCU\\Software\\Wine\\Direct3D" \
		/v renderer /d gdi /f >/dev/null 2>&1 \
		|| die "could not set the gdi renderer"
fi

TEMP_NODE=""
for z in /sys/class/thermal/thermal_zone*/; do
	[ "$(cat "$z/type" 2>/dev/null)" = "cpu_thermal" ] && TEMP_NODE="$z/temp"
done
[ -n "$TEMP_NODE" ] || echo "warning: no cpu_thermal zone found, running without a thermal guard"

temp_c() { [ -n "$TEMP_NODE" ] && echo $(( $(cat "$TEMP_NODE") / 1000 )) || echo 0; }

PROFILER=""
if [ "$PROFILE" = 1 ]; then
	for c in "$(dirname "$0")/pyra-x-load-profile.sh" \
	         "$HOME/pyra-x-load-profile.sh" /tmp/pyra-x-load-profile.sh; do
		[ -x "$c" ] && { PROFILER=$c; break; }
	done
	[ -n "$PROFILER" ] || die "-p given but pyra-x-load-profile.sh not found"
fi

GAMEPID=""
PROFPID=""
PROFOUT=$(mktemp)
ABORT=""

cleanup() {
	echo
	echo "shutting down the prefix ..."
	[ -n "$PROFPID" ] && kill "$PROFPID" 2>/dev/null
	gl4es box86 "$WINESERVER" -k >/dev/null 2>&1
	sleep 2
	pkill -f "$GAMEEXE" 2>/dev/null
	rm -f "$PROFOUT"
	[ -n "$ABORT" ] && { echo "$ABORT"; exit 2; }
}
trap cleanup EXIT
trap 'echo; echo "interrupted"; exit 130' INT TERM

echo "wine      $WINE"
echo "prefix    $WINEPREFIX"
echo "game      $GAMEDIR/$GAMEEXE"
echo "display   $DISPLAY"
echo "run       ${DURATION}s, abort above ${TEMP_LIMIT}C, starting at $(temp_c)C"
echo

cd "$GAMEDIR" || die "cannot enter $GAMEDIR"
gl4es box86 "$WINE" explorer /desktop=anno,800x600 "./$GAMEEXE" \
	>"$BOX86TEST/anno-run.log" 2>&1 &
GAMEPID=$!

echo "started, giving it ${SETTLE}s to boot under emulation ..."
for i in $(seq 1 "$SETTLE"); do
	sleep 1
	t=$(temp_c)
	if [ -n "$TEMP_NODE" ] && [ "$t" -ge "$TEMP_LIMIT" ]; then
		ABORT="ABORTED: ${t}C during startup, at or above the ${TEMP_LIMIT}C limit"
		exit 2
	fi
done

# Liveness. The documented failure mode is a window that appears and then sits
# at 0% CPU, so CPU time is the signal that it is really rendering.
game_ticks() {
	local total=0 p
	for p in $(pgrep -f "$GAMEEXE" 2>/dev/null); do
		total=$((total + $(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null || echo 0)))
	done
	echo "$total"
}

if [ "$(pgrep -cf "$GAMEEXE" 2>/dev/null || echo 0)" -eq 0 ]; then
	ABORT="ABORTED: $GAMEEXE is not running. See $BOX86TEST/anno-run.log"
	exit 2
fi

if [ "$PROFILE" = 1 ]; then
	echo "profiling the X server for ${DURATION}s ..."
	"$PROFILER" -d "$DURATION" -n "$GAMEEXE" >"$PROFOUT" 2>&1 &
	PROFPID=$!
fi

HZ=$(getconf CLK_TCK)
T0=$(game_ticks)
PEAK=0
START=$(date +%s)

printf "%-8s %-7s %-9s %s\n" "elapsed" "cpu C" "game CPU" "state"
while [ $(( $(date +%s) - START )) -lt "$DURATION" ]; do
	sleep 5
	el=$(( $(date +%s) - START ))
	t=$(temp_c)
	[ "$t" -gt "$PEAK" ] && PEAK=$t
	now=$(game_ticks)
	pct=$(( (now - T0) * 100 / HZ / (el > 0 ? el : 1) ))
	state="rendering"
	[ "$pct" -lt 5 ] && state="STALLED (0% CPU is the no-GLX hang)"
	if [ "$(pgrep -cf "$GAMEEXE" 2>/dev/null || echo 0)" -eq 0 ]; then
		ABORT="ABORTED: $GAMEEXE exited after ${el}s. See $BOX86TEST/anno-run.log"
		exit 2
	fi
	printf "%-8s %-7s %-9s %s\n" "${el}s" "$t" "${pct}%" "$state"
	if [ -n "$TEMP_NODE" ] && [ "$t" -ge "$TEMP_LIMIT" ]; then
		ABORT="ABORTED at ${el}s: ${t}C reached the ${TEMP_LIMIT}C limit (trip is 100C)"
		exit 2
	fi
done

TOTAL=$(( ($(game_ticks) - T0) * 100 / HZ / DURATION ))
echo
echo "=== ran ${DURATION}s, peak cpu_thermal ${PEAK}C, mean game CPU ${TOTAL}% of one core"
echo "    docs/box86.md measured 80-87% and 95C, so compare against that."
echo "    wine output: $BOX86TEST/anno-run.log"

if [ "$PROFILE" = 1 ]; then
	wait "$PROFPID" 2>/dev/null
	PROFPID=""
	echo
	cat "$PROFOUT"
fi
