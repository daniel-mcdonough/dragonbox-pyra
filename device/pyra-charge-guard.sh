#!/bin/bash
#
# pyra-charge-guard.sh — lower the charge current before the pack gets near
# the charger's own hot cut-off, and put it back once it has cooled.
#
#   sudo ./pyra-charge-guard.sh [--dry-run] [FILE] [SECONDS] [INTERVAL]
#
# Defaults to ~/pyra-charge-guard-<stamp>.tsv, 14400 s (four hours), sampled
# every 10 s. Needs root: it reads the bq24297's registers over the i2c bus
# directly (there is no sysfs file for the charge current, unlike the input
# limit's max_current), which needs CAP_SYS_RAWIO-ish access to /dev/i2c-N and
# bypasses the kernel driver's own claim on the address.
#
# BACKGROUND: see docs/fixes.md "Fix 8" and experiments/charging/README.md
# "What protects the cell". Short version: this board's only cell thermal
# protection is the charger's TS pin, a hardware comparator on the pack
# thermistor. It trips charging off at VTCO and does not resume until the
# thermistor recovers past VHTF, about 30 mV higher at the GPADC tap. That is
# enough protection to not damage anything, but it is a hard stop with no
# warning: one moment the charger is pushing 2 A in, the next it is HOT and
# the gauge has stopped moving. This script watches the same margin
# `pyra-chgwatch.sh --ts` logs (Palmas GPADC channel 0 against the cut-off
# worked back from channel 10, VBUS) and leans on the charge current — REG02
# of the bq24297, not the input limit fix 8 owns — well before that trip, so
# the pack spends less time near it and the hard stop happens less often.
#
# WHAT IT ASSUMES
#
# It is a two-state thermostat, not a ladder: full current until the margin
# falls to LOW_MV, then the floor (REDUCED_MA, default the chip's 512 mA
# minimum) until the margin climbs back to HIGH_MV. The 30 mV gap between
# them by default is not a guess at hysteresis; it is VTCO to VHTF, the same
# gap the charger itself uses, so this backs off before the real trip and does
# not let go again until the real trip would have let go too. A margin under
# about 15 mV is already within the GPADC's own measurement slop (see the
# README section above), so LOW_MV defaults well above that.
#
# It only ever touches REG02's ICHG field (bits 7:2). Bits 1:0 (FORCE_20PCT,
# BCOLD) are read once at the start and written back unchanged on every
# update; this script does not interpret or validate them, it only preserves
# them. If FORCE_20PCT is set, the mA figures below are wrong (ICHG then means
# 20% of itself) — this has not been seen on this board and the script warns
# if it finds it. It never writes REG00 (the input limit) or any other
# register: that is fix 8's, and fighting it would re-open the drain-on-charger
# fault that fix exists to close.
#
# It reads IN0 and IN10 exactly as `pyra-chgwatch.sh --ts` does and must not
# reconfigure the GPADC: IN2 is the volume wheel, read on the same ADC.
#
# WHAT IT DOES ON START, AND WHY
#
# Nothing else writes REG02 while the charger stays plugged in (checked: it
# stays at the device tree's chg_current, 2048 mA / register 0x60, across
# boots and charges). A replug does reset it to 0x60, even one shorter than a
# sample (seen 2026-11-25: a 0.4 s VBUS drop mid-reduction), so every sample
# while REDUCED compares the live register and writes the reduction again if
# it has moved. If this script is killed mid-reduction — the charger stays
# exactly where it was left, which is the safe direction, not a crash that
# silently restores full current under a hot pack — a later run would
# otherwise mistake that leftover reduced value for the configured FULL_MA.
# To avoid that, every start asserts FULL_MA before doing anything else,
# whatever the register currently reads. That is also why it does not restore
# on exit: leaving a reduction in place when this script stops is the
# conservative failure, and asserting-on-start is what undoes it once someone
# is watching again.
#
# It does restore automatically when the charger goes offline — IN0 means
# nothing without one (REGN, which biases the divider, is off on battery) —
# so a card left running this across unplugs always comes back to full
# current for the next plug-in, the same way fix 8's helper re-asserts the
# input limit on one.
#
# --dry-run computes and logs the same decisions but skips every i2c write, so
# the state machine can be checked against a real charge without touching the
# chip.
#
# TSV COLUMNS (see pyra-chgwatch.sh's header for in0_mV, in10_mV, vtco_mV,
# margin_mV, gauge_dC, bat_ua; the formula is identical, duplicated here so
# this script does not depend on that one):
#
#   state      FULL or REDUCED.
#   ichg_mA    the fast-charge current limit this script believes is set,
#              from the register it last wrote (or read, at start).
#   reg02      the live register byte, re-read every sample, so a divergence
#              between it and ichg_mA is visible. While REDUCED, a divergence
#              is written back the next sample ("reg02 was 0x60 while reduced,
#              re-applied 512 mA"); while FULL it is only logged, since a
#              lower value set by someone else is the safe direction.
#   note       "-", or what changed this sample ("start: asserting 2048 mA",
#              "reduced 2048 -> 512 mA, margin 54 mV", "restored 512 -> 2048
#              mA, margin 93 mV", "charger offline, restored 512 -> 2048 mA").

