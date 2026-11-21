#!/bin/bash
# Type every Fn-layer keycode on tty1's login prompt, dot-separated, and read
# the line back from /dev/vcsu1. Switches to tty1 and back to tty7.
# Usage: sudo fn-tty.sh [-s]     (-s: with Shift)
cd "$(dirname "$0")" || exit 1
L="112 121 141 146 160 170 175 176 222 209 196 214 240 197 211 89 95 124 189 194 195 13 12 26 27 43 41 39 53 127"
N="Q W E R T Y U I O P ' A S D F G H J K L M Z X C V B N , . Space"
systemctl restart getty@tty1; chvt 1; sleep 2
p=; [ "$1" = -s ] && p=s
python3 fn-inject.py $(for c in $L; do echo -n "52 $p$c "; done) 52
sleep 0.3
# ignore_loglevel on the Pyra's command line puts the device's printk line on tty1 too
got=$(python3 -c '
import re
d = open("/dev/vcsu1", "rb").read().decode("utf-32-le")
t = d.rstrip().rsplit("login: ", 1)[-1]
print(re.sub(r"\[ *[0-9.]+\] input: fn-inject as \S+ *", "", t))')
python3 fn-inject.py $(for i in $(seq 90); do echo -n "14 "; done)
chvt 7
echo "keys: ${1:+Shift+}Fn+ $N"
echo "got:  $got"
