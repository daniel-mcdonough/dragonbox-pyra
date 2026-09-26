#!/bin/sh
# Device side of pyra_undervolt.ko.  Run as the pyra user; it sudoes what it needs.
#   ./undervolt.sh load                 insmod pyra_undervolt.ko from this directory
#   ./undervolt.sh table                kHz, device-tree uV, live uV; and the rail now
#   ./undervolt.sh set <kHz> <uV>       change one point and leave the CPU pinned on it
#   ./undervolt.sh restore              every point back, module out, governor back
#
# The OPP core applies a point's voltage only on a transition to it, so `set` pins the
# CPU one step above the point, changes it, and pins back down onto it.  The pin is the
# userspace governor + scaling_setspeed, as Shipwright's bench.sh does: pyra-thermal
# rewrites scaling_max_freq every 2 s, so min == max does not hold a pin.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
CPU=/sys/devices/system/cpu/cpu0/cpufreq
PARAM=/sys/module/pyra_undervolt/parameters
GOV_SAVE=/tmp/pyra-undervolt.governor

rail() {
	for r in /sys/class/regulator/regulator.*; do
		[ "$(cat "$r/name" 2>/dev/null)" = smps123 ] || continue
		echo "smps123 (cpu rail) set to $(cat "$r/microvolts") uV; cpu at $(cat $CPU/scaling_cur_freq) kHz"
		return
	done
	echo "smps123 not found under /sys/class/regulator"
}

pin() {
	[ -f $GOV_SAVE ] || cat $CPU/scaling_governor > $GOV_SAVE
	sudo sh -c "echo userspace > $CPU/scaling_governor; echo $1 > $CPU/scaling_setspeed"
	sleep 0.2
	[ "$(cat $CPU/scaling_cur_freq)" = "$1" ] || { echo "pin to $1 kHz did not take (cur $(cat $CPU/scaling_cur_freq)); pyra-thermal cap?"; exit 1; }
}

# the next frequency above $1 in cpufreq's table, or the lowest if $1 is the top
above() {
	for f in $(tr ' ' '\n' < $CPU/scaling_available_frequencies | sort -n); do
		[ "$f" -gt "$1" ] && { echo "$f"; return; }
	done
	# at the top already: the lowest instead
	tr ' ' '\n' < $CPU/scaling_available_frequencies | sort -n | grep . | head -1
}

case "${1:-}" in
load)
	[ -d $PARAM ] || sudo insmod "$HERE/pyra_undervolt.ko"
	cat $PARAM/table; rail ;;
table)
	cat $PARAM/table; rail ;;
set)
	[ $# -eq 3 ] || { echo "usage: $0 set <kHz> <uV>"; exit 1; }
	pin "$(above "$2")"
	sudo sh -c "echo '$2 $3' > $PARAM/set"
	pin "$2"
	grep -E "^ *$2 " $PARAM/table; rail ;;
restore)
	if [ -d $PARAM ]; then
		pin "$(above "$(cat $CPU/scaling_cur_freq)")"
		sudo rmmod pyra_undervolt
	fi
	gov=$(cat $GOV_SAVE 2>/dev/null || echo ondemand)
	[ "$gov" = userspace ] && gov=ondemand
	sudo sh -c "echo $gov > $CPU/scaling_governor"
	rm -f $GOV_SAVE
	echo "governor $(cat $CPU/scaling_governor)"; rail ;;
*)
	sed -n '2,6p' "$0"; exit 1 ;;
esac
