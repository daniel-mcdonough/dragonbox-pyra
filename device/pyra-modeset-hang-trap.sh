#!/bin/bash
#
# pyra-modeset-hang-trap.sh — provoke the modeset hang and capture where the
# kernel is stuck, then reboot before the case gets hot. Runs on the Pyra.
#
#   sudo ./pyra-modeset-hang-trap.sh                    mixed trigger, auto-reboot
#   sudo ./pyra-modeset-hang-trap.sh --trigger dpms     only the cold path
#   sudo ./pyra-modeset-hang-trap.sh --trigger x11perf  only the hot path
#   sudo ./pyra-modeset-hang-trap.sh --no-reboot     capture and stay wedged
#   sudo ./pyra-modeset-hang-trap.sh --selftest      prove the capture works, hang nothing
#
# WHAT THIS DOES ON PURPOSE: it hangs the X server. That pins one core at 100%
# in a fanless case and a reboot is the only recovery, which is exactly the
# fault described in troubleshooting.md. Nothing here is safe to run casually.
#
# Why it is worth doing anyway: the fault is in the kernel, inside
# DRM_IOCTL_MODE_SETCRTC, and the one piece of evidence nobody has yet is the
# kernel stack of the spinning thread. That evidence only exists while the
# machine is wedged and is gone after the reboot that recovers it. See
# building.md. Note that /proc/PID/stack cannot supply it: ARM refuses stack
# traces of any task but the caller when CONFIG_SMP is set, which this kernel
# is. sysrq's NMI backtrace does work, and is what this captures.
#
# The watchdog samples twice a second and fires the moment Xorg is burning a
# whole core with the display controller stopped, so the capture happens within
# a couple of seconds of the wedge rather than whenever a human notices. Then it
# reboots, which is both the recovery and the thermal protection.
#
set -uo pipefail

TRIGGER=mixed
REBOOT=yes
SELFTEST=no
MAX_ROUNDS=40
TEMP_ABORT=90000	# millidegrees. Bail out rather than cook the case.
COOL_TARGET=65000	# x11perf bursts only happen below this

while [ $# -gt 0 ]; do
	case "$1" in
		--trigger) TRIGGER=$2; shift 2 ;;
		--no-reboot) REBOOT=no; shift ;;
		--selftest) SELFTEST=yes; shift ;;
		--rounds) MAX_ROUNDS=$2; shift 2 ;;
		*) echo "usage: $0 [--trigger x11perf|dpms] [--no-reboot] [--rounds N]" >&2; exit 2 ;;
	esac
done

[ "$(id -u)" = 0 ] || { echo "must run as root (sudo)" >&2; exit 1; }

XPID=$(pgrep -x Xorg | head -1)
[ -n "$XPID" ] || { echo "no Xorg running" >&2; exit 1; }

HOME_DIR=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
OUT=$HOME_DIR/modeset-hang-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
chmod 755 "$OUT"

export DISPLAY=:0
export XAUTHORITY=/var/run/lightdm/root/:0

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/run.log"; }

dispc_count() { awk '/OMAP DISPC/ {print $2 + $3}' /proc/interrupts; }
xorg_ticks()  { awk '{print $14 + $15}' "/proc/$XPID/stat" 2>/dev/null || echo 0; }
cpu_temp()    { cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0; }

# ---------------------------------------------------------------- baseline
say "Xorg is pid $XPID, kernel $(uname -r)"
SYSRQ_WAS=$(cat /proc/sys/kernel/sysrq)
echo 1 > /proc/sys/kernel/sysrq
say "sysrq was $SYSRQ_WAS, set to 1 for the duration"

{
	echo "=== uname"; uname -a
	echo "=== sysrq before"; echo "$SYSRQ_WAS"
	echo "=== interrupts"; cat /proc/interrupts
	echo "=== thermal"; for z in /sys/class/thermal/thermal_zone*; do
		echo "$(cat "$z"/type) $(cat "$z"/temp)"; done
	echo "=== xrandr"; timeout 5 xrandr --verbose 2>&1
	echo "=== dmesg"; dmesg
} > "$OUT/00-baseline.txt" 2>&1
cp /var/log/Xorg.0.log "$OUT/00-Xorg.0.log.before" 2>/dev/null

