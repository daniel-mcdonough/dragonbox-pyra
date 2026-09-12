#!/bin/bash
#
# pyra-thermal-fix.sh — make the Pyra's thermal daemon able to apply its own
# decision.
#
#   sudo ./pyra-thermal-fix.sh --check    say what the state is, change nothing
#   sudo ./pyra-thermal-fix.sh            apply the fix, restart, verify
#   sudo ./pyra-thermal-fix.sh --undo     put the vendor file back
#
# WHAT IS WRONG
#
# `/usr/share/pyra/scripts/pyra-thermal.sh` reads the core and battery
# temperatures every 20 seconds, decides a maximum CPU frequency, and applies
# it by calling `cpufreq-set`. That program is not installed, and it cannot be
# installed: it came from `cpufrequtils`, which is not in trixie at all and has
# no candidate version. So the daemon has read the sensors, chosen a cap and
# failed to apply it on every cycle since the image's first boot:
#
#   pyra-thermal.sh[2000]: pyra-thermal.sh: 89: cpufreq-set: not found
#
# The next line of the same function writes the charging limit, and that one is
# a plain redirection, so it works. There is no `set -e` to stop in between.
# The daemon has therefore been managing the charger correctly and the CPU not
# at all, while looking healthy in `systemctl status`.
#
# That leaves the kernel's `step_wise` governor as the only thing limiting
# frequency for heat, and it is not enough on its own: two cores of `7z b`
# take this machine seven degrees past its 100 C passive trip in under two
# minutes. See `docs/improvements.md` item 2.
#
# WHAT THIS DOES
#
# Replaces the one `cpufreq-set` call with a direct write to
# `scaling_max_freq`, which is all `cpufreq-set -u` ever did, and which needs
# nothing installed. The daemon already runs as root. Everything else in the
# vendor script is left exactly as it is, including its thermal ladder, on
# purpose: the ladder is the vendor's policy and this is a fix for the one
# line that cannot work, not a rewrite.
#
# Both cores share one cpufreq policy on this SoC, so one write covers both.
# The loop is over every policy anyway, because that costs nothing and is
# right on a machine where it is not true.
#
# CAVEAT WORTH KNOWING
#
# This edits a file shipped by a package. `/usr/share` is not a conffile
# location, so an upgrade of the Pyra scripts will silently put the broken
# version back. `--check` detects that; run it after any upgrade. The proper
# home for this fix is upstream, and it is on the report list.
#
set -euo pipefail

VENDOR=/usr/share/pyra/scripts/pyra-thermal.sh
BACKUP=$VENDOR.before-pyra-thermal-fix
MARKER='pyra-thermal-fix'
SERVICE=pyra-thermal.service
CPUFREQ=/sys/devices/system/cpu/cpu0/cpufreq

ACTION=apply
case "${1:-}" in
	--check) ACTION=check ;;
	--undo)  ACTION=undo ;;
	-h|--help) sed -n '3,52p' "$0" | sed 's/^# \?//'; exit 0 ;;
	"") ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
esac

