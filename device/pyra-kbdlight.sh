#!/bin/sh
#
# pyra-kbdlight.sh — the Fn keyboard-brightness keys, on either kernel.
#
#   pyra-kbdlight.sh up|down          one step brighter or dimmer
#   pyra-kbdlight.sh --configure CFG  point the Fn keys at this script in CFG
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
# (pyrainput.cpp:158-161), so only the reload applies these lines (fixes.md, fix 15).
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
*)           echo "usage: $0 up|down | --configure CFG" >&2; exit 2 ;;
esac
