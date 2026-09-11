#!/bin/bash
#
# pyra-sleep-test.sh — suspend the Pyra and prove it came back.
#
#   sudo ./pyra-sleep-test.sh                 staged: idle first, then RAM
#   sudo ./pyra-sleep-test.sh --mode mem      only suspend to RAM
#   sudo ./pyra-sleep-test.sh --seconds 60    stay asleep longer
#
# Suspend on this machine used to hang forever in the SD card subsystem and
# take the desktop down with it, so this does three things to make testing it
# survivable.
#
# It arms the real-time clock to wake the machine by itself, so nothing
# depends on a wake key working or on you being in front of it.
#
# It tries suspend-to-idle first. That exercises the freezer and the power
# notifier chain, which is where the old fault was, without powering the SoC
# down, so a chip that does not come back is much less likely. Only if that
# works does it try suspend to RAM.
#
# And it detaches before suspending, so running it over SSH does not leave
# the test half-done if the connection drops. Re-run it with the connection
# gone and the log is still there.
#
# See docs/troubleshooting.md for what a good and a bad result look like.
#
set -euo pipefail

MODE=staged
SECONDS_ASLEEP=30
LOGDIR=/var/log
RTC=/sys/class/rtc/rtc0/wakealarm

while [ $# -gt 0 ]; do
	case $1 in
	--mode)     MODE=${2:?}; shift 2 ;;
	--seconds)  SECONDS_ASLEEP=${2:?}; shift 2 ;;
	-h|--help)  sed -n '3,26p' "$0" | sed 's/^# \?//'; exit 0 ;;
	*)          echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done
case $MODE in staged|freeze|mem) ;; *) echo "--mode must be staged, freeze or mem" >&2; exit 2 ;; esac

[ "$(id -u)" = 0 ] || { echo "run this with sudo" >&2; exit 2; }

die() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

# ------------------------------------------------------------------ preflight
say "checking this machine can be put to sleep"

[ -w "$RTC" ] || die "no writable $RTC, so there is no way to wake it again"

for t in sleep.target suspend.target; do
	[ "$(systemctl is-enabled "$t" 2>/dev/null || true)" != masked ] \
		|| die "$t is masked. That was the workaround for suspend hanging.
Unmask all five before testing:

    systemctl unmask sleep.target suspend.target hybrid-sleep.target \\
                     suspend-then-hibernate.target hibernate.target"
done

states=$(cat /sys/power/state)
echo "  /sys/power/state offers: $states"
want_states=$MODE
[ "$MODE" != staged ] || want_states="freeze mem"
for w in $want_states; do
	case " $states " in *" $w "*) ;; *) die "this kernel does not offer '$w'" ;; esac
done

# A rescan worker stuck in uninterruptible sleep is the exact thing that used
# to make suspend hang, so say so before rather than after.
stuck=$(ps -eo stat,comm | awk '$1 ~ /^D/ {print $2}' | sort -u | tr '\n' ' ')
if [ -n "$stuck" ]; then
	echo "  WARNING: tasks already in uninterruptible sleep: $stuck"
	echo "  On a kernel without patches/0003 these will hang the suspend."
else
	echo "  nothing is in uninterruptible sleep, which is what we want"
fi