# ---------------------------------------------------------------- capture
# Everything here must work with X dead. Nothing may call an X client.
capture() {
	local why=$1
	say "WEDGE DETECTED ($why) — capturing"

	# /proc/PID/stack is always empty on this kernel: ARM's
	# __save_stack_trace refuses any task but the caller when CONFIG_SMP is
	# set. Captured anyway, to keep proving that rather than re-discovering
	# it. The real evidence is the sysrq NMI backtraces below.
	cat "/proc/$XPID/stack"   > "$OUT/10-xorg-kernel-stack.txt" 2>&1
	cat "/proc/$XPID/status"  > "$OUT/11-xorg-status.txt" 2>&1
	cat "/proc/$XPID/wchan"   > "$OUT/12-xorg-wchan.txt" 2>&1; echo >> "$OUT/12-xorg-wchan.txt"
	cat "/proc/$XPID/syscall" > "$OUT/13-xorg-syscall.txt" 2>&1

	# Per-thread stacks: the spinning one may not be the main thread.
	for t in /proc/$XPID/task/*; do
		echo "--- thread ${t##*/}"
		cat "$t/stack" 2>&1
	done > "$OUT/14-xorg-thread-stacks.txt"

	# THE evidence. sysrq-l sends an NMI to every CPU and dumps the
	# symbolised backtrace of whatever is running on it, which is the
	# spinning thread itself. Five samples a second apart, because a tight
	# loop will show a different PC each time and the spread says how big
	# the loop is and where it sits.
	dmesg -c > /dev/null 2>&1
	for n in 1 2 3 4 5; do
		echo l > /proc/sysrq-trigger
		sleep 1
		dmesg -c > "$OUT/20-sysrq-l-sample-$n.txt" 2>&1
	done
	cat "$OUT"/20-sysrq-l-sample-*.txt > "$OUT/20-sysrq-l-all-samples.txt" 2>&1
	echo w > /proc/sysrq-trigger; sleep 1
	dmesg -c > "$OUT/21-sysrq-w-blocked-tasks.txt" 2>&1

	{
		echo "=== interrupts"; cat /proc/interrupts
		echo "=== thermal"; for z in /sys/class/thermal/thermal_zone*; do
			echo "$(cat "$z"/type) $(cat "$z"/temp)"; done
		echo "=== top by cpu"; ps -eo pid,stat,pcpu,wchan:24,comm --sort=-pcpu | head -15
		echo "=== loadavg"; cat /proc/loadavg
	} > "$OUT/30-machine-state.txt" 2>&1

	cp /var/log/Xorg.0.log "$OUT/31-Xorg.0.log.after" 2>/dev/null
	tail -5 /var/log/Xorg.0.log > "$OUT/32-Xorg-last-lines.txt" 2>/dev/null

	say "captured to $OUT"
	# Show the CPU that was running Xorg, across all the samples rather than
	# just the first, since the spinning thread need not be scheduled at the
	# instant of any one NMI. If Xorg is nowhere — the spin turned out to be
	# in a kworker, say — show every CPU rather than nothing, because a
	# summary that prints nothing looks like a capture that failed.
	if grep -qs "Comm: Xorg" "$OUT"/20-sysrq-l-sample-*.txt; then
		say "--- backtrace of the CPU running Xorg ---"
		grep -h -A30 -m1 "Comm: Xorg" "$OUT"/20-sysrq-l-sample-*.txt \
			| tee -a "$OUT/run.log"
	else
		say "--- Xorg was on neither CPU at any sample; here is every CPU ---"
		awk '/NMI backtrace for cpu/,0' "$OUT/20-sysrq-l-sample-1.txt" \
			| tee -a "$OUT/run.log"
	fi
}

# ---------------------------------------------------------------- watchdog
# Fires when Xorg is burning most of a core while the display controller has
# stopped producing interrupts. Both halves matter: a busy X server with
# vblanks still arriving is just a busy X server.
watchdog() {
	local hits=0 pt pd t d temp
	pt=$(xorg_ticks); pd=$(dispc_count)
	while :; do
		sleep 0.5
		t=$(xorg_ticks); d=$(dispc_count); temp=$(cpu_temp)
		# 100 ticks/s, so half a second of one full core is 50.
		if [ $((t - pt)) -ge 40 ] && [ $((d - pd)) -eq 0 ]; then
			hits=$((hits + 1))
		else
			hits=0
		fi
		pt=$t; pd=$d
		# Three seconds of a pegged core with no vblanks is only a
		# candidate. Confirm it by asking the X server a question: a
		# healthy server answers instantly, a wedged one never answers
		# and takes every other client down with it.
		if [ "$hits" -ge 6 ]; then
			if timeout 5 xdpyinfo > /dev/null 2>&1; then
				say "candidate at $(date +%H:%M:%S) but X still answers — not a wedge"
				hits=0
			else
				echo wedge > "$OUT/.verdict"; return 0
			fi
		fi
		if [ "$temp" -ge "$TEMP_ABORT" ]; then
			echo hot > "$OUT/.verdict"; return 0
		fi
		[ -f "$OUT/.stop" ] && { echo stopped > "$OUT/.verdict"; return 0; }
	done
}

