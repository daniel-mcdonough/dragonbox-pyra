# Performance: what is already done, what is worth doing, what is not

A survey of the proposed performance work, checked against the running unit on
2026-09-09 rather than against expectations. The reference documents describe
the machine as built; this one describes what is left.

Every "Measured" line below came off the device over SSH on that date. Numbers
without a measurement are marked as estimates and should be treated as such.

---

## The proposed ranking, corrected

The original list ranked the opportunities like this. The right-hand columns are
what the device actually says.

| Proposal | Claimed | Actual state |
| --- | --- | --- |
| Make 3D use the SGX, not software Mesa | Enormous | **Already done and verified.** No work left |
| Eliminate framebuffer copies, fix TILER | Potentially enormous | **Rotation is already in hardware.** A smaller Present question remains |
| Optimise gl4es / native GLES paths | Large | Real but unquantified. Measure before building |
| Sustained CPU clocks and thermals | Large | **Real, and the governor is misconfigured.** Cheapest win on the list |
| Optimise 2D X rendering, EXA, pixman | Medium–large | Real, and the shipped config contradicts its own comment |
| Cortex-A15 / NEON rebuilds | Medium | Smaller than claimed. pixman already dispatches NEON at runtime |
| Xorg to XLibre | Small–medium | **No performance value.** Possible correctness value, see below |
| Strip legacy code from X | Small | None. Dropped |

Three items the original list did not contain outrank most of what it did:

- The `ondemand` governor is set to step up only at **95% load**, with I/O wait
  not counted as load and a 250 MHz floor.
- The MATE window manager is **compositing**, with GLX disabled, so every window
  update takes an extra XRender pass.
- The GPU rail sits at its **nominal** operating point, not its top one.

---

## Already done

Do not spend time re-deriving these. Each has a dated entry in
`verification-log.md` or `gl4es.md`.

**3D runs on the SGX.** `libGL` from gl4es resolves `libEGL` and `libGLESv2` to
the DDK blob in `/opt/omap5-sgx-ddk-um-linux/lib/`, which drives the SGX544MP2
on `card1` (`pvrsrvkm`, `ti,omap5-sgx544-116`). `glxgears` runs at ~870 FPS and
glmark2 scores 246, both at hardware speeds. There is no path here that falls
back to software Mesa, because fix 4 removed the X server's GLX entirely and
software GLX along with it. The fear that software rendering is silently in use
does not apply to this build.

**The blob is already contained.** It lives under `/opt`, is packaged as
`omap5-sgx-ddk-um-linux` 1.14.3699939-15, and dictates nothing about the rest of
the userspace. Trixie's own Mesa 25.0.7, X 21.1.16 and libraries are untouched.
The proposed "compatibility island" is the layout that already ships.

**Display rotation is done by the display controller, not the CPU.** This was
the largest item on the original list and it is not a problem. The X device
section carries `Option "TilerRotation" "270"`, the driver confirms it, and the
kernel is booted with `drm.force_hw_rotation` and
`drm_kms_helper.fbdev_rotation=8`:

    (II) OMAP5(0): Buffer Flipping is Enabled
    (II) OMAP5(0): TILER rotation set to 270 degrees

The panel is 720x1280 at 60 Hz and the desktop is 1280x720 rotated right. No CPU
rotate pass exists to remove. The 211 MB/s-per-copy arithmetic in the proposal
is sound but it is describing a machine other than this one.

**Memory bandwidth is already at the ceiling.** `omapconf show opp` reports
LP-DDR2 at 531 MHz with the DMM/EMIF and L3 at 265 MHz, which is the top CORE
operating point on an OMAP5432. There is no faster setting to find.

**The CPU already reaches 1.5 GHz.** The part identifies as `OMAP5432 ES2.0 GP
Device (STANDARD performance (1.5GHz))` and was observed at 1500 MHz on the MPU
rail's HIGH operating point. The problem is not the ceiling, it is how rarely
the governor goes there. See item 1.

---

## Worth doing, in order

### 0. Build a repeatable benchmark before changing anything

Nothing below can be judged without it, and several items are plausible enough
to "confirm" by eye whether or not they help.

The suite already exists in pieces and needs assembling into one script that
writes a dated file:

| Layer | Tool | Known baseline |
| --- | --- | --- |
| 3D translated | `gl4es glmark2 --visual-config red=8:green=8:blue=8:alpha=8:buffer=16:depth=24:stencil=8` | score 246 |
| 3D native GLES | `glmark2-es2` | not yet recorded |
| 2D X | `x11perf -aa10text -copywinwin500 -comppixwin500` | not yet recorded |
| CPU | `sysbench` or `7z b`, pinned, both cores | not yet recorded |
| Storage | `fio` 4K random read on the rootfs | not yet recorded |
| Thermal | zone 0/1/2 sampled through the run | 55/58/57 idle, 95 under box86 |

