# Fn symbols under X and on the console

What each Fn key types on the desktop and on a tty, checked without pressing
keys: `fn-inject.py` creates a uinput keyboard and sends the keycodes that
funkeymonkey-pyrainput sends for each Fn key (`pyraKeyMap.cpp`). That is the
same path the daemon uses, so X and the console can't tell the difference.

- `fn-inject.py [-s] CODE...` sends key taps (`sNN` with Shift, `dNN`/`uNN`
  press or release only). Needs root for `/dev/uinput`.
- `fn-tty.sh [-s]` (root) restarts tty1's getty, switches to tty1, types every
  Fn keycode dot-separated, reads the line back from `/dev/vcsu1`, and
  returns to tty7.
- `fn-x.sh [-s | -q SEQ] [xterm|mate-terminal]` (desktop user) opens a
  terminal on `:0`, checks it has focus, types into it and prints what it
  received. `XKBDIR=dir` tests a changed `dir/symbols/pyra` first.

Results and the fixes: `docs/troubleshooting.md`, "Fn+D (`_`), Fn+' (`:`)
or other Fn symbols type nothing, or the wrong thing"; the run is in
`docs/verification-log.md`, 2026-11-21 (R78). The X fix is
`patches/userspace/pyra-config-xorg/0001-*.patch`, the console one
`device/etc/console-setup/pyra-fn.kmap`.

Traps: the Pyra's kernel command line has `ignore_loglevel`, so each new
input device prints a line on tty1 (`fn-tty.sh` strips it). X gives a newly
attached keyboard the server's default keymap, so `fn-x.sh` loads a test
keymap after the device appears. Reloading an `xkbcomp -xkb` dump drops a
modifier entry; restore with `setxkbmap -rules evdev -model pyra -layout
pyra -variant pyra -option ""`. `loadkeys` of a keymap that doesn't mention
a keycode leaves its old binding: restore the console from a full `dumpkeys
-f` taken first.
