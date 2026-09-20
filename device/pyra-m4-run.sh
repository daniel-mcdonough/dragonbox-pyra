#!/bin/bash
#
# pyra-m4-run.sh — load the test firmware onto the IPU, prove the two
# Cortex-M4s are executing it, and put the machine back as it was.
#
#   sudo ./pyra-m4-run.sh omap5-ipu-fw.xem4     run the test
#   sudo ./pyra-m4-run.sh --keep <fw>           leave the firmware installed
#   sudo ./pyra-m4-run.sh --stop                stop the IPU, remove firmware
#
# Build the firmware on the PC (experiments/m4-ipu/firmware, `make`) and copy
# it over with this script. Needs the 5.6.19-m4 kernel: on any other kernel
# there is no ipu node and nothing to load onto.
#
# What it proves, in order of how easy it would be to fake:
#
#   1. the firmware loads at all — resource table parsed, 1 MiB allocated
#      from the ipu-memory@95800000 pool, IOMMU programmed for device
#      address 0
#   2. the trace buffer is not empty. It lives in .bss, so it is not in the
#      file and the loader zeroed it; anything in it was written by an M4
#   3. core0's counter advances between two samples a second apart. Text
#      alone could come from a core that ran once and died
#   4. core1's counter is non-zero and advancing, which is the only evidence
#      that the SECOND M4 left reset — the device tree asks for both
#   5. neither core reports FAULT, the kernel logged no IOMMU fault, and it
#      logged no BUG or WARNING of any kind while the IPU was up
#
# BY DEFAULT IT REMOVES THE FIRMWARE AGAIN, and that is not tidiness. The
# remoteproc core sets auto_boot = true and the omap driver never clears it,
# so a firmware file sitting in /lib/firmware means the IPU starts during
# every boot, with nothing typed and nothing watching. Use --keep only if
# that is what you want; `modprobe.blacklist=omap_remoteproc` on the kernel
# command line is the way to take it back.
#
set -uo pipefail

FW_DEST=/lib/firmware/omap5-ipu-fw.xem4
KEEP=0
STOP_ONLY=0
SECONDS_RUN=1
SRC=""

while [ $# -gt 0 ]; do
	case "$1" in
	--keep)    KEEP=1 ;;
	--stop)    STOP_ONLY=1 ;;
	--seconds) SECONDS_RUN=${2:?}; shift ;;
	-h|--help) sed -n '3,33p' "$0" | sed 's/^# \?//'; exit 0 ;;
	-*)        echo "unknown argument: $1" >&2; exit 2 ;;
	*)         SRC=$1 ;;
	esac
	shift
done

[ "$(id -u)" = 0 ] || { echo "needs root: debugfs and /lib/firmware" >&2; exit 2; }

pass=0 fail=0
ok()   { echo "  ok    $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail+1)); }
note() { echo "        $*"; }

# ---- find the IPU, by name rather than by index ----------------------------
RP=""
for d in /sys/class/remoteproc/remoteproc*; do
	[ -d "$d" ] || continue
	case "$(cat "$d/name" 2>/dev/null)" in
	*ipu) RP=$d ;;
	esac
done
if [ -z "$RP" ]; then
	echo "no ipu remoteproc device." >&2
	echo "Is this the 5.6.19-m4 kernel, and is omap_remoteproc loaded?" >&2
	echo "  uname -r = $(uname -r)" >&2
	exit 1
