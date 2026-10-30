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
# directory. Everything it touches lives under /usr/local, /etc or the calling
# user's own systemd directory, except the two PulseAudio mixer paths, which
# can only live in /usr/share/pulseaudio (docs/audio.md). Every file it
# installs has a pyra- name no Debian package uses, so nothing here fights a
# package.
#
# The idle dimmer and the brightness applet are no longer here. They are the
# pyra-backlight package, in its own repository. This removes any copies an
# earlier run of it left behind, since those would shadow the package's.
#
# It does not install a kernel: that is pyra-install-debug-kernel.sh, which
# this script puts on the path for you. It does install the two init-top hooks
# that keep root from mounting late, and rebuilds the initrd of every kernel in
# /boot whose initrd lacks them or predates them. It does not apply the fifteen
# card fixes: those are pc/pyra-trixie-prep.sh, applied offline before first boot.
# Fixes 13, 14 and 15 are the exception, since their files (pyra-gles, the two
# hooks and pyra-kbdlight.sh) are in the map below and land on the same paths
# prep uses, and fix 15's two lines in /etc/pyrainput.cfg are written by the
# same script prep calls.
#
# Every step is idempotent. Run it again after a `git pull`.
#
set -euo pipefail

DRYRUN=0
case "${1:-}" in
--dry-run) DRYRUN=1 ;;
--list)    DRYRUN=2 ;;
-h|--help) sed -n '3,/^# Every step/p' "$0" | sed 's/^# \?//'; exit 0 ;;
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
pyra-undervolt                      /usr/local/sbin                    0755
pyra-undervolt.service              /etc/systemd/system                0644
pyra-thermal-fix.sh                 /usr/local/sbin                    0755
pyra-thermal-ladder.sh              /usr/local/sbin                    0755
pyra-thermal-guard                  /usr/local/sbin                    0755
etc/dpkg/dpkg.cfg.d/pyra-thermal-guard /etc/dpkg/dpkg.cfg.d          0644
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
pyra-kbdlight.sh                    /usr/local/sbin                    0755
pyra-soh                            /usr/local/bin                     0755
pyra-cpu-pin                        /usr/local/sbin                    0755
etc/sudoers.d/pyra-cpu-pin          /etc/sudoers.d                     0440
etc/sysctl.d/90-pyra-lockup-capture.conf  /etc/sysctl.d                0644
pyra-exa-fallback-bench.c           /usr/local/src/pyra                0644
pyra-audio-select.sh                /usr/local/sbin                    0755
pyra-audio-select.service           /etc/systemd/system                0644
pulse/zz-pyra-aess.conf             /usr/local/share/pyra-audio        0644
pulse/pyra-aess.pa                  /etc/pulse                         0644
pulse/alsa-mixer/profile-sets/pyra-aess.conf /etc/pulse/pyra-alsa-mixer/profile-sets 0644
pulse/alsa-mixer/paths/pyra-speaker.conf     /usr/share/pulseaudio/alsa-mixer/paths  0644
pulse/alsa-mixer/paths/pyra-headphones.conf  /usr/share/pulseaudio/alsa-mixer/paths  0644
pyra-gles2-smoke.c                  /usr/local/src/pyra                0644
etc/initramfs-tools/scripts/init-top/pyra-fw-nofallback /etc/initramfs-tools/scripts/init-top 0755
etc/initramfs-tools/scripts/init-top/pyra-settle-nudge  /etc/initramfs-tools/scripts/init-top 0755
"

# The init-top hooks in the map above. Copying one changes no initrd, so each
# kernel's initrd is rebuilt below when it needs them.
HOOKDIR=/etc/initramfs-tools/scripts/init-top
HOOKS="pyra-fw-nofallback pyra-settle-nudge"

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