say()  { printf '\n== %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die()  { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run this with sudo"
[ -f "$VENDOR" ] || die "no $VENDOR — is this a Pyra?"

patched() { grep -q "$MARKER" "$VENDOR"; }
broken()  { grep -qE '^[[:space:]]*cpufreq-set -u' "$VENDOR"; }

state() {
	say "state"
	note "vendor script : $VENDOR"
	if patched; then
		note "frequency cap : PATCHED, applied by writing scaling_max_freq"
	elif broken; then
		note "frequency cap : BROKEN, calls cpufreq-set which is not installed"
	else
		note "frequency cap : UNRECOGNISED — neither the vendor line nor this fix"
	fi
	note "cpufreq-set   : $(command -v cpufreq-set || echo 'not installed')"
	note "service       : $(systemctl is-active $SERVICE 2>/dev/null || echo inactive)"
	note "scaling_max   : $(cat $CPUFREQ/scaling_max_freq) kHz"
	local fails
	fails=$(journalctl -u "$SERVICE" --no-pager 2>/dev/null | grep -c 'cpufreq-set: not found' || true)
	note "failed calls in the current journal: ${fails:-0}"
}

# ---------------------------------------------------------------- check ------
if [ "$ACTION" = check ]; then
	state
	echo
	if patched; then
		echo "Nothing to do."
	else
		echo "Run this without --check to fix it."
	fi
	exit 0
fi

# ----------------------------------------------------------------- undo ------
if [ "$ACTION" = undo ]; then
	[ -f "$BACKUP" ] || die "no backup at $BACKUP, so there is nothing to restore"
	cp -a "$BACKUP" "$VENDOR"
	rm -f "$BACKUP"
	systemctl restart "$SERVICE"
	say "restored the vendor script and restarted the daemon"
	note "the frequency cap is broken again, which is the vendor's behaviour"
	state
	exit 0
fi

# ---------------------------------------------------------------- apply ------
state

if patched; then
	say "already applied, nothing to do"
	exit 0
fi

broken || die "the line this fix replaces is not in $VENDOR.
  Expected a line calling 'cpufreq-set -u'. Refusing to guess at a script
  that is not the one this was written for."

[ -f "$BACKUP" ] || cp -a "$VENDOR" "$BACKUP"

say "patching the one line that cannot work"
TMP=$(mktemp)
awk -v marker="$MARKER" '
	# The vendor line, whatever it is indented with.
	$0 ~ /^[[:space:]]*cpufreq-set -u \$\{current_maxFreq\}MHz[[:space:]]*$/ {
		print "\t# " marker ": cpufreq-set came from cpufrequtils, which is not in"
		print "\t# trixie and has no candidate version, so this call failed on every"
		print "\t# cycle since the first boot and the daemon never capped anything."
		print "\t# Writing scaling_max_freq is what cpufreq-set -u did, and needs"
		print "\t# nothing installed. Both cores share one policy on this SoC."
		print "\tfor _policy in /sys/devices/system/cpu/cpufreq/policy*; do"
		print "\t\t[ -w \"$_policy/scaling_max_freq\" ] || continue"
		print "\t\techo $((current_maxFreq * 1000)) > \"$_policy/scaling_max_freq\""
		print "\tdone"
		done_patch = 1
		next
	}
	{ print }
	END { if (!done_patch) exit 3 }
' "$VENDOR" > "$TMP" || { rm -f "$TMP"; die "the line was not replaced; nothing changed"; }

# Never install a thermal daemon that does not parse.
sh -n "$TMP" || { rm -f "$TMP"; die "the patched script is not valid shell; nothing changed"; }

cat "$TMP" > "$VENDOR"        # preserve the vendor file's mode and owner
rm -f "$TMP"
note "patched, and it parses"
note "backup at $BACKUP"

say "restarting the daemon"
systemctl restart "$SERVICE"

# ------------------------------------------------------------- verify --------
# Prove the write path works rather than assuming it. Move the cap somewhere
# it should not be, run the daemon's own one-shot mode, and see it corrected.
say "verifying that the daemon can now move the cap"
ORIG=$(cat "$CPUFREQ/scaling_max_freq")
note "cap before the test: $ORIG kHz"
echo 750000 > "$CPUFREQ/scaling_max_freq"
note "cap forced down to : $(cat $CPUFREQ/scaling_max_freq) kHz"
"$VENDOR" >/dev/null 2>&1 || true
AFTER=$(cat "$CPUFREQ/scaling_max_freq")
note "cap after one pass : $AFTER kHz"
if [ "$AFTER" = 750000 ]; then
	echo 1500000 > "$CPUFREQ/scaling_max_freq" 2>/dev/null || true
	die "the daemon did not move the cap. The fix is in place but not working."
fi
note "the daemon moved it, so the write path works"

sleep 25
FAILS=$(journalctl -u "$SERVICE" --since "-25s" --no-pager 2>/dev/null | grep -c 'cpufreq-set: not found' || true)
if [ "${FAILS:-0}" -gt 0 ]; then
	die "still $FAILS failures in the last 25 seconds"
fi
note "no failures in the 25 seconds since the restart"

state
echo
echo "Done. The daemon now applies its own thermal decisions."
echo "Run with --check after any upgrade of the Pyra scripts: this edits a"
echo "packaged file and an upgrade will silently revert it."
