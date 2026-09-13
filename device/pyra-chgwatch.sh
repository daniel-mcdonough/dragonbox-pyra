#!/bin/bash
#
# pyra-chgwatch.sh — watch the charge path, once a second, and change nothing.
#
#   ./pyra-chgwatch.sh [FILE] [SECONDS]
#
# Defaults to ~/pyra-chgwatch-<stamp>.tsv for 600 seconds. Needs no root: every
# column is a world-readable sysfs file.
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
#               conclude anything from a single read of it.
#   gauge_mC    bq27421-0, which is the fuel gauge's own die on the mainboard,
#               not the cell. It is not a battery temperature. See
#               pyra-thermal-ladder.sh.
out=${1:-$HOME/pyra-chgwatch-$(date +%Y%m%d-%H%M%S).tsv}
r() { cat "$1" 2>/dev/null || echo NA; }
CHG=/sys/class/power_supply/bq24297
BAT=/sys/class/power_supply/bq27421-0
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
		"$(awk "/reg 00/{print \$4}" $REG)" \
		"$(awk "/reg 08/{print \$4}" $REG)" \
		"$(awk "/reg 09/{print \$4}" $REG)" \
		"$(r /sys/class/thermal/thermal_zone2/temp)" \
		"$(r /sys/class/thermal/thermal_zone3/temp)" \
		"$(r /sys/class/thermal/thermal_zone4/temp)" >> "$out"
	sleep 1
done
echo "wrote $out"
