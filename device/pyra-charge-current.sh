#!/bin/bash
#
# pyra-charge-current.sh — let the machine charge while it is running.
#
#   sudo ./pyra-charge-current.sh --check   say what the state is, change nothing
#   sudo ./pyra-charge-current.sh           apply it and verify
#   sudo ./pyra-charge-current.sh --undo    put 500 mA and the stock rules back
#
#        ./pyra-charge-current.sh --emit-into ROOT
#
# writes the three files below under ROOT instead of under /, touches nothing
# else, and does not care whether it is running on a Pyra. That mode is the
# door `pc/pyra-trixie-prep.sh` goes through to put this on a card offline, as
# fix 8, so a freshly prepared card charges from its first boot. There is one
# implementation of the three files and every mode calls it.
#
# WHAT IS WRONG
#
# A Pyra plugged into a charger goes flat. Measured on this machine, idle, at
# the stock setting:
#
#     input_current_limit   500000        (500 mA, the USB floor)
#     battery current_now  -617000        (617 mA OUT of the battery)
#     battery status        Discharging   while online=1 and PG_STAT is good
#
# The machine's own idle draw is about 620 mA. The charger was admitting 500.
# The battery made up the difference, so it drained with the cable in. One
# write to the charger's input limit is the whole fix:
#
#     input_current_limit  2000000
#     battery current_now  +476000 mean over 899 s, capacity 21% -> 23%
#     REG08                0x2c on all 815 samples: fast charging, PG good
#
# Same supply, same cable, one register.
#
# WHY IT IS 500 mA
#
# Nothing on this machine ever sets it. Three things were supposed to and none
# of them do:
#
# 1. `/lib/udev/rules.d/charging.rules` links `/dev/usb_max_current` to the
#    charger's `input_current_limit`, and the rules that work name **twl4030**
#    — the OMAP3/GTA04 charger. This is an OMAP5 with a bq24297. The Pyra
#    rules sit right below them under the vendor's own comment:
#
#        # 3. this is preparation for the Pyra but neither tested nor
#        #    complete nor working
#
#    They also link `/sys%p/id`, and the bq24297 exposes no `id` attribute.
#
# 2. Because that link was never made, `/dev/usb_max_current` is not a symlink
#    at all. It is an ordinary file:
#
#        -rw-r--r-- 1 root root 7 /dev/usb_max_current    <- regular file 0:0
#
#    The thermal daemon writes its charge-current decision there every poll.
#    Nothing reads it. That half of the daemon has never done anything.
#
# 3. The driver parses limits out of the device tree at probe and does not
#    apply them:
#
#        bq2429x_parse_dt: chg_current = 2048000 usb_input_current = 3000000
#                          adp_input_current = 2048000 bat_volt_max = 4200000
#
# So the limit stays wherever the chip powers up, which is the 500 mA USB
# floor, forever.
#
# WHAT THIS SCRIPT ASSUMES, AND YOU SHOULD READ THIS
#
# It asserts a number. It does not detect anything, because nothing on this
# machine can: proper BC1.2 detection means driving FORCE_DPDM in the
# bq24297's REG07, and that belongs in the driver, not in a shell script. So
# this says "the supply you plug in can deliver PYRA_INPUT_CURRENT_UA", and if
# that is false the charger will try anyway.
#
# The hardware backstop is real but it is not free. VINDPM is set to 4.36 V:
# when VBUS sags to there the chip stops taking more current, which is why a
# weak supply browns out rather than catches fire. 4.36 V is below the 4.75 V
# a USB port is entitled to, so pointing this at a genuine 500 mA port will
# pull that port out of spec. Do not raise the default and then plug into a
# keyboard hub.
#
# The pack's own thermal protection is the charger's TS pin and is unaffected
# by any of this. It is a hardware comparator on the battery thermistor and it
# gates charging regardless of what the input limit says.
#
# WHY THIS DOES NOT WIRE UP THE THERMAL DAEMON'S CHARGE LADDER
#
# It would be easy to point the daemon at the real knob and let its ladder
# work. That would make this machine worse. The ladder reads `bq27421-0` — the
# fuel gauge's die, not the cell, see pyra-thermal-ladder.sh — and it drops to
# 500 mA above 44 C. This machine idles with that sensor at 46-47 C. Wiring
# the two together would re-impose the exact cap this script exists to lift,
# permanently, and the battery would drain while plugged in again.
#
# The ladder has to be recalibrated onto a sensor that means something before
# it is allowed to touch the charger. Until then the correct state is the one
# here: the daemon's charge half stays disconnected, and the pack is protected
# by the TS pin that was always doing that job anyway.
#
# WHAT IT INSTALLS
#
#   /etc/default/pyra-charge-current        the number, so you can change it
#   /usr/local/sbin/pyra-charge-current-apply   one idempotent sysfs write
#   /etc/udev/rules.d/60-pyra-charge-current.rules   re-apply on plug events
#
# The limit is a register. It does not survive an unplug or a reboot, which is
# what the udev rule is for.

