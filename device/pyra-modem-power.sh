#!/bin/bash
#
# pyra-modem-power.sh — read the INA231 on the modem rail, or say why it
# cannot be read.
#
#   ./pyra-modem-power.sh             read it, or diagnose the failure
#   ./pyra-modem-power.sh 60          sample for 60 seconds, min/mean/max
#   ./pyra-modem-power.sh --explain   what the numbers mean and their limits
#
# Read-only. Changes nothing and needs no privileges, except that the failure
# diagnosis reads the kernel log, which on this machine wants sudo.
#
# ON THE UNIT THIS WAS WRITTEN AGAINST, IT CANNOT BE READ. That is the finding,
# not a bug in the script; see "what was actually found" below. The script is
# kept because the sensor becomes readable the moment a modem is fitted and
# powers up, and because the diagnosis is the useful part either way.
#
# WHAT THIS SENSOR IS, AND WHAT IT IS NOT
#
# The board carries one INA231, and the device tree says what it is for:
#
#     /* modem current sensor */
#     ina231@4f {
#             compatible = "ti,ina231";
#             shunt-resistor = <20000>;       /* 20 mOhm */
#     };
#
# It measures the Gemalto PLS8 modem rail and nothing else. It is NOT a system
# power meter and cannot see the SoC, the display or the radios. For
# whole-machine power this repo uses the fuel gauge,
# `/sys/class/power_supply/bq27421-0/current_now`, which is what
# `pyra-idle-profile.sh` and eight other scripts already read. Do not reach for
# this one to answer a question about the SoC.
#
# WHAT WAS ACTUALLY FOUND, 2026-09-20, on 5.6.19-m4
#
# The driver is present and correct and the device instantiates, but probe
# fails:
#
#     ina2xx 1-004f: error configuring the device: -121
#
# -121 is -EREMOTEIO: the chip does not acknowledge on the bus. It is not a
# driver problem. Every other device on the same bus binds --- tca8418,
# two as5013, bq27421, bq24297 --- so i2c-1 itself is healthy and only 0x4f is
# silent. The reason is upstream of I2C entirely:
#
#     wwan_on_off_set_power: failed to change modem state   (twice, at boot)
#     gpio-491 (en-modem | modem_power_reg) out lo
#     modem_vbus_power: disabled
#
# and `lsusb` shows only the hub and the ethernet adapter, with no tty or
# cdc-wdm nodes. No modem is fitted, or the one fitted does not answer. The
# INA231 is powered from the rail it measures, so with that rail down the chip
# is simply not there. Fit a modem and this starts working with no software
# change.
#
# Note the bus number: the device tree label is `&i2c2`, but OMAP numbers from
# zero, so it appears as `i2c-1` and the device is `1-004f`. This script finds
# it by compatible string rather than assuming either.
#
set -euo pipefail

explain() {
	cat <<'EOF'
The INA231 measures a shunt on the modem supply and reports four things.

  in0_input     shunt voltage, mV      2.5 uV per count
  in1_input     bus voltage, mV        1.25 mV per count, full scale 36 V
  curr1_input   current, mA            125 uA per count, range +/- 4.096 A
  power1_input  power, uW              3.125 mW per count

Those follow from the 20 mOhm shunt and the driver's fixed calibration: it
holds the calibration register at 2048 and derives the current LSB as
(1e9 / 400) / 20000 = 125 uA, then the power LSB as 25 x that. So current is
fine-grained enough to see an idle modem, but POWER quantises at 3.125 mW and
should not be trusted for small differences. This script computes power as
current x bus voltage instead, and says so.

The driver configures 16-sample averaging and sysfs caches for about a
fifteenth of a second, so this samples at roughly 15 Hz at best. It is an
average-power instrument, not a way to catch transmit bursts.
EOF
}

case ${1:-} in
--explain) explain; exit 0 ;;
-h|--help) sed -n '3,16p' "$0" | sed 's/^# \?//'; exit 0 ;;
esac

WINDOW=${1:-0}
case $WINDOW in ''|*[!0-9]*) echo "usage: $0 [seconds] | --explain" >&2; exit 2 ;; esac

