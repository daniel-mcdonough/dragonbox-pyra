#!/bin/bash
#
# pyra-greeter-audio.sh — stop the login greeter stealing the sound card.
#
#   sudo ./pyra-greeter-audio.sh --check   say what the state is, change nothing
#   sudo ./pyra-greeter-audio.sh           apply it and verify
#   sudo ./pyra-greeter-audio.sh --undo    put the stock behaviour back
#
#        ./pyra-greeter-audio.sh --emit-into ROOT
#
# writes the two files below under ROOT instead of under /, touches nothing
# else, and does not care whether it is running on a Pyra. That mode is the
# door `pc/pyra-trixie-prep.sh` goes through to put this on a card offline, so
# a freshly prepared card is not silent on the boots where it loses the race.
#
# WHAT IS WRONG
#
# On some boots the desktop session comes up with no sound at all and no way
# back except restarting PulseAudio by hand. Measured on this machine it hit
# 2 of the 6 boots on record. The sequence:
#
#     15:59:38  card (L15) registers
#     15:59:45  user@105 — the lightdm greeter — starts
#     15:59:52  greeter pulseaudio STARTED, holding hw:CARD=L15
#     15:59:59  user@1000 starts
#     16:00:00  session pulseaudio FAILS: device busy
#     16:00:14  greeter pulseaudio stops — fourteen seconds too late
#
# The greeter runs a PulseAudio of its own. `/etc/pulse/pyra.pa` opens the
# codec as a raw ALSA device with `module-alsa-sink`, which is an exclusive
# open, so whichever instance gets there first owns the card outright. When
# the greeter wins, the user's daemon logs
#
#     Failed to load module "module-alsa-sink" (...): initialization failed
#     Master sink not found
#
# and both `module-remap-sink` instances fail behind it, taking the `speakers`
# and `headphones` sinks with them. PulseAudio does not retry, so the session
# is left on `auto_null` — a silent dummy sink — until something restarts it.
# The greeter releases the card fourteen seconds later and nothing notices.
#
# This is not the same fault as fix 9 and does not overlap with it. Fix 9 was
# the codec shipping switched off, which silenced every boot. This silences a
# minority of boots on top of that, which is why it stayed hidden: it looked
# like the same bug intermittently failing to be fixed.
#
# WHY NOT ARBITRATE INSTEAD
#
# A stock PulseAudio uses `module-udev-detect`, which claims cards through
# ALSA's own reservation protocol and hands them over politely. `pyra.pa`
# cannot: it needs the card opened as one 4-channel device so the two
# `module-remap-sink` instances can split front (headphones) from rear
# (speakers), and that means a raw exclusive open with no arbitration. Going
# back to `module-udev-detect` would fix the race and destroy the separate
# Speakers and Headphones sinks. Not worth it — see fix 9.
#
# So the fix is to remove the second claimant rather than teach the two to
# share. A login greeter on a handheld has no use for audio: the only thing
# that normally wants it is an accessibility reader at the login prompt, which
# this machine does not run. If you ever need one, `--undo` puts it back.
#
# HOW
#
# A drop-in under /etc/systemd/user, which takes precedence over the packaged
# units in /usr/lib/systemd/user and leaves them untouched, so an upgrade will
# not revert it. `ConditionUser=!lightdm` is evaluated by each user's own
# systemd instance against the user it is running as, so the unit is skipped
# in the greeter's manager and runs normally in everyone else's. One file for
# the service and one for the socket, because the socket would otherwise
# start the service on the first connection.
#
set -eu

GREETER=lightdm
SVC_DIR=/etc/systemd/user/pulseaudio.service.d
SOCK_DIR=/etc/systemd/user/pulseaudio.socket.d
SVC_CONF=$SVC_DIR/10-no-greeter.conf
SOCK_CONF=$SOCK_DIR/10-no-greeter.conf