set -u

CONF=/etc/default/pyra-charge-current
HELPER=/usr/local/sbin/pyra-charge-current-apply
RULE=/etc/udev/rules.d/60-pyra-charge-current.rules
MARKER='pyra-charge-current'
SELFPATH=/usr/local/sbin/pyra-charge-current.sh

# The chip's own ceiling, and the larger of the two numbers the device tree
# already states for this board. Refuse anything above it.
MAX_UA=3000000
DEFAULT_UA=${PYRA_INPUT_CURRENT_UA:-2000000}

# The floor the chip powers up at, and what --undo puts back.
STOCK_UA=500000

say()  { printf '\n== %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die()  { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

# Find the limit by driver rather than by i2c address, so a bus renumber does
# not silently turn this into a no-op.
find_knob() {
	local p
	for p in /sys/bus/i2c/drivers/bq2429x_charger/*/max_current; do
		[ -w "$p" ] && { printf '%s\n' "$p"; return 0; }
	done
	return 1
}

find_supply() {
	local s
	for s in /sys/class/power_supply/bq24297; do
		[ -d "$s" ] && { printf '%s\n' "$s"; return 0; }
	done
	return 1
}

BATT=/sys/class/power_supply/bq27421-0

state() {
	local knob supply
	knob=$(find_knob) || { note "no bq2429x_charger max_current: not a Pyra, or the driver did not bind"; return 1; }
	supply=$(find_supply) || true
	note "limit now       : $(cat "$knob") uA   ($knob)"
	if [ -n "${supply:-}" ]; then
		note "charger online  : $(cat "$supply/online" 2>/dev/null)"
		note "charger status  : $(cat "$supply/status" 2>/dev/null)"
	fi
	if [ -r "$BATT/current_now" ]; then
		local ua
		ua=$(cat "$BATT/current_now")
		note "battery current : $ua uA   $( [ "$ua" -gt 0 ] && echo "(into the battery)" || echo "(OUT of the battery)" )"
		note "battery         : $(cat "$BATT/capacity" 2>/dev/null)%  $(cat "$BATT/status" 2>/dev/null)"
	fi
	note "config          : $( [ -r "$CONF" ] && grep -h '^PYRA_INPUT_CURRENT_UA' "$CONF" || echo "not installed" )"
	note "helper          : $( [ -x "$HELPER" ] && echo present || echo "not installed" )"
	note "udev rule       : $( [ -r "$RULE" ] && echo present || echo "not installed" )"
	return 0
}

# ------------------------------------------------------------------ the files
# One implementation of the three files. `--emit-into` writes them under a
# card, the apply path writes them under /. Nothing else knows their content.
emit_into() {
	# $1 is the root to write under: "" for the live system, a mount point
	# for a card. The paths *inside* the files stay absolute either way,
	# because they are what the target will run, not where we put them.
	local root=$1 ua=$2

	install -d -m 0755 "$root/etc/default" "$root/usr/local/sbin" "$root/etc/udev/rules.d"

	cat > "$root$CONF" <<EOF
# $MARKER
#
# How much current the charger is allowed to draw from the supply, in
# microamps. Nothing on this machine detects what the supply can give, so this
# is an assertion, not a measurement. See the header of
# $SELFPATH before raising it.
#
#   500000   the USB floor the chip powers up at. The machine's idle draw is
#            about 620 mA, so at this value it discharges while plugged in.
#  2000000   what the device tree calls adp_input_current for this board.
#  3000000   what it calls usb_input_current, and the chip's ceiling.
#
# On a long or thin cable you will not get the whole of this anyway: VBUS sags,
# VINDPM regulates at 4.36 V and the chip takes what the cable allows.

PYRA_INPUT_CURRENT_UA=$ua
EOF

	cat > "$root$HELPER" <<EOF
#!/bin/sh
# $MARKER — set the bq24297 input current limit.
#
# Run from a udev rule on charger plug events, and by hand. One idempotent
# sysfs write: the limit is a register and does not survive an unplug.
#
# Installed by pyra-charge-current.sh. See that script's header for why this
# is needed and what it assumes about the supply.

UA=$ua
[ -r $CONF ] && . $CONF
UA=\${PYRA_INPUT_CURRENT_UA:-$ua}

for knob in /sys/bus/i2c/drivers/bq2429x_charger/*/max_current; do
	[ -w "\$knob" ] || continue
	now=\$(cat "\$knob" 2>/dev/null) || continue
	[ "\$now" = "\$UA" ] && exit 0
	printf '%s\\n' "\$UA" > "\$knob" 2>/dev/null
done
exit 0
EOF
	chmod 0755 "$root$HELPER"

	cat > "$root$RULE" <<EOF
# $MARKER
#
# The charger's input current limit is a register. It resets to the 500 mA USB
# floor on every plug event and every boot, and 500 mA is less than this
# machine draws at idle, so without this the battery drains on the charger.
#
# The stock /lib/udev/rules.d/charging.rules cannot do this: the rules that
# work there name twl4030, which is GTA04 hardware, and the bq24297 rules
# beside them carry the vendor's own "neither tested nor complete nor
# working". This rule replaces that intent for the charger this board has.

ACTION=="add|change", SUBSYSTEM=="power_supply", KERNEL=="bq24297", RUN+="$HELPER"
EOF
}

# --------------------------------------------------------------------- check
if [ "${1:-}" = --check ]; then
	say "charge input current"
	state || exit 1
	echo
	if [ -x "$HELPER" ] && [ -r "$RULE" ] && [ -r "$CONF" ]; then
		echo "applied."
	else
		echo "NOT applied. Run this without --check to apply it."
	fi
	exit 0
fi

# ----------------------------------------------------------------- emit-into
# Needs no root if ROOT is writable, and needs no Pyra. This is how the card
# prep applies the same three files offline.
if [ "${1:-}" = --emit-into ]; then
	root=${2:-}
	[ -n "$root" ] || die "--emit-into needs a root to write under"
	[ -d "$root" ] || die "not a directory: $root"
	UA=$DEFAULT_UA
	emit_into "$root" "$UA"
	printf '%s\n%s\n%s\n' "$root$CONF" "$root$HELPER" "$root$RULE"
	exit 0
fi

[ "$(id -u)" = 0 ] || die "run this with sudo"

# ---------------------------------------------------------------------- undo
if [ "${1:-}" = --undo ]; then
	say "removing"
	for f in "$RULE" "$HELPER" "$CONF"; do
		if [ -e "$f" ]; then
			if grep -q "$MARKER" "$f" 2>/dev/null; then
				rm -f "$f"; note "removed $f"
			else
				note "left alone (not ours): $f"
			fi
		fi
	done
	udevadm control --reload 2>/dev/null && note "udev rules reloaded"
	if knob=$(find_knob); then
		printf '%s\n' "$STOCK_UA" > "$knob"
		note "limit put back to $(cat "$knob") uA"
	fi
	say "state now"
	state || true
	echo
	echo "Back to stock. The machine will discharge on a charger again;"
	echo "that is what stock does."
	exit 0
fi

[ "${1:-}" = "" ] || die "unknown argument: $1 (try --check, --undo, or no argument)"

# --------------------------------------------------------------------- apply
say "before"
state || die "nothing to configure"

UA=$DEFAULT_UA
case $UA in
	''|*[!0-9]*) die "PYRA_INPUT_CURRENT_UA must be a number of microamps, got: $UA" ;;
