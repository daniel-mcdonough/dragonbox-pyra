#!/bin/bash
#
# pyra-m4-demo.sh — show the Pyra's two Cortex-M4s running, live, and
# measure how fast they are clocked. Then put the machine back as it was.
#
#   sudo ./pyra-m4-demo.sh                      uses ./pyra-m4-demo.xem4
#   sudo ./pyra-m4-demo.sh --seconds 20 <fw>    watch for longer
#
# This is the one to run for an audience; pyra-m4-run.sh is the strict test
# and the two complement each other. Build the firmware on a PC with
# `make demo` in experiments/m4-ipu/firmware, or use the prebuilt one in the
# demo kit. Needs the 5.6.19-m4 kernel.
#
# What you see, and why each part means something:
#
#   1. live: both cores' heartbeat counters, and each core's own cycle
#      counter (the Cortex-M4 DWT CYCCNT), sampled once a second against
#      Linux's clock. The beats prove the code is running; the cycle
#      counter divided by wall time is the M4 core clock, measured rather
#      than read off a clock tree.
#   2. stop: the IPU goes offline and the trace buffer disappears with it.
#   3. start again: the counters begin again from near zero. They live in
#      .bss, which is not in the firmware file and is zeroed by the loader
#      at every start, so a fresh count is a fresh M4 boot — not a file
#      being echoed back.
#   4. the kernel log for the whole run: no IOMMU fault, no BUG, no WARNING.
#
# THE FIRMWARE IS ALWAYS REMOVED AGAIN on exit, however the script ends.
# remoteproc's auto_boot is on, so a file left in /lib/firmware would start
# the M4s at every boot with nothing typed. See pyra-m4-run.sh for --keep.
#
set -uo pipefail

FW_DEST=/lib/firmware/omap5-ipu-fw.xem4
WATCH=10
SRC=""

while [ $# -gt 0 ]; do
	case "$1" in
	--seconds) WATCH=${2:?}; shift ;;
	-h|--help) sed -n '3,30p' "$0" | sed 's/^# \?//'; exit 0 ;;
	-*)        echo "unknown argument: $1" >&2; exit 2 ;;
	*)         SRC=$1 ;;
	esac
	shift
done
[ -n "$SRC" ] || SRC="$(dirname "$0")/pyra-m4-demo.xem4"

[ "$(id -u)" = 0 ] || { echo "needs root: debugfs and /lib/firmware" >&2; exit 2; }
[ -f "$SRC" ] || { echo "no firmware at $SRC (see --help)" >&2; exit 2; }
case "$WATCH" in ''|*[!0-9]*) echo "--seconds wants a number" >&2; exit 2 ;; esac
[ "$WATCH" -ge 2 ] || WATCH=2

pass=0 fail=0
ok()   { echo "  ok    $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail+1)); }
note() { echo "        $*"; }

# ---- the machine ------------------------------------------------------------
echo "== this machine =="
soc=/sys/bus/soc/devices/soc0
note "kernel   $(uname -r)"
note "soc      $(cat $soc/machine 2>/dev/null) $(cat $soc/revision 2>/dev/null) $(cat $soc/type 2>/dev/null)"

RP=""
for d in /sys/class/remoteproc/remoteproc*; do
	[ -d "$d" ] || continue
	note "${d##*/}  $(cat "$d/name")  state=$(cat "$d/state")"
	case "$(cat "$d/name" 2>/dev/null)" in
	*ipu) RP=$d ;;
	esac
done
if [ -z "$RP" ]; then
	echo "no ipu remoteproc device: this needs the 5.6.19-m4 kernel with" >&2
	echo "omap_remoteproc loaded (is it blacklisted on the command line?)" >&2
	exit 1
fi
if [ -e "$FW_DEST" ]; then
	echo "$FW_DEST already exists. Not overwriting someone else's firmware;" >&2
	echo "move it aside (or: sudo ./pyra-m4-run.sh --stop) and run again." >&2
	exit 1
