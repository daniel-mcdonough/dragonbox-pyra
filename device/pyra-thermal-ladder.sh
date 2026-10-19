#!/bin/bash
#
# pyra-thermal-ladder.sh — make the thermal daemon decide from the right
# sensors, at a speed that can control this machine.
#
#   sudo ./pyra-thermal-ladder.sh --check   say what the state is, change nothing
#   sudo ./pyra-thermal-ladder.sh           apply it, restart, verify
#   sudo ./pyra-thermal-ladder.sh --undo    put the previous ladder back
#
#        ./pyra-thermal-ladder.sh --emit-patched FILE
#
# writes the changed version of FILE to stdout, touches nothing, needs no root
# and does not care whether it is running on a Pyra. That mode is how the
# transformation is tested against a copy of the vendor file without a device,
# and it is the door `pc/pyra-trixie-prep.sh` goes through to apply the same
# change to a card offline, as fix 7. There is one implementation of the change
# and every mode calls it.
#
# RUN pyra-thermal-fix.sh FIRST
#
# Until that fix is applied the daemon cannot apply any frequency decision at
# all, so changing which decision it makes is inert. This script checks and
# says so rather than leaving you to wonder why nothing moved.
#
# WHAT IS WRONG
#
# `/usr/share/pyra/scripts/pyra-thermal.sh` picks a CPU ceiling from two
# sensors. One is `core_thermal`, the SoC. The other it calls the battery, and
# it is `bq27421-0`, the fuel gauge. The two ladders are wildly different:
#
#     core    > 77 C -> 1250 MHz      battery > 44 C -> 1250 MHz
#             > 82 C -> 1000 MHz              > 45 C -> 1000 MHz
#             > 87 C ->  750 MHz              > 47 C ->  750 MHz
#             > 92 C ->  500 MHz              > 49 C ->  500 MHz
#             > 97 C ->  250 MHz              > 50 C ->  250 MHz
#
# That is only sane if the second sensor is measuring a battery. It is not. The
# bq27421 reports its own die temperature: it is an I2C chip on the mainboard,
# and what it measures is the board it is soldered to. Measured on this machine
# with one core loaded:
#
#     t=182s   core 55.4 C   gauge 42.2 C   ceiling 1500 MHz   (load starts)
#     t=213s   core 70.6 C   gauge 44.6 C   ceiling 1250 MHz
#
# The gauge rose 2.0 C within ten seconds of the load starting. A 6000 mAh cell
# cannot change temperature that fast, and nothing in those ten seconds put any
# current through it — the machine was discharging gently the whole time. The
# other sensor on the charge path, `bq24297`, returned exactly 22500 on all 252
# samples of that run — but that run was on battery, with the charger offline.
# Plugged in it reads 60000, and it has never varied within a run in either
# state across about 1500 samples — 1123 of them while the pack warmed and the
# charge current moved by a factor of two. It reports whether a cable is
# attached, not a temperature. There is no cell temperature on this machine.
#
# Three more things that run showed, none of which are guesses:
#
#   The core peaked at 71.0 C and never reached its own first rung at 77 C.
#   The whole throttling episode happened without the core ladder being
#   consulted once.
#
#   The ceiling changed twelve times, six of them oscillating between 1250 and
#   1000 MHz inside a 116-second window while the gauge sat between 44.8 and
#   45.5 C. That is the oscillation, measured.
#
#   The cap outlived the work that caused it by more than five minutes: still
#   1250 MHz 350 seconds after the load stopped, with the core back at 57.4 C.
#
# So the battery ladder is a second CPU ladder, reading a sensor with a worse
# view of the CPU than core_thermal has, calibrated as though it were reading a
# cell. It is also the one that fires: the core has to reach 77 C to give up a
# step, the gauge only has to reach 44 C, and half a minute of one core does
# that. The machine spends ordinary afternoons two steps below its top speed.
#
# AND A THIRD FAULT, WHICH IS THE SERIOUS ONE
#
# `setMaxFreq` tests its argument against the constant `maxFreq`, 1500, rather
# than against the cap already chosen. So whichever ladder runs last wins,
# whether or not it is the more restrictive one — and the battery ladder runs
# last. Reduced from the vendor's own helpers, unmodified:
#
#     current_maxFreq=$maxFreq
#     core_temp=98000       # the core ladder's deepest rung, 250 MHz
#     battery_temp=44500    # the battery ladder's shallowest rung, 1250 MHz
#
#     if [ $core_temp -gt 97000 ]; then setMaxFreq 250; fi      # -> 250, right
#     if [ $battery_temp -gt 44000 ]; then setMaxFreq 1250; fi  # -> 1250
#
# A core at 98 C asks for 250 MHz and gets 1250, because the board happens to
# be at an entirely ordinary 44.5 C. The deeper the core rung the larger the
# overwrite, so this is worst exactly when it matters most. Unlike the other
# two, this one is a loss of thermal protection rather than a loss of speed.
#
# WHAT THIS CHANGES
#
# 1. The gauge ladder is recalibrated as what it is — a board sensor — instead
#    of being deleted. The board is worth watching: it sees case heat that the
#    die sensor does not. Its rungs are moved to temperatures the board reaches
#    only when the SoC is already in trouble, so it becomes the backstop it
#    should always have been rather than the primary control. The thresholds
#    are in one block at the top of the generated ladder, named and commented,
#    so they can be argued with.
#
# 2. Both ladders get hysteresis. There was none: the daemon capped, cooled a
#    degree, released at the very next sample, heated a degree and capped
#    again, on a 20-second cycle. That is the 1.5/1.25 GHz oscillation this
#    hardware is known for, and it could not have been seen on trixie before
#    the cpufreq-set fault was fixed, because nothing was capping.
#
# 3. Every frequency decision goes through a helper that takes the LOWER of
#    the cap chosen so far and the one being asked for, which is what both
#    ladders always meant. The vendor's setMaxFreq is left in the file,
#    untouched and now unused by the frequency path, because setMaxCharge
#    beside it is still correct and still used.
#
# 4. The poll goes from 20 seconds to 2. THIS IS NOT OPTIONAL, and the reason
#    is the most important thing in this file. Two cores flat out take this
#    machine from a 63 C idle to its 100 C passive trip in SIXTEEN SECONDS. A
#    20-second poll therefore arrives after the trip rather than before it,
#    and measurement confirms it: with the ladder corrected but the poll left
#    alone, two cores reached 102 C and the ceiling never moved once.
#
#    The vendor got away with 20 seconds only by accident. Its broken ladder
#    capped on a board sensor that sits above 44 C in ordinary use, so the
#    machine was permanently pre-capped — measured at 750 MHz, where two cores
#    flat out peak at a harmless 74 C. That is real protection obtained for
#    entirely the wrong reason, and correcting the ladder takes it away. The
#    poll has to become fast enough to do the job on purpose.
#
# 5. The ladder reads the hotter of core_thermal and cpu_thermal rather than
#    core_thermal alone. The passive trip is on cpu_thermal, and during a fast
#    ramp the two diverge: measured here, cpu_thermal read 77.7 C at the
#    moment core_thermal read 67.0 C. Watching only the cooler of the two is
#    acting ten degrees late on the sensor that decides whether the trip fires.
#
# Together, 4 and 5 take two cores flat out from 102 C to 87 C, thirteen
# degrees clear of the trip, with the load running to completion.
#
# Points 4 and 5 exist because of point 1. They were invisible while the
# machine was permanently pre-capped, and they became load-bearing the moment
# it was not. A fix for 1 without 4 and 5 makes this machine less safe than it
# was, which was measured the hard way before it was written down here.
#
# The charging ladder is left alone, on purpose. Holding charge current down
# when the board around the charge path is warm is defensible and conservative,
# it is the half of this daemon that has always worked, and loosening a
# charging safety limit is not a thing to do on the strength of a performance
# measurement.
#
# CAVEAT WORTH KNOWING
#
# This edits a file shipped by a package, and `/usr/share` is not a conffile
# location, so an upgrade of the Pyra scripts will silently put the old ladder
# back. `--check` detects that. The proper home for this is upstream.
#
set -euo pipefail

