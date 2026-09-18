# Result: the theme is a third of it, and one environment variable is another third

Measured on a Pyra V5.3 on 2026-09-18, on `5.6.19-freq`, with Pegasus at commit
`83fd27f` running under `device/pyra-gles`. The question was the one left open
in `docs/pegasus.md`: the launcher costs 20–30% of a core sitting on its home
screen doing nothing, and the bundled Grid theme animates continuously, so
**would a theme that does not animate fix it?**

Partly. It is worth about a third. The other two thirds split into one
environment variable and one poll timer.

## What was compared

`pyra-static/` is a theme written for this measurement and nothing else: a
header, a `ListView` of the games, a highlight rectangle, and not one
animation, transition or `Behavior` anywhere. At rest it renders **0 frames per
second**, against **22 per second** for Grid — counted from
`QSG_RENDER_TIMING=1`, so that part of the premise was right.

Every row below is the frontend process's own CPU time over a 40-second window,
after a 25-second settle, with the machine cooled below 64°C first so the
thermal ceiling is the same 1.5 GHz in each. `idlemeasure2.sh` runs one row;
`threads.sh` breaks a running one down by thread.

| what is running | render loop | frontend | of which render thread | of which GUI thread |
| --- | --- | --- | --- | --- |
| Grid theme | threaded (default) | **29.4%, 29.6%** | 20.5%, 20.7% | 5.9% |
| Static theme | threaded (default) | **21.0%, 20.8%** | 11.6%, 11.5% | 7.1%, 6.9% |
| Grid theme | `QSG_RENDER_LOOP=basic` | **18.2%** | — | 19.2% |
| Static theme | `QSG_RENDER_LOOP=basic` | **9.1%** | — | 7.8% |
| *control:* `qmlscene`, a static scene, no Pegasus | threaded (default) | **0.0%** | — | — |
| *control:* the MATE desktop, nothing running | — | 6.0%, 6.1% of **both** cores | | |

Two conditions were run twice, in separate sessions, and repeat within 0.2
points. `SDL_JOYSTICK_DISABLE_UDEV=1` makes no difference at idle either way
(21.0 vs 20.8, 29.4 vs 29.6), so the workaround for the launch-path abort costs
nothing here.

## What the numbers say

**The animation is real but it is not the main cost.** Stopping it entirely
saves 8.5 points of a core. The launcher still burns 21% drawing *nothing*.

**Most of what is left is a render thread that renders nothing.** With the
static theme the `QSGRenderThread` accounts for 11.5 of those 21 points while
the frame counter sits at zero. Setting `QSG_RENDER_LOOP=basic`, which puts
rendering back on the GUI thread, removes that thread and its cost: 21.0% falls
to **9.1%**, and Grid falls from 29.5% to 18.2%. The screen looks identical —
the same screenshot, the same theme, no visible lag — so this is a free 11
points in either theme.

**It is not Qt, and it is not the SGX driver.** The control matters here: a
bare `qmlscene` showing a static scene, on the same GLES stack through the same
shim, with Qt's *default threaded* loop, costs **0.0%**. Qt Quick at rest on
this hardware is free. Whatever keeps Pegasus's render thread awake is
something Pegasus does, not something Qt or the blob does to everyone.

**What remains is the GUI thread, at about 8%.** That is where
`GamepadManagerSDL2` polls SDL every 16 ms, on a machine whose gamepad is
soldered on. Raising that interval is a one-line change in the file that
already had to be patched for the launch abort, and it is the obvious next
measurement.

## So, for a launcher session

Static theme plus `QSG_RENDER_LOOP=basic` is **9.1% of one core against the
29.5% Pegasus ships with** — roughly a third of the idle cost, for one theme
and one environment variable, with nothing given up on screen. That is the
difference between a launcher you can leave running and one you cannot.

For comparison the whole MATE desktop with nothing running is 6% of both cores.
Pegasus at 9% of one core is about 4.5 points of the same measure, so the
launcher still roughly doubles an idle machine — but it is no longer the
dominant consumer, and the remaining half has a named cause.

## What this does not settle

- Whether the SDL poll interval is safely raisable, and what it buys. Not tried.
- Why Pegasus's render thread spins with the threaded loop when a plain Qt Quick
  application's does not. `QSG_RENDER_LOOP=basic` sidesteps it rather than
  explaining it.
- Battery current. It was sampled throughout and is not reported as a
  conclusion: the same desktop-idle condition measured 333 mA on a cold machine
  and 478 mA on a warm one in the same session, so at this resolution the gauge
  is reading die temperature as much as it is reading load. CPU time is the
  metric that reproduces.

## Reproducing

    # on the device, with pegasus-fe and pyra-gles in /tmp
    cp -r pyra-static ~/.config/pegasus-frontend/themes/
    ./idlemeasure2.sh static-udevOFF themes/pyra-static/ off
    ./idlemeasure2.sh grid-udevOFF   ":/themes/pegasus-theme-grid/" off
    ./qmlidle.sh                     # the bare Qt Quick control

`idlemeasure2.sh` writes `~/.config/pegasus-frontend/settings.txt` to select the
theme, because the alternative is driving a menu with `xdotool`. It leaves the
last condition's theme selected.
