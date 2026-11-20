#!/bin/bash
#
# pyra-chgwatch.sh — watch the charge path, once a second, and change nothing.
#
#   ./pyra-chgwatch.sh [FILE] [SECONDS]
#   ./pyra-chgwatch.sh --ts [FILE] [SECONDS] [INTERVAL]
#
# Defaults to ~/pyra-chgwatch-<stamp>.tsv for 600 seconds. Needs no root: every
# column is a world-readable sysfs file.
#
# --ts logs the pack thermistor's margin to the charger's hot cut-off instead,
# every INTERVAL seconds (default 10), for SECONDS (default 14400, four hours);
# the default file is ~/pyra-ts-margin-<stamp>.tsv. See "--ts columns" below.
# It does not read the charger's `registers` file. Run it with sudo to get the
# kernel-log fault column; without root that column reads NA.
#
# This observes whatever input current limit is already set. It does not set
# one — that is pyra-charge-current.sh. Use this to answer "is it actually
# charging, and how fast", which the battery's own `status` alone will not tell
# you: this machine has been seen reporting the charger as "Not charging" while
# the gauge reported "Charging" with half an amp going in.
#
# The columns that matter, and how to read them:
#
#   bat_ua      positive is into the battery, negative is out of it. Negative
#               with a charger attached means the input limit is below the
#               machine's own draw, which at idle is about 620 mA.
#   reg00       bits 2-0 are IINLIM. 010 is 500 mA, 110 is 2 A.
#   reg08       bits 5-4 are the charge state: 00 not charging, 01 pre-charge,
#               10 fast charging, 11 done. Bit 3 is DPM_STAT — set means the
#               chip is regulating the input, either against IINLIM or against
#               VINDPM at 4.36 V. Set while drawing well under IINLIM means
#               VBUS is sagging, which is the cable.
#   reg09       faults. This register is read-to-clear, so a non-zero value in
#               one sample is a latch that may already be stale. Do not
#               conclude anything from a single read of it. The driver's
#               `registers` file reads it straight off the chip without
#               telling the driver, so this mode also clears latches the
#               driver has not seen yet; a fault it takes never reaches the
#               kernel log. --ts does not read `registers` for that reason.
#               A kernel with patches/0054 (not the shipped r3) prints the
#               driver's own copy for reg 09 instead, which is safe to read.
#   gauge_mC    bq27421-0, which is the fuel gauge's own die on the mainboard,
#               not the cell. It is not a battery temperature. See
#               pyra-thermal-ladder.sh.
#
# --ts columns (experiments/charging/README.md, "The trip points, in IN0
# terms"). All levels are mV at Palmas GPADC channel 0, the thermistor tap;
# lower IN0 is a warmer pack.
#
#   in0_mV      the tap. Only biased with a charger in.
#   in10_mV     VBUS. REGN, which the TS comparator scales from, is taken to
#               be VBUS - 20 mV.
#   vtco_mV     the hot cut-off while charging, 44.7 % of REGN, worked back
#               to IN0: 0.2481 x 0.447 x REGN + 124 mV.
#   vhtf_mV     the level IN0 must climb back over before charging resumes,
#               47.2 % of REGN.
#   margin_mV   in0 - vtco. Charging suspends when it reaches 0. NA without
#               a charger (VBUS under 4 V), when the levels mean nothing.
#   gauge_dC    bq27421-0 temperature, 0.1 °C, the gauge's die, not the cell.
#   bat_ua      as above.
#   chg_temp    the driver's last-read REG09 as a temperature: 225 no fault,
#               600 HOT, -100 COLD. The driver's own copy; reading it touches
#               no register.
#   klog_r9     the driver's kernel-log status lines (`r8=.. r9=..`, logged
#               when either register changes) that appeared since the last
#               sample, joined with '; ', or '-'. A HOT here is the trip
#               happening. The driver reads REG09 only on the charger's
#               interrupt, so a line marks an event, not a poll.
ts() {
	local out=${1:-$HOME/pyra-ts-margin-$(date +%Y%m%d-%H%M%S).tsv}
	local dur=${2:-14400} step=${3:-10} adc="" d t0 n0 in0 in10 lv new k
	for d in /sys/bus/iio/devices/iio:device*; do
		[ "$(r "$d/name")" = palmas-gpadc ] && adc=$d
	done
	[ -n "$adc" ] || { echo "no palmas-gpadc IIO device" >&2; exit 1; }
	# Count the r9 lines already in the kernel log, to report only new ones.
	# dmesg needs root on Debian; without it the column is NA.
	n0=NA
	dmesg >/dev/null 2>&1 && n0=$(dmesg | grep -c 'r8=.* r9=')
	printf "time\tt\tin0_mV\tin10_mV\tvtco_mV\tvhtf_mV\tmargin_mV\tgauge_dC\tbat_ua\tcap\tchg_status\tchg_temp\tklog_r9\n" > "$out"
	t0=$(date +%s)
	while [ $(( $(date +%s) - t0 )) -lt "$dur" ]; do
		in0=$(r "$adc/in_voltage0_input")
		in10=$(r "$adc/in_voltage10_input")
		lv=$(awk -v a="$in0" -v v="$in10" 'BEGIN {
			if (v !~ /^[0-9]+$/ || v < 4000) { print "NA\tNA\tNA"; exit }
			c = 0.2481 * 0.447 * (v - 20) + 124
			h = 0.2481 * 0.472 * (v - 20) + 124
			m = (a ~ /^[0-9]+$/) ? sprintf("%.0f", a - c) : "NA"
			printf "%.0f\t%.0f\t%s\n", c, h, m }')
		new=NA
		if [ "$n0" != NA ]; then
			mapfile -t k < <(dmesg | grep -o 'r8=.* r9=.*')
			new=-
			# Fewer lines than last time means the ring buffer wrapped.
			if [ "${#k[@]}" -gt "$n0" ]; then
				new=$(printf '%s; ' "${k[@]:n0}")
				new=${new%; }
			fi
			n0=${#k[@]}
		fi
		printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
			"$(date +%H:%M:%S)" "$(( $(date +%s) - t0 ))" "$in0" "$in10" "$lv" \
			"$(r $BAT/temp)" "$(r $BAT/current_now)" "$(r $BAT/capacity)" \
			"$(r $CHG/status)" "$(r $CHG/temp)" "$new" >> "$out"
		sleep "$step"
	done
	echo "wrote $out"
}
r() { cat "$1" 2>/dev/null || echo NA; }
CHG=/sys/class/power_supply/bq24297
BAT=/sys/class/power_supply/bq27421-0
if [ "$1" = --ts ]; then
	shift
	ts "$@"
	exit
fi
out=${1:-$HOME/pyra-chgwatch-$(date +%Y%m%d-%H%M%S).tsv}
# Find the chip by driver, not by i2c address.
REG=$(echo /sys/bus/i2c/drivers/bq2429x_charger/*/registers)
IIN=$(echo /sys/bus/i2c/drivers/bq2429x_charger/*/max_current)
printf "t\tiinlim\tbat_status\tbat_ua\tbat_uv\tcap\tbat_temp\tchg_status\treg00\treg08\treg09\tcore_mC\tgauge_mC\tchgzone_mC\n" > "$out"
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt "${2:-600}" ]; do
	printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
		"$(( $(date +%s) - t0 ))" \
		"$(r "$IIN")" \
		"$(r $BAT/status)" "$(r $BAT/current_now)" "$(r $BAT/voltage_now)" \
		"$(r $BAT/capacity)" "$(r $BAT/temp)" "$(r $CHG/status)" \
		"$(awk "/reg 00/{print \$4}" "$REG")" \
		"$(awk "/reg 08/{print \$4}" "$REG")" \
		"$(awk "/reg 09/{print \$4}" "$REG")" \
		"$(r /sys/class/thermal/thermal_zone2/temp)" \
		"$(r /sys/class/thermal/thermal_zone3/temp)" \
		"$(r /sys/class/thermal/thermal_zone4/temp)" >> "$out"
	sleep 1
done
echo "wrote $out"
