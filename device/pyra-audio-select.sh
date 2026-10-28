#!/bin/bash
#
# pyra-audio-select.sh — give PulseAudio the script that matches the kernel.
#
#   sudo ./pyra-audio-select.sh            choose, at boot (what the unit runs)
#        ./pyra-audio-select.sh --check    say which path this kernel has and
#                                          which script PulseAudio will load
#
# WHAT IS WRONG
#
# Audio reaches the codec one of two ways, and which one depends on the kernel
# that booted (docs/audio.md, "Two paths, chosen by the kernel"):
#
#     AESS kernels (-m4, -m4-kbdled)   the audio DSP, hw:L15,5, MultiMedia1 LP
#                                      needs /etc/pulse/pyra-aess.pa
#     every other kernel               the direct McPDM link, hw:L15,0
#                                      needs the packaged /etc/pulse/pyra.pa
#
# Load the wrong one and PulseAudio falls back to auto_null, the desktop's
# "dummy output", for the whole session. A file in /etc can only ever name one
# of the two, and this machine boots both kinds of kernel.
#
# WHAT THIS DOES
#
# /etc/pulse/daemon.conf.d/zz-pyra-aess.conf is a symlink into /run, which
# starts empty on every boot. This script looks at the card the kernel built
# and, on an AESS kernel only, puts the AESS daemon.conf at the end of that
# link. On any other kernel the link stays dangling, PulseAudio skips it, and
# the packaged pyra.conf selects the packaged pyra.pa, untouched.
#
# The test is the one docs/audio.md gives: the front end MultiMedia1 LP exists
# only on a kernel with the AESS patches. The card registers all its PCMs
# before /proc/asound/L15 appears, so once that link exists the PCM list is
# complete. The card shows up about 20 s into boot, a few seconds before the
# display manager, which the unit waits for.
#
# If the card never appears there is no sound either way; the direct path is
# chosen, because it is the packaged configuration.
#
set -euo pipefail

CARD=/proc/asound/L15
WAIT=30					# seconds to wait for the card
PAYLOAD=/usr/local/share/pyra-audio/zz-pyra-aess.conf
RUNDIR=/run/pyra-audio
LINK=/etc/pulse/daemon.conf.d/zz-pyra-aess.conf

path() {
	if [ ! -e "$CARD" ]; then echo none
	elif grep -q 'MultiMedia1 LP' /proc/asound/pcm; then echo aess
	else echo direct
	fi
}

if [ "${1:-}" = --check ]; then
	p=$(path)
	echo "kernel   $(uname -r)"
	echo "path     $p"
	if [ -e "$LINK" ]; then
		echo "script   $(sed -n 's/^default-script-file *= *//p' "$LINK") (via $LINK)"
	else
		echo "script   $(sed -n 's/^default-script-file *= *//p' /etc/pulse/daemon.conf.d/pyra.conf) (packaged)"
	fi
	[ -L "$LINK" ] || echo "WARNING  $LINK is not a symlink; the choice is fixed, not made per boot"
	if [ "$p" = aess ] && [ ! -e "$LINK" ]; then echo "MISMATCH AESS kernel, packaged script"; exit 1; fi
	if [ "$p" = direct ] && [ -e "$LINK" ]; then echo "MISMATCH direct kernel, AESS script"; exit 1; fi
	echo "ok"
	exit 0
fi
case "${1:-}" in
"") ;;
-h|--help) sed -n '3,7p' "$0" | sed 's/^# \?//'; exit 0 ;;
*) echo "unknown argument: $1" >&2; exit 2 ;;
esac

[ "$(id -u)" = 0 ] || { echo "run this with sudo" >&2; exit 2; }

for _ in $(seq $((WAIT * 4))); do
	[ -e "$CARD" ] && break
	sleep 0.25
done

install -d -m 0755 "$RUNDIR"
case $(path) in
aess)
	if [ -r "$PAYLOAD" ]; then
		install -m 0644 "$PAYLOAD" "$RUNDIR/"
		echo "AESS kernel: PulseAudio gets /etc/pulse/pyra-aess.pa"
	else
		rm -f "$RUNDIR/zz-pyra-aess.conf"
		echo "AESS kernel, but $PAYLOAD is missing: packaged script, expect a dummy sink" >&2
	fi ;;
direct)
	rm -f "$RUNDIR/zz-pyra-aess.conf"
	echo "direct-link kernel: PulseAudio gets the packaged /etc/pulse/pyra.pa" ;;
none)
	rm -f "$RUNDIR/zz-pyra-aess.conf"
	echo "no card L15 after ${WAIT}s: packaged script" >&2 ;;
esac
[ -L "$LINK" ] || echo "note: $LINK is not a symlink, so this choice has no effect; run pyra-install-helpers.sh" >&2