VENDOR=/usr/share/pyra/scripts/pyra-thermal.sh
BACKUP=$VENDOR.before-pyra-thermal-ladder
MARKER='pyra-thermal-ladder'
FIXMARKER='pyra-thermal-fix'
SERVICE=pyra-thermal.service
CPUFREQ=/sys/devices/system/cpu/cpu0/cpufreq

ACTION=apply
EMIT_SRC=
case "${1:-}" in
	--check) ACTION=check ;;
	--undo)  ACTION=undo ;;
	--emit-patched)
		ACTION=emit
		EMIT_SRC=${2:-}
		[ -n "$EMIT_SRC" ] || { echo "--emit-patched needs a file" >&2; exit 2; }
		;;
	-h|--help) sed -n '3,153p' "$0" | sed 's/^# \?//'; exit 0 ;;
	"") ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
esac

say()  { printf '\n== %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die()  { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# The replacement ladder. This is the whole of the change and it is one
# contiguous block, which is what makes the transformation a single anchored
# replacement rather than a dozen surgical edits to a file that must keep
# parsing as /bin/sh.
#
# It is written in the vendor's own style and keeps the vendor's setMaxCharge,
# so the diff reads as an edit to the ladder rather than as a rewrite of the
# daemon. It does not use the vendor's setMaxFreq: that helper is the third
# fault described above and the block carries its own correct one.
# ---------------------------------------------------------------------------
new_ladder() {
	cat <<'LADDER'
	# pyra-thermal-ladder: the ladder below replaces the vendor's. Two
	# changes, both explained in full in the script that applied this.
	#
	# 1. The sensor the vendor calls the battery is bq27421-0, the fuel
	#    gauge, and it
	#    reports the gauge's own die temperature — the mainboard it is
	#    soldered to, not the cell. It rises 2.0 C within ten seconds of one
	#    core being loaded, which no 6000 mAh cell can do. The vendor's rungs
	#    for it start at 44 C, which one core reaches in half a minute, so
	#    it, and not core_thermal, was what capped this machine in ordinary
	#    use. Its rungs are moved to board temperatures that mean something.
	#
	# 2. Neither ladder had hysteresis, so a cap was given back at the first
	#    sample below the threshold that took it, one poll before the heat
	#    that caused it returned. Hence the 1.5/1.25 GHz oscillation.

	# Board rungs, on the fuel gauge die. Chosen so that this ladder is a
	# backstop and core_thermal stays the primary control: the numbers are
	# where the board sits when the SoC is already at the matching rung of
	# the core ladder, measured rather than guessed.
	gaugeHot1=GAUGE_HOT1
	gaugeHot2=GAUGE_HOT2
	gaugeHot3=GAUGE_HOT3
	gaugeHot4=GAUGE_HOT4
	gaugeHot5=GAUGE_HOT5

	# How far a temperature must fall below the rung that took a step away
	# before it is given back: one full rung of the core ladder.
	#
	# Sized from the machine rather than from the ladder. This core moves up
	# to 6 C between five-second samples under one core of load and 10 C
	# under two. A 2 C band was tried first, at the vendor's 20-second poll,
	# and is below this controller's noise floor: it released correctly and
	# still crossed the same rung six times in four minutes. A full rung means
	# a release has to undo a whole step's worth of heating. The poll is now
	# 2 seconds (see the interval note at the top of the file), which moves
	# less per sample. The 2 C against 5 C comparison was made at 20 s and
	# has not been repeated at 2 s; 5 C at 2 s is what produced the 87 C
	# two-core result, so it is the tested value, not a derived one.
	#
	# The fine regulation is not this daemon's job in any case. The kernel's
	# step_wise governor polls the same zone every 250 ms; this one is the
	# slower backstop, and it should act like one.
	pyraHyst=PYRA_HYST

	# Two ladders, not one, and the split is the point. Frequency is
	# debounced; charging is not touched by the debounce at all. Evaluating
	# one combined ladder twice would mean a release pass deciding the
	# charge current from a temperature one hysteresis band (5 C by default)
	# higher than the real one, which
	# would clamp the charger to 500 mA at a board temperature where the
	# vendor allows 2 A. Defined here rather than at the top of the file so
	# that this entire change stays one reviewable block.
	# Take the lower of the cap already chosen and the one being asked for.
	# The vendor's setMaxFreq compares against maxFreq instead, which lets a
	# later ladder undo an earlier one's deeper cap; see note 3 above.
	pyraCap()
	{
		if [ "$1" -lt "${current_maxFreq}" ]
		then
			current_maxFreq=$1
		fi
	}

	pyraFreqLadder()
	{
		current_maxFreq=${maxFreq}

		#Check Core, from hottest to coldest. Unchanged: this is the
		#right sensor for CPU heat and these are the right rungs for it.
		if [ "$1" -gt 97000 ]
		then
			pyraCap 250
		elif [ "$1" -gt 92000 ]
		then
			pyraCap 500
		elif [ "$1" -gt 87000 ]
		then
			pyraCap 750
		elif [ "$1" -gt 82000 ]
		then
			pyraCap 1000
		elif [ "$1" -gt 77000 ]
		then
			pyraCap 1250
		fi

		#Check the board, from hottest to coldest. Frequency only: this
		#sensor has nothing to say about the cell.
		if [ "$2" -gt "${gaugeHot1}" ]
		then
			pyraCap 250
		elif [ "$2" -gt "${gaugeHot2}" ]
		then
			pyraCap 500
		elif [ "$2" -gt "${gaugeHot3}" ]
		then
			pyraCap 750
		elif [ "$2" -gt "${gaugeHot4}" ]
		then
			pyraCap 1000
		elif [ "$2" -gt "${gaugeHot5}" ]
		then
			pyraCap 1250
		fi
	}

	# The vendor's charging ladder, thresholds and all, kept in its own
	# function and fed the temperature as read. The first five branches all
	# choose the same current; that redundancy is the vendor's and is left
	# alone so that this reads as a move, not an edit.
	pyraChargeLadder()
	{
		current_maxCharge=${maxCharge}

		if [ "$1" -gt 50000 ]
		then
			setMaxCharge 500000
		elif [ "$1" -gt 49000 ]
		then
			setMaxCharge 500000
		elif [ "$1" -gt 47000 ]
		then
			setMaxCharge 500000
		elif [ "$1" -gt 45000 ]
		then
			setMaxCharge 500000
		elif [ "$1" -gt 44000 ]
		then
			setMaxCharge 500000
		elif [ "$1" -gt 43000 ]
		then
			setMaxCharge 1000000
		elif [ "$1" -gt 42000 ]
		then
			setMaxCharge 2000000
		fi
	}

	# The ladder is fed the hotter of core_thermal and cpu_thermal, not
	# core_thermal alone. The passive trip is on cpu_thermal, and during a
	# fast ramp the two diverge badly: measured on this machine, cpu_thermal
	# read 77.7 C at the moment core_thermal read 67.0 C. Watching only the
	# cooler of the two means acting ten degrees late on the sensor that
	# actually decides whether the trip fires. core_temp itself is left
	# alone so the daemon's own one-shot output still reports what it read.
	if [ -z "${pyraCpuDev+set}" ]
	then
		pyraCpuDev=
		for _pyra_z in /sys/class/thermal/thermal_zone*
		do
			if [ "$(cat "${_pyra_z}/type" 2>/dev/null)" = "cpu_thermal" ]
			then
				pyraCpuDev=${_pyra_z}/temp
			fi
		done
	fi
	pyraHot=${core_temp}
	if [ -n "${pyraCpuDev}" ] && [ -r "${pyraCpuDev}" ]
	then
		_pyra_cpu=$(cat "${pyraCpuDev}" 2>/dev/null || echo 0)
		if [ "${_pyra_cpu}" -gt "${pyraHot}" ]
		then
			pyraHot=${_pyra_cpu}
		fi
	fi

	pyraChargeLadder "${battery_temp}"

	pyraFreqLadder "${pyraHot}" "${battery_temp}"
	if [ "${current_maxFreq}" -gt "${pyraPrevMaxFreq:-${maxFreq}}" ]
	then
		# This pass wants to hand a step back. Only do it once the
		# temperature has fallen clear of the rung that took it, rather
		# than merely back across it.
		pyraFreqLadder "$((pyraHot + pyraHyst))" "$((battery_temp + pyraHyst))"
	fi
	pyraPrevMaxFreq=${current_maxFreq}
LADDER
}

# The board rungs, and the hysteresis, in one place. See the report for how
# each number was arrived at; every one of them is a measurement on a V5.3.
#
# CALIBRATED ON A STOCK MACHINE, AND OVERRIDABLE FOR THAT REASON.
#
# The rungs come from the worst board temperature this unit reached with
# nothing capping it — 50.5 C — rounded up, given 3 C of margin, then stepped
# 2 C. That is a stock V5.3: stock heatsink, factory thermal interface, no
# conformal coating, no aftermarket compound, no added airflow, closed case.
#
# Cooling work moves this sensor a long way. The author of the frequency table
# in experiments/thermals-and-frequency reports 20-23 C below stock after
# soldering the heatsink, stripping the factory adhesive, applying high-end
# compound and coating the board. On a board like that these rungs never fire,
# which is harmless — the SoC rungs below are the primary control and they mean
# the same thing whatever the case is doing. Set GAUGE_HOT1..5 in the
# environment if you have measured your own machine and know better.
#
# Do NOT raise them on the strength of someone else's numbers. The whole fault
# being fixed here is a ladder whose thresholds came from somewhere other than
# the machine they run on.
GAUGE_HOT1=${GAUGE_HOT1:-62000}
GAUGE_HOT2=${GAUGE_HOT2:-60000}
GAUGE_HOT3=${GAUGE_HOT3:-58000}
GAUGE_HOT4=${GAUGE_HOT4:-56000}
GAUGE_HOT5=${GAUGE_HOT5:-54000}
PYRA_HYST=${PYRA_HYST:-5000}

render_ladder() {
	new_ladder | sed \
		-e "s/GAUGE_HOT1/$GAUGE_HOT1/" \
		-e "s/GAUGE_HOT2/$GAUGE_HOT2/" \
		-e "s/GAUGE_HOT3/$GAUGE_HOT3/" \
		-e "s/GAUGE_HOT4/$GAUGE_HOT4/" \
		-e "s/GAUGE_HOT5/$GAUGE_HOT5/" \
		-e "s/PYRA_HYST/$PYRA_HYST/"
}

# Refuse to touch a file that is not the one this was written for. The old
# ladder's thresholds are the signature: if any of them is missing, the ladder
# has already been changed by something else and guessing would be worse than
# stopping.
EXPECT_CORE='97000 92000 87000 82000 77000'
EXPECT_BATT='50000 49000 47000 45000 44000 43000 42000'

recognised() {
	local src=$1 n
	grep -q 'Check Core, from hottest to coldest' "$src" || return 1
	grep -q 'Check Battery, from hottest to coldest' "$src" || return 1
	grep -qE '^[[:space:]]*if \[ "\$daemon" -eq 0 \]' "$src" || return 1
	grep -qE '^[[:space:]]*interval=[0-9]+[[:space:]]*$' "$src" || return 1
	for n in $EXPECT_CORE $EXPECT_BATT; do
		grep -q -- "-gt ${n}\b" "$src" || return 1
	done
	return 0
}

# How often the daemon looks. The vendor polls every 20 seconds, which cannot
# control this machine: see the note written into the file below.
PYRA_INTERVAL=${PYRA_INTERVAL:-2}

# Replace everything from the "#Check Core" line up to, but not including, the
# "if [ "$daemon" -eq 0 ]" line that follows the ladder, and separately replace
# the poll interval at the top of the file. Anchoring on recognisable lines
# rather than byte offsets means the vendor's indentation, which mixes tabs and
# spaces, never has to be matched exactly.
emit_patched() {
	local src=$1 lad
	if grep -q "$MARKER" "$src"; then
		cat "$src"
		return 0
	fi
	lad=$(mktemp)
	render_ladder > "$lad"
	awk -v ladfile="$lad" -v interval="$PYRA_INTERVAL" '
		BEGIN { state = 0 }
		# The poll interval, before the ladder and independent of it.
		!done_interval && $0 ~ /^[[:space:]]*interval=[0-9]+[[:space:]]*$/ {
			print "# pyra-thermal-ladder: was interval=20, which cannot control"
			print "# this machine. Measured: two cores from a 63 C idle reach the"
			print "# 100 C passive trip in 16 seconds, so a 20 second poll arrives"
			print "# after the trip rather than before it. With the vendor ladder"
			print "# that was masked, because the gauge sat above 44 C in ordinary"
			print "# use and left the machine permanently pre-capped — measured at"
			print "# 750 MHz, where two cores flat out peak at a harmless 74 C."
			print "# Correcting the ladder removes that accident, so the poll has"
			print "# to become fast enough to do the job on purpose."
			print "interval=" interval
			done_interval = 1
			next
		}
		state == 0 && $0 ~ /#Check Core, from hottest to coldest/ {
			while ((getline line < ladfile) > 0) print line
			close(ladfile)
			state = 1
			next
		}
		state == 1 {
			if ($0 ~ /^[[:space:]]*if \[ "\$daemon" -eq 0 \]/) { state = 2 }
			else { next }
		}
		{ print }
		END { if (state != 2 || !done_interval) exit 3 }
	' "$src"
	local rc=$?
	rm -f "$lad"
	return $rc
}