set -u

for _p in /usr/sbin /sbin /usr/local/sbin; do
	case ":$PATH:" in
		*":$_p:"*) ;;
		*) PATH="$PATH:$_p" ;;
	esac
done
unset _p

CHG=/sys/class/power_supply/bq24297
BAT=/sys/class/power_supply/bq27421-0

# The chip's own ceiling (3008 mA) is not the point; FULL_MA is what the
# device tree asserts today (chg_current = 2048000 in bq2429x_parse_dt's
# boot log), so a guard that restores "full" restores what was always there,
# not a new opinion. REDUCED_MA is the chip's floor: the most margin this can
# buy, and simplest to reason about. LOW_MV/HIGH_MV: see "what it assumes".
FULL_MA=${PYRA_CHARGE_GUARD_FULL_MA:-2048}
REDUCED_MA=${PYRA_CHARGE_GUARD_REDUCED_MA:-512}
LOW_MV=${PYRA_CHARGE_GUARD_LOW_MV:-60}
HIGH_MV=${PYRA_CHARGE_GUARD_HIGH_MV:-90}
MARKER=pyra-charge-guard

r() { cat "$1" 2>/dev/null || echo NA; }

die() { printf 'pyra-charge-guard: %s\n' "$*" >&2; exit 1; }

find_adc() {
	local d
	for d in /sys/bus/iio/devices/iio:device*; do
		[ "$(r "$d/name")" = palmas-gpadc ] && { printf '%s\n' "$d"; return 0; }
	done
	return 1
}

# By driver, not i2c address, same reasoning as pyra-charge-current.sh: a bus
# renumber must not silently turn this into a no-op against the wrong chip.
find_charger() {
	local d
	for d in /sys/bus/i2c/drivers/bq2429x_charger/*-*/; do
		[ -d "$d" ] && { printf '%s\n' "${d%/}"; return 0; }
	done
	return 1
}

# code 0-39 <-> mA, per TI SLUSBP6D Table 9-9 (REG02 ICHG[5:0]): offset
# 512 mA, 64 mA/step, 512-3008 mA. Values above 3008 mA are documented "not
# supported"; this script never asks for more than FULL_MA anyway.
ma_to_code() {
	local ma=$1
	local code=$(( (ma - 512) / 64 ))
	[ "$code" -lt 0 ] && code=0
	[ "$code" -gt 39 ] && code=39
	printf '%s\n' "$code"
}
code_to_ma() { printf '%s\n' "$(( 512 + $1 * 64 ))"; }

DRYRUN=0
if [ "${1:-}" = --dry-run ]; then DRYRUN=1; shift; fi

[ "$(id -u)" = 0 ] || die "run this with sudo (it reads/writes the charger's i2c registers directly)"

