#!/bin/sh
# codec-state.sh -- the TWL6040's mic path while a capture runs (R103).
#
#   sudo sh codec-state.sh
#
# Selects the built-in mic (left) and the headset mic (right), starts a 6 s
# capture as the desktop user, and meanwhile prints the codec's mic registers
# (0x0A AMICBCTL .. 0x0E MICGAIN) and the DAPM state of every mic, bias and ADC
# widget. Stock kernel (direct link) only: on an AESS kernel the capture does
# not open (docs/audio.md, "Recording: the microphones"). Leaves both capture
# routes selected; set them back to Off afterwards.
user=${SUDO_USER:-pyra}
amixer -q -c L15 cset name="Analog Left Capture Route" "Main Mic"
amixer -q -c L15 cset name="Analog Right Capture Route" "Headset Mic"
su "$user" -c 'arecord -q -D hw:CARD=L15,DEV=0 -f S32_LE -r 88200 -c 2 -d 6 /dev/null' &
sleep 2
echo "== regmap (twl6040 0x0A AMICBCTL .. 0x0E MICGAIN)"
for r in /sys/kernel/debug/regmap/*004b*/registers; do echo "$r"; grep -E '^0?0?0[a-e]:' "$r"; done
echo "== dapm"
for f in /sys/kernel/debug/asoc/*/dapm/* /sys/kernel/debug/asoc/*/*/dapm/*; do
	case "$f" in *Mic*|*ADC*|*MAINMIC*|*HSMIC*) echo "-- $f"; head -3 "$f";; esac
done 2>/dev/null
wait
