#!/bin/bash
#
# pyra-x-load-profile.sh — measure what the X server actually costs during a
# real workload, and bound what any display-driver change could be worth.
#
# Start this, then use the machine: play the game, run the emulator, drag
# windows around. It samples in the background and prints a summary.
#
#   ./pyra-x-load-profile.sh                 # 60 seconds
#   ./pyra-x-load-profile.sh -d 300          # 5 minutes
#   ./pyra-x-load-profile.sh -d 180 -n wine  # also track processes matching 'wine'
#
# Reads only. Changes nothing. sudo is used for the GPU counter and is
# optional; without it that one section is skipped.

set -u

DURATION=60
PATTERN=""

usage() { sed -n '2,/^$/s/^# \?//p' "$0"; exit "${1:-0}"; }

while getopts "d:n:h" o; do
	case "$o" in
	d) DURATION=$OPTARG ;;
	n) PATTERN=$OPTARG ;;
	h) usage 0 ;;
	*) usage 1 ;;
	esac
done

XPID=$(pidof Xorg 2>/dev/null | awk '{print $1}')
if [ -z "$XPID" ]; then
	echo "no Xorg process found" >&2
	exit 1
fi

HZ=$(getconf CLK_TCK)
NCPU=$(nproc)

# utime + stime for a pid, in ticks
proc_cpu() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }

# total and busy jiffies across all cores
sys_cpu() {
	awk '/^cpu /{t=0; for (i=2;i<=NF;i++) t+=$i; print t, t-$5-$6}' /proc/stat
}

declare -A PID_FIRST PID_LAST

# Sample every process matching PATTERN. Processes come and go during a run,
# so accumulate per pid and sum (last - first) at the end.
sample_pattern() {
	[ -z "$PATTERN" ] && return
	local p c
	for p in $( { pgrep -f "$PATTERN"; pgrep -x "$PATTERN"; } 2>/dev/null | sort -un); do
		[ "$p" = "$$" ] && continue
		[ "$p" = "$PPID" ] && continue
		c=$(proc_cpu "$p")
		[ -z "${PID_FIRST[$p]:-}" ] && PID_FIRST[$p]=$c
		PID_LAST[$p]=$c
	done
}

pattern_total() {
	local total=0 p
	for p in "${!PID_LAST[@]}"; do
		total=$((total + PID_LAST[$p] - PID_FIRST[$p]))
	done
	echo "$total"
}

# thermal zone whose type matches $1
zone_for() {
	local z
	for z in /sys/class/thermal/thermal_zone*/; do
		[ "$(cat "$z/type" 2>/dev/null)" = "$1" ] && { echo "$z/temp"; return; }
	done
}

# debugfs node for the etnaviv 2D core. /sys/kernel/debug is mode 0700, so
# the directory has to be listed through sudo as well, not just read.
find_gpu() {
	local n
	for n in $(sudo -n ls /sys/kernel/debug/dri/ 2>/dev/null); do
		if sudo -n cat "/sys/kernel/debug/dri/$n/name" 2>/dev/null | grep -q etnaviv; then
			echo "/sys/kernel/debug/dri/$n/gpu"
			return
		fi
	done
}

CPU_TEMP=$(zone_for cpu_thermal)
GPU_NODE=""
if sudo -n true 2>/dev/null; then
	GPU_NODE=$(find_gpu)
fi

echo "Xorg pid $XPID, ${NCPU} cores, sampling for ${DURATION}s."
[ -n "$PATTERN" ] && echo "also tracking processes matching '$PATTERN'."
echo "Use the machine normally now. Ctrl-C stops early and still reports."
echo

X0=$(proc_cpu "$XPID")
read -r S0 B0 <<<"$(sys_cpu)"
GPU_SEEN=""
TEMP_MAX=0
FREQ_SUM=0
FREQ_N=0
SAMPLES=0
START=$(date +%s)