# ----------------------------------------------------------------- emit ------
if [ "$ACTION" = emit ]; then
	[ -r "$EMIT_SRC" ] || die "cannot read $EMIT_SRC"
	# An already-changed file passes straight through, so that a caller can
	# emit-and-compare without having to know the state of its input.
	if ! grep -q "$MARKER" "$EMIT_SRC"; then
		recognised "$EMIT_SRC" || die "$EMIT_SRC is not the ladder this was written for"
	fi
	emit_patched "$EMIT_SRC" || die "the ladder block was not replaced in $EMIT_SRC"
	exit 0
fi

[ "$(id -u)" = 0 ] || die "run this with sudo"
[ -f "$VENDOR" ] || die "no $VENDOR — is this a Pyra?"

patched()  { grep -q "$MARKER" "$VENDOR"; }
freqfixed(){ grep -q "$FIXMARKER" "$VENDOR"; }

# A zone's temperature in whole degrees, found by type as the daemon itself
# finds them; zone numbering is not stable across kernels. Prints nothing if
# the zone does not exist.
zone_c() {
	local z
	for z in /sys/class/thermal/thermal_zone*; do
		if [ "$(cat "$z/type" 2>/dev/null)" = "$1" ]; then
			echo $(( $(cat "$z/temp") / 1000 ))
			return 0
		fi
	done
}
gauge_c()  { zone_c bq27421-0; }
# The hotter of the two SoC zones, which is what the new ladder reads.
cpu_c() {
	local a b
	a=$(zone_c core_thermal); b=$(zone_c cpu_thermal)
	if [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ]; then echo "$b"; else echo "${a:-$b}"; fi
}