Record the CPU frequency trace alongside every run. Half the results below will
turn out to be governor artefacts and there is no way to tell without it.

Ten scenes in glmark2 fail to start on this hardware for a reason that is
glmark2's own bug, documented in `gl4es.md`. That is stable across runs, so the
score is still comparable to itself, but do not compare it to scores from other
machines.

### 1. Fix the cpufreq governor

**Measured.** The governor is `ondemand` with:

    up_threshold          95
    sampling_rate         20000
    sampling_down_factor  1
    io_is_busy            0
    scaling_min_freq      250000

Available steps are 250, 500, 750, 1000, 1250 and 1500 MHz.

`up_threshold 95` means a core must be 95% busy across a 20 ms window before it
steps up even one notch. The stock default is 80, and 95 is high enough that
ordinary interactive work never triggers it. `io_is_busy 0` means time blocked
on the SD card does not count as load at all, so anything I/O bound stays at the
bottom of the table. `sampling_down_factor 1` means the clock drops again at the
first idle sample. And the floor is 250 MHz, six steps below the top, so every
interaction pays a ramp.

This is a configuration choice, not a defect — somebody traded responsiveness
for heat and battery, on a fanless handheld where that is a defensible trade.
But it is a trade that was made without measurement and it is worth remeasuring.

Try, in this order, measuring each:

    up_threshold        95 -> 70
    io_is_busy           0 -> 1
    sampling_down_factor 1 -> 10
    scaling_min_freq   250 -> 500 or 750 MHz

Then compare against the `performance` governor as the upper bound. If
`performance` is not much better than tuned `ondemand`, stop tuning.

**Watch the thermals while you do this.** The passive trip is at 100°C and
sustained box86 emulation already reaches 95°C. There are five degrees of
margin, so this change genuinely can push the machine into throttling where it
previously was not. That is the honest cost, and it is why item 2 pairs with
this one.

Effort: an afternoon. Risk: thermal, real but observable.

### 2. Thermals, and where the real limit is

**Measured.** Idle is 55°C CPU, 58°C GPU, 57°C core. Sustained x86 emulation was
recorded at 95°C CPU and ~88°C GPU in the box86 work. The passive trip is
100°C, the critical trip is 125°C, and `thermal-cpufreq-0` is the bound cooling
device with a `step_wise` policy.

So the unit is not throttling today, but it is running five degrees under the
trip on a heavy workload, which means any of item 1's changes eat that margin
directly.

Two separable pieces of work:

- **Software.** `sustainable_power` reads 0, so the `power_allocator` policy is
  unavailable and `step_wise` is the only real option. Confirm that `step_wise`
  is stepping cleanly rather than oscillating, by logging zone 0 and
  `scaling_cur_freq` at 1 Hz through a sustained load. Oscillation between 1.5
  and 1.25 GHz has been reported by others on this hardware and is worse than a
  stable lower clock.
- **Hardware.** Community reports of 20–23°C reductions from improved thermal
  contact are the largest single number anywhere in this document. That is a
  physical modification, out of scope for this repository, but it is the thing
  that would make every software change above free.

Do not chase 1.8 GHz. Sustained 1.5 GHz is worth more than a peak that
immediately collapses, and the part is a 1.5 GHz-rated GP device.

Effort: measurement is an afternoon; the physical mod is a separate project.

### 3. Turn off Marco's compositor and measure

**Measured.** `org.mate.Marco.general compositing-manager` is `true`, and the X
server has `Composite`, `DAMAGE`, `MIT-SHM`, `DRI3` and `Present`, with no GLX.

With GLX disabled by fix 4, Marco's compositor has no GL path available and
falls back to XRender. Every window update is therefore redirected to an
offscreen pixmap and composited to the screen in a second pass, on a machine
whose 2D acceleration is one narrow hardware hook and otherwise the CPU.

Turn it off, run the 2D benchmark, and keep whichever wins:

    gsettings set org.mate.Marco.general compositing-manager false

The cost is losing window shadows, fades and any true transparency. On a 5-inch
720p panel that is a small price if the numbers move.

Effort: minutes to test. Risk: none, trivially reversible.

### 4. Settle the EXA question, because the shipped config argues with itself

**Measured.** `/etc/X11/xorg.conf.d/10-pyra-driver.conf` contains:

    Option "SoftEXA" "FALSE" # will disable etnaviv acceleration. CPU only EXA
                             # is actually faster, but let all the work to A15 core

The comment says this disables hardware acceleration. The X log says the
opposite:

    (II) OMAP5(0): Hardware EXA is Enabled
    (II) OMAP5(0): Viv2DEXA: Etnaviv driver found
    (II) OMAP5(0): Viv2DEXA: Vivante GC320 GPU revision 5301 found !

