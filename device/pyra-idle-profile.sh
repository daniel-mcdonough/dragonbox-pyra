#!/bin/bash
#
# pyra-idle-profile.sh — where the processor spends its idle time, and what
# that costs the battery.
#
#   ./pyra-idle-profile.sh            sample for 60 seconds
#   ./pyra-idle-profile.sh 300        sample for five minutes
#
# Written for one comparison in particular: this kernel tree removes OMAP5's
# retention idle state, leaving only wait-for-interrupt with the whole
# processor subsystem powered. `experiments/c2-idle` puts it back. Run this on
# each kernel, over the same idle machine, and compare.
#
# It reads sysfs and nothing else, changes nothing, and needs no privileges.
#
# Leave the machine alone while it runs. An idle profile of a machine somebody
# is typing on measures the typing.
#
set -euo pipefail

WINDOW=${1:-60}
case $WINDOW in ''|*[!0-9]*) echo "usage: $0 [seconds]" >&2; exit 2 ;; esac
[ "$WINDOW" -ge 5 ] || { echo "give it at least 5 seconds" >&2; exit 2; }

CPUIDLE=/sys/devices/system/cpu
BATT=/sys/class/power_supply/bq27421-0

[ -d "$CPUIDLE/cpu0/cpuidle" ] || { echo "no cpuidle on this kernel" >&2; exit 1; }

say() { printf '\n== %s\n' "$*"; }

say "what is idling"
printf '  kernel    %s\n' "$(uname -r)"
printf '  driver    %s\n' "$(cat $CPUIDLE/cpuidle/current_driver 2>/dev/null || echo unknown)"
printf '  governor  %s\n' "$(cat $CPUIDLE/cpuidle/current_governor 2>/dev/null ||
                             cat $CPUIDLE/cpuidle/current_governor_ro 2>/dev/null || echo unknown)"

# One line per state, so that a kernel with one state and a kernel with two
# are obviously different before any number is compared.
for d in "$CPUIDLE"/cpu0/cpuidle/state*; do
	printf '  %-6s %-24s exit %sus, needs %sus to be worth it\n' \
		"$(cat "$d/name")" "$(cat "$d/desc")" \
		"$(cat "$d/latency")" "$(cat "$d/residency")"
done

# ------------------------------------------------------------------ snapshot
snapshot() {
	local c d
	for c in "$CPUIDLE"/cpu[0-9]*; do
		[ -d "$c/cpuidle" ] || continue
		for d in "$c/cpuidle"/state*; do
			echo "$(basename "$c") $(basename "$d") $(cat "$d/usage") $(cat "$d/time")"
		done
	done
}

charge() { cat "$BATT/charge_now" 2>/dev/null || echo 0; }
current(){ cat "$BATT/current_now" 2>/dev/null || echo 0; }

say "sampling for ${WINDOW}s, leave it alone"
before=$(snapshot)
c_before=$(charge)
i_before=$(current)
s_before=$(cat "$BATT/status" 2>/dev/null || echo unknown)
t_before=$(date +%s)
sleep "$WINDOW"
after=$(snapshot)
c_after=$(charge)
i_after=$(current)
s_after=$(cat "$BATT/status" 2>/dev/null || echo unknown)
elapsed=$(( $(date +%s) - t_before ))

say "where the time went"
printf '  %-5s %-6s %12s %10s %9s\n' cpu state entries per-sec residency
echo "$after" | while read -r cpu st usage time; do
	b=$(echo "$before" | awk -v c="$cpu" -v s="$st" '$1==c && $2==s {print $3" "$4}')
	ub=${b%% *}; tb=${b##* }
	du=$(( usage - ub ))
	dt=$(( time - tb ))
	printf '  %-5s %-6s %12s %10s %8s%%\n' "$cpu" \
		"$(cat "$CPUIDLE/$cpu/cpuidle/$st/name")" "$du" \
		"$(awk -v a="$du" -v w="$elapsed" 'BEGIN{printf "%.1f", a/w}')" \
		"$(awk -v a="$dt" -v w="$elapsed" 'BEGIN{printf "%.1f", a/10000/w}')"
done

# Residency above 100% is normal and not a bug: two cores each idling most of
# the window add up to more wall clock than the window has.

say "what it cost"
printf '  battery status   %s at the start, %s at the end\n' "$s_before" "$s_after"
printf '  current, start   %s mA\n' "$(( i_before / 1000 ))"
printf '  current, end     %s mA\n' "$(( i_after / 1000 ))"
printf '  charge delta     %s uAh over %ss\n' "$(( c_after - c_before ))" "$elapsed"

# Negative current is the machine drawing from the battery, which is the only
# condition under which any of this measures the machine. A charger that cycles
# on and off during the window is worse than one that stays on, because the
# numbers look plausible and are not comparable to anything.
charging=no
if [ "$s_before" = Charging ] || [ "$s_after" = Charging ] ||
   [ "$(( i_before ))" -gt 0 ] || [ "$(( i_after ))" -gt 0 ]; then
	charging=yes
fi

if [ "$charging" = yes ]; then
	echo
	if [ "$s_before" = "$s_after" ] && [ "$s_before" = Charging ]; then
		echo "  The battery charged throughout, so every figure above is the"
		echo "  charger and none of it is the machine. Unplug it and run this"
		echo "  again."
	else
		echo "  The battery changed between charging and discharging during the"
		echo "  window, which is what a connected charger topping up looks like."
		echo "  The figures above are part machine and part charger, in unknown"
		echo "  proportions, and cannot be compared with another run. Unplug it"
		echo "  and run this again."
	fi
elif [ "$elapsed" -lt 600 ]; then
	echo
	echo "  A window this short is below the gauge's own resolution. The"
	echo "  current readings are usable; the charge delta is not. For a"
	echo "  number worth comparing between kernels, sample for an hour:"
	echo
	echo "      $0 3600"
fi
