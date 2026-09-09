# x86 software through box86

Status: **working**, with one significant limit. Tested 2026-09-09 on the trixie
card built by `procedure.md`, against the running unit over SSH with a MATE session
live on `:0`.

Linux x86 binaries run. Windows programs run through an x86 Wine under box86.
2D DirectDraw games run and are playable; anything that needs Wine's 3D path
does not, for a reason that belongs to fix 4 rather than to box86. That is
explained under "The 3D limit" below.

This document assumes the machine `procedure.md` produces: fix 4 applied, so the X
server has no GLX, and gl4es available as the per-application GL wrapper.

---

## 1. Install box86

`box86-pyra` is in the Pyra repository and is **not** installed by the image:

    sudo apt-get install box86-pyra
    box86 --version
    # Box86 with Dynarec v0.3.7  built on Nov  5 2024 02:20:53

The dynarec build is the one that matters: it translates x86 to ARM once and
caches it, rather than interpreting.

`BOX86_NOBANNER=1` silences its startup lines. `BOX86_LOG=1` expands them when
something needs diagnosing.

---

## 2. What box86 actually does, and why it pairs with gl4es

box86 translates the x86 code and then **substitutes the device's own ARM
libraries** for the x86 ones the binary asks for. An x86 program that calls into
`libc`, `libX11` or `libGL` ends up in the native ARM build of that library, at
native speed. Only the program's own code is emulated.

Two consequences follow, and both were confirmed here rather than assumed.

**Dynamically linked i386 binaries run.** A statically linked one does not:

    Error, using brk on multi-part memory elf is not allowed for now

That is a box86 limitation, and not much of one in practice, since the whole
design depends on the binary resolving its libraries at run time.

**x86 GL costs nothing.** Debian's i386 `glxgears` under the gl4es wrapper:

    gl4es box86 ./glxgears.i386-linux-gnu
    # 4260 frames in 5.0 seconds = 851.920 FPS
    # 4344 frames in 5.0 seconds = 868.788 FPS

Against ~870 FPS for the ARM build of the same program. The emulation is not on
the path that matters, because the GL calls leave it immediately.

Without the wrapper the same binary fails the way every GL program on this image
fails, which is fix 4 doing its job and nothing to do with box86:

    Error: couldn't get an RGB, Double-buffered visual

The test binary came from Debian's `mesa-utils-bin` 9.0.0-2+b2 for i386,
unpacked on a PC and copied over. No i386 packages are installed on the device
and none should be.

---

## 3. Wine

Wine has to be an **x86** build. The ARM Wine in the Debian archive runs ARM
Windows binaries, which is not what an x86 Windows program is.

Use a self-contained relocatable tarball. It is far less work than Debian's i386
Wine packages, which would drag in the i386 libraries box86 exists to avoid:

    wine-9.0-x86.tar.xz     from github.com/Kron4ek/Wine-Builds

Wine 9.0 was chosen as a stable release contemporary with this box86 build.
Unpack it anywhere in `$HOME`; nothing needs to be installed system-wide.

Bootstrap a prefix. This takes about 75 seconds under emulation:

    export WINEPREFIX=$HOME/wine-x86
    export WINEDLLOVERRIDES="mscoree,mshtml="      # skip the mono/gecko prompts
    gl4es box86 ~/wine/bin/wine wineboot -u

Check it with something trivial before trying anything real:

    DISPLAY=:0 gl4es box86 ~/wine/bin/wine notepad

Notepad renders normally on the MATE desktop, decorated by `marco` like any
other window.

Stop everything a prefix is running with:

    gl4es box86 ~/wine/bin/wineserver -k

---

## 4. Running a game

Worked example: **Anno 1602** (sold as *1602 A.D.*), Win32, 1999, DirectDraw.

Two settings matter, and one of them is not optional.

**Tell DirectDraw to use the GDI renderer.** This is a per-prefix registry
value, set once:

    gl4es box86 ~/wine/bin/wine reg add \
        "HKCU\Software\Wine\Direct3D" /v renderer /d gdi /f

**Run inside a Wine virtual desktop** rather than letting the game go
fullscreen. Old games ask for display modes the Pyra's panel does not have:

    cd "/path/to/1602 A.D"
    DISPLAY=:0 gl4es box86 ~/wine/bin/wine explorer /desktop=anno,800x600 ./1602.exe

What that gives, measured on the device:

| | |
| --- | --- |
| resolution | 800x600 inside a 1280x720 desktop |
| CPU | 80–87% of one core |
| audio | works, via PulseAudio, as a sink input named `ANNO 1602` |
| rendering | animates continuously; screenshots taken 6 s apart all differ |

`pyra-box86-anno1602.png`, beside this file, is the game in play.

The game's own `Config.exe` also runs and draws correctly, which is a useful
first check for any title that ships one: it exercises the same x86 Windows code
path with none of the graphics complexity.

### It runs hot

Sustained emulation is the heaviest load this machine has been put under here:

