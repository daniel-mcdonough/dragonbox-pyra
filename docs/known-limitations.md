# Known limitations

Hard walls, and things already tried that did not work. The purpose of this
document is to stop the same afternoons being spent twice.

Each entry says what the limit is, whether it is absolute or merely expensive,
and — where it exists — the evidence that closed it.

---

## 1. Absolute: not going to change

### 1.1 OpenGL ES 2.0 is the ceiling

`GL_VERSION` is `OpenGL ES 2.0 build 1.14@3699939`, GLSL ES 1.00. There is no
GLES 3 path, no desktop GL path on the hardware, and no prospect of either.

Mesa's PowerVR driver begins at **Rogue**. SGX544 is Series5XT, is not
supported, and will not be — the architecture is undocumented and writing an
open driver for it would be a multi-year reverse-engineering project. The
proprietary DDK blob is the only driver that exists for this part.

Desktop GL is available through **gl4es**, which translates GL 2.1 to GLES2 on
top of the blob. That works and runs at hardware speed (`glxgears` ~870 fps,
glmark2 246). It does not raise the feature ceiling; it lowers the API onto it.

### 1.2 Eight varying vectors

`MAX_VARYING_VECTORS = 8`. Not tunable, not extendable. See
`gpu-optimization.md` §2.1 for the ways around it.

### 1.3 `GL_EXT_frag_depth` is absent

No `gl_FragDepthEXT`. Any renderer that writes depth from the fragment shader
needs a path that does not, and accepts the resulting depth-sorting inaccuracy.

### 1.4 No `glBlitFramebuffer`

Neither `GL_NV_framebuffer_blit` nor `GL_ANGLE_framebuffer_blit` is present.
Framebuffer-to-framebuffer moves are a textured quad.

### 1.5 32-bit userspace

Debian armhf. Pointers are 4 bytes, `size_t` is 4 bytes, and a process gets
roughly 3 GB of address space regardless of the 4 GB installed. The kernel is
`ARM_LPAE=y`, which is how the machine addresses all 4 GB across processes — it
does not give any single process more.

### 1.6 Two cores

Not two plus four. Two, shared with the X server, the audio daemon and the
kernel's i2c interrupt threads.

### 1.7 The audio codec takes only 88200 or 96000 Hz, `S32_LE`

`aplay --dump-hw-params` on the TWL6040:

    FORMAT:  S32_LE
    CHANNELS: [1 5]
    RATE: [88200 96000]

No 44100, no 48000, no `S16_LE`. Every ordinary stream is upsampled and widened
before it can play. There is no configuration that avoids it in software, and
four candidate fixes were tested and all four were already correct or already
ruled out — `resample-method` is already `trivial`, the daemon already uses
NEON, the remap sinks are free, and moving the resample into the application is
worse.

The hardware *does* have an answer: the AESS audio DSP accepts 44.1 and 48 kHz
natively. It is live silicon and the reason the codec has an 88200 mode and a
96000 mode at all. It is driven only by this repository's patches. See
`docs/audio.md`.

### 1.8 The display controller reads the framebuffer continuously

DSI video mode, no partial update, 221 MB/s of DDR reads at 60 Hz whether or not
anything changed. Cannot be disabled short of turning the panel off.

### 1.9 There is one CPU idle state

`C1` — WFI with the MPU subsystem left powered. The retention state `C2` that
mainline has for this chip is `#if 0`-ed out in this kernel tree.

**It was tried.** Two boots on a kernel with it enabled, both wedged with no
warning, no backtrace and no network response, at 48 s and 74 s. The same kernel
without it runs for hours. The `#if 0` is best read as somebody having found the
same thing. Reopening it needs a serial console. See `experiments/c2-idle/`.

Consequence: there is no deeper sleep for background work to enable, which also
closes the idea of offloading work to the SoC's Cortex-M4s to let the A15s sleep
harder — there is nothing to deepen, and an executing M4 holds the CORE domain
on and DDR out of self-refresh anyway. See `docs/m4-ipu.md`.

### 1.10 Memory clock is already at its ceiling

DMM, EMIF and L3 at 265 MHz is the top CORE operating point on an OMAP5432.
There is no faster setting to find.

---

## 2. Expensive, not absolute

### 2.1 Fragment shader instructions

Roughly 3% of frame time per `texture2D` instruction, in the one workload
measured. This is the binding constraint for GLES2 game workloads on this part.
Not a wall — a budget. See `gpu-optimization.md` §4.

### 2.2 Draw calls at ~14.2 µs

About 70,000 per second for the whole machine; about 2,300 per frame at 30 fps.
An order of magnitude worse than a modern driver, and still not usually the
limit for this class of workload.

### 2.3 Reading pixels back

62 MB/s, against 1750 MB/s for a hardware copy of the same rectangle. Plus a
full TBDR pipeline flush if it is the target you are drawing to. Avoidable
rather than impossible, and it must be avoided on any per-frame path.

### 2.4 The thermal envelope