# A dry run of the capture against a healthy X server. Proves every file can
# actually be produced before the one chance to produce them for real.
if [ "$SELFTEST" = yes ]; then
	capture "selftest, nothing is actually wrong"
	echo "$SYSRQ_WAS" > /proc/sys/kernel/sysrq
	say "sysrq restored to $SYSRQ_WAS"
	say "selftest files:"
	ls -la "$OUT" | tee -a "$OUT/run.log"
	for f in 20-sysrq-l-all-samples.txt 21-sysrq-w-blocked-tasks.txt 30-machine-state.txt; do
		[ -s "$OUT/$f" ] || say "EMPTY: $f — the real capture would lose this"
	done
	chown -R "${SUDO_USER:-root}" "$OUT" 2>/dev/null
	exit 0
fi

watchdog & WD=$!

# ---------------------------------------------------------------- trigger
say "trigger: $TRIGGER, up to $MAX_ROUNDS rounds"

# Count modesets before and after, so a run that provokes nothing can still be
# told apart from a run that never reached the driver at all.
MODESETS_BEFORE=$(grep -c "preparing to set mode" /var/log/Xorg.0.log 2>/dev/null || echo 0)
(
	for i in $(seq 1 "$MAX_ROUNDS"); do
		[ -f "$OUT/.verdict" ] && break
		echo "[$(date +%H:%M:%S)] round $i, cpu $(cpu_temp)"

		# Two ways into the same modeset path, with very different
		# thermal costs.
		#
		# The DPMS toggle is three modesets for almost no CPU, so it
		# runs however warm the case already is. x11perf adds concurrent
		# drawing, which is how both recorded hangs happened and may well
		# be half the race, but twenty seconds of it moves the case
		# sixteen degrees, so it only runs when there is headroom.
		case "$TRIGGER" in
		dpms|mixed)
			for _ in 1 2 3 4 5 6 7 8 9 10; do
				[ -f "$OUT/.verdict" ] && break
				timeout 10 xset dpms force off
				sleep 1
				timeout 10 xset dpms force on
				sleep 1
			done
			;;
		esac

		[ -f "$OUT/.verdict" ] && break

		case "$TRIGGER" in
		x11perf|mixed)
			if [ "$(cpu_temp)" -lt "$COOL_TARGET" ]; then
				echo "  x11perf burst at $(cpu_temp)"
				# A wrong test name makes x11perf print usage
				# and exit, which looks just like a fast clean
				# round. These two are confirmed to exist.
				timeout 120 x11perf -display :0 -time 1 \
					-srect10 -copywinwin10 2>&1 | tail -2
			else
				echo "  too warm for x11perf at $(cpu_temp)"
			fi
			;;
		esac
	done
	echo "[$(date +%H:%M:%S)] trigger loop finished"
) >> "$OUT/run.log" 2>&1

# The trigger may have returned because the wedge killed it, or because it ran
# out of rounds. Give the watchdog a moment either way.
sleep 3
[ -f "$OUT/.verdict" ] || touch "$OUT/.stop"
wait $WD
VERDICT=$(cat "$OUT/.verdict" 2>/dev/null || echo none)

case "$VERDICT" in
	wedge)
		capture "Xorg spinning, DISPC stopped"
		if [ "$REBOOT" = yes ]; then
			say "rebooting in 10s to recover and to keep the case cool"
			sleep 10
			systemctl reboot
		else
			say "--no-reboot given: the machine is still wedged, reboot it yourself"
		fi
		;;
	hot)
		say "ABORTED: cpu_thermal passed ${TEMP_ABORT} without a detected wedge"
		echo "$SYSRQ_WAS" > /proc/sys/kernel/sysrq
		;;
	*)
		MODESETS_AFTER=$(grep -c "preparing to set mode" /var/log/Xorg.0.log 2>/dev/null || echo 0)
		DELTA=$((MODESETS_AFTER - MODESETS_BEFORE))
		say "no wedge after $MAX_ROUNDS rounds, $DELTA modesets provoked"
		[ "$DELTA" -eq 0 ] && say "WARNING: zero modesets — the trigger never reached the driver"
		{ echo "=== interrupts after"; cat /proc/interrupts
		  echo "=== modesets before/after"; echo "$MODESETS_BEFORE $MODESETS_AFTER"
		} >> "$OUT/40-no-wedge.txt" 2>&1
		echo "$SYSRQ_WAS" > /proc/sys/kernel/sysrq
		say "sysrq restored to $SYSRQ_WAS"
		;;
esac

chown -R "${SUDO_USER:-root}" "$OUT" 2>/dev/null
say "done: $OUT"