ADC=$(find_adc) || die "no palmas-gpadc IIO device"
CHGDIR=$(find_charger) || die "no bq2429x_charger i2c client bound"
BUSADDR=$(basename "$CHGDIR")
I2CBUS=${BUSADDR%-*}
I2CADDR=$(printf '0x%02x' "0x${BUSADDR#*-}")

read_reg() { i2cget -f -y "$I2CBUS" "$I2CADDR" "$1" 2>&1; }
write_reg() { i2cset -f -y "$I2CBUS" "$I2CADDR" "$1" "$2" b 2>&1; }

for _v in FULL_MA REDUCED_MA LOW_MV HIGH_MV; do
	case ${!_v} in ''|*[!0-9]*) die "$_v must be a whole number, got '${!_v}'" ;; esac
done
unset _v
# The overrides may only lower the current: FULL_MA above the device tree's
# 2048 mA would make every start and every restore raise the charge current
# past what fix 8 and the charging README settle on.
[ "$FULL_MA" -le 2048 ] || die "FULL_MA ($FULL_MA) is above the device tree's 2048 mA; this guard only ever lowers the charge current"
[ "$REDUCED_MA" -ge 512 ] && [ "$REDUCED_MA" -lt "$FULL_MA" ] \
	|| die "REDUCED_MA ($REDUCED_MA) must be at least 512 and below FULL_MA ($FULL_MA)"
[ "$LOW_MV" -lt "$HIGH_MV" ] || die "LOW_MV ($LOW_MV) must be below HIGH_MV ($HIGH_MV)"

reg02=$(read_reg 0x02) || die "could not read REG02: $reg02"
case $reg02 in 0x*) ;; *) die "unexpected i2cget output for REG02: $reg02" ;; esac
LOW2=$(( reg02 & 0x03 ))
if [ "$LOW2" != 0 ]; then
	printf 'pyra-charge-guard: REG02 bits 1:0 are %#04x, not 00 (FORCE_20PCT/BCOLD); preserving them, but the mA figures below assume FORCE_20PCT=0 and may not be the real current.\n' "$LOW2" >&2
fi

FULL_CODE=$(ma_to_code "$FULL_MA")
REDUCED_CODE=$(ma_to_code "$REDUCED_MA")

set_code() {
	# $1 the ICHG code to write, $2 a human label for the log/journal.
	local code=$1 label=$2 byte wret got
	byte=$(printf '0x%02x' "$(( (code << 2) | LOW2 ))")
	if [ "$DRYRUN" = 1 ]; then
		printf '(dry run, not written) %s\n' "$label"
		return 0
	fi
	if ! wret=$(write_reg 0x02 "$byte" 2>&1); then
		printf 'pyra-charge-guard: write to REG02 failed: %s\n' "$wret" >&2
		return 1
	fi
	got=$(read_reg 0x02)
	if [ "$got" != "$byte" ]; then
		printf 'pyra-charge-guard: wrote %s to REG02 but it reads back %s\n' "$byte" "$got" >&2
		logger -t "$MARKER" -p user.warning "wrote $byte to REG02 but it reads back $got" 2>/dev/null
		return 1
	fi
	logger -t "$MARKER" "$label" 2>/dev/null
	return 0
}

out=${1:-$HOME/pyra-charge-guard-$(date +%Y%m%d-%H%M%S).tsv}
dur=${2:-14400}
step=${3:-10}

printf "time\tt\tin0_mV\tin10_mV\tvtco_mV\tmargin_mV\tstate\tichg_mA\treg02\tgauge_dC\tbat_ua\tcap\tchg_status\tnote\n" > "$out"

state=FULL
ichg_mA=$(code_to_ma "$FULL_CODE")
# Carried into the first sample's note column, which the loop otherwise
# overwrites, so a failed start shows up in the TSV and not only on stderr.
start_note="start: asserting ${ichg_mA} mA"
if ! set_code "$FULL_CODE" "start: asserting ${ichg_mA} mA (was reg02=$reg02)"; then
	start_note="start: FAILED to assert ${ichg_mA} mA, leaving reg02=$reg02"