`SoftEXA "FALSE"` means "do not use software EXA", so the Vivante GC320 2D core
on `card2` is doing the work. Somebody wrote the comment for the opposite
setting, or changed the value and left the comment. Either way the file is
actively misleading and should be corrected once the benchmark says which value
is right.

There is a second finding in that log worth chasing:

    (II) EXA(0): Driver registered support for the following operations:
    (II)         Composite (RENDER acceleration)

Composite is the only registered operation. Solid fills and blits — which is
most of what a desktop does — are not in the list, so they appear to fall back
to software with the pixmap migration overhead that implies. That would make
this the worst of both configurations: hardware EXA's migration costs without
hardware EXA's coverage. Confirm it against the `xf86-video-armsoc-omap5` source
before believing it; the log may simply be listing only what the EXA core
considers noteworthy.

So: benchmark `SoftEXA "TRUE"` against `"FALSE"` with `x11perf`, with the
compositor off in both cases so item 3 does not contaminate the result. Also
capture power draw from the `bq27421-0` gauge, because if CPU EXA wins on speed
the GC320 may still win on battery, and that is a legitimate reason to keep it.

Effort: a morning, given item 0. Risk: none.

### 5. Find out whether the GPU rail can go above nominal

**Measured.** `omapconf show opp`:

    VDD_MM / VDD_CORE2   ...  NOM
      GPU                     425 MHz

The graphics rail is at its nominal operating point. `dpll_core_m3x2_ck` reads
425.472 MHz in the clock summary, matching. There is a higher operating point on
this part, and the difference is worth roughly a quarter of the GPU's
throughput — which would land directly on every glmark2 scene, every gl4es
frame and every emulator.

This is the highest-value unexplored item in the document and also the one most
likely to turn out to be impossible. Before getting attached to it, establish:

- Whether the device tree offers a higher GPU operating point at all. There is
  no `devfreq` node and no GPU OPP table visible under `/proc/device-tree`, so
  the DDK driver is probably setting a fixed rate.
- Whether the TWL6035 PMIC can be commanded to the matching VDD_MM voltage.
  `omapconf` reports every rail as 0.000 V and the PMIC as `ES UNKNOWN`, so
  voltage readback is not currently available, which makes this materially
  harder to do safely.
- Whether the thermal budget survives it. The GPU already idles at 58°C.

**Raising a clock without confirming the matching voltage is how silicon gets
damaged.** Do not do the clock half of this on its own. If the voltage side
cannot be verified, the correct outcome is to close this item, not to try it
anyway.

Effort: unknown, potentially large. Risk: **high, and physical.** Treat as
research, not as a change.

### 6. Measure whether Present flips or copies

The one part of the original framebuffer-copy thesis that is not already
resolved. Rotation is in hardware; what remains unknown is whether a fullscreen
client's buffers reach the scanout by flip or by blit.

`Buffer Flipping is Enabled` in the log says the driver is willing. It does not
say that any particular client's pixmaps are scanout-capable, and a client whose
buffer cannot be flipped falls back to a copy silently. The composited desktop
guarantees a copy anyway, which is another reason to do item 3 first.

Measure rather than reason about it: instrument the `armsoc` DRI3 and Present
paths, or count `DRM_IOCTL_MODE_PAGE_FLIP` against frames presented for a
fullscreen gl4es client. If the flip count tracks the frame count, this item is
closed.

Effort: a day, mostly in reading the DDX. Payoff: unknown until measured, which
is precisely why it is worth an afternoon rather than a week.

### 7. Profile gl4es before rebuilding it

The proposal to rebuild gl4es with `-mcpu=cortex-a15 -mfpu=neon-vfpv4` and LTO
is reasonable and cheap, and it is also a guess. gl4es 1.1.7.1 is the packaged
`libgl-gl4es-pyra` build; its flags are not known here.

Profile first. `perf record` a glmark2 run and find out whether the time is in
gl4es at all. Two outcomes:

- **The SGX is the bottleneck.** Then compiler flags change nothing, and the
  work belongs in item 8 instead. The 597 FPS `pulsar` result against 3 FPS
  `terrain` is what a GPU-bound suite looks like.
- **gl4es is the bottleneck**, most likely in immediate-mode batching or shader
  conversion. Then the flags are worth trying, and so is looking for GL
  operations that are cheap on desktop hardware and ruinous on an SGX. The
  Pandora-era TORCS work found exactly that, and got more from replacing one
  costly copy with an FBO render than from any compiler flag.

Note that Debian armhf's baseline is ARMv7-A with VFPv3-D16 and **no NEON**, so
a rebuild genuinely does unlock instructions the stock package cannot use. That
is the strongest argument for this item.

Effort: half a day to profile, then it depends. Risk: none.

