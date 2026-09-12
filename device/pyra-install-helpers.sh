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
pyra-thermal-fix.sh                 /usr/local/sbin                    0755
pyra-anno1602-test.sh               /usr/local/sbin                    0755
pyra-usb3503-rescue                 /usr/local/sbin                    0755
pyra-keypad-rescue                  /usr/local/sbin                    0755
pyra-idle-dim                       /usr/local/bin                     0755
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
	echo "pyra-idle-dim.service                      ~/.config/systemd/user/ (per user)"
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
[ -r "$HERE/pyra-idle-dim.service" ] || die "pyra-idle-dim.service is missing"
note "all payloads present in $HERE"

# The user whose desktop session gets the dimmer. Under sudo this is the
# person who typed the command, not root.
TARGET_USER=${SUDO_USER:-}
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = root ]; then
	note "no non-root invoking user, so the idle dimmer will not be enabled"
else
	note "desktop helper will be enabled for: $TARGET_USER"
fi

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

# ------------------------------------------------------------- desktop helper
say "the idle dimmer"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = root ]; then
	note "skipped, see above"
else
	home=$(getent passwd "$TARGET_USER" | cut -d: -f6)
	uid=$(id -u "$TARGET_USER")
	unitdir=$home/.config/systemd/user
	if [ "$DRYRUN" = 1 ]; then
		note "would install pyra-idle-dim.service into $unitdir and enable it"
	else
		install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$unitdir"
		install -m 0644 -o "$TARGET_USER" -g "$TARGET_USER" \
			"$HERE/pyra-idle-dim.service" "$unitdir/pyra-idle-dim.service"
		note "installed $unitdir/pyra-idle-dim.service"
		# A user unit is enabled by that user's own systemd, not root's.
		# Without a live session there is nothing to talk to, which is
		# normal over SSH before anyone has logged in at the screen.
		if sudo -u "$TARGET_USER" \
			XDG_RUNTIME_DIR=/run/user/$uid \
			systemctl --user daemon-reload 2>/dev/null; then
			sudo -u "$TARGET_USER" XDG_RUNTIME_DIR=/run/user/$uid \
				systemctl --user enable --now pyra-idle-dim.service 2>/dev/null \
				&& note "enabled and started for $TARGET_USER" \
				|| note "installed but could not be started; log in at the screen and run:
     systemctl --user enable --now pyra-idle-dim.service"
		else
			note "installed; $TARGET_USER has no running session yet. After logging in:
     systemctl --user enable --now pyra-idle-dim.service"
		fi
	fi
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
    pyra-thermal-fix.sh --check       is the thermal daemon's fix still applied
    pyra-anno1602-test.sh             the box86 and Wine workload

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
