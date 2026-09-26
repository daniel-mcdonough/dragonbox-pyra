#!/bin/bash
#
# pyra-cpu-attribution.sh — account for every busy CPU cycle on the machine,
# by process, across a window of time.
#
#   ./pyra-cpu-attribution.sh              # 60 s
#   ./pyra-cpu-attribution.sh -d 120       # 2 minutes
#   ./pyra-cpu-attribution.sh -d 90 -n 25  # and show the top 25
#   ./pyra-cpu-attribution.sh -t soh.elf   # and that process's threads, by name
#
# Read-only. Samples /proc every second so that processes which start and exit
# inside the window are still counted, and reports what fraction of the busy
# time each one took. The residual line at the end is the part no surviving
# /proc entry could explain, which is kernel threads and very short-lived
# processes.
#
# Written for the question "the machine is busy, but the workload does not add
# up to that" — the answer is usually a process nobody thought to look at.

set -u

DURATION=60
TOP=20
INTERVAL=1
THREADS=

usage() { sed -n '2,/^$/s/^# \?//p' "$0"; exit "${1:-0}"; }

while getopts "d:n:t:h" o; do
	case "$o" in
	d) DURATION=$OPTARG ;;
	n) TOP=$OPTARG ;;
	t) THREADS=$OPTARG ;;
	h) usage 0 ;;
	*) usage 1 ;;
	esac
done

HZ=$(getconf CLK_TCK)
NCPU=$(nproc)

RAW=$(mktemp /tmp/.cpuattr.XXXXXX)
trap 'rm -f "$RAW"' EXIT INT TERM

sys_busy() { awk '/^cpu /{t=0; for (i=2;i<=NF;i++) t+=$i; print t-$5-$6}' /proc/stat; }
sys_total() { awk '/^cpu /{t=0; for (i=2;i<=NF;i++) t+=$i; print t}' /proc/stat; }
# user nice system idle iowait irq softirq steal
sys_fields() { awk '/^cpu /{print $2, $3, $4, $5, $6, $7, $8}' /proc/stat; }
# busy and total ticks per core, "cpu0 busy total cpu1 busy total ..."
core_fields() { awk '/^cpu[0-9]/{t=0; for (i=2;i<=NF;i++) t+=$i; printf "%s %d %d ", $1, t-$5-$6, t}' /proc/stat; }
# utime+stime and name of every thread of process $1: "tid ticks name"
thread_sample() {
	awk '{
		i = index($0, "("); j = 0
		for (k = length($0); k > 0; k--) if (substr($0, k, 1) == ")") { j = k; break }
		split(substr($0, j+2), f, " ")
		print $1, f[12] + f[13], substr($0, i+1, j-i-1)
	}' /proc/"$1"/task/[0-9]*/stat 2>/dev/null
}

# One awk per sample, not one per process: on a two-core handheld the sampler
# must not become the workload.
sample() {
	awk '
	{
		n = split(FILENAME, parts, "/"); pid = parts[3]
		i = index($0, "("); j = 0
		for (k = length($0); k > 0; k--) if (substr($0, k, 1) == ")") { j = k; break }
		comm = substr($0, i+1, j-i-1)
		rest = substr($0, j+2)
		split(rest, f, " ")
		print pid, f[12] + f[13], comm
	}' /proc/[0-9]*/stat 2>/dev/null >> "$RAW"
}

echo "sampling $DURATION s at ${INTERVAL}s, $NCPU cores, $HZ ticks/s"
echo

TPID=
if [ -n "$THREADS" ]; then
	TPID=$(pgrep -xo "$THREADS") || { echo "no process named $THREADS"; exit 1; }
	thread_sample "$TPID" > "$RAW.t0"
fi
B0=$(sys_busy); T0=$(sys_total); F0=$(sys_fields); C0=$(core_fields)
END=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$END" ]; do
	sample
	sleep "$INTERVAL"
done
sample
B1=$(sys_busy); T1=$(sys_total); F1=$(sys_fields); C1=$(core_fields)
[ -n "$TPID" ] && thread_sample "$TPID" > "$RAW.t1"

BUSY=$(( B1 - B0 ))
TOTAL=$(( T1 - T0 ))
[ "$BUSY" -gt 0 ] || { echo "machine was idle throughout"; exit 0; }