emit_conf() {
	cat <<EOF
# fix 10 — keep the login greeter off the sound card.
#
# /etc/pulse/pyra.pa opens the codec as a raw ALSA device, which is an
# exclusive open with no arbitration. When the greeter's PulseAudio wins that
# race the user's session is left on a silent auto_null sink for the rest of
# its life, because PulseAudio does not retry.
#
# Evaluated by each user's own systemd instance against the user it runs as:
# skipped for $GREETER, runs normally for everyone else.
[Unit]
ConditionUser=!$GREETER
EOF
}

install_files() {
	root="$1"
	install -d -m 0755 "$root$SVC_DIR" "$root$SOCK_DIR"
	emit_conf > "$root$SVC_CONF";  chmod 0644 "$root$SVC_CONF"
	emit_conf > "$root$SOCK_CONF"; chmod 0644 "$root$SOCK_CONF"
}

say_state() {
	echo "files:"
	for f in "$SVC_CONF" "$SOCK_CONF"; do
		if [ -e "$f" ]; then echo "  present  $f"; else echo "  ABSENT   $f"; fi
	done
	if id "$GREETER" >/dev/null 2>&1; then
		uid=$(id -u "$GREETER")
		echo "greeter:  $GREETER (uid $uid)"
		if pgrep -u "$uid" -x pulseaudio >/dev/null 2>&1; then
			echo "  RUNNING  a pulseaudio owned by the greeter — it holds the card"
		else
			echo "  clear    no pulseaudio owned by the greeter"
		fi
	else
		echo "greeter:  $GREETER not present on this system"
	fi
	echo "session sinks:"
	# under sudo we are root, and root cannot reach the desktop user's daemon.
	# Reach back into the invoking user's session so --check is useful there,
	# which is how it will nearly always be run.
	sinks=""
	# runuser wants a name, not a uid, so resolve one. SUDO_USER is normally
	# already it; getent covers a sudo that did not export it.
	who="${SUDO_USER:-}"
	[ -z "$who" ] && [ -n "${SUDO_UID:-}" ] && \
		who=$(getent passwd "$SUDO_UID" 2>/dev/null | cut -d: -f1)
	if [ -n "$who" ] && [ "${SUDO_UID:-0}" != 0 ]; then
		sinks=$(runuser -u "$who" -- env \
			XDG_RUNTIME_DIR="/run/user/${SUDO_UID}" \
			pactl list short sinks 2>/dev/null) || sinks=""
	fi
	if [ -z "$sinks" ] && command -v pactl >/dev/null 2>&1; then
		sinks=$(pactl list short sinks 2>/dev/null) || sinks=""
	fi
	if [ -n "$sinks" ]; then
		printf '%s\n' "$sinks" | sed 's/^/  /'
		case "$sinks" in
			*auto_null*) echo "  ^ auto_null is the silent fallback: the card was lost this boot" ;;
		esac
	else
		echo "  (no reachable PulseAudio from here)"
	fi
}

case "${1:---apply}" in
--emit-into)
	root="${2:?--emit-into needs a ROOT}"
	install_files "$root"
	# bare paths, one per line: the contract pc/pyra-trixie-prep.sh consumes.
	printf '%s\n%s\n' "$root$SVC_CONF" "$root$SOCK_CONF"
	;;
--check)
	say_state
	;;
--undo)
	[ "$(id -u)" = 0 ] || { echo "needs root" >&2; exit 1; }
	rm -f "$SVC_CONF" "$SOCK_CONF"
	rmdir "$SVC_DIR" "$SOCK_DIR" 2>/dev/null || true
	systemctl daemon-reload 2>/dev/null || true
	echo "removed — the greeter will start its own PulseAudio again from the next boot."
	;;
--apply)
	[ "$(id -u)" = 0 ] || { echo "needs root" >&2; exit 1; }
	install_files ""
	systemctl daemon-reload 2>/dev/null || true
	echo "applied."
	say_state
	;;
*)
	sed -n '2,8p' "$0" >&2
	exit 1
	;;
esac
