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
#   1. live: both cores' heartbeat counters, and each core's own clock
#      counter (DWT CYCCNT where usable, otherwise SysTick extended to 32
#      bits by the firmware), sampled once a second against Linux's clock.
#      The beats prove the code is running; the count divided by wall time
#      is the M4 clock, measured rather than read off a clock tree.
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

if [ -e "$FW_DEST" ]; then
	echo "$FW_DEST already exists. Not overwriting someone else's firmware;" >&2
	echo "move it aside (or: sudo ./pyra-m4-run.sh --stop) and run again." >&2
	exit 1
fi

# The kernel install blacklists omap_remoteproc so that it does not load at
# boot (auto_boot again); the blacklist only stops the autoload, so load it
# here. Checked after the firmware, because a module loaded with the file in
# place starts the M4s at once. It stays loaded afterwards, as it would be
# on a card without the blacklist.
if ! grep -q '^omap_remoteproc ' /proc/modules; then
	note "loading omap_remoteproc (blacklisted at boot, loaded on request)"
	modprobe omap_remoteproc 2>&1 | sed 's/^/        /'
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		ls /sys/class/remoteproc/remoteproc* >/dev/null 2>&1 && break
		sleep 0.2
	done
fi

RP=""
for d in /sys/class/remoteproc/remoteproc*; do
	[ -d "$d" ] || continue
	note "${d##*/}  $(cat "$d/name")  state=$(cat "$d/state")"
	case "$(cat "$d/name" 2>/dev/null)" in
	*ipu) RP=$d ;;
	esac
done
if [ -z "$RP" ]; then
	echo "no ipu remoteproc device: this needs the 5.6.19-m4 kernel, whose" >&2
	echo "omap_remoteproc module the line above should have loaded" >&2
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
	src)    sed -n "s/^core$1 clock-src=\([a-z]*\) .*/\1/p" <<<"$3" ;;
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

# Where the count comes from: the DWT cycle counter, SysTick on the core
# clock, or SysTick on a reference clock (sysext), which is NOT the core
# clock and is labelled as such below.
have_cyc=1
boot=$(cat "$TRACE" 2>/dev/null)
CLKSRC=$(field 0 src "$boot")
for c in 0 1; do
	case "$(field $c cycles "$boot")" in
	''|no-dwt|none) have_cyc=0 ;;
	esac
done
case "$CLKSRC" in
dwt)     WHAT="core clock, from the DWT cycle counter" ;;
systick) WHAT="core clock, from SysTick" ;;
sysext)  WHAT="SysTick reference clock, NOT the core clock" ;;
*)       WHAT="" ;;
esac

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
		# Two estimates, which have to agree. The main one is total
		# count over total time, whose only error is how stale the
		# first and last readings were. The median of the one-second
		# rates is the check on it: robust to a read that catches the
		# M4 halfway through rewriting its ten digits, and the thing
		# that would have caught the first firmware, which republished
		# the count once per beat -- slower than this samples -- so
		# that every interval saw a whole beat's worth of cycles or
		# none, and the "rate" was the beat length in disguise.
		zeros=$(awk -v c="$c" '$1 == c && $3 == 0' <<<"$samples" | wc -l)
		total=$(awk -v c="$c" '$1 == c { y += $3; t += $2 } END {
			if (t > 0) printf "%.1f", y * 1000 / t }' <<<"$samples")
		median=$(awk -v c="$c" '$1 == c { print $3 * 1000 / $2 }' <<<"$samples" \
			| sort -n | awk '{ v[NR] = $1 } END {
				if (NR == 0) exit
				m = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
				printf "%.1f", m }')
		n=$(grep -c "^$c " <<<"$samples")
		if [ -z "$total" ] || [ -z "$median" ]; then
			bad "core$c: no usable clock-counter samples"
		elif [ "$zeros" -gt 0 ]; then
			bad "core$c: the count stood still in $zeros of $n one-second samples — it is published too rarely to be a rate"
		elif ! awk -v a="$total" -v b="$median" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= a * 0.02) }'; then
			bad "core$c: total-over-time ($total MHz) and the per-second median ($median MHz) disagree by more than 2%"
		else
			CLOCK[$c]=$total
			ok "core$c: $total MHz, $WHAT ($n one-second samples, median $median)"
		fi
	done
else
	note "no usable clock counter on the M4s: the clock was not measured."
	note "$(grep 'clock-src=' <<<"$boot" | head -1)"
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
	[ -n "${CLOCK[0]:-}" ] && [ -n "${CLOCK[1]:-}" ] \
		&& note "Measured: core0 ${CLOCK[0]} MHz, core1 ${CLOCK[1]} MHz ($WHAT)."
fi
note "firmware removed from /lib/firmware; ipu offline"
echo "$pass ok, $fail failed"
exit $((fail > 0))
