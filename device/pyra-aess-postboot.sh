#!/bin/sh
# pyra-aess-postboot.sh -- the three things to look at on an AESS kernel boot.
#
#	sudo ./pyra-aess-postboot.sh
#
# Answers, in order, the questions 0022 left open:
#
#   1. did the McPDM back-end ports actually open?  ("Port pdmdl1 is not open"
#      was the symptom; 0022 removed the skip in omap_aess_dai_probe())
#   2. do they reach PORT_ENABLED when a stream plays?  opening a port touches
#      no hardware -- omap_aess_enable_data_transfer() from the back-end
#      trigger is what does -- so open-but-never-enabled is a distinct failure
#      from never-opened, and they need telling apart
#   3. does anything land in the McPDM downlink FIFO in DMEM?  all zero while
#      the PCM says RUNNING means the DSP is transmitting silence, which is
#      where this stood before 0022
#
# Reads only. The one thing it does is play six seconds of test tone.
#
# ALL ABE memory access must be 32-bit and aligned -- byte reads raise
# asynchronous external aborts that surface at whatever access happens next
# and blame the wrong line. busybox devmem defaults to the word width we want;
# /usr/bin/devmem2 on this image reads back 0x0 for every address and must not
# be used.  See the header of pyra-aess-run.py.

set -u

DMEM=0x40180000		# proven on hardware, not read from the DT
FIFO_OFF=0x3800		# DMEM_MCPDM_DL_FIFO
FIFO_WORDS=32
PORTS=/sys/kernel/debug/omap-aess/ports
DUR=6

devmem=$(command -v busybox >/dev/null 2>&1 && echo "busybox devmem")
[ -n "$devmem" ] || { echo "need busybox devmem; /usr/bin/devmem2 misreads" >&2; exit 1; }

# Prove the tool before trusting a zero from it. CONTROL_ID_CODE on an
# OMAP5432 ES2.0 is 0x1B99802F and cannot read as zero.
id=$($devmem 0x4A002204 32 2>/dev/null)
case "$id" in
0x1B99802F|0x1b99802f) ;;
*) echo "devmem sanity check failed: CONTROL_ID_CODE read as ${id:-nothing}" >&2
   echo "refusing to draw conclusions from anything else it returns" >&2; exit 1 ;;
esac

hr() { echo; echo "=== $* ==="; }

hr kernel
uname -r

hr card
aplay -l 2>&1 | sed -n '/L15/,$p' | head -20

hr "dmesg: aess, mcpdm, ports"
dmesg | grep -iE 'aess|mcpdm|not open' | tail -40

port_states() {
	[ -d "$PORTS" ] || { echo "  no $PORTS -- is CONFIG_DEBUG_FS on and the aess bound?"; return; }
	for p in "$PORTS"/*; do
		[ -d "$p" ] || continue
		s=$(cat "$p/state" 2>/dev/null)
		u=$(cat "$p/users" 2>/dev/null)
		case "$s" in 0) n=DISABLED ;; 1) n=ENABLED ;; *) n="?$s" ;; esac
		printf '  %-10s %-9s users=%s\n' "${p##*/}" "$n" "$u"
	done
}

hr "the playback path"
# None of these survive a reboot, and without them dpcm_path_get() finds no
# back end and the PCM will not even open ("no backend DAIs enabled").
# The graph runs MMLP Playback -> MM VMixer -> MM_DL -> DL1 Mixer[Multimedia]
# -> Sidetone Mixer[Playback] -> DL1 PDM[Switch] -> PDM_DL1 -> BE_OUT, so the
# Sidetone Mixer sits in the path whether or not sidetone is wanted.
for c in 'DL1 Mixer Multimedia' 'Sidetone Mixer Playback' 'DL1 PDM Switch'; do
	amixer -c L15 sset "$c" on >/dev/null 2>&1 &&
		echo "  on   $c" || echo "  MISSING  $c"
done
for c in 'DL1 Media Playback Volume' 'DL1 Playback Volume'; do
	amixer -c L15 sset "$c" 120 >/dev/null 2>&1 &&
		echo "  120  $c" || echo "  MISSING  $c"
done

hr "ports, idle"
port_states

fifo() {
	a=$(($DMEM + $FIFO_OFF))
	i=0
	nz=0
	out=""
	while [ $i -lt $FIFO_WORDS ]; do
		w=$($devmem $(printf '0x%x' $((a + i * 4))) 32 2>/dev/null)
		[ "$w" = 0x00000000 ] || nz=$((nz + 1))
		out="$out $w"
		i=$((i + 1))
	done
	echo "  non-zero words: $nz of $FIFO_WORDS"
	echo " $out" | tr ' ' '\n' | grep -v '^$' | head -8 | tr '\n' ' '
	echo
}

# McPDM's registers are NOT readable from /dev/mem here. Its target module is
# clock-gated whenever the driver is runtime-suspended, and a read then raises
# an asynchronous external abort -- which, being asynchronous, lands on some
# later unrelated access and blames it. An earlier version of this script did
# that and produced "Bus error" against an innocent line. Read the port state
# and the DMEM FIFO instead; between them they say the same thing without
# touching a gated bus.

hr "FIFO, idle"
fifo

hr "playing ${DUR}s"
# No -l: let it run and kill it, so the samples below are taken while the
# stream is definitely still open rather than racing its exit.
speaker-test -D hw:L15,5 -c 2 -r 48000 -t sine >${TMPDIR:-/var/tmp}/aess-st.log 2>&1 &
st=$!
sleep 2
if ! kill -0 $st 2>/dev/null; then
	echo "  speaker-test already exited -- it failed to open the device:"
	tail -5 ${TMPDIR:-/var/tmp}/aess-st.log
else
	echo "-- ports, playing --"; port_states
	echo "-- fifo, playing --"; fifo
	sleep 1
	echo "-- fifo, playing, second sample --"; fifo
	kill $st 2>/dev/null
	wait $st 2>/dev/null
fi

hr "the AESS internals, while it was playing"
# Collected in one pass so a boot costs one command's worth of battery.
speaker-test -D hw:L15,5 -c 2 -r 48000 -t sine \
	>${TMPDIR:-/var/tmp}/aess-st2.log 2>&1 &
st2=$!
sleep 2
if kill -0 $st2 2>/dev/null; then
	for mode in opp flow atc sched sweep; do
		echo "-- $mode --"
		pyra-aess-trace.py $mode 2>&1 | head -30
	done
	kill $st2 2>/dev/null
	wait $st2 2>/dev/null
else
	echo "  the second stream did not open:"
	tail -3 ${TMPDIR:-/var/tmp}/aess-st2.log
fi

hr "the reference path (bypasses the AESS entirely)"
# Needs legacy_link=1; see /etc/modprobe.d/pyra-aess-reference.conf.
if aplay -l 2>/dev/null | grep -q "TWL6040 Direct"; then
	echo "  playing 4 s on the direct McPDM link -- this one is known to work"
	timeout 6 speaker-test -D hw:L15,9 -c 2 -r 96000 -F S32_LE -t sine -l 1 \
		>/dev/null 2>&1
	echo "  done; if THAT was inaudible the problem is not the AESS"
else
	echo "  not present -- boot with legacy_link=1 to get it"
fi

hr "speaker-test said"
tail -15 ${TMPDIR:-/var/tmp}/aess-st.log

hr "dmesg since"
dmesg | grep -iE 'aess|mcpdm|not open|underrun|xrun' | tail -20
