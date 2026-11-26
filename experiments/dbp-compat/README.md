# DBP compatibility runs: tools

The forum review's compatibility list is worked through one DBP at a time.
The results are in [docs/dbp.md](../../docs/dbp.md) and
[docs/verification-log.md](../../docs/verification-log.md). This folder holds
what those runs needed on the card that the image doesn't have.

## xsend.c: keys and clicks without xdotool

The image has no `xdotool`, `strace` or `gdb`, and no X headers. `xsend`
declares the few Xlib/XTest prototypes it needs and links the image's
`libX11.so.6` and `libXtst.so.6` directly (build line at the top of the file).
Copy it to `/tmp` on the card, build it there with the image's gcc, and run it
with `DISPLAY=:0`:

    xsend click 647 206          # root coordinates; use xwininfo for the window's absolute position
    xsend key Escape
    xsend key Return Alt_L       # key with a modifier held

Used for ft2-clone and Fit for Autopsy (2026-11-26). Events reach SDL 1.2 and
SDL2 programs like real input. `xprop -root _NET_ACTIVE_WINDOW` shows which
window receives the keys. A key goes to the focused window, so click into the
target first if a dialog or the desktop has focus.