# ------------------------------------------------------------------- one round
# Everything below the detach runs with no controlling terminal, so all output
# goes to the log and the caller polls it.
one_round() {
	local mode=$1 log=$2 t0 path rc count tries

	echo "=== $mode ===" >>"$log"

	# Settle first. The kernel refuses to suspend while a wakeup event is
	# still outstanding, and the wake that ended the previous round is
	# exactly such an event: going straight into the next one gets
	# "Wakeup pending. Abort CPU freeze" in dmesg and a failed write here.
	#
	# Writing the count back to /sys/power/wakeup_count is how userspace
	# says it has seen every wakeup so far. The write fails while one is
	# outstanding, so looping on it is the wait.
	tries=0
	until count=$(cat /sys/power/wakeup_count 2>/dev/null) &&
	      echo "$count" >/sys/power/wakeup_count 2>/dev/null; do
		tries=$((tries + 1))
		if [ "$tries" -gt 15 ]; then
			echo "RESULT $mode: a wakeup source is still active after ${tries}s," >>"$log"
			echo "  so the kernel would refuse to sleep. Check:" >>"$log"
			echo "  grep -v '	0	' /sys/kernel/debug/wakeup_sources" >>"$log"
			return 1
		fi
		sleep 1
	done
	[ "$tries" = 0 ] || echo "waited ${tries}s for the previous wake to settle" >>"$log"

	echo "armed for ${SECONDS_ASLEEP}s at $(date)" >>"$log"
	echo 0 >"$RTC"
	echo "+$SECONDS_ASLEEP" >"$RTC"
	[ "$(cat "$RTC")" != 0 ] || { echo "RESULT $mode: could not arm the RTC" >>"$log"; return 1; }

	echo "pyra-sleep-test: entering $mode" >/dev/kmsg || true
	t0=$(date +%s)
	rc=0
	echo "$mode" >/sys/power/state || rc=$?
	echo "returned $rc after $(( $(date +%s) - t0 ))s of wall clock" >>"$log"
	echo 0 >"$RTC"

	if [ "$rc" != 0 ]; then
		echo "RESULT $mode: FAILED, the write returned $rc" >>"$log"
		echo "  what the kernel said:" >>"$log"
		dmesg | tail -20 | grep -iE "PM:|wakeup|abort|freez" | sed 's/^/  /' >>"$log" || true
		return 1
	fi
	# Returning 0 is necessary but not sufficient. The old fault froze the
	# session on the way in and never thawed it, so check the thing that
	# actually broke.
	local frozen
	frozen=$(systemctl show user.slice -p FreezerState --value 2>/dev/null || echo unknown)
	echo "user.slice FreezerState: $frozen" >>"$log"

	# Writing "mem" does not decide how deep it goes; /sys/power/mem_sleep
	# does, and it can make "mem" mean s2idle without saying so anywhere in
	# the result. The kernel names the path it took on the way in, so take
	# the answer from there rather than inferring it.
	path=$(dmesg | sed -n 's/.*PM: suspend entry (\(.*\))$/\1/p' | tail -1)
	if [ -n "$path" ]; then
		echo "the kernel took the '$path' path" >>"$log"
		if [ "$mode" = mem ] && [ "$path" != deep ]; then
			echo "WARNING: 'mem' did not go deep. What it will do is in:" >>"$log"
			echo "  cat /sys/power/mem_sleep" >>"$log"
		fi
	fi
	if [ "$frozen" = frozen ]; then
		echo "RESULT $mode: CAME BACK BUT THE SESSION IS FROZEN." >>"$log"
		echo "  Recover it with: systemctl thaw user.slice" >>"$log"
		return 1
	fi
	echo "RESULT $mode: ok, slept and resumed with the session intact" >>"$log"
	return 0
}

run_all() {
	local log=$1
	: >"$log"
	case $MODE in
	staged)
		one_round freeze "$log" || { echo "DONE" >>"$log"; return; }
		echo "suspend-to-idle worked, trying suspend to RAM" >>"$log"
		one_round mem "$log" || true ;;
	*)      one_round "$MODE" "$log" || true ;;
	esac
	echo "DONE" >>"$log"
}

# --------------------------------------------------------------------- detach
LOG=$LOGDIR/pyra-sleep-test.log
if [ "${PYRA_SLEEP_TEST_CHILD:-0}" = 1 ]; then
	run_all "$LOG"
	exit 0
fi

say "sleeping for ${SECONDS_ASLEEP}s per round, mode: $MODE"
echo "  log: $LOG"
echo "  the machine is about to go quiet. It wakes itself."
: >"$LOG"
PYRA_SLEEP_TEST_CHILD=1 setsid nohup "$0" --mode "$MODE" --seconds "$SECONDS_ASLEEP" \
	</dev/null >/dev/null 2>&1 &

# Poll rather than wait, so that a dropped SSH connection loses the report and
# not the test. Allow generous slack for a round that goes badly.
deadline=$(( $(date +%s) + (SECONDS_ASLEEP + 60) * 2 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
	grep -q '^DONE$' "$LOG" 2>/dev/null && break
	sleep 2
done

say "result"
sed '/^DONE$/d' "$LOG"

if ! grep -q '^DONE$' "$LOG"; then
	echo
	echo "The test has not finished. It is still running, or the machine did"
	echo "not come back. Look at $LOG when you can reach it again."
	exit 1
fi

if grep -q 'RESULT mem: ok' "$LOG" || { [ "$MODE" = freeze ] && grep -q 'RESULT freeze: ok' "$LOG"; }; then
	cat <<EOF

Suspend works. What the kernel did is in:

    dmesg | grep -E "PM: suspend (entry|exit)|Freezing user space|Restarting tasks"

Resume should be quiet. A burst of "Failed to read IRQ status" means the
kernel is missing patches/0004. Three smaller warnings per wake are expected
and harmless; docs/troubleshooting.md lists them.
EOF
	exit 0
fi

echo
echo "Suspend did not pass. docs/troubleshooting.md has what each failure means."
exit 1