report() {
	local END X1 P1 S1 B1 elapsed xcpu pcpu stot sbusy
	END=$(date +%s)
	elapsed=$((END - START))
	[ "$elapsed" -lt 1 ] && elapsed=1
	X1=$(proc_cpu "$XPID")
	P1=$(pattern_total)
	read -r S1 B1 <<<"$(sys_cpu)"

	xcpu=$(echo "scale=3; ($X1-$X0)/$HZ" | bc)
	pcpu=$(echo "scale=3; $P1/$HZ" | bc)
	stot=$((S1 - S0))
	sbusy=$((B1 - B0))

	echo
	echo "=== ${elapsed}s sampled, ${SAMPLES} polls"
	echo
	printf "  %-38s %s s\n" "Xorg CPU consumed" "$xcpu"
	printf "  %-38s %s %%\n" "  as share of one core" \
		"$(echo "scale=2; ($X1-$X0)*100/$HZ/$elapsed" | bc)"
	printf "  %-38s %s %%\n" "  as share of the whole machine" \
		"$(echo "scale=2; ($X1-$X0)*100/$HZ/$elapsed/$NCPU" | bc)"
	if [ "$sbusy" -gt 0 ]; then
		printf "  %-38s %s %%\n" "  as share of all busy CPU time" \
			"$(echo "scale=2; ($X1-$X0)*100/$sbusy" | bc)"
	fi
	if [ "$stot" -gt 0 ]; then
		printf "  %-38s %s %%\n" "machine busy overall" \
			"$(echo "scale=2; $sbusy*100/$stot" | bc)"
	fi
	if [ -n "$PATTERN" ]; then
		printf "  %-38s %s s\n" "matched processes CPU" "$pcpu"
		echo "     sampled once a second, so processes that live for less than"
		echo "     that are undercounted. Sound for a sustained game or emulator."
	fi

	echo
	printf "  %-38s %s MHz\n" "mean cpu0 clock" \
		"$( [ "$FREQ_N" -gt 0 ] && echo "scale=0; $FREQ_SUM/$FREQ_N/1000" | bc || echo '?')"
	printf "  %-38s %s C\n" "peak CPU temperature" \
		"$(echo "scale=1; $TEMP_MAX/1000" | bc)"

	if [ -n "$GPU_NODE" ]; then
		local n
		n=$(echo "$GPU_SEEN" | sort -u | grep -c . )
		printf "  %-38s %s\n" "distinct GC320 command addresses" "$n"
		if [ "$n" -le 1 ]; then
			echo "     the 2D core never moved: this workload does not use it"
		else
			echo "     the 2D core was executing during the run"
		fi
	else
		echo "  GC320 counter skipped (needs passwordless sudo)"
	fi

	echo
	echo "  Interpretation: the display driver cannot give back more than the"
	echo "  Xorg share above. If that number is small, no change to omap5_drv.so"
	echo "  is worth making for this workload."
	echo

	# MIT-SHM heuristic: X clients using shared memory show up as segments
	# attached by two processes.
	if command -v ipcs >/dev/null 2>&1; then
		local shm
		shm=$(ipcs -m 2>/dev/null | awk 'NR>3 && $6>=2 {n++} END{print n+0}')
		printf "  %-38s %s\n" "shared memory segments in use" "$shm"
		echo "     nonzero suggests clients present frames via MIT-SHM, which"
		echo "     is already the fast upload path"
	fi
}

trap 'report; exit 0' INT TERM

while [ $(( $(date +%s) - START )) -lt "$DURATION" ]; do
	SAMPLES=$((SAMPLES + 1))
	t=$(cat "$CPU_TEMP" 2>/dev/null || echo 0)
	[ "$t" -gt "$TEMP_MAX" ] && TEMP_MAX=$t
	f=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
	FREQ_SUM=$((FREQ_SUM + f))
	FREQ_N=$((FREQ_N + 1))
	sample_pattern
	if [ -n "$GPU_NODE" ]; then
		GPU_SEEN="$GPU_SEEN
$(sudo -n grep -m1 'address 0:' "$GPU_NODE" 2>/dev/null)"
	fi
	sleep 1
done

report