| sensor | idle | under the game |
| --- | --- | --- |
| `cpu_thermal` | 65°C | 95°C |
| `gpu_thermal` | 69°C | 88°C |
| `core_thermal` | 66°C | 87°C |

Nothing throttled and nothing fell over, but the runs were tens of minutes, not
hours, and this is a fanless handheld. A long session is a different test.

---

## 5. The 3D limit

**Wine's GL renderer cannot create a context on this machine.** With the default
`renderer`, the game created its window and then hung, drawing nothing, at 0%
CPU. Wine's own debug channels name it exactly:

    trace:ddraw:DirectDrawCreate driver_guid (null) ...
    LIBGL: ERROR: EGL Error detected: EGL_BAD_MATCH
    err:d3d:wined3d_caps_gl_ctx_create_attribs Failed to make new context current

This is **fix 4 and the SGX blob's fbconfig strictness meeting each other**, and
neither half belongs to box86 or to Wine:

- Fix 4 disables the X server's GLX extension, so Wine's window is created with
  the server's default 24-bit visual.
- The only EGL config the SGX blob will accept is the exact
  RGBA8 / depth24 / stencil8 one documented in `gl4es.md`, which
  needs an alpha channel.

A context on one and a surface on the other can never match, which is what
`EGL_BAD_MATCH` is saying.

`LIBGL_ALPHAHACK`, `LIBGL_AVOID24BITS` and `LIBGL_FBONOALPHA` were each tried
against this, alongside a baseline run. All four failed identically, so this is
not a gl4es tuning problem.

The practical rule:

| Windows program | Works? |
| --- | --- |
| 2D DirectDraw, with `renderer=gdi` | yes |
| GDI / plain Win32 GUI | yes |
| 3D through wined3d's GL renderer | no |

The GDI renderer sidesteps GL completely, which for a 2D game is no loss at all.

**This would be retired by the same upstream fix as fix 4.** If xorg-server's
AIGLX probe ever fails gracefully instead of segfaulting, fix 4 goes away, GLX
comes back, Wine gets a visual it can match, and the 3D path becomes worth
retesting. See the open items in `progress.md`.

Untested, and the obvious next thing to try if someone wants 3D: pointing Wine
at gl4es hard enough that it never asks the X server for a visual at all, the
way gl4es already bypasses GLX for native programs.

---

## 6. Troubleshooting

**A program starts and nothing appears.** Take a screenshot before concluding
anything. `xwininfo -root -children` does not show an application's name for a
decorated window, because the frame that is a child of root belongs to the
window manager, not to the program. Use `xwininfo -root -tree`, or just look:

    DISPLAY=:0 xwd -root -silent > /tmp/root.xwd      # on the Pyra
    magick root.xwd root.png                          # on the PC

**Nothing in the log to go on.** `WINEDEBUG=-all` is the right setting for
running something and the wrong one for diagnosing it. Turn the relevant
channels back on:

    WINEDEBUG=+ddraw,+dsound      # 2D and audio
    WINEDEBUG=+d3d                # the GL path

Default (unset) gives `err:` and `fixme:` only, which is often enough.

**`err:wineboot:process_run_key ... winemenubuilder.exe` on every launch.**
Harmless in these builds. It has no bearing on whether a program runs.

**`fixme:hid:` and `fixme:xinput:` floods.** Also harmless, and worth filtering
out of a log before reading it.

**Killing a stuck program over SSH.** Prefer `wineserver -k`. Do not reach for
`pkill -f <exe name>` in an SSH command: the pattern matches your own remote
shell's command line, which contains that name, and kills the session instead.

**A game that ignores its own settings.** Anno's `Config.exe` writes settings
that the game reads at next start; the virtual desktop size is what actually
determines the window, so set them to agree.

---

## 7. Reproducing the measurements

Everything here was measured on the device, not inferred:

    # box86 identity
    box86 --version

    # x86 GL against ARM GL
    DISPLAY=:0 gl4es box86 ./glxgears.i386-linux-gnu
    DISPLAY=:0 gl4es glxgears

    # is the game actually producing audio
    pactl list sink-inputs | grep -A2 "application.name"
    grep -H . /proc/asound/card*/pcm*p/sub0/status

    # is it actually rendering, rather than just alive
    id=$(DISPLAY=:0 xwininfo -root -tree | grep '"Anno 1602"' | awk '{print $1}')
    for i in 1 2 3; do DISPLAY=:0 xwd -id $id -silent | md5sum; sleep 6; done

    # thermals, idle and under load
    for z in /sys/class/thermal/thermal_zone*; do
        printf '%s %s\n' "$(cat $z/type)" "$(cat $z/temp)"
    done

---

## Side note: ARM binaries across the two suites

Unrelated to x86, but it belongs with the compatibility notes. From the original
forum report: a test binary compiled on bookworm ran unmodified on trixie, so
the armhf 64-bit `time_t` transition did not bite this particular stack.

---

## Sources

- box86: https://github.com/ptitSeb/box86
- Wine builds: https://github.com/Kron4ek/Wine-Builds
- The machine this runs on: `procedure.md`
- What was done when, and why: `progress.md`
