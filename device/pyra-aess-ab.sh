#!/bin/sh
#
# pyra-aess-ab.sh -- compare the DSP against the direct link, honestly.
#
#   pyra-aess-ab.sh [file.wav]     A/B/A on one clip
#   pyra-aess-ab.sh bass           80 Hz vs 1 kHz through both paths
#
# WHY THIS EXISTS
#
# Every A/B before this one compared the DSP *through PulseAudio* against the
# direct link *through aplay*, because `aplay -D hw:L15,5` fails with "Device
# or resource busy" whenever the PulseAudio sink holds the PCM -- and that
# failure went to /dev/null, so it was invisible. Two things changed at once
# in every result. Here both clips go through aplay with the sink suspended,
# so the only difference is the DSP.
#
# The file must be 48 kHz. The AESS runs a fixed 48 kHz schedule; it used to
# advertise 44100 and play it 8.84% fast (see experiments/aess/0029). The
# direct link only does 88.2/96 kHz S32_LE, so plughw has to convert for it --
# that is inherent to the comparison, not a flaw in it.
#
set -eu

DSP=hw:L15,5           # MultiMedia1 LP, through the AESS
DIRECT=plughw:L15,9    # McPDM, bypassing the AESS

play_dsp()    { echo "  [DSP]    $1"; aplay -q -D "$DSP" "$1" || echo "  FAILED"; }
play_direct() { echo "  [direct] $1"; aplay -q -D "$DIRECT" "$1" || echo "  FAILED"; }

pactl suspend-sink aess 1 2>/dev/null || true
trap 'pactl suspend-sink aess 0 2>/dev/null || true' EXIT
sleep 1

case "${1:-}" in
bass)
	# If the DSP path is "tinny", the question is whether it is losing bass
	# or adding harshness. Equal-amplitude 80 Hz and 1 kHz tones answer it:
	# a bass loss shows up as the 80 Hz tone being quieter through the DSP
	# than through the direct link, while the 1 kHz tone matches.
	for f in /var/tmp/f80.wav /var/tmp/f1000.wav; do
		[ -f "$f" ] || { echo "missing $f"; exit 1; }
		echo "=== $f"
		play_direct "$f"; sleep 1; play_dsp "$f"; sleep 2
	done
	;;
*)
	f=${1:-/var/tmp/song48.wav}
	[ -f "$f" ] || { echo "no such file: $f"; exit 1; }
	rate=$(soxi -r "$f" 2>/dev/null || echo 48000)
	[ "$rate" = 48000 ] || echo "WARNING: $f is $rate Hz, not 48000"
	echo "=== A: the DSP ==="   ; play_dsp    "$f"; sleep 2
	echo "=== B: direct link ===" ; play_direct "$f"; sleep 2
	echo "=== A again: the DSP ==="; play_dsp  "$f"
	;;
esac
