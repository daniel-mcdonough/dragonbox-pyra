#!/bin/bash
# Type every Fn-layer keycode into a new terminal on :0 and print what the
# terminal received. Run as the desktop user (sudo for uinput).
# Usage: fn-x.sh [-s | -q "SEQ"] [xterm|mate-terminal]
#   -s      with Shift
#   -q SEQ  a fn-inject.py sequence instead, e.g. the rollover check
#           "30 d197 d48 u48 u197 46" (a, Fn+D held while b is typed, c)
# XKBDIR=dir compiles the current layout with dir/symbols/pyra first in the
# include path and loads it once the test device is attached, then leaves it
# loaded: restore with
#   setxkbmap -rules evdev -model pyra -layout pyra -variant pyra -option ""
cd "$(dirname "$0")" || exit 1
export DISPLAY=:0
L="112 121 141 146 160 170 175 176 222 209 196 214 240 197 211 89 95 124 189 194 195 13 12 26 27 43 41 39 53"
sh=""; seq=""
case $1 in
  -s) sh=-s; shift ;;
  -q) seq=$2; sh=-q; shift 2 ;;
esac
term=${1:-xterm}
out=$PWD/x-$term$sh.txt; rm -f "$out"
case $term in
  xterm) xterm -geometry 80x10+0+0 -e bash -c "stty -icanon; cat > $out" & ;;
  mate-terminal) mate-terminal --disable-factory --geometry 80x10+0+0 -e "bash -c 'stty -icanon; cat > $out'" & ;;
  *) echo "xterm or mate-terminal" >&2; exit 2 ;;
esac
tp=$!; sleep 4
# the keys go to whatever has focus: stop unless it is the test terminal
aw=$(xprop -root _NET_ACTIVE_WINDOW | awk '{print $NF}')
wn=$(xprop -id "$aw" WM_CLASS 2>/dev/null)
case "$wn" in *[Xx]term*|*[Mm]ate-terminal*) ;; *) echo "focus is not the test terminal: $wn"; kill $tp; exit 1 ;; esac
[ "$seq" ] || seq="$(for c in $L; do echo -n "52 ${sh:+s}$c "; done) 52"
if [ "$XKBDIR" ]; then
  # a new keyboard gets the server's default keymap, so load after it attaches
  sudo FN_WAIT=5 python3 fn-inject.py $seq 28 & ip=$!
  until grep -q fn-inject /proc/bus/input/devices; do sleep 0.2; done; sleep 1.5
  setxkbmap -print | xkbcomp -w0 -I"$XKBDIR" - :0
  wait $ip
else
  sudo python3 fn-inject.py $seq 28
fi
sleep 1; pkill -f "cat > $out"; sleep 1; kill $tp 2>/dev/null
echo "== $term $sh"; cat "$out"