### 8. Native GLES2 builds for the things you actually run

Strictly better than translation where it is available: one less layer, and no
fbconfig negotiation to fail. `glmark2-es2` is already installed and is the
control case that proves the SGX path works without gl4es in the picture.

This is per-application work with no general answer. It is worth doing for
whichever emulators and games get used, and worth nothing in the abstract. Pick
targets from actual use, not from a list.

Effort: per application. Risk: none.

### 9. Selective Cortex-A15 rebuilds

Smaller than the proposal claims, because the two libraries that would matter
most already do this at runtime. `libpixman-1.so.0` carries an `arm-neon`
dispatch path and selects it on this CPU, and ffmpeg does the same. Rebuilding
either buys close to nothing.

What is left is code with no runtime dispatch and a hot inner loop: emulator
cores, decompression, specific image and audio codecs. Those are worth targeting
individually, after a profile shows them at the top. A blanket archive rebuild
is a large amount of work for a result nobody has measured.

Effort: per package. Risk: rebuild divergence from the archive, which is a
maintenance cost that outlasts the speedup.

---

## Not worth doing

**Xorg to XLibre, for performance.** XLibre is a fork of the same code with the
same architecture. There is no mechanism by which it would be faster here, and
the cost is running an unpackaged X server on a device whose display driver is
an out-of-tree fork of `xf86-video-armsoc`.

It is worth exactly one look for a different reason. Fix 4 exists because
21.1.16's AIGLX DRI2 probe NULL-dereferences on every failure path, and that
single bug costs this machine desktop GLX, which in turn is what blocks wine's
3D renderer. If XLibre has fixed that probe, it retires fix 4 and unblocks
wined3d. That is a correctness question with a real payoff, and it belongs in
`fixes.md`, not here. Check the diff; do not port the server on spec.

**Stripping legacy code from X.** Dead code that is never called costs nothing
at runtime. This is a build-size exercise wearing a performance costume.

**Writing an open-source SGX driver.** Mesa's PowerVR driver starts at Rogue.
SGX544 is not supported and will not be, and the architecture is undocumented.
This would be a multi-year reverse-engineering project and it would be the right
project for somebody, but it is not a performance task and it does not belong on
the same list as tuning a governor.

**Chasing memory bandwidth.** Already at the top CORE operating point. Nothing
to gain.

---

## Smaller items, unranked

- **No swap and no zram**, with 4 GB of RAM and 2.5 GB free at idle. Not a
  problem today. It becomes one the first time a browser is opened, and `zram`
  with `lz4` is the cheap answer if it does.
- **The rootfs mounts with inline `discard`** (`f2fs ... background_gc=on,discard`).
  Inline discard on an SD card can stall writes; `nodiscard` plus a weekly
  `fstrim` timer is usually better. Worth one `fio` run to find out. The rest of
  the mount options are already sensible — `lazytime` and `relatime` are both
  set.
- **Two kworkers are permanently in `D` state** on `events_freezable`, pinning
  the load average near 2.0 while the CPU is ~80% idle. Documented as cosmetic
  in `troubleshooting.md` and present from the image's first boot. It is still
  worth ten minutes with `/proc/36/stack` to find out what they are blocked on,
  because a driver blocked forever on an i2c transfer is not always harmless.
- **`Option "SwapbuffersWait" "true"`** ties buffer swaps to vblank. That is
  almost certainly correct — it is what prevents tearing — but it caps
  fullscreen throughput at 60 FPS and should be named as a deliberate choice
  rather than discovered during a benchmark that mysteriously refuses to exceed
  60.

---

## Baseline, as measured on 2026-09-09

Recorded so that later runs have something to compare against.

| Thing | Value |
| --- | --- |
| Kernel | 5.6.19-pyradef, SMP PREEMPT |
| CPU | 2x Cortex-A15 r2p2, 250–1500 MHz, `ondemand` |
| RAM | 3940 MB, no swap |
| MPU rail | HIGH operating point, 1500 MHz |
| GPU rail | NOM operating point, 425 MHz |
| L3 / EMIF | 265 MHz, LP-DDR2 at 531 MHz |
| DSS | 192 MHz |
| Temperatures, idle | CPU 55°C, GPU 58°C, core 57°C |
| Trips | passive 100°C, critical 125°C |
| Panel | 720x1280 at 60 Hz, rotated right to a 1280x720 desktop |
| DRM | `card0` omapdrm, `card1` pvrsrvkm SGX544, `card2` etnaviv GC320 |
| X | 21.1.16, `omap5` DDX, hardware EXA via Viv2D, DRI3 + Present, no GLX |
| Compositor | Marco, compositing on |
| 3D | gl4es 1.1.7.1 onto DDK 1.14.3699939, glxgears ~870 FPS, glmark2 246 |