fi
TRACE=/sys/kernel/debug/remoteproc/${RP##*/}/trace0

stop_ipu() {
	if [ "$(cat "$RP/state")" = running ]; then
		echo stop > "$RP/state" 2>/dev/null \
			&& note "ipu stopped" \
			|| note "could not stop the ipu"
	fi
}

if [ "$STOP_ONLY" = 1 ]; then
	stop_ipu
	rm -f "$FW_DEST" && note "removed $FW_DEST"
	exit 0
fi

[ -n "$SRC" ] || { echo "give me the firmware to load (see --help)" >&2; exit 2; }
[ -f "$SRC" ] || { echo "no such file: $SRC" >&2; exit 2; }

mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug

# ---- leave the machine as we found it, whatever happens below --------------
cleanup() {
	stop_ipu
	if [ "$KEEP" = 0 ]; then
		rm -f "$FW_DEST"
		note "removed $FW_DEST (auto_boot would otherwise start the IPU at every boot)"
	else
		note "LEFT $FW_DEST in place — the IPU will start during every boot from now on"
	fi
}
trap cleanup EXIT

echo "== installing =="
install -m 0644 "$SRC" "$FW_DEST"
note "$SRC -> $FW_DEST ($(stat -c %s "$FW_DEST") bytes)"
note "firmware-name the driver asks for: $(cat "$RP/firmware")"

DMESG_MARK=$(dmesg | wc -l)

echo
echo "== starting the ipu =="
if [ "$(cat "$RP/state")" = running ]; then
	bad "the ipu was already running before this test started"
	exit 1
fi
if echo start > "$RP/state" 2>/dev/null; then
	ok "start accepted"
else
	bad "writing 'start' failed — see dmesg below"
	dmesg | tail -n +"$DMESG_MARK" | sed 's/^/        /'
	exit 1
fi

sleep 1
st=$(cat "$RP/state")
[ "$st" = running ] && ok "state is running" || bad "state is '$st', expected running"

# ---- 2: the trace buffer has something in it -------------------------------
echo
echo "== the trace buffer =="
if [ ! -r "$TRACE" ]; then
	bad "no $TRACE — the TYPE_TRACE resource was not accepted"
	exit 1
fi
first=$(cat "$TRACE" 2>/dev/null)
if [ -z "$first" ]; then
	bad "trace0 is empty: the M4 wrote nothing. It is in .bss, so empty means nothing ran"
else
	ok "trace0 is not empty — .bss is zeroed by the loader, so an M4 wrote this"
	echo "$first" | sed 's/^/        | /'
fi
grep -q 'pyra-m4-hello' <<<"$first" \
	&& ok "the banner is ours" \
	|| bad "trace0 does not contain our banner"

beats() {  # beats <core> <text>
	sed -n "s/^core$1: state=[a-zA-Z]* beats=\([0-9]*\)$/\1/p" <<<"$2"
}
state() {
	sed -n "s/^core$1: state=\([a-zA-Z]*\) beats=[0-9]*$/\1/p" <<<"$2"
}

b0a=$(beats 0 "$first"); b1a=$(beats 1 "$first")

# ---- 3 and 4: both counters advance ----------------------------------------
echo
echo "== is it still running, ${SECONDS_RUN}s later =="
sleep "$SECONDS_RUN"
second=$(cat "$TRACE" 2>/dev/null)
b0b=$(beats 0 "$second"); b1b=$(beats 1 "$second")
s0=$(state 0 "$second");  s1=$(state 1 "$second")

note "core0 beats $b0a -> $b0b   state=$s0"
note "core1 beats $b1a -> $b1b   state=$s1"

if [ -n "$b0a" ] && [ -n "$b0b" ] && [ "$((10#$b0b))" -gt "$((10#$b0a))" ]; then
	ok "core0 is executing: its counter advanced"
else
	bad "core0's counter did not advance — it is not running"
fi

if [ -n "$b1b" ] && [ "$((10#$b1b))" -gt 0 ]; then
	ok "core1 came out of reset too: its counter is non-zero"
	if [ "$((10#$b1b))" -gt "$((10#${b1a:-0}))" ]; then
		ok "core1 is still executing"
	else
		bad "core1 started but its counter has stopped"
	fi
else
	bad "core1 never ran — only one of the two M4s left reset"
fi

[ "$s0" = alive ] && ok "core0 reports no fault" || bad "core0 state is '$s0'"
[ "$s1" = alive ] && ok "core1 reports no fault" || bad "core1 state is '$s1'"

# ---- 5: what the kernel thought of all this --------------------------------
echo
echo "== what the kernel logged =="
new=$(dmesg | tail -n +"$DMESG_MARK")
echo "$new" | grep -iE 'remoteproc|55020000|55082000' | sed 's/^/        /' | tail -12

if echo "$new" | grep -qiE 'iommu.*fault|mmu fault|MMU_FAULT'; then
	bad "the IOMMU reported a fault — the firmware went outside its carveout"
else
	ok "no IOMMU fault"
fi

# Checked separately, and by prefix rather than by keyword. The first version
# of this script grepped the log for 'iommu|remoteproc|mmu' and reported
# "0 failed" through two BUG: splats, because a backtrace does not repeat the
# subsystem name on every line and the one line that did match was the
# "Modules linked in:" dump. A test that filters the kernel log by topic will
# always be the last to know.
splat=$(echo "$new" | grep -cE '^\[[^]]*\] (BUG:|WARNING:|Unable to handle|Internal error|INFO: rcu)')
if [ "$splat" = 0 ]; then
	ok "the kernel logged no BUG or WARNING"
else
	bad "the kernel logged $splat BUG/WARNING line(s) while the IPU was running"
	echo "$new" | grep -E '^\[[^]]*\] (BUG:|WARNING:|Unable to handle|Internal error|INFO: rcu)' \
		| sed 's/^/        /'
	note "full backtraces: dmesg | tail -n +$DMESG_MARK"
fi

echo
echo "$pass ok, $fail failed"
exit $((fail>0))
