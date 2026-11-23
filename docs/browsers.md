# Which web browser to use

> **Type: reference.** What was measured, and what to install.

Measured 2026-11-23 on a card made with `--release` (kernel `5.6.19-m4-kbdled`,
CPU ceiling 1.5 GHz, `ondemand` governor, 4 GB, no swap). Recorded in the development log, R98.

**Use Firefox ESR:** `sudo apt install firefox-esr`. It is the only full browser
in trixie's armhf archive that renders on this card. NetSurf is a light second
choice for pages that need little JavaScript. Chromium and Epiphany both start
and then fail. Dillo runs but shows a blank page on a modern site.

A prepared card ships no browser and no `x-www-browser` alternative. Installing
`firefox-esr` sets both.

## Results

The test page was the English Wikipedia article "OMAP": once live over WiFi and
once as a local copy (`wget -p -k`, 824 KB), opened with `file://`. All runs
started with the page URL on the command line, on the MATE desktop.

- **Window:** seconds from launch to the first visible new window.
- **Settled:** seconds until the whole process tree used less than 10% of one core
  for 3 s.
- **PSS:** the process tree's proportional memory (shared pages split between
  processes). RSS counts shared pages once per process and overstates a
  multi-process browser.
- **Cold:** page cache dropped and a fresh profile. **Warm:** the same profile
  started again.

| Browser (trixie armhf) | Result | Window, cold / warm | Settled, warm | PSS, warm | RSS, warm |
| --- | --- | --- | --- | --- | --- |
| `firefox-esr` 153.7.0esr | **Renders both pages correctly** | 15.0 s / 4.6–5.1 s | never (see below) | 437–447 MiB | ~1.0 GiB |
| `netsurf-gtk` 3.11 | Renders both; simplified layout, little JS | 1.6 s / 0.6 s | 4.4 s | 43 MiB | 69 MiB |
| `dillo` 3.0.5 | **Fails:** window opens, page area stays blank on both copies | 1.0 s / 0.6 s | 0.7–0.8 s | 12 MiB | 19 MiB |
| `epiphany-browser` 48.5 | **Fails:** aborts at start, no window | — | — | — | — |
| `chromium` 156.0.8078.108 | **Fails:** black window, nothing rendered | 39.0 s / 26.3–31.9 s | 33–41 s | 313–389 MiB | 1.3–1.6 GiB |

NetSurf's own status bar gave the page load as 2.8 s (live) and 4.1 s (local).
Firefox's first start opens a privacy-notice tab as well, and that run used
613 MiB PSS. The `MemAvailable` drop was 287–292 MiB warm and 552 MiB on the
first start.

### Firefox ESR

It works, but it is not light:

- **It keeps a core busy.** It never met the settle test within 150 s. With the
  Wikipedia page open and no input, the tree used 71% of one core between
  60 and 90 s after launch. The main process alone used 31% in `top`.
- **Rendering is in software.** It maps mesa's `libGL`. Fix 4 removed GLX, so
  rendering falls back to the CPU. This was not confirmed in `about:support`.
  Scrolling, video and WebGL were not measured.
- **Watch the tab count.** About 450 MiB for one page is affordable in 4 GB with
  roughly 3.5 GB available at idle, but there is no swap, and the OOM killer
  ends an overshoot. `memory-optimization.md` §5 covers zram as the cheap
  cushion.

The forum's reports of Firefox ESR crashing (2023–2025) were on the older
images, and none of these runs crashed.

### NetSurf

It is the right tool when RAM or battery matters more than JavaScript: a tenth of
Firefox's memory, and a window in under a second. Wikipedia's icons show as
pink boxes, and the page lays out in one column. Scripted sites will not work.

### Why the others fail

- **Epiphany** is GTK4 with WebKitGTK 6.0 (2.54.3). It aborts with
  `malloc(): invalid size (unsorted)` in GTK4's GL renderer, and
  `WEBKIT_DISABLE_DMABUF_RENDERER=1`, `WEBKIT_DISABLE_COMPOSITING_MODE=1` and
  `LIBGL_ALWAYS_SOFTWARE=1` do not change that. With `GSK_RENDERER=cairo` the
  window stays up, but WebKit's web process crashes on every page. Those
  switches plus `WEBKIT_SKIA_ENABLE_CPU_RENDERING=1` do not help either.
  WebKitGTK 4.1 (GTK3, 2.50.4) is on the image already for `yelp`, and yelp does
  stays running for 20 s (whether it rendered was not checked). A GTK3 WebKit browser might work, but none was tried.
- **Chromium**'s GPU process exits at start (`ANGLE Display::initialize error
  12289: GLX is not present`, then signal 6). The renderer is then terminated
  for "bad Mojo message", and the window stays black. These flags all give the
  same result: `--disable-gpu`; `--disable-gpu --disable-gpu-compositing
  --disable-software-rasterizer`; `--use-gl=angle --use-angle=swiftshader`;
  `--use-gl=egl`. It also needs half a minute to show that black window.
- **Dillo** 3.0.5 fetches the page (its status bar counts the bytes) but draws
  nothing visible of current Wikipedia. It is only useful for plain HTML.

Vivaldi, which forum users recommended for the older images, is not in Debian
and was not tried.

### A prompt to unlock the "login keyring"

On the r5 release card, Chromium's first start asked for the login keyring's
password. The password that worked was `pyra`, the image's original one, not the
one set at the first login (see `troubleshooting.md`, "Asked for a keyring password that is not yours").
Release images from fix 33 on create the keyring with the user's own password.

## Security

A browser runs code from strangers, which is the case that makes Spectre v2 a
live risk on this machine. `kernel-notes.md` §5 (the Spectre v2
workaround) covers why the kernel keeps that mitigation and what it costs. The
browser is Debian's package, so `apt upgrade` brings its security updates.

## How it was measured

A Python script on the card launched each browser with the URL and polled
`/proc` every 0.25 s. For the window it ran `xdotool search --onlyvisible`. It
summed `utime + stime` for CPU and `smaps_rollup` for PSS and RSS over the
process tree, found by parent PID plus any new process whose name matched the
browser. Then it saved an `xwd` screenshot, which was used to judge whether the
page rendered. The browsers and `xdotool` were removed afterwards, except
`firefox-esr`.
