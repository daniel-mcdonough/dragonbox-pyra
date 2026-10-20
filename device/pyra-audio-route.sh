#!/bin/bash
#
# pyra-audio-route.sh — give the machine sound. It has never had any.
#
#   sudo ./pyra-audio-route.sh --check   say what the state is, change nothing
#   sudo ./pyra-audio-route.sh           apply it and verify
#   sudo ./pyra-audio-route.sh --undo    remove the rule and the helper
#
#        ./pyra-audio-route.sh --emit-into ROOT
#
# writes the two files below under ROOT instead of under /, touches nothing
# else, and does not care whether it is running on a Pyra. That mode is the
# door `pc/pyra-trixie-prep.sh` goes through to put this on a card offline, so
# a freshly prepared card has sound from its first boot. There is one
# implementation of the two files and every mode calls it.
#
# WHAT IS WRONG
#
# Nothing is broken. The codec is simply switched off, and has been since the
# image was built. The TWL6040 sends its DACs to the amplifiers through four
# enumerated ALSA controls, and on a stock Debian 13 card all four read `Off`:
#
#     Handsfree Left Playback    Off      (speakers)
#     Handsfree Right Playback   Off
#     Headset Left Playback      Off      (headphones)
#     Headset Right Playback     Off
#     Headset Playback Volume    0,0      (-30 dB, the floor)
#
# Everything upstream of those five controls is healthy and always was. ALSA
# enumerates the card, PulseAudio opens it, the PCM reaches `state: RUNNING`
# with a moving `hw_ptr`, `pactl` shows three unmuted sinks at 100%. The
# samples arrive at the DAC and the DAC is not connected to anything. Setting
# the four routes and lifting the headset volume produces sound immediately,
# on both outputs, with no reboot and no other change.
#
# WHY IT IS OFF
#
# `/var/lib/alsa/asound.state` shipped that way, and it is restored faithfully
# on every boot. `alsactl` is doing its job; the saved state is the bug. The
# file was captured on a machine whose codec was muted, so every boot since has
# replayed the silence. There is no UCM profile for this card to override it
# -- `alsa-restore` logs `failed to import hw:4 use case configuration -2` and
# falls back to the state file -- so the state file is the whole story.
#
# This is also why the volume wheel appeared dead. `pyra_volumed` (pyra-hacks)
# reads the encoder on `palmas-gpadc` and writes **`Handsfree` only**, through
# `snd_mixer_selem_set_playback_volume_all` on `hw:CARD=L15`. It sets a volume;
# it never sets a route. Turning the wheel was moving the speaker volume up and
# down a path that ended at an amplifier that was switched off.
#
# Two things follow, and both are worth knowing before touching the volumes:
#
#   * `Handsfree Playback Volume` belongs to `pyra_volumed`. Whatever this
#     script or `alsactl` writes there is overwritten the next time the wheel
#     moves. It is not ours to set, so we do not set it.
#   * `Headset Playback Volume` has no daemon behind it. The wheel does not
#     reach the headphones at all; only PulseAudio's software volume does. So
#     this one does need a sane floor, and it is the one that shipped at zero.
#
# WHAT IT DOES NOT FIX
#
# The empty `Hardware` tab in MATE's Sound Preferences is not this, and is not
# a fault. See fix 9 in `docs/fixes.md`.
#
set -eu

RULE_PATH=/etc/udev/rules.d/95-pyra-audio-route.rules
HELPER_PATH=/usr/local/sbin/pyra-audio-route-apply
CARD=L15

# the floor we put the headphone output at when it is found sitting at zero.
# 13 of 15 on a -30 dB..0 dB scale in 2 dB steps, so -4 dB: loud enough to be
# obviously working, short of the clipping the top of the range invites.
HS_FLOOR=13

emit_helper() {
	cat <<'EOF'
#!/bin/sh
# pyra-audio-route-apply — assert the TWL6040 and AESS output routing. Idempotent.
#
# Installed by pyra-audio-route.sh (fix 9). Runs from a udev rule on the
# sound card, ordered after 90-alsa-restore so it has the last word over
# whatever /var/lib/alsa/asound.state happens to contain.
set -u
AMIXER=/usr/bin/amixer
CARD=L15
[ -x "$AMIXER" ] || exit 0

get() { $AMIXER -c "$CARD" cget name="$1" 2>/dev/null | sed -n 's/^[[:space:]]*: values=//p'; }

# The four routes. Nothing else on the system manages these, so they are set
# unconditionally on every boot.
for pair in \
	'Handsfree Left Playback=HF DAC' \
	'Handsfree Right Playback=HF DAC' \
	'Headset Left Playback=HS DAC' \
	'Headset Right Playback=HS DAC'
do
	$AMIXER -c "$CARD" -q cset name="${pair%%=*}" "${pair#*=}" 2>/dev/null
done

# The AESS graph, on kernels that have the audio DSP. These are not
# preferences: with DL1 PDM or the sidetone mixer off, the playback front end
# has no path to a back end, hw:L15,5 refuses to open, and PulseAudio falls
# back to a dummy sink. alsa-restore saves them at every shutdown, so one
# session that switched them off used to break every boot after it. The
# direct-McPDM kernels have none of these controls; that is not an error.
if [ -n "$(get 'DL1 PDM Switch')" ]; then
	for pair in \
		'DL1 Mixer Multimedia=on' \
		'DL2 Mixer Multimedia=on' \
		'Sidetone Mixer Playback=on' \
		'DL1 PDM Switch=on'
	do
		$AMIXER -c "$CARD" -q cset name="${pair%%=*}" "${pair#*=}" 2>/dev/null ||
			logger -t pyra-audio-route "could not set ${pair%%=*}"
	done
	# The DSP gains, all at unity (120 = 0 dB; 0 is muted). None of them is a
	# user control -- PulseAudio does the volume and the wheel sets the codec --
	# so anything below unity is a leftover, and alsa-restore replays it on
	# every boot. DL2 Playback Volume sat at 113 for weeks that way, putting
	# the speakers 7 dB below the headphones. Set unconditionally.
	for c in 'DL1 Media Playback Volume' 'DL2 Media Playback Volume'; do
		$AMIXER -c "$CARD" -q cset name="$c" 120 2>/dev/null ||
			logger -t pyra-audio-route "could not set $c"
	done
	for c in 'DL1 Playback Volume' 'DL2 Playback Volume'; do
		$AMIXER -c "$CARD" -q cset name="$c" 120,120 2>/dev/null ||
			logger -t pyra-audio-route "could not set $c"
	done
fi

# The headphone volume, which has no daemon behind it, is only lifted when it
# is found at the floor. A value the user chose is left alone.
case "$(get 'Headset Playback Volume')" in
	'0,0'|'') $AMIXER -c "$CARD" -q cset name='Headset Playback Volume' 13,13 2>/dev/null ;;