state() {
	say "state"
	note "vendor script : $VENDOR"
	if patched; then
		note "ladder        : RECALIBRATED, board rungs from ${GAUGE_HOT5} mC, hysteresis ${PYRA_HYST} mC"
		note "poll          : $(grep -oE '^interval=[0-9]+' "$VENDOR" | cut -d= -f2)s, watching core_thermal and cpu_thermal"
	else
		note "ladder        : VENDOR, the gauge caps the CPU from 44 C with no hysteresis"
		note "poll          : $(grep -oE '^[[:space:]]*interval=[0-9]+' "$VENDOR" | grep -oE '[0-9]+')s, watching core_thermal only"
	fi
	if freqfixed; then
		note "cpufreq-set   : fixed, so the daemon can apply what it decides"
	else
		note "cpufreq-set   : NOT FIXED — run pyra-thermal-fix.sh first, or this"
		note "                change has nothing to act through"
	fi
	note "service       : $(systemctl is-active $SERVICE 2>/dev/null || echo inactive)"
	note "ceiling now   : $(cat $CPUFREQ/scaling_max_freq) kHz"
	note "core / cpu / gauge : $(zone_c core_thermal) C / $(zone_c cpu_thermal) C / $(gauge_c) C"
}

# ---------------------------------------------------------------- check ------
if [ "$ACTION" = check ]; then
	state
	echo
	if patched; then echo "Nothing to do."; else echo "Run this without --check to apply it."; fi
	exit 0
