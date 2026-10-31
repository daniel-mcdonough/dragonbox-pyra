#!/bin/sh
#
# pyra-kbdlight.sh — the Fn keyboard-brightness keys, on either kernel.
#
#   pyra-kbdlight.sh up|down          one step brighter or dimmer
#   pyra-kbdlight.sh --configure CFG  point the Fn keys at this script in CFG
#   pyra-kbdlight.sh --reload PID     make pyrainput (funkeymonkey, PID) apply CFG
#
# funkeymonkey (libpyrainput) runs a shell command for each brightness key
# combination, as root. Its built-in commands for Fn+brightness and
# Fn+Shift+brightness are the vendor's /usr/share/pyra/scripts/pyra-brightkey.sh
# (package pyra-scripts), which only knows /sys/class/backlight/keyboard-backlight.
# A kernel that declares the keyboard light as an LED (5.6.19-m4-kbdled,
# patches: experiments/kbd-led/0035) has no such directory, so the keys do
# nothing there.
#
# This script drives /sys/class/leds/*::kbd_backlight when it exists, in the same
# nine steps the stock kernel's brightness-levels table has (0 1 2 5 10 20 40 60
# 100 percent of full duty; the LED is linear, 0 to max_brightness). Without the
# LED it hands the key to the vendor script unchanged, so the stock kernel keeps
# the stock behaviour and any upstream change to it.
#
# The keys reach it through /etc/pyrainput.cfg, which no package ships, rather
# than by replacing or diverting the vendor file: a pyra-scripts upgrade leaves
# it alone, and nothing hides a newer vendor script. --configure writes the two
# lines (pc/pyra-trixie-prep.sh and pyra-install-helpers.sh both call it). It
# leaves a line the user wrote for either key alone. funkeymonkey reads the file
# at start and on `systemctl reload pyrainput`, but 0.1.19 overwrites the four
# brightness commands with its built-in ones after the read at start
# (pyrainput.cpp:158-161), so only the reload applies these lines. The drop-in
# pyrainput.service.d/pyra-kbdlight.conf runs --reload from ExecStartPost, so
# every start ends with a reload (fixes.md, fix 15).
#
set -u

# PYRA_KBDLIGHT_LEDS is for testing on a copy of the LED directory.
LEDS=${PYRA_KBDLIGHT_LEDS:-/sys/class/leds}
SELF=/usr/local/sbin/pyra-kbdlight.sh
VENDOR=/usr/share/pyra/scripts/pyra-brightkey.sh
PERCENT="0 1 2 5 10 20 40 60 100"

configure() {
	cfg=$1
	[ -e "$cfg" ] || : > "$cfg" || return 1
	# A last line without its newline would run into the first line added.
	[ -n "$(tail -c 1 "$cfg")" ] && echo >> "$cfg"
	for pair in "fn up" "fnshift down"; do
		key=${pair% *}
		dir=${pair#* }
		want="scripts.brightness.$key = $SELF $dir"
		# Keys are case-insensitive to libpyrainput; values run to end of line.
		have=$(grep -i "^scripts\.brightness\.$key[[:space:]]*=" "$cfg" | tail -n 1)
		if [ "$have" = "$want" ]; then
			echo "pyra-kbdlight: $key already set"
		elif [ -n "$have" ]; then
			echo "pyra-kbdlight: $key left alone, the file sets it: $have" >&2
		else
			printf '%s\n' "$want" >> "$cfg" || return 1
			echo "pyra-kbdlight: $key set"
		fi
	done
}

# funkeymonkey 0.1.2 installs its SIGUSR1 handler only once it has opened and
# grabbed the devices and loaded the plugin (main.cpp, process()), and a USR1
# before that kills it. ExecStartPost runs as soon as the process exists, so
# wait for /proc/PID/status to show USR1 caught. A USR1 that lands during the
# plugin's init() is kept and served after it. The second one covers a USR1 that
# lands between the loop's flag check and its select(), which has no timeout:
# that one would wait for the next input event, which would still get the old
# commands; the second interrupts the select(). Always exits 0, so a miss never
# fails the unit; it only logs.
reload() {
	pid=$1 n=0
	while :; do
		cgt=$(sed -n 's/^SigCgt:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null)
		if [ -z "$cgt" ]; then
			echo "pyra-kbdlight: pyrainput (pid $pid) is gone, not reloaded" >&2
			return 0
		fi
		# SIGUSR1 is signal 10, bit 9 of the mask; the last four digits hold it.
		[ $(( 0x${cgt#"${cgt%????}"} & 0x200 )) -ne 0 ] && break
		n=$((n + 1))
		if [ "$n" -ge 100 ]; then
			echo "pyra-kbdlight: pyrainput (pid $pid) has no SIGUSR1 handler after 10 s, not reloaded" >&2
			return 0
		fi
		sleep 0.1
	done
	kill -USR1 "$pid" && sleep 1 && kill -USR1 "$pid" &&
		echo "pyra-kbdlight: pyrainput reloaded, Fn keys from the config (handler up after ${n}00 ms)"
	return 0
}

step() {
	led=
	for d in "$LEDS"/*::kbd_backlight; do
		[ -d "$d" ] && { led=$d; break; }
	done
	if [ -z "$led" ]; then
		[ -x "$VENDOR" ] || exit 1
		exec "$VENDOR" keyboard "$1"
	fi

	max=$(cat "$led/max_brightness") || exit 1
	cur=$(cat "$led/brightness") || exit 1
	# The raw value of each step, and the step nearest the current value
	# (something else, such as the applet or UPower, may have set a value
	# between two steps).
	steps= n=0 at=0 best=
	for p in $PERCENT; do
		v=$(( (p * max + 50) / 100 ))
		steps="$steps $v"
		d=$(( v > cur ? v - cur : cur - v ))
		if [ -z "$best" ] || [ "$d" -lt "$best" ]; then best=$d at=$n; fi
		n=$((n + 1))
	done
	case $1 in
	up)   at=$((at + 1)) ;;
	down) at=$((at - 1)) ;;
	esac
	[ "$at" -lt 0 ] && at=0
	[ "$at" -gt $((n - 1)) ] && at=$((n - 1))
	set -- $steps
	shift "$at"
	echo "$1" > "$led/brightness"
}

case "${1:-}" in
up|down)     step "$1" ;;
--configure) [ -n "${2:-}" ] || { echo "usage: $0 --configure /etc/pyrainput.cfg" >&2; exit 2; }
             configure "$2" ;;
--reload)    case ${2:-} in ''|*[!0-9]*) echo "usage: $0 --reload PID" >&2; exit 2 ;; esac
             reload "$2" ;;
*)           echo "usage: $0 up|down | --configure CFG | --reload PID" >&2; exit 2 ;;
esac