esac
[ "$UA" -le "$MAX_UA" ] || die "PYRA_INPUT_CURRENT_UA=$UA is above the chip's $MAX_UA uA ceiling"
[ "$UA" -ge "$STOCK_UA" ] || die "PYRA_INPUT_CURRENT_UA=$UA is below the $STOCK_UA uA floor; that is not a fix"


say "installing"
emit_into "" "$UA"
note "wrote $CONF"
note "wrote $HELPER"
chown 0:0 "$HELPER"
note "wrote $RULE"

udevadm control --reload || die "could not reload udev rules"
note "udev rules reloaded"

"$HELPER"
note "applied now"

# -------------------------------------------------------------------- verify
say "verifying"
knob=$(find_knob) || die "the max_current knob went away"
got=$(cat "$knob")
[ "$got" = "$UA" ] || die "wrote $UA but the chip reports $got"
note "limit is $got uA"

say "after"
state || true

echo
if [ -r "$BATT/current_now" ] && [ "$(cat /sys/class/power_supply/bq24297/online 2>/dev/null)" = 1 ]; then
	sleep 5
	ua=$(cat "$BATT/current_now")
	if [ "$ua" -gt 0 ]; then
		echo "Charging: ${ua} uA into the battery."
	else
		echo "Still ${ua} uA out of the battery five seconds later."
		echo "That is not necessarily wrong — a long cable, a weak supply, a hot"
		echo "pack the TS pin is holding off, or simply more load than the supply"
		echo "can carry. Watch it with pyra-chgwatch.sh before concluding."
	fi
else
	echo "No charger attached, so there is nothing to observe yet."
	echo "The limit is set and the udev rule will set it again on plug."
fi