# ------------------------------------------------- find the device, any bus
DEV=
for d in /sys/bus/i2c/devices/*-004f /sys/bus/i2c/devices/*; do
	[ -e "$d/of_node/compatible" ] || continue
	if tr '\0' '\n' < "$d/of_node/compatible" 2>/dev/null | grep -qx 'ti,ina231'; then
		DEV=$d; break
	fi
done

if [ -z "$DEV" ]; then
	echo "No ti,ina231 device exists on any i2c bus."
	echo "The device tree node did not instantiate. Check the running dtb:"
	echo "    dtc -I dtb -O dts /boot/dtb/\$(uname -r)/*.dtb 2>/dev/null | grep -A4 ina231"
	exit 1
fi

# ------------------------------------------------- is it bound and readable?
HWMON=
if [ -e "$DEV/driver" ]; then
	for h in "$DEV"/hwmon/hwmon*; do
		[ -r "$h/name" ] && HWMON=$h && break
	done
fi

if [ -z "$HWMON" ]; then
	echo "The INA231 exists at $(basename "$DEV") but is not readable."
	echo
	if [ ! -e "$DEV/driver" ]; then
		echo "  No driver is bound to it."
		if ! lsmod 2>/dev/null | grep -q '^ina2xx'; then
			echo "  The ina2xx module is not loaded either. Try: sudo modprobe ina2xx"
			echo "  If it then binds, this was only a missing autoload."
			exit 1
		fi
		echo "  The ina2xx module IS loaded, so probe ran and failed. The reason:"
		echo
		err=$( (sudo dmesg 2>/dev/null || dmesg 2>/dev/null) | grep -E 'ina2xx .*:' | tail -3 )
		if [ -n "$err" ]; then
			echo "$err" | sed 's/^/      /'
			echo
			if echo "$err" | grep -q -- '-121'; then
				echo "  -121 is -EREMOTEIO: the chip does not acknowledge on the bus."
				echo "  That is almost always an unpowered chip rather than a broken"
				echo "  driver, and this sensor is powered from the rail it measures."
			fi
		else
			echo "      (no ina2xx line in the kernel log; it may have rolled over)"
			echo
		fi
	else
		echo "  A driver is bound but registered no hwmon node, which is unexpected."
	fi

	# The rail is the usual answer, so report it whether or not dmesg survived.
	echo "  State of the modem rail, which is what powers it:"
	for r in /sys/class/rfkill/rfkill*; do
		[ -r "$r/type" ] || continue
		[ "$(cat "$r/type")" = wwan ] && \
			echo "      rfkill $(cat "$r/name"): soft=$(cat "$r/soft") hard=$(cat "$r/hard")  (1 = blocked)"
	done
	for n in /sys/class/regulator/*/name; do
		case $(cat "$n" 2>/dev/null) in
		*modem*) echo "      regulator $(cat "$n"): $(cat "$(dirname "$n")/state" 2>/dev/null)" ;;
		esac
	done
	if command -v lsusb >/dev/null 2>&1; then
		echo "      usb devices: $(lsusb | wc -l) (a fitted modem adds one, plus a tty or cdc-wdm)"
	fi
	echo
	echo "  If the modem regulator is disabled and no modem shows on USB, there is"
	echo "  no modem fitted and nothing to measure. That is not a fault."
	exit 1
fi

# ------------------------------------------------- read it
echo "== the sensor"
echo "  device: $(basename "$DEV")   hwmon: $HWMON ($(cat "$HWMON/name"))"
if [ -r "$HWMON/shunt_resistor" ]; then
	sr=$(cat "$HWMON/shunt_resistor")
	if [ "$sr" = 20000 ]; then
		echo "  shunt:  ${sr} uOhm (matches the device tree)"
	else
		echo "  shunt:  ${sr} uOhm -- NOT the 20000 the device tree asks for;"
		echo "          every reading below is scaled wrong by $((20000 * 100 / sr))%"
	fi
fi
[ -r "$HWMON/update_interval" ] && echo "  averaging window: $(cat "$HWMON/update_interval") ms"

echo
echo "== the modem"
for r in /sys/class/rfkill/rfkill*; do
	[ -r "$r/type" ] || continue
	[ "$(cat "$r/type")" = wwan ] && \
		echo "  $(cat "$r/name"): soft=$(cat "$r/soft") hard=$(cat "$r/hard")  (1 = blocked/off)"
done

rd() { cat "$HWMON/$1" 2>/dev/null || echo ""; }
sample() {   # -> "mA mV mW", or empty on a failed read
	local cur bus
	cur=$(rd curr1_input); bus=$(rd in1_input)
	[ -n "$cur" ] && [ -n "$bus" ] || { echo ""; return; }
	echo "$cur $bus $(( cur * bus / 1000 ))"
}

echo
if [ "$WINDOW" = 0 ]; then
	echo "== one reading"
	s=$(sample)
	[ -n "$s" ] || { echo "  reads failed; the chip stopped answering"; exit 1; }
	set -- $s
	printf '  bus voltage:  %d.%03d V\n' $(( $2 / 1000 )) $(( $2 % 1000 ))
	printf '  current:      %s mA\n' "$1"
	printf '  power:        %s mW   (current x voltage, not power1_input)\n' "$3"
	echo
	echo "Run '$0 60' to average over a minute, or --explain for the limits."
else
	echo "== sampling for ${WINDOW}s"
	n=0; sum=0; min=; max=
	end=$(( $(date +%s) + WINDOW ))
	while [ "$(date +%s)" -lt "$end" ]; do
		s=$(sample)
		if [ -n "$s" ]; then
			set -- $s
			n=$(( n + 1 )); sum=$(( sum + $3 ))
			if [ -z "$min" ] || [ "$3" -lt "$min" ]; then min=$3; fi
			if [ -z "$max" ] || [ "$3" -gt "$max" ]; then max=$3; fi
		fi
		sleep 0.2
	done
	[ "$n" != 0 ] || { echo "  no successful reads"; exit 1; }
	printf '  %d samples:  min %s mW   mean %s mW   max %s mW\n' \
		"$n" "$min" "$(( sum / n ))" "$max"
fi

cat <<'EOF'

== what to do with it

The question worth answering is what the modem costs when nobody is using it:

    ./pyra-modem-power.sh 30
    sudo sh -c 'echo 1 > /sys/class/rfkill/rfkill0/soft'   # block it
    ./pyra-modem-power.sh 30

A blocked modem that still draws current is a battery finding, and the
`gemalto,pls8-power` node is where it would be fixed.
EOF