esac

# Handsfree volume is pyra_volumed's, driven by the encoder wheel. Not ours.
exit 0
EOF
}

emit_rule() {
	cat <<'EOF'
# fix 9 — assert the TWL6040 and AESS output routing once the card is up.
#
# 95- so this runs after /lib/udev/rules.d/90-alsa-restore.rules, which
# replays /var/lib/alsa/asound.state. The shipped state file has every output
# route Off, and alsa-restore re-saves whatever is live at every shutdown;
# this rule is what puts them back regardless of what is in it.
ACTION=="add", SUBSYSTEM=="sound", KERNEL=="controlC*", ATTRS{id}=="L15", RUN+="/usr/local/sbin/pyra-audio-route-apply"
EOF
}

install_files() {
	root="$1"
	install -d -m 0755 "$root/usr/local/sbin" "$root/etc/udev/rules.d"
	emit_helper > "$root$HELPER_PATH"
	chmod 0755 "$root$HELPER_PATH"
	emit_rule > "$root$RULE_PATH"
	chmod 0644 "$root$RULE_PATH"
}

say_state() {
	echo "files:"
	for f in "$HELPER_PATH" "$RULE_PATH"; do
		if [ -e "$f" ]; then echo "  present  $f"; else echo "  ABSENT   $f"; fi
	done
	command -v amixer >/dev/null 2>&1 || { echo "amixer: not installed"; return 0; }
	amixer -c "$CARD" cget name='Handsfree Left Playback' >/dev/null 2>&1 || {
		echo "card $CARD: not present"; return 0; }
	echo "controls:"
	for c in 'Handsfree Left Playback' 'Handsfree Right Playback' \
	         'Headset Left Playback' 'Headset Right Playback' \
	         'Headset Playback Volume' 'Handsfree Playback Volume'; do
		v=$(amixer -c "$CARD" cget name="$c" 2>/dev/null | sed -n 's/^[[:space:]]*: values=//p')
		printf '  %-26s %s\n' "$c" "${v:-?}"
	done
	if amixer -c "$CARD" cget name='DL1 PDM Switch' >/dev/null 2>&1; then
		echo "AESS:"
		for c in 'DL1 PDM Switch' 'Sidetone Mixer Playback' \
		         'DL1 Mixer Multimedia' 'DL2 Mixer Multimedia' \
		         'DL1 Media Playback Volume' 'DL2 Media Playback Volume' \
		         'DL1 Playback Volume' 'DL2 Playback Volume'; do
			v=$(amixer -c "$CARD" cget name="$c" 2>/dev/null | sed -n 's/^[[:space:]]*: values=//p')
			printf '  %-26s %s\n' "$c" "${v:-?}"
		done
	fi
	echo "  (Handsfree Playback Volume is pyra_volumed's, from the wheel)"
}

case "${1:---apply}" in
--emit-into)
	root="${2:?--emit-into needs a ROOT}"
	install_files "$root"
	# bare paths, one per line: this is the contract pc/pyra-trixie-prep.sh
	# consumes, same as pyra-charge-current.sh.
	printf '%s\n%s\n' "$root$HELPER_PATH" "$root$RULE_PATH"
	;;
--check)
	say_state
	;;
--undo)
	[ "$(id -u)" = 0 ] || { echo "needs root" >&2; exit 1; }
	rm -f "$RULE_PATH" "$HELPER_PATH"
	udevadm control --reload 2>/dev/null || true
	echo "removed. the codec keeps its current routing until the next boot,"
	echo "when /var/lib/alsa/asound.state decides again."
	;;
--apply)
	[ "$(id -u)" = 0 ] || { echo "needs root" >&2; exit 1; }
	install_files ""
	udevadm control --reload 2>/dev/null || true
	"$HELPER_PATH"
	# belt and braces: also put the good routing in the state file, so a boot
	# that somehow misses the udev rule still comes up with sound.
	alsactl store 2>/dev/null || true
	echo "applied."
	say_state
	;;
*)
	sed -n '2,8p' "$0" >&2
	exit 1
	;;
esac
