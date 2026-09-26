#!/bin/bash
#
# pyra-install-helpers.sh — put every device-side helper in this repository
# onto the Pyra, in one step.
#
#   sudo ./pyra-install-helpers.sh            install or update everything
#   sudo ./pyra-install-helpers.sh --dry-run  say what would change
#   sudo ./pyra-install-helpers.sh --list     say where each thing goes
#
# Copy the repository onto the device and run this from inside its `device`
# directory. Everything it touches lives under /usr/local, /etc/sysctl.d or
# the calling user's own systemd directory, so nothing here fights a Debian
# package or survives a reinstall of one.
#
# The idle dimmer and the brightness applet are no longer here. They are the
# pyra-backlight package, in its own repository. This removes any copies an
# earlier run of it left behind, since those would shadow the package's.
#
# It does not install a kernel: that is pyra-install-debug-kernel.sh, which
# this script puts on the path for you. It does not apply the six card fixes
# either: those are pc/pyra-trixie-prep.sh, applied offline before first boot.
#
# Every step is idempotent. Run it again after a `git pull`.
#
set -euo pipefail

DRYRUN=0
case "${1:-}" in
--dry-run) DRYRUN=1 ;;
--list)    DRYRUN=2 ;;
-h|--help) sed -n '3,19p' "$0" | sed 's/^# \?//'; exit 0 ;;
"")        ;;
*)         echo "unknown argument: $1" >&2; exit 2 ;;
esac

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# what                              where                              mode
MAP="
pyra-boot-kernel.sh                 /usr/local/sbin                    0755
pyra-install-debug-kernel.sh        /usr/local/sbin                    0755
pyra-sleep-test.sh                  /usr/local/sbin                    0755
pyra-modeset-hang-trap.sh           /usr/local/sbin                    0755
pyra-cpu-attribution.sh             /usr/local/sbin                    0755
pyra-x-load-profile.sh              /usr/local/sbin                    0755
pyra-idle-profile.sh                /usr/local/sbin                    0755
pyra-freq-profile.sh                /usr/local/sbin                    0755
pyra-governor-sweep.sh              /usr/local/sbin                    0755
pyra-governor-tune.sh               /usr/local/sbin                    0755
pyra-governor-tune.service          /etc/systemd/system                0644
pyra-thermal-fix.sh                 /usr/local/sbin                    0755
pyra-thermal-ladder.sh              /usr/local/sbin                    0755
pyra-thermal-probe.sh               /usr/local/sbin                    0755
pyra-ceiling-cost.sh                /usr/local/sbin                    0755
pyra-charge-probe.sh                /usr/local/sbin                    0755
pyra-charge-current.sh              /usr/local/sbin                    0755
pyra-chgwatch.sh                    /usr/local/sbin                    0755
pyra-anno1602-test.sh               /usr/local/sbin                    0755
pyra-m4-check.sh                    /usr/local/sbin                    0755
pyra-m4-run.sh                      /usr/local/sbin                    0755
pyra-usb3503-rescue                 /usr/local/sbin                    0755
pyra-keypad-rescue                  /usr/local/sbin                    0755
pyra-gles                           /usr/local/bin                     0755
etc/sysctl.d/90-pyra-lockup-capture.conf  /etc/sysctl.d                0644
pyra-exa-fallback-bench.c           /usr/local/src/pyra                0644
pyra-gles2-smoke.c                  /usr/local/src/pyra                0644
"

if [ "$DRYRUN" = 2 ]; then
	printf '%-42s %s\n' "FILE" "INSTALLED AS"
	while read -r src dst mode; do
		[ -n "$src" ] || continue
		printf '%-42s %s\n' "$src" "$dst/$(basename "$src")"
	done <<<"$MAP"
	echo
	echo "The two .c files are sources and are installed as sources. Each one"
	echo "carries its own compile line in its header comment; both need"
	echo "libx11-dev, which this image does not ship."
	exit 0