fi

# ----------------------------------------------------------------- undo ------
if [ "$ACTION" = undo ]; then
	[ -f "$BACKUP" ] || die "no backup at $BACKUP, so there is nothing to restore"
	cp -a "$BACKUP" "$VENDOR"
	rm -f "$BACKUP"
	systemctl restart "$SERVICE"
	say "restored the ladder that was there before this ran"
	note "the gauge caps the CPU from 44 C again, which is the vendor's behaviour"
	state
	exit 0
fi

# ---------------------------------------------------------------- apply ------
state

if patched; then
	say "already applied, nothing to do"
	exit 0
fi

freqfixed || note "WARNING: applying this anyway, but it will do nothing visible
  until pyra-thermal-fix.sh has been run. The daemon currently cannot apply any
  frequency decision at all."

recognised "$VENDOR" || die "the ladder in $VENDOR is not the one this was written
  for. Expected the vendor thresholds $EXPECT_CORE and $EXPECT_BATT.
  Refusing to guess at a ladder that has already been changed."

[ -f "$BACKUP" ] || cp -a "$VENDOR" "$BACKUP"

say "replacing the ladder"
TMP=$(mktemp)
emit_patched "$VENDOR" > "$TMP" || { rm -f "$TMP"; die "the ladder block was not replaced; nothing changed"; }