# A sudoers file that does not parse can take sudo away altogether, so it is
# checked before anything is copied.
for f in "$HERE"/etc/sudoers.d/*; do
	visudo -cqf "$f" || die "$f does not parse as sudoers; nothing installed"
done
note "sudoers rules parse"

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
	note "would enable and restart pyra-governor-tune.service"
else
	systemctl daemon-reload
	# restart, not start: the unit is a oneshot that stays active, so start
	# is a no-op on a machine where a governor switch has since reset the
	# tunable (a benchmark pin does that).
	if systemctl enable pyra-governor-tune.service >/dev/null 2>&1 &&
	   systemctl restart pyra-governor-tune.service >/dev/null 2>&1; then
		note "enabled and applied"
		note "$(/usr/local/sbin/pyra-governor-tune.sh --check | head -1)"
	else
		note "could not enable it; check: systemctl status pyra-governor-tune.service"
	fi
fi

# ---------------------------------------------------------- the Fn keys
# The keyboard-light keys reach pyra-kbdlight.sh through two lines in
# /etc/pyrainput.cfg (the script's header says why there). The script writes
# them itself, the same way prep's fix 15 does, and funkeymonkey rereads the
# file on a reload.
say "the Fn keyboard-brightness keys"
if [ "$DRYRUN" = 1 ]; then
	note "would point them at /usr/local/sbin/pyra-kbdlight.sh in /etc/pyrainput.cfg"
else
	/usr/local/sbin/pyra-kbdlight.sh --configure /etc/pyrainput.cfg 2>&1 |
		while read -r line; do note "$line"; done
	if systemctl reload pyrainput.service >/dev/null 2>&1; then
		note "pyrainput reloaded"
	else
		note "could not reload pyrainput; the keys take effect at the next boot"
	fi
fi

# ------------------------------------------------------- the audio script
# Which PulseAudio script is right depends on the kernel that booted, so the
# daemon.conf that picks the AESS one is a link into /run, filled in at each
# boot by pyra-audio-select.service (its header says how). A regular file
# here, from an install by hand, would pick the AESS script for every kernel;
# it is moved aside if its settings differ from the repository's, so nothing
# is lost.
say "the PulseAudio script, chosen per boot"
LINK=/etc/pulse/daemon.conf.d/zz-pyra-aess.conf
RUNFILE=/run/pyra-audio/zz-pyra-aess.conf
if [ "$(readlink "$LINK" 2>/dev/null)" = "$RUNFILE" ]; then
	note "same      $LINK -> $RUNFILE"
elif [ "$DRYRUN" = 1 ]; then
	note "would link $LINK -> $RUNFILE"
else
	if [ -f "$LINK" ] && [ ! -L "$LINK" ] &&
	   ! cmp -s <(grep -v '^#' "$LINK") <(grep -v '^#' "$HERE/pulse/zz-pyra-aess.conf"); then
		mv "$LINK" "$LINK.before-select"
		note "kept the old file as $LINK.before-select"
	fi
	install -d -m 0755 "$(dirname "$LINK")"
	ln -sfn "$RUNFILE" "$LINK"
	note "linked $LINK -> $RUNFILE"
fi
if [ "$DRYRUN" = 1 ]; then
	note "would enable and restart pyra-audio-select.service"
else
	systemctl daemon-reload
	if systemctl enable pyra-audio-select.service >/dev/null 2>&1 &&
	   systemctl restart pyra-audio-select.service >/dev/null 2>&1; then
		/usr/local/sbin/pyra-audio-select.sh --check | sed 's/^/  /' || true
		note "a PulseAudio already running keeps its script until it restarts:"
		note "systemctl --user restart pulseaudio.service"
	else
		note "could not enable it; check: systemctl status pyra-audio-select.service"
	fi
fi

# ---------------------------------------------------------------- undervolt
# The CPU's 750 MHz point at 870 mV instead of 950 (experiments/undervolt).
# Like the governor setting it is a runtime change, so the unit is what makes
# it persistent; it is applied now as well. restart, not start, for the same
# reason as above, and so that a changed POINTS takes effect.
say "the undervolt"
# The module is a build product (gitignored): experiments/undervolt/build-module.sh
# leaves it in device/lib/. Without it the unit is installed but stays inert.
KO=$HERE/lib/pyra_undervolt.ko
if [ ! -r "$KO" ]; then
	note "no lib/pyra_undervolt.ko; build it with experiments/undervolt/build-module.sh"
elif [ "$DRYRUN" = 1 ]; then
	cmp -s "$KO" /usr/local/lib/pyra-undervolt/pyra_undervolt.ko || note "would install /usr/local/lib/pyra-undervolt/pyra_undervolt.ko"
else
	install -d -m 0755 /usr/local/lib/pyra-undervolt
	install -m 0644 -o 0 -g 0 "$KO" /usr/local/lib/pyra-undervolt/pyra_undervolt.ko
	note "module in /usr/local/lib/pyra-undervolt"
fi
if [ "$DRYRUN" = 1 ]; then
	note "would enable and restart pyra-undervolt.service"
else
	systemctl daemon-reload
	if systemctl enable pyra-undervolt.service >/dev/null 2>&1 &&
	   systemctl restart pyra-undervolt.service >/dev/null 2>&1; then
		note "enabled and applied"
		/usr/local/sbin/pyra-undervolt status | grep -E 'running|smps123' | sed 's/^/  /'
	else
		note "could not enable it; check: systemctl status pyra-undervolt.service"
	fi
fi

# ----------------------------------------------------------- the initramfs
# pyra-fw-nofallback and pyra-settle-nudge run inside the initramfs
# (docs/troubleshooting.md, "Root mounts a minute or two late"), so a kernel
# only gets them when its initrd is rebuilt. An initrd is rebuilt when it does
# not list both hooks, or is older than either installed hook (one this run, or
# a run that stopped before its rebuild, just changed). Otherwise it is left
# alone, so a second run rebuilds nothing. Only initrds that already exist are
# touched: a kernel without one is not booted through an initramfs here.
# update-initramfs takes about 20 s per kernel on the Pyra, writes the new initrd
# beside the old one before replacing it, and /boot is small, so free space is
# checked before each.
say "the initramfs hooks, in each kernel's initrd"
initrd_needs() {	# initrd -> true when it must be rebuilt
	local h t
	for h in $HOOKS; do
		t=$HOOKDIR/$h
		# dry run: a hook that would be installed or updated above
		cmp -s "$HERE/etc/initramfs-tools/scripts/init-top/$h" "$t" 2>/dev/null || return 0
		[ "$t" -nt "$1" ] && return 0
		lsinitramfs "$1" 2>/dev/null | grep -x "scripts/init-top/$h" >/dev/null || return 0
	done
	return 1
}
rebuild_fail=""
for initrd in /boot/initrd.img-*; do
	[ -f "$initrd" ] || continue
	rel=${initrd#/boot/initrd.img-}
	if [ ! -d "/lib/modules/$rel" ]; then
		note "skipped   $initrd (no /lib/modules/$rel to build it from)"
		continue
	fi
	if ! initrd_needs "$initrd"; then
		note "same      $initrd"
		continue
	fi
	if [ "$DRYRUN" = 1 ]; then
		note "would rebuild $initrd"
		continue
	fi
	need=$(( $(stat -c %s "$initrd") / 1024 + 2048 ))
	free=$(df -Pk /boot | awk 'NR==2{print $4}')
	if [ "$free" -lt "$need" ]; then
		note "NOT rebuilt $initrd: /boot has ${free} KB free, needs about ${need} KB"
		rebuild_fail="$rebuild_fail $rel"
		continue
	fi
	note "rebuilding $initrd (about 20 s)"
	if update-initramfs -u -k "$rel" >/dev/null 2>&1; then
		note "rebuilt   $initrd"
	else
		rm -f -- "$initrd.new"
		note "FAILED    update-initramfs -u -k $rel; run it by hand to see why"
		rebuild_fail="$rebuild_fail $rel"
	fi
done
note "/boot: $(df -Ph /boot | awk 'NR==2{print $4}') free"

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
for initrd in /boot/initrd.img-*; do
	[ -f "$initrd" ] && [ -d "/lib/modules/${initrd#/boot/initrd.img-}" ] || continue
	if initrd_needs "$initrd"; then
		note "BAD  $initrd lacks a hook, or predates one"; fail=1
	else
		note "ok   $initrd has both init-top hooks"
	fi
done
[ "$fail" = 0 ] || die "rebuild the initrds above:${rebuild_fail:- see above}"

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
    pyra-thermal-guard                run by dpkg after every package run: puts
                                      both back if a pyra-hacks reinstall reverts them
    pyra-charge-current.sh --check    can the machine charge while it runs
    pyra-chgwatch.sh                  watch the charge path, change nothing
    pyra-anno1602-test.sh             the box86 and Wine workload
    pyra-gles PROGRAM                 run a GLES2 program on the SGX, not on glvnd
    pyra-soh [--check]                Ship of Harkinian, pinned at 750 MHz while it runs
    pyra-cpu-pin status               is a game holding the CPU clock (sudo)
    pyra-audio-select.sh --check      does PulseAudio's script match the kernel
    pyra-undervolt status             the CPU's voltages, and the 750 MHz undervolt (sudo)

In every kernel's initrd, two init-top hooks against a late root mount:

    pyra-fw-nofallback                no 60 s wait for absent firmware
    pyra-settle-nudge                 wakes udevadm settle if it sleeps on

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