The machine is fanless. Two cores flat out, unmanaged, reach **107 °C** — seven
degrees past the passive trip — in under two minutes. With the thermal daemon
fixed and its ladder corrected, the same loads peak at 84–89 °C.

Sustained frequency, not peak frequency, is what you get. Frame rate falls ~30%
between cold and equilibrium.

**Do not chase 1.8 or 2.0 GHz.** An unlocked frequency table exists in
`experiments/thermals-and-frequency/` and it builds. Its author tuned it on a
CPU board with the heatsink soldered, the factory adhesive stripped, high-end
compound applied and the components conformally coated — reporting 20–23 °C
cooler than stock — and still says *"unless you've modified the cooling, you
probably can't run 2 GHz I assure you. I hardly can."* That is a statement of a
hardware prerequisite, and a stock unit does not meet it.

### 2.5 The GPU rail is at NOM, not its top operating point

Worth roughly a quarter of the GPU's throughput, and it is the highest-value
unexplored item on the device — also the one most likely to be impossible.

There is no `devfreq` node and no GPU OPP table under `/proc/device-tree`, so
the DDK is probably setting a fixed rate. `omapconf` reports every rail at
0.000 V and the PMIC as `ES UNKNOWN`, so **voltage readback is unavailable**,
which makes this materially harder to do safely.

**Raising a clock without confirming the matching voltage is how silicon gets
damaged.** Do not do the clock half on its own. If the voltage side cannot be
verified, the correct outcome is to close the item, not to try it anyway.
Treat as research, not as a change.

### 2.6 The i2c interrupt floor

858 interrupts per second on an idle machine — 457/s for the two AS5013 analog
nubs plus keypad, fuel gauge and charger, and 265–511/s for the PMIC, codec and
USB hub. That is 2–3% of one core, permanently, in hard IRQ time.

The nubs are polled every 25 ms because **their interrupt lines are unusable**:
the device tree names gpio6_174/175, the driver ignores them, and on hardware
both pins are held low even with the chip's INTn forced to Hi-Z, so fixing the
driver would fire nothing (`improvements.md` item 11). The driver falls back to
a delayed work item. The driver has
no close callback, so the poll never stops — stopping the daemon that holds the
input devices open changes the rate by 1%.

**Do not bother.** There is one cpuidle state, so the wakeups are not blocking a
deeper sleep, and the whole prize is 2–3% of one core for a kernel patch on an
out-of-tree tree. "Wire the interrupt" was checked on 2026-09-24 and is not
available: the fault is on the board, not in the device tree.

### 2.7 x86 Direct3D under Wine

2D DirectDraw games run under box86 with an x86 Wine and are playable. Anything
needing Wine's 3D path does not, because wined3d needs desktop GLX and fix 4
removes the X server's GLX entirely — fix 4 exists because Xorg 21.1.16's AIGLX
DRI2 probe NULL-dereferences on every failure path.

Fixing that upstream would retire fix 4 and unblock this. It is the
highest-value unreported finding in the project.

### 2.8 Statically linked x86 binaries

box86 rejects them:

    Error, using brk on multi-part memory elf is not allowed for now

Not much of a limitation in practice — box86's whole design depends on the
binary resolving its libraries at runtime so that native ARM libraries can be
substituted.

### 2.9 Unplugging headphones is not detected while the headset amplifier is on

The TS3A227E jack chip detects insertion and removal on one pin,
DET_TRIGGER, with an internal pull-up of about 1 MΩ. Plug-in pulls it low;
removal is the line rising back above 0.65 × VDD. While the TWL6040's headset
amplifier is powered (during playback, and for PulseAudio's five-minute idle
timeout after it), nothing registers on unplug. Turning the amplifier off
makes the pending removal register within 190 ms. The likely reason is that
the pin sees the jack's tip, and the amplifier's ground-centred,
low-impedance output holds it near 0 V. The mainboard schematic (rev 5.1.3,
sheet 18) confirms it: the pin is wired to the jack's tip switch contact,
which rests on the headphone left output whenever nothing is plugged in.

So plugging in switches PulseAudio to the headphones, and unplugging leaves
it on them, silent, until Speakers is picked by hand or the amplifier powers
down. The board has no other removal signal: the TWL6040's own `PLUGDET`
input is driven by a FET from the same contact. Fixing it would take a board
change, such as using the jack's switch without sharing the tip.
`experiments/jack-detect/README.md`, step 3.

---

## 3. Tried, measured, does not work

Recorded with numbers so nobody re-derives them.