# Never install a thermal daemon that does not parse.
sh -n "$TMP" || { rm -f "$TMP"; die "the patched script is not valid shell; nothing changed"; }

cat "$TMP" > "$VENDOR"        # preserve the vendor file's mode and owner
rm -f "$TMP"
note "replaced, and it parses"
note "backup at $BACKUP"

# ------------------------------------------------------------- verify --------
# Prove the new ladder decides what it is supposed to decide, by running the
# daemon's own one-shot mode and reading what it prints, before trusting it
# with the machine.
say "checking what the new ladder decides at the temperatures right now"
OUT=$("$VENDOR" 2>&1) || die "the patched daemon exited non-zero:
$OUT"
echo "$OUT" | sed 's/^/    /'
DECIDED=$(echo "$OUT" | awk '/^MaxFreq:/ {print $2}')
[ -n "$DECIDED" ] || die "the patched daemon printed no decision"

G=$(gauge_c)
C=$(cpu_c)
[ -n "$G" ] && [ -n "$C" ] || die "could not find the core_thermal/cpu_thermal or bq27421-0
  zones by name, so the decision cannot be checked."
# Only assert when both sensors are below their first rung. If the core is
# genuinely hot right now then a cap is the correct answer and failing here
# would be the check being wrong, not the ladder. C is the hotter of the two
# SoC zones, because that is what the ladder reads.
if [ "$G" -lt $(( GAUGE_HOT5 / 1000 )) ] && [ "$C" -lt 77 ] && [ "$DECIDED" != 1500 ]; then
	die "the gauge is at ${G} C and the core at ${C} C, both below their first
  rung, and the ladder still chose ${DECIDED} MHz. That is not what this change
  was supposed to do; the vendor file has been left patched, run --undo."
fi
note "core ${C} C, gauge ${G} C, decision ${DECIDED} MHz"

say "restarting the daemon"
systemctl restart "$SERVICE"
sleep 25
systemctl is-active --quiet "$SERVICE" || die "the daemon did not stay running"
note "running, 25 seconds after the restart"

state
echo
echo "Done."
echo "Run with --check after any upgrade of the Pyra scripts: this edits a"
echo "packaged file and an upgrade will silently revert it."