fi

t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt "$dur" ]; do
	online=$(r "$CHG/online")
	in0=NA in10=NA vtco=NA margin=NA
	if [ "$online" = 1 ]; then
		in0=$(r "$ADC/in_voltage0_input")
		in10=$(r "$ADC/in_voltage10_input")
		read -r vtco margin <<< "$(awk -v a="$in0" -v v="$in10" 'BEGIN {
			if (v !~ /^[0-9]+$/ || v < 4000) { print "NA NA"; exit }
			c = 0.2481 * 0.447 * (v - 20) + 124
			m = (a ~ /^[0-9]+$/) ? sprintf("%.0f", a - c) : "NA"
			printf "%.0f %s\n", c, m }')"

		# A charger replug puts REG02 back to 0x60 behind this script (see
		# "what it does on start"), so a reduction has to be re-checked
		# against the live register, not only remembered.
		live=$(read_reg 0x02)
		reapplied=
		if [ "$state" = REDUCED ] && [ "$DRYRUN" = 0 ] \
			&& [ "$live" != "$(printf '0x%02x' "$(( (REDUCED_CODE << 2) | LOW2 ))")" ]; then
			if set_code "$REDUCED_CODE" "reg02 was $live while reduced, re-applied ${REDUCED_MA} mA"; then
				reapplied="reg02 was $live while reduced, re-applied ${REDUCED_MA} mA"
			else
				reapplied="reg02 was $live while reduced, FAILED to re-apply"
			fi
		fi

		if [ "$margin" != NA ]; then
			if [ "$state" = FULL ] && [ "$margin" -le "$LOW_MV" ]; then
				if set_code "$REDUCED_CODE" "reduced ${FULL_MA} -> ${REDUCED_MA} mA, margin ${margin} mV"; then
					state=REDUCED; ichg_mA=$REDUCED_MA
					note="reduced ${FULL_MA} -> ${REDUCED_MA} mA, margin ${margin} mV"
				else
					note="FAILED to reduce at margin ${margin} mV"
				fi
			elif [ "$state" = REDUCED ] && [ "$margin" -ge "$HIGH_MV" ]; then
				if set_code "$FULL_CODE" "restored ${REDUCED_MA} -> ${FULL_MA} mA, margin ${margin} mV"; then
					state=FULL; ichg_mA=$FULL_MA
					note="restored ${REDUCED_MA} -> ${FULL_MA} mA, margin ${margin} mV"
				else
					note="FAILED to restore at margin ${margin} mV"
				fi
			else
				note=-
			fi
		else
			note=-
		fi
		if [ -n "$reapplied" ]; then
			[ "$note" = - ] && note=$reapplied || note="$reapplied; $note"
		fi
	else
		if [ "$state" = REDUCED ]; then
			if set_code "$FULL_CODE" "charger offline, restored ${REDUCED_MA} -> ${FULL_MA} mA"; then
				state=FULL; ichg_mA=$FULL_MA
				note="charger offline, restored ${REDUCED_MA} -> ${FULL_MA} mA"
			else
				note="charger offline, FAILED to restore"
			fi
		else
			note=-
		fi
	fi

	if [ -n "$start_note" ]; then
		[ "$note" = - ] && note=$start_note || note="$start_note; $note"
		start_note=
	fi
	reg02=$(read_reg 0x02)
	printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
		"$(date +%H:%M:%S)" "$(( $(date +%s) - t0 ))" "$in0" "$in10" "$vtco" "$margin" \
		"$state" "$ichg_mA" "$reg02" \
		"$(r "$BAT/temp")" "$(r "$BAT/current_now")" "$(r "$BAT/capacity")" \
		"$(r "$CHG/status")" "$note" >> "$out"
	sleep "$step"
done
echo "wrote $out"