fi
if [ "$(cat "$RP/state")" = running ]; then
	echo "the ipu is already running; stop it first: sudo ./pyra-m4-run.sh --stop" >&2
	exit 1
fi

mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
TRACE=/sys/kernel/debug/remoteproc/${RP##*/}/trace0

stop_ipu() {
	[ "$(cat "$RP/state")" = running ] && echo stop > "$RP/state" 2>/dev/null
	true
}
cleanup() {
	stop_ipu
	rm -f "$FW_DEST"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

start_ipu() {
	if ! echo start > "$RP/state" 2>/dev/null; then
		bad "writing 'start' failed:"
		dmesg | tail -n +"$DMESG_MARK" | sed 's/^/        /' | tail -8
		exit 1
	fi
	# trace0 appears with the start; give the cores a moment to write it
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		grep -q 'state=alive' "$TRACE" 2>/dev/null && return 0
		sleep 0.1
	done
	return 0
}

field() {  # field <core> <beats|state|cycles> <text>
	case "$2" in
	beats)  sed -n "s/^core$1: state=[a-zA-Z]* beats=\([0-9]*\)$/\1/p" <<<"$3" ;;
	state)  sed -n "s/^core$1: state=\([a-zA-Z]*\) beats=[0-9]*$/\1/p" <<<"$3" ;;
	cycles) sed -n "s/^core$1 cpu-cycles=\([0-9a-z-]*\) *$/\1/p" <<<"$3" ;;
	esac
}
now_ns() { date +%s%N; }

install -m 0644 "$SRC" "$FW_DEST"
DMESG_MARK=$(( $(dmesg | wc -l) + 1 ))

# ---- 1: live ------------------------------------------------------------------
echo
echo "== starting both M4s =="
start_ipu
ok "ipu state: $(cat "$RP/state")"
echo
cat "$TRACE" 2>/dev/null | sed 's/^/        | /'

have_cyc=1
for c in 0 1; do
	case "$(field $c cycles "$(cat "$TRACE" 2>/dev/null)")" in
	''|no-dwt) have_cyc=0 ;;
	esac
done