| Idea | Result |
| --- | --- |
| `GL_EXT_discard_framebuffer` to save ~140 MB/s of writeback | **−0.64%, not significant** across 5 interleaved pairs. Calls confirmed executing with `GL_NO_ERROR`. The workload is fragment-bound, not bandwidth-starved |
| `glBufferSubData` ring buffer instead of `glBufferData` orphaning | **4x worse** — 221 µs/draw against 68 |
| Nearest filtering instead of bilinear, to save texel reads | **0.1%, not significant.** The texture unit filters in fixed-function hardware |
| Finer CPU frequency steps for responsiveness | **4% slower** on the mean, 18% in the best case. They buy idle battery (~21 min), not latency |
| `up_threshold`, `io_is_busy`, 500 MHz floor | ~1–2% each. Only `sampling_down_factor` pays (23%) |
| C2 retention idle state | **Hangs the machine** in under 90 seconds. Two for two |
| Rebuilding pixman / ffmpeg with NEON flags | They already dispatch NEON at runtime. Close to nothing |
| Matching the audio *ratio* (32000 → 44100 Hz) | **+22.9% PulseAudio CPU**, measured twice. Only matching the *rate* reaches the cheap path |
| `ETNA_BO_CACHED` instead of write-combine for 2D buffers | Identical numbers. The write-combine mapping costs nothing measurable |
| `VIV2D_MIN_SIZE` tuning | It is a per-pixmap allocation threshold, not a per-operation one. Cannot express what people want it to |
| `A8` destination support for fills | Software fills into alpha-only are already `memset`-fast, 1347 Mpix/s |
| Xorg → XLibre for performance | Same code, same architecture. No mechanism by which it would be faster |
| Stripping legacy code from X | Dead code costs nothing at runtime. A build-size exercise in a performance costume |
| Kernel security options traded for speed | Almost nothing. `pyra_defconfig` is already trimmed; see `kernel-notes.md` §5 |
| Pegasus as a launcher | 9.1% of a core on a **static** screen against a 0.0% control. Dropped |

---

## 4. Measurement traps that produce false results

Each of these produces a confident, reproducible, wrong number.

- **`x11perf`** toggles DPMS around every test; each is a modeset, and the
  modeset path can wedge the display hard enough to need a reboot. Two hangs
  came from it.
- **`pasuspender`**, if killed, leaves every sink suspended. The machine goes
  silent and looks faster.
- **`SDL_AUDIODRIVER=alsa`** never opens the codec at all on this machine. Same
  false speedup. `SDL_AUDIODRIVER=dummy` is the honest way to measure without
  audio.
- **Muting saves nothing.** PulseAudio still resamples and mixes, then
  multiplies by zero.
- **`top` percentages under `ondemand`** measure the governor. Identical work
  reads 26% at 625 MHz and 11% at 1500 MHz.
- **Any A/B without a thermal warm-up** measures the thermostat — a 30% swing.
- **Any A/B with vsync on** measures the 60/N quantiser.
- **Synthetic microbenchmarks on a TBDR** measure a best case and get read as a
  prediction. This cost a whole phase.

---

## 5. Open, unresolved

Stated so they are not mistaken for settled.

- **The display can wedge inside a modeset**, spinning a core at 100% until
  reboot. Not reproducible on demand — roughly 2,100 deliberate modesets have
  not triggered it. A candidate fix exists and cannot be confirmed until it next
  fails to happen. This outranks every performance item in the project.
- **Why fullscreen games are copied, not flipped.** Measured 2026-09-27: no
  `PAGE_FLIP`. Xorg has the GC320 copy every frame into the TILER front buffer.
  ~~The cause is probably that SGX buffers cannot be TILER-backed for the rotated
  plane, but that is not proven.~~ **Cause found in source, 2026-10-18:** the DDX
  is built with its Present flip commented out (`ARMSOC_PRESENT_FLIP`), so it
  copies by design. Rotation would also block a flip, because the window
  system's buffers are not TILER buffers. The copy's cost is not measured
  either; from the source it is bandwidth and watts, not swap time. The open
  part is whether the SGX can render into a TILER buffer.
  `improvements.md` §6.
- **`eglSwapBuffers` under X waits for the GPU.** From source, 2026-10-18,
  not measured. The window system library sleeps until the SGX has finished
  each frame before presenting, so CPU and GPU never overlap across frames.
  It is open source and fixable. `improvements.md` §6, "What the source says".
- **The WiFi driver can loop in a hardware restart** and flood the kernel log with mac80211 warnings
  (~17 stack traces a second), starving userspace until a reboot. Seen once, 2026-09-28, while idle;
  trigger unknown, because the image's 50 MB journal cap let the storm erase it. Mitigations, none
  applied: a larger journal, WiFi off during long sessions, power save off. `troubleshooting.md`,
  "The WiFi driver can flood the kernel log".
- **Whether the GPU rail can go above NOM** — see §2.5.
- **Transparent huge pages.** One config symbol, plausible mechanism against the
  TLB, entirely unmeasured. `kernel-notes.md` §4.
- **Whether narrowing texture formats helps.** Two bandwidth arguments have come
  back null, but neither varied the working set. Genuinely open.
- **Whether eliminating dependent texture reads helps, and by how much.** The
  premise is confirmed; the magnitude is not. Top open candidate.
- **Whether the IMG shader compiler flattens dynamic branches.** Assumed, not
  checked.
