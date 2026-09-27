#!/bin/bash
#
# pyra-desktop-settings.sh — the MATE desktop settings the development setup
# depends on, applied to the logged-in user's dconf database.
#
#   ./pyra-desktop-settings.sh --check   say what the state is, change nothing
#   ./pyra-desktop-settings.sh           apply them, and verify they took
#   ./pyra-desktop-settings.sh --undo    put the MATE defaults back
#
# Run it as the desktop user (pyra), not root: gsettings writes the calling
# user's ~/.config/dconf/user. Over ssh it finds the session bus itself. The
# values persist across reboots on their own; this script exists so they also
# survive a reflash, a new user, or a restore from a backup taken before they
# were set (the 2026-09-26 card backup predates both).
#
# WHAT IT CHANGES, AND WHY
#
#   org.mate.power-manager notify-discharging    true -> false
#       USB power drops under load even when plugged in, and mate-power-manager
#       raises a "Battery Discharging" dialog. That dialog knocked Ship of
#       Harkinian out of fullscreen mid-benchmark, and the game saved the
#       smaller window size (Shipwright docs/pyra/TESTING.md, trap 22).
#
#   org.mate.power-manager notify-low-capacity   true -> false
#       The "battery may be old or broken" popup, driven by the bq27421 fuel
#       gauge's capacity estimate. Off for the same reason: nothing may pop up
#       over a running game. The low-battery warnings (notify-low-power) stay on.

set -u

SCHEMA=org.mate.power-manager
# key  wanted  default
SETTINGS=(
    "notify-discharging  false  true"
    "notify-low-capacity false  true"
)

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
fi

mode=${1:-apply}
case $mode in
    --check|apply|--undo) ;;
    *) echo "usage: $0 [--check|--undo]" >&2; exit 2 ;;
esac

rc=0
for line in "${SETTINGS[@]}"; do
    read -r key want def <<< "$line"
    [ "$mode" = --undo ] && want=$def
    cur=$(gsettings get $SCHEMA "$key") || { echo "$key: cannot read (no session bus?)" >&2; exit 1; }
    if [ "$mode" != --check ] && [ "$cur" != "$want" ]; then
        gsettings set $SCHEMA "$key" "$want"
        cur=$(gsettings get $SCHEMA "$key")
    fi
    if [ "$cur" = "$want" ]; then
        echo "$key=$cur ok"
    else
        echo "$key=$cur, want $want"
        rc=1
    fi
done
exit $rc