sort -k1,1n "$RAW" | awk '
{
	pid = $1; t = $2; comm = $3
	for (i = 4; i <= NF; i++) comm = comm " " $i
	if (!(pid in first)) { first[pid] = t; name[pid] = comm }
	last[pid] = t
}
END { for (p in last) if (last[p] - first[p] > 0) print last[p] - first[p], p, name[p] }
' | sort -rn > "$RAW.agg"

ACCOUNTED=$(awk '{s+=$1} END{print s+0}' "$RAW.agg")

awk -v hz="$HZ" -v busy="$BUSY" -v ncpu="$NCPU" -v top="$TOP" -v dur="$DURATION" '
BEGIN {
	printf "%-24s %8s %10s %10s\n", "process", "pid", "CPU s", "% of busy"
	printf "%-24s %8s %10s %10s\n", "------------------------", "--------", "----------", "----------"
}
NR <= top {
	comm = $3
	for (i = 4; i <= NF; i++) comm = comm " " $i
	printf "%-24s %8s %10.2f %9.1f%%\n", comm, $2, $1/hz, 100*$1/busy
}
' "$RAW.agg"

RESIDUAL=$(( BUSY - ACCOUNTED ))
echo
awk -v hz="$HZ" -v busy="$BUSY" -v total="$TOTAL" -v acc="$ACCOUNTED" -v res="$RESIDUAL" -v ncpu="$NCPU" '
BEGIN {
	printf "%-40s %10.2f s\n", "busy CPU time in the window", busy/hz
	printf "%-40s %10.1f %%\n", "  machine busy, all cores", 100*busy/total
	printf "%-40s %10.2f s  (%.1f%%)\n", "accounted to processes", acc/hz, 100*acc/busy
	printf "%-40s %10.2f s  (%.1f%%)\n", "residual: kernel threads, short-lived", res/hz, 100*res/busy
}
'
echo
# Time in hard and soft interrupt context belongs to no process, so it can only
# ever appear in the residual above. Naming it separately is the difference
# between "unexplained" and "the network or the display is interrupting a lot".
awk -v hz="$HZ" -v busy="$BUSY" -v f0="$F0" -v f1="$F1" '
BEGIN {
	n = split(f0, a, " "); split(f1, b, " ")
	label[1]="user"; label[2]="nice"; label[3]="system"
	label[5]="iowait"; label[6]="irq (hard)"; label[7]="softirq"
	printf "%-40s %10s %10s\n", "busy time by kernel class", "CPU s", "% of busy"
	for (i = 1; i <= 7; i++) {
		if (i == 4) continue
		d = b[i] - a[i]
		if (d <= 0 && i != 6 && i != 7) continue
		printf "%-40s %10.2f %9.1f%%\n", label[i], d/hz, 100*d/busy
	}
}
'
echo
awk -v c0="$C0" -v c1="$C1" '
BEGIN {
	n = split(c0, a, " "); split(c1, b, " ")
	printf "%-40s %10s\n", "busy by core", "% busy"
	for (i = 1; i <= n; i += 3)
		printf "%-40s %9.1f%%\n", a[i], 100*(b[i+1]-a[i+1])/(b[i+2]-a[i+2])
}
'
if [ -n "$TPID" ]; then
	echo
	# Threads alive at both ends; one that started or ended inside the window is left out, and
	# counted as such.
	awk -v hz="$HZ" -v dur="$DURATION" -v busy="$BUSY" -v name="$THREADS" -v pid="$TPID" '
	FNR == NR { t0[$1] = $2; next }
	{ n = $3; for (i = 4; i <= NF; i++) n = n " " $i
	  if ($1 in t0) { d = $2 - t0[$1]; if (d > 0) printf "%d %s %s\n", d, $1, n } else gone++ }
	END { if (gone) printf "0 - (%d threads not alive at both ends)\n", gone }
	' "$RAW.t0" "$RAW.t1" | sort -rn | awk -v hz="$HZ" -v dur="$DURATION" -v busy="$BUSY" -v name="$THREADS" -v pid="$TPID" '
	BEGIN { printf "%-24s %8s %10s %10s %10s\n", name " " pid ": thread", "tid", "CPU s", "% of a core", "% of busy" }
	$2 == "-" { print; next }
	{ n = $3; for (i = 4; i <= NF; i++) n = n " " $i
	  printf "%-24s %8s %10.2f %9.1f%% %9.1f%%\n", n, $2, $1/hz, 100*$1/hz/dur, 100*$1/busy }
	'
fi
rm -f "$RAW.agg" "$RAW.t0" "$RAW.t1"