fi

[ "$(id -u)" = 0 ] || { echo "run this with sudo" >&2; exit 2; }

say()  { printf '\n== %s\n' "$*"; }
die()  { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

# ----------------------------------------------------------------- preflight
say "checking the checkout is complete"
missing=""
while read -r src dst mode; do
	[ -n "$src" ] || continue
	[ -r "$HERE/$src" ] || missing="$missing $src"
done <<<"$MAP"
[ -z "$missing" ] || die "not run from a complete checkout; missing:$missing"
note "all payloads present in $HERE"

# The user whose old per-user idle dimmer unit gets cleaned up. Under sudo
# this is the person who typed the command, not root.
TARGET_USER=${SUDO_USER:-}

# ------------------------------------------------------------------- install
say "installing"
changed=0
while read -r src dst mode; do
	[ -n "$src" ] || continue
	target=$dst/$(basename "$src")
	if [ -e "$target" ] && cmp -s "$HERE/$src" "$target"; then
		note "same      $target"
		continue
	fi
	verb=installed; [ -e "$target" ] && verb=updated
	if [ "$DRYRUN" = 1 ]; then
		note "would be $verb: $target"
	else
		install -d -m 0755 "$dst"
		install -m "$mode" -o 0 -g 0 "$HERE/$src" "$target"
		note "$verb $target"
	fi
	changed=1
done <<<"$MAP"

# --------------------------------------------------------------------- sysctl
say "applying the capture settings"
if [ "$DRYRUN" = 1 ]; then
	note "would run: sysctl --system"
else
	sysctl --system >/dev/null
	note "kernel.sysrq                        = $(sysctl -n kernel.sysrq)"
	note "kernel.softlockup_all_cpu_backtrace = $(sysctl -n kernel.softlockup_all_cpu_backtrace)"
fi

# --------------------------------------------------------------- system unit
# The governor setting is a sysfs write and does not survive a reboot, so the
# unit is what makes it persistent. Enabling is separate from installing
# because the map can copy a file but cannot tell systemd about it.
say "the governor setting"
if [ "$DRYRUN" = 1 ]; then
	note "would enable and start pyra-governor-tune.service"
else
	systemctl daemon-reload
	if systemctl enable --now pyra-governor-tune.service >/dev/null 2>&1; then
		note "enabled and started"
		note "$(/usr/local/sbin/pyra-governor-tune.sh --check | head -1)"
	else
		note "could not enable it; check: systemctl status pyra-governor-tune.service"
	fi
fi

# -------------------------------------------------- moved to pyra-backlight
# Earlier versions of this script installed the idle dimmer and the
# brightness applet by hand. Left in place, /usr/local/bin/pyra-idle-dim
# comes first on the PATH and the per-user unit overrides the package's, so
# the package would never run. The two /usr/share files carry the same names
# as the package's, so they are only removed while no package owns them.
say "copies now provided by the pyra-backlight package"
gone() {
	if [ "$DRYRUN" = 1 ]; then note "would remove $1"; else rm -f -- "$1"; note "removed $1"; fi
}
for f in /usr/local/bin/pyra-idle-dim /usr/local/libexec/pyra-brightness-applet; do
	[ -e "$f" ] && gone "$f"
done
for f in /usr/share/mate-panel/applets/org.pyra.BrightnessApplet.mate-panel-applet \
	/usr/share/dbus-1/services/org.mate.panel.applet.PyraBrightnessAppletFactory.service; do
	[ -e "$f" ] && ! dpkg -S "$f" >/dev/null 2>&1 && gone "$f"
done
if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != root ]; then
	home=$(getent passwd "$TARGET_USER" | cut -d: -f6)
	uid=$(id -u "$TARGET_USER")
	unit=$home/.config/systemd/user/pyra-idle-dim.service
	if [ -e "$unit" ]; then
		if [ "$DRYRUN" = 1 ]; then
			note "would disable and remove $unit"
		else
			sudo -u "$TARGET_USER" XDG_RUNTIME_DIR=/run/user/$uid \
				systemctl --user disable --now pyra-idle-dim.service >/dev/null 2>&1 || true
			rm -f "$home/.config/systemd/user/default.target.wants/pyra-idle-dim.service" "$unit"
			note "disabled and removed $unit"
			# Disabling it stopped the running dimmer. Start the
			# package's in its place rather than wait for a login.
			if sudo -u "$TARGET_USER" XDG_RUNTIME_DIR=/run/user/$uid \
				systemctl --user daemon-reload 2>/dev/null &&
			   dpkg -s pyra-backlight >/dev/null 2>&1 &&
			   sudo -u "$TARGET_USER" XDG_RUNTIME_DIR=/run/user/$uid \
				systemctl --user start pyra-idle-dim.service 2>/dev/null; then
				note "started the packaged pyra-idle-dim for $TARGET_USER"
			fi
		fi
	fi