echo
echo "== live, ${WATCH}s =="
printf '        %4s  %12s %10s  %12s %10s\n' t core0-beats MHz core1-beats MHz
samples=""            # "core dt_ns dcycles" per interval, for the median
prev_t=$(now_ns); prev=$(cat "$TRACE" 2>/dev/null)
first_b0=$(field 0 beats "$prev"); first_b1=$(field 1 beats "$prev")
for ((i = 1; i <= WATCH; i++)); do
	sleep 1
	t=$(now_ns); cur=$(cat "$TRACE" 2>/dev/null)
	row=()
	for c in 0 1; do
		b=$(field $c beats "$cur")
		mhz="-"
		if [ "$have_cyc" = 1 ]; then
			y0=$(field $c cycles "$prev"); y1=$(field $c cycles "$cur")
			if [ -n "$y0" ] && [ -n "$y1" ]; then
				# CYCCNT is 32 bits and wraps every ~10 s at 425 MHz;
				# one-second intervals see at most one wrap.
				dy=$(( (10#$y1 - 10#$y0 + 4294967296) % 4294967296 ))
				dt=$(( t - prev_t ))
				samples+="$c $dt $dy"$'\n'
				mhz=$(awk -v y="$dy" -v t="$dt" 'BEGIN{printf "%.1f", y*1000/t}')
			fi
		fi
		row+=("${b:-?}" "$mhz")
	done
	printf '        %3ds  %12s %10s  %12s %10s\n' "$i" "${row[@]}"
	prev=$cur; prev_t=$t
done
last=$cur
last_b0=$(field 0 beats "$last"); last_b1=$(field 1 beats "$last")

echo
for c in 0 1; do
	s=$(field $c state "$last")
	[ "$s" = alive ] && ok "core$c reports alive" || bad "core$c state is '${s:-missing}'"
done
if [ -n "$first_b0" ] && [ -n "$last_b0" ] && [ "$((10#$last_b0))" -gt "$((10#$first_b0))" ]; then
	ok "core0 executed: beats $((10#$first_b0)) -> $((10#$last_b0))"
else
	bad "core0's counter did not advance"
fi
if [ -n "$first_b1" ] && [ -n "$last_b1" ] && [ "$((10#$last_b1))" -gt "$((10#$first_b1))" ]; then
	ok "core1 executed: beats $((10#$first_b1)) -> $((10#$last_b1))"
else
	bad "core1's counter did not advance — the second M4 is not running"
fi

declare -A CLOCK
if [ "$have_cyc" = 1 ]; then
	for c in 0 1; do
		# Median rather than mean: a read can catch the M4 halfway
		# through rewriting its ten digits, and one torn sample should
		# cost one interval, not the result.
		CLOCK[$c]=$(awk -v c="$c" '$1 == c { print $3 * 1000 / $2 }' <<<"$samples" \
			| sort -n | awk '{ v[NR] = $1 } END {
				if (NR == 0) exit
				m = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
				printf "%.1f", m }')
		[ -n "${CLOCK[$c]}" ] \
			&& ok "core$c clock measured: ${CLOCK[$c]} MHz (median of $(grep -c "^$c " <<<"$samples") one-second samples)" \
			|| bad "core$c: no usable cycle-counter samples"
	done
else
	note "no DWT cycle counter reported (no-dwt): the clock was not measured."
	note "The heartbeat above is still the proof that both cores run."
fi

# ---- 2: stop ------------------------------------------------------------------
echo
echo "== stopping the ipu =="
echo stop > "$RP/state"
st=$(cat "$RP/state")
[ "$st" = offline ] && ok "ipu state: offline" || bad "ipu state is '$st' after stop"
[ -e "$TRACE" ] && bad "trace0 is still there after stop" || ok "trace0 is gone with it"

# ---- 3: start again -----------------------------------------------------------
echo
echo "== starting again: the count must begin from scratch =="
start_ipu
sleep 0.5
again=$(cat "$TRACE" 2>/dev/null)
a0=$(field 0 beats "$again"); a1=$(field 1 beats "$again")
note "core0 beats now ${a0:-?} (was ${last_b0:-?} before the stop)"
note "core1 beats now ${a1:-?} (was ${last_b1:-?})"
if [ -n "$a0" ] && [ -n "$last_b0" ] && [ "$((10#$a0))" -gt 0 ] && [ "$((10#$a0))" -lt "$((10#$last_b0))" ]; then
	ok "a fresh count: .bss was zeroed by the loader and an M4 started over"
else
	bad "core0 did not restart its count"
fi
[ -n "$a1" ] && [ "$((10#$a1))" -gt 0 ] && ok "core1 came back too" || bad "core1 did not come back"
echo stop > "$RP/state"

# ---- 4: the kernel log ----------------------------------------------------------
echo
echo "== what the kernel logged =="
new=$(dmesg | tail -n +"$DMESG_MARK")
echo "$new" | grep -E 'remoteproc|55020000' | sed 's/^/        /' | tail -8
if grep -qiE 'iommu.*fault|mmu fault|MMU_FAULT' <<<"$new"; then
	bad "the IOMMU reported a fault"
else
	ok "no IOMMU fault"
fi
splat=$(grep -cE '^\[[^]]*\] (BUG:|WARNING:|Unable to handle|Internal error|INFO: rcu)' <<<"$new")
[ "$splat" = 0 ] && ok "no BUG or WARNING" || bad "$splat BUG/WARNING line(s): dmesg | tail -n +$DMESG_MARK"

# ---- summary ------------------------------------------------------------------
echo
echo "== summary =="
if [ "$fail" = 0 ]; then
	note "Both Cortex-M4s in the OMAP5432 IPU ran this firmware, under Linux remoteproc."
	[ "$have_cyc" = 1 ] && note "Core clock: core0 ${CLOCK[0]} MHz, core1 ${CLOCK[1]} MHz."
fi
note "firmware removed from /lib/firmware; ipu offline"
echo "$pass ok, $fail failed"
exit $((fail > 0))
