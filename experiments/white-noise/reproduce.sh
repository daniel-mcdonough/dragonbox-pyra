#!/bin/bash
# R79 reproducer, run on the Pyra as the desktop user with make-tones.py's
# files in the current directory:
#   bash reproduce.sh [cycles] [long]        # defaults 20 1
#   PULSE_SINK=headphones bash reproduce.sh  # direct link: pick the remap sink
# Each cycle suspends the first (hardware) sink for 1 s, so the PCM closes and
# reopens as it does at a game's first sound, then plays 3 s of silence and a
# beep. Then two minutes of beeps for anything mid-playback. Prints the time of
# each step, to line up with a recording.
XDG_RUNTIME_DIR=/run/user/$(id -u); export XDG_RUNTIME_DIR
S=$(pactl list short sinks | awk 'NR==1{print $2}')
t0=$(date +%s.%N); ts(){ printf '%6.2f %s\n' "$(echo "$(date +%s.%N)-$t0"|bc)" "$*"; }
N=${1:-20}; LONG=${2:-1}
for i in $(seq 1 "$N"); do
  pactl suspend-sink "$S" 1; sleep 1
  pactl suspend-sink "$S" 0
  ts "open $i silence"; paplay silence.wav
  ts "tone $i"; paplay tone.wav
done
[ "$LONG" = 1 ] && { pactl suspend-sink "$S" 1; sleep 1; pactl suspend-sink "$S" 0; ts long; paplay long.wav; }
ts end