fi
if dpkg -s pyra-backlight >/dev/null 2>&1; then
	note "pyra-backlight $(dpkg-query -W -f='${Version}' pyra-backlight) is installed"
else
	note "pyra-backlight is not installed; the screen will not dim on idle"
	note "until it is. Build it from its own repository with build-deb.sh."
fi

# --------------------------------------------------------------------- verify
[ "$DRYRUN" = 0 ] || { echo; echo "dry run, nothing was changed."; exit 0; }

say "verifying"
fail=0
while read -r src dst mode; do
	[ -n "$src" ] || continue
	target=$dst/$(basename "$src")
	if cmp -s "$HERE/$src" "$target"; then
		note "ok   $target"
	else
		note "BAD  $target does not match the checkout"; fail=1
	fi
done <<<"$MAP"
[ "$fail" = 0 ] || die "one of the files above did not install"

cat <<'EOF'

Done. What is now on the path:

    pyra-boot-kernel.sh status        which kernel boots next
    pyra-install-debug-kernel.sh      install a built kernel beside the stock one
    pyra-sleep-test.sh                suspend and prove it came back
    pyra-modeset-hang-trap.sh         provoke the display hang and capture it
    pyra-cpu-attribution.sh           account for every busy cycle
    pyra-x-load-profile.sh            the X server's share of a workload
    pyra-idle-profile.sh              where an idle machine spends its power
    pyra-freq-profile.sh              compare two kernels' cpufreq behaviour
    pyra-governor-sweep.sh            measure what each governor setting buys
    pyra-governor-tune.sh --check     is the governor setting applied (--undo to revert)
    pyra-thermal-fix.sh --check       is the thermal daemon's fix still applied
    pyra-thermal-ladder.sh --check    is its corrected ladder still applied
    pyra-charge-current.sh --check    can the machine charge while it runs
    pyra-chgwatch.sh                  watch the charge path, change nothing
    pyra-anno1602-test.sh             the box86 and Wine workload
    pyra-gles PROGRAM                 run a GLES2 program on the SGX, not on glvnd

The two benchmarks are installed as source, in /usr/local/src/pyra, because
both link against Xlib and this image does not ship libx11-dev:

    pyra-exa-fallback-bench.c         what the DDX's EXA fallbacks cost
    pyra-gles2-smoke.c                GLES2 through the SGX blob

Each carries its own compile line in its header. To build them:

    sudo apt install libx11-dev
    sed -n '1,20p' /usr/local/src/pyra/pyra-exa-fallback-bench.c

Two of these change the machine while they run and put it back afterwards:
pyra-governor-sweep.sh stops the thermal daemon and pins the frequency
ceiling, and pyra-modeset-hang-trap.sh is trying to provoke a hang. Read the
header of either before running it unattended.

docs/reproduce.md is the whole path from a blank card to this state.
EOF
