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
| Optimise 2D X rendering, EXA, pixman | Medium–large | **Fills and blits are already accelerated.** The gap is image readback |
| *(not on the original list)* Turn the compositor off | — | **Done and measured. 3.5% of all busy CPU, one command** |
| *(not on the original list)* Fix the modeset hang | — | **Outranks everything here.** See `troubleshooting.md` |
| Cortex-A15 / NEON rebuilds | Medium | Smaller than claimed. pixman already dispatches NEON at runtime |
| Xorg to XLibre | Small–medium | **No performance value.** Possible correctness value, see below |
| Strip legacy code from X | Small | None. Dropped |

Five things the original list did not contain outrank most of what it did. The
first is not a performance item at all, and it still comes first.

- **The display driver wedges inside a modeset** and only a reboot recovers it,
  spinning a core at 100% inside a fanless case while it does. Every DPMS
  transition is a modeset. Mitigated, not fixed, in `troubleshooting.md`.
- The `ondemand` governor is set to step up only at **95% load**, with I/O wait
  not counted as load and a 250 MHz floor. Still untouched, still the cheapest
  performance item.
- **PulseAudio spends 16% of a core** converting every audio stream to the only
  format the codec accepts. Measured, understood and unreachable. See item 10.
- The MATE window manager was **compositing**, with GLX disabled, so every window
  update took an extra XRender pass. Measured at 3.5% of all busy CPU and now
  turned off. See item 3.
- The GPU rail sits at its **nominal** operating point, not its top one.

---

## What the whole machine is actually doing

Added 2026-09-10. Every earlier section measures one subsystem at a time. This
one accounts for **all** the busy CPU on the machine across a real workload, by
process, which changes the ranking above more than any single measurement so
far. `pyra-cpu-attribution.sh` produces it and needs no privileges.

Two runs of Anno 1602 under box86, sixty seconds of sampling each, taken at
different points in the same game. The two columns are the same measurement at
two moments, and the spread between them is the honest error bar:

| process | run 1 | run 2 |
| --- | --- | --- |
| `1602.exe` | 56.0% | 49.9% |
| `pulseaudio` | below the noise | **14.0%** |
| `Xorg` | 13.6% | 12.3% |
| `marco` | 3.6% | 3.4% |
| `wineserver` + `winedevice.exe` | 2.2% | 4.0% |
| GC320 kernel thread `59000000.bb2d` | 0.7% | 0.7% |
| kernel threads and short-lived processes | 21.5% | 10.9% |
| machine busy, both cores | 87.9% | 58.7% |

Split by kernel accounting class, the second run was 60.4% user, 35.3% system,
3.6% hard IRQ and 0.5% softirq. So the interrupt path is not where the time
goes, which rules out a whole family of guesses cheaply.

**PulseAudio is the finding.** It appears in one run and not the other because
the game's music had started, and when it plays it costs more than the
compositor and nearly as much as the X server. Nothing in the earlier work
looked at audio at all.

An idle desktop is 5.9% busy across both cores, and at the login screen with no
session it is 7.4%. In both cases the largest consumers are kernel threads,
mostly two i2c interrupt threads. See the last section for what those are.

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
| 2D X | **not `x11perf`.** See below | see "against the game" below |
| CPU | `sysbench` or `7z b`, pinned, both cores | not yet recorded |
| Storage | `fio` 4K random read on the rootfs | not yet recorded |
| Thermal | zone 0/1/2 sampled through the run | 55/58/57 idle, 95 under box86 |

Record the CPU frequency trace alongside every run. Half the results below will
turn out to be governor artefacts and there is no way to tell without it.

Ten scenes in glmark2 fail to start on this hardware for a reason that is
glmark2's own bug, documented in `gl4es.md`. That is stable across runs, so the
score is still comparable to itself, but do not compare it to scores from other
machines.

**Do not use `x11perf` on this machine.** It disables and restores DPMS around
every single test, each of those is a full modeset in the `omap5` driver, and
that modeset path wedges the display hard enough to need a reboot. Two hangs
came from it on 2026-09-10. `troubleshooting.md` has the counting that proves
it.

What to use instead, all of which are in this repository and none of which touch
DPMS:

| Question | Tool |
| --- | --- |
| where is all the CPU going | `pyra-cpu-attribution.sh` |
| what share is the X server | `pyra-x-load-profile.sh` |
| a real, repeatable, bounded load | `pyra-anno1602-test.sh` |
| driver fallback costs against hardware paths | `pyra-exa-fallback-bench.c` |

**Measure against the game, and compare ratios rather than absolutes.** The
game's own CPU varies from 30% to 88% of a core depending on what is on screen,
so the same change measured on two runs can look like anything. Each process's
cost *relative to the game's own CPU* reproduces to within a few percent. That is
what made the compositor question answerable in item 3 and it is the method to
use for everything below.

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

**Six steps may not be all there are.** Added 2026-09-12. A third-party device
tree in `experiments/thermals-and-frequency/` adds five steps below 1.5 GHz —
375, 625, 875, 1125 and 1400 MHz — at voltages interpolated on the stock curve,
with every existing step keeping its stock voltage to the microvolt. That half
of it is not overclocking, and it speaks directly to two of the complaints
above: the 250 MHz floor is six steps below the top because the steps are
coarse, and a ramp that has to cross 250 MHz gaps is a slower ramp than one
that does not. **Measured 2026-09-12, and the answer is not the one this item expected.**
`./pc/pyra-crossbuild.sh kernel-freq` carries exactly those five steps and
nothing else, and two runs on each kernel say that finer steps do not improve
responsiveness at all: bursty work is about 4% slower on the mean and 18%
slower in the best case, because the governor now has somewhere comfortable to
stop short of the top. What they buy instead is idle power. With six steps the
governor spends 7.3% of an *idle* machine at 1.5 GHz, since the step above
500 MHz is 750 and the ramp overshoots; with eleven it reaches the top 0.1% of
the time. That is 0.27 W, about 6.5%, or roughly 21 minutes of the 21.3 Wh
battery.

So the reasoning in this item was wrong about the benefit and right that the
step table was worth changing. It also does not overlap with the three
misconfigurations below, which remain untested: a finer table and a tuned
governor are separate experiments, and the second is more interesting now that
the first exists. Full numbers in
`experiments/thermals-and-frequency/README.md`. The same published table also
carries five steps above the part's rating; those are a separate patch and a
separate build, deliberately.

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

  **Measured 2026-09-12, and it is worse than oscillation: the trip does not
  hold.** `7z b` on both cores took the CPU zone from 64°C to **107°C**, seven
  degrees past the 100°C passive trip, in under two minutes, and the run was
  stopped by the profiler rather than by the kernel. The zone is configured
  correctly — `cooling-maps` present, `thermal-cpufreq-0` bound with ten
  states, `polling-delay-passive` 250 ms — so this is not a missing binding.
  `step_wise` simply concedes one cooling state per poll, and on a fanless case
  this load outruns it. The userspace `pyra-thermal.sh` cannot help either: it
  polls every 20 seconds, which is an age at this heating rate.

  Nothing was damaged, the critical trip at 125°C was never approached, and the
  machine was healthy afterwards. But 107°C is the answer to "where is the real
  limit", and it is a property of this hardware rather than of any kernel here:
  every kernel in this repository tops out at the same 1.5 GHz. It also means
  the five degrees of margin quoted above are not margin at all under a load
  heavier than box86.

  Two cores flat out is therefore not a benchmark this machine should be asked
  to run repeatedly. `device/pyra-freq-profile.sh` uses one core for exactly
  this reason and aborts at the trip rather than above it.
- **Hardware.** Community reports of 20–23°C reductions from improved thermal
  contact are the largest single number anywhere in this document. That is a
  physical modification, out of scope for this repository, but it is the thing
  that would make every software change above free.

Do not chase 1.8 GHz. Sustained 1.5 GHz is worth more than a peak that
immediately collapses, and the part is a 1.5 GHz-rated GP device. That advice
predates the unlocked device tree now sitting in
`experiments/thermals-and-frequency/`, which offers 1.6 through 2.0 GHz, and it
is unchanged by it. The blob's own author says plainly that 2 GHz needs
modified cooling and that they can hardly run it; this unit has five degrees of
margin at 1.5 GHz under load.

Effort: measurement is an afternoon; the physical mod is a separate project.

### 3. Marco's compositor — done, and it was worth taking

**Resolved 2026-09-10. Compositing is off on this unit.**

The reasoning that put it on the list was sound. With GLX disabled by fix 4,
Marco's compositor has no GL path and falls back to XRender, so every window
update is redirected to an offscreen pixmap and composited in a second pass, on
a machine whose 2D acceleration is one narrow hardware hook and otherwise the
CPU. The X server has `Composite`, `DAMAGE`, `MIT-SHM`, `DRI3` and `Present`,
and no GLX.

The open question was whether that second pass also made the X server itself
work harder, which would have made the compositor cost much more than it
appeared to. It does not.

**Measured 2026-09-10. Turning it off is worth about 3.5% of all busy CPU, and
costs the X server nothing.** Take it.

The comparison could not be done with `x11perf`, because `x11perf` toggles DPMS
around every test and that is what wedges the display driver on this machine.
See `troubleshooting.md`. It was done against the game instead, which is the
more honest test anyway.

The catch is that the game's own CPU varies enormously between runs, from 30% to
88% of a core depending on what is on screen, so absolute figures cannot be
compared across runs. What is stable is each process's cost *relative to the
game*, and that comparison is clean:

| | compositing on, run 1 | on, run 2 | off |
| --- | --- | --- | --- |
| `Xorg` / game CPU | 0.243 | 0.246 | 0.240 |
| `marco` / game CPU | 0.064 | 0.068 | below 0.010 |

So the compositor costs what it appears to cost and nothing more. It does not
make the X server work harder, which was the open question, and switching it off
removes `marco` almost entirely: under 0.46 s of CPU in a 60 s window against
2.38 s and 3.37 s with compositing on, a reduction of at least five times.

In whole-machine terms that is roughly 3.5% of all busy CPU returned, for one
`gsettings` call, with no effect on anything else measured. It is the largest
confirmed win in this document that costs nothing to take.

    gsettings set org.mate.Marco.general compositing-manager false   # take it
    gsettings set org.mate.Marco.general compositing-manager true    # revert

What it costs is window shadows, fades and true transparency.

### 4. Correct the EXA comment, and chase the readback path instead

**Resolved.** Both halves of this item have been settled against the driver
source and the running unit. The config comment is wrong, hardware EXA is on,
and fills and blits are accelerated. The real gap is somewhere else.

**Hardware EXA is enabled.** `/etc/X11/xorg.conf.d/10-pyra-driver.conf` carries:

    Option "SoftEXA" "FALSE" # will disable etnaviv acceleration. CPU only EXA
                             # is actually faster, but let all the work to A15 core

The comment is backwards. In `armsoc_driver.c` the option is read straight into
`pARMSOC->SoftExa`, logged as `Hardware EXA is %s` with `SoftExa ? "Disabled" :
"Enabled"`, and `ARMSOCAccelInit` calls `InitViv2DEXA` under `if
(!pARMSOC->SoftExa)`, falling through to `InitNullEXA` only if that fails. So
`FALSE` selects the Vivante path, which is what the log reports:

    (**) OMAP5(0): Option "SoftEXA" "FALSE"
    (II) OMAP5(0): Hardware EXA is Enabled
    (II) OMAP5(0): Viv2DEXA: Vivante GC320 GPU revision 5301 found !
    (II) OMAP5(0): Viv2DEXA: initialized.

The comment describes the setting somebody rejected. Fix the comment; leave the
value alone until the benchmark says otherwise.

**Fills and blits do not fall back.** The earlier reading of the log was an
artifact of a filtered `grep`. The unfiltered block lists three operations:

    (II) EXA(0): Driver registered support for the following operations:
    (II)         Solid
    (II)         Copy
    (II)         Composite (RENDER acceleration)

`Solid` and `Copy` were there all along. Confirmed on the hardware by sampling
the etnaviv command-DMA address in `/sys/kernel/debug/dri/2/gpu` while a
benchmark ran. (The `x11perf` figures in this item and the next were taken on
2026-09-09, before `x11perf` was found to wedge the display driver. They stand as
a record; do not reproduce them that way. See item 0.) Idle, the address never moves. Under `x11perf -rect500` it took
6 distinct values, and under `-copywinwin500` it took 12. The GC320 is executing
both.

The rates agree. A 500x500 fill is 1 MB of writes and a copy is 1 MB each way:

| operation | rate | implied traffic |
| --- | --- | --- |
| `-rect500` | 2370/sec | 2.4 GB/s written |
| `-copywinwin500` | 1670/sec | 3.3 GB/s moved |
| `-copypixpix500` | 1670/sec | 3.3 GB/s moved |

LP-DDR2 at 531 MHz cannot give a CPU memcpy those numbers, so this is not a
software path.

**The real gap is image transfer, not drawing.** `libexa.so` can print five
operation names, and the log printed three. The two it did not print are
`UploadToScreen` and `DownloadFromScreen`, and the driver's build config has
both hooks commented out:

    //#define VIV2D_UPLOAD_TO_SCREEN 1
    //#define VIV2D_DOWNLOAD_FROM_SCREEN 1

With no hook, every image transfer goes the generic route: EXA maps the buffer
object and the CPU copies through it. That shows up immediately:

| operation | rate | implied throughput |
| --- | --- | --- |
| `-putimage500` | 318/sec | 318 MB/s in |
| `-shmput500` | 988/sec | 988 MB/s in |
| `-getimage500` | 61.6/sec | 62 MB/s out |

Readback at 62 MB/s is 27 times slower than the accelerated copy of the same
rectangle. That is the signature of the CPU reading uncached GPU memory, and it
lands on anything that pulls pixels back off the screen. This, not the drawing
path, is where the migration cost the previous entry worried about actually
lives.

Two things follow. Anything that can use `MIT-SHM` should, since it is three
times the plain path. And building the driver with the two transfer hooks
enabled is now a concrete experiment with a number attached to it, rather than
a guess.

**The three fallbacks, now measured.** Each was benchmarked on the running
unit. One is worth implementing, one is worth a look, and one was a bad idea
based on a wrong reading of the code.

First, the baselines everything below is judged against. All three are the same
500x500 region, and the software figures are guaranteed software because the
pixmaps involved are larger than `VIV2D_MAX_SIZE` and so are `malloc`ed rather
than allocated on the GPU:

| path | throughput |
| --- | --- |
| `memcpy` in userspace, for reference | 2130 MB/s |
| GC320 hardware copy | 1750 MB/s |
| X server software `fb` copy | 161 MB/s |

The X server's own software path is 13 times slower than a plain `memcpy` on
the same CPU at the same clock. That gap, not the GPU's speed, is what makes a
fallback expensive. The CPU was sampled at 1.5 GHz throughout, so none of this
is the governor from item 1.

*Raster ops other than `GXcopy` — worth implementing.* An XOR fill runs at
5.7 Mpix/s, which is 23 MB/s. That is 76 times slower than a hardware copy and
7 times slower than even the software `GXcopy` path, because the X server
handles non-copy ops with its fully generic bit-blit code.

The GC320 supports this in hardware. `state_2d.xml.h` exposes `VIVS_DE_ROP`
with ROP2, ROP3 and ROP4 types, `_Viv2DStreamDst` already takes a `rop`
argument, and `viv2d.h` already defines all sixteen ROP codes in X's own `alu`
order. Every one of the thirteen call sites passes the hardcoded `ROP_SRC`.
Somebody laid the groundwork and never wired it up. Removing the two `alu !=
GXcopy` rejections and passing a table lookup instead of `ROP_SRC` is the whole
change.

What is not known is how often a modern desktop asks for one. GTK and cairo go
through RENDER, not core raster ops, so the likely callers are rubber-band
selections and the emulators this device exists to run. Measure before
building: see the counting method below.

*`A8` destinations — worth a look, for copies only.* Splitting this by
operation changes the answer.

| operation into a depth-8 pixmap | rate |
| --- | --- |
| fill | 1347 Mpix/s |
| copy | 34 MB/s |

Software fills into an alpha-only surface are essentially `memset` and are
already faster than the GPU would be at one byte per pixel, so defining
`VIV2D_SUPPORT_A8_DST` buys nothing there. Copies are the opposite case, about
50 times off the hardware path, because the fallback has to read the source
through the same generic code. Only copies into `A8` would benefit, and the
setting is marked experimental upstream, so it needs correctness checking as
well as a benchmark.

*`VIV2D_MIN_SIZE` — leave it at zero.* The previous entry's reasoning here was
wrong twice over, and the measurements confirm the header's own comment.

`VIV2D_MIN_SIZE` is not an operation threshold. It is used once, in
`Viv2DAllocBuf`, to decide whether a whole pixmap gets a GPU buffer or a
`malloc`, so it cannot express a per-operation cutoff at all. And there is no
per-operation submit to avoid: `Viv2DDoneSolid` and `Viv2DDoneCopy` only append
to a 32 KB command stream, which is flushed when it fills or on the X server's
flush callback. A thousand small fills cost stream bytes, not a thousand
submits, which is why a 10x10 fill measures 0.37 us.

The one thing raising it would do is move small pixmaps to `malloc`, and that
turns out to be worth nothing. Running identical software paths against a
write-combine GPU buffer and against plain `malloc` gives the same number every
time:

| identical software path | GPU write-combine | plain malloc |
| --- | --- | --- |
| XOR fill 1000x1000 | 5.7 Mpix/s | 5.7 Mpix/s |
| depth-8 copy 1000x1000 | 34.5 MB/s | 33.9 MB/s |
| `GetImage` 1000x1000 | 43.5 MB/s | 46.8 MB/s |

So the write-combine mapping costs nothing measurable, and switching the
allocator to `ETNA_BO_CACHED` — which the code is already structured for, since
every CPU access is bracketed by `etna_bo_cpu_prep` and `etna_bo_cpu_fini` —
would gain nothing either. That idea is closed.

*A real per-operation cost the config cannot reach.* Every hardware copy
carries a fixed cost that swamps small operations. A size sweep of
pixmap-to-pixmap copies is nearly flat from 8x8 to 32x32, at 22.7, 18.1 and
16.6 us, because almost none of that time is the pixels. The software path has
no such floor: at 162 MB/s a 16x16 region is 6 us of work and an 8x8 region is
under 2 us.

That puts the crossover somewhere around 30x30, which is roughly where the
header's commented-out `VIV2D_MIN_SIZE 1024*4` sits. Both paths have fixed
costs the sweep cannot cleanly separate, so treat that as an order of
magnitude rather than a threshold to hardcode. The point is that capturing it
needs a size check inside `Viv2DPrepareCopy`, where the operation's dimensions
are known. `VIV2D_MIN_SIZE` is applied to whole pixmaps at allocation time and
never sees an operation at all.

**How to get the frequencies.** Everything above is a per-operation cost. None
of it says how often a real session hits these paths, and that is what decides
whether any of it is worth building.

Take the cheap measurement first, because it can rule the whole question out.
`pyra-x-load-profile.sh` samples the X server's CPU consumption across a real
workload and reports it as a share of one core, of the machine, and of all
busy CPU time. The display driver cannot give back more than that share, so if
Xorg is at two percent while a game runs, nothing in `omap5_drv.so` is worth
changing for that workload. It also reports whether the GC320 moved at all and
whether clients are presenting through `MIT-SHM`. It needs no rebuild and
changes nothing.

This has now been run against the real thing. `pyra-anno1602-test.sh` starts
Anno 1602 under box86 and x86 Wine, which is the heaviest sustained load this
machine has been put under, and profiles the X server across it:

| workload | Xorg, share of one core | Xorg, share of all busy CPU |
| --- | --- | --- |
| idle desktop | 0.03% | negligible |
| Anno 1602 under box86 | 16.0% | 9.3% |
| synthetic 2D drawing load | 9.6% | 27.0% |

The middle row is the one that decides this. During the game the machine was
87.9% busy, the game itself held 92% of a core, and everything the X server did
came to 9.3% of the busy time. That is the ceiling on the entire driver
question for this workload, and it assumes the X server could be made free,
which it cannot. Most of that 9.3% is legitimate accelerated work, not
fallbacks. The GC320 was active throughout, and clients were presenting through
`MIT-SHM`, which is already the fast upload path.

So the honest expected return on the EXA work, for this workload, is a fraction
of 9.3%. That does not justify a driver rebuild on performance grounds. It may
still be worth doing for the emulator titles that use a raster op or a plain
`PutImage`, but that is a correctness-shaped argument about specific titles, not
a general performance one, and it needs the same measurement run against those
titles first.

Only if that number is large is a rebuild justified. Then define
`VIV2D_UNSUPPORTED` in `viv2d_config.h`, rebuild, run a desktop session and an
emulator session, and count the `unsupported` lines in the X log by category.
That turns all three of these from costs into budgets.

**Known fallbacks not yet measured.** Surfaces above `VIV2D_MAX_SIZE`, which is
16 MB. The 720x1280 screen is 3.5 MB, so this never fires for on-screen work.

The config header is trustworthy here: its `UploadToScreen` and
`DownloadFromScreen` settings predict exactly what the shipped binary logged,
and the binary carries none of the `VIV2D_UNSUPPORTED` debug strings, which the
same header also disables.

**Still open.** Whether `SoftEXA "TRUE"` beats `"FALSE"` on this panel is
unmeasured, and the comment's claim that CPU EXA is faster is not disproven by
any of the above. Benchmark both with the compositor off so item 3 does not
contaminate the result, and capture power draw from the `bq27421-0` gauge,
because if CPU EXA wins on speed the GC320 may still win on battery.

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

### 10. Audio: the second-largest consumer, and why it has no knob

**Measured 2026-09-10, and this is a negative result with a number attached.**

When the game plays music, `pulseaudio` takes 14% of all busy CPU, about 16% of
one core. That puts it above the compositor and level with the X server, and
nothing in this document had looked at it before.

Two thirds of that is conversion, not mixing. The same thirty seconds of audio,
played three ways with `paplay`:

| stream | PulseAudio cost |
| --- | --- |
| 22050 Hz, needs conversion | 10.3% of one core |
| 44100 Hz, needs conversion | 11.1% of one core |
| 88200 Hz, matches the hardware | 3.5% of one core |

It is a cliff, not a curve. A stream that matches the sink is copied; anything
else pays the full conversion pipeline, and the input rate barely matters, which
is why the 44100 case costs slightly more than the 22050 one despite the smaller
ratio.

The cause is the codec. `aplay --dump-hw-params` on the TWL6040 gives:

    FORMAT:  S32_LE
    CHANNELS: [1 5]
    RATE: [88200 96000]

There is no 44100 and no `S16_LE`. So every ordinary audio stream on this
machine is upsampled to 88200 and widened to 32 bits before it can be played,
and there is no configuration that avoids it.

Four candidate fixes were tested and all four are already correct or already
ruled out:

- **The resampler.** `resample-method` is already `trivial`, the cheapest one
  PulseAudio has. Nothing to gain.
- **NEON.** The daemon detects it and uses it. Startup logs
  `sconv_neon.c`, `mix_neon.c` and `remap_neon.c` all initialising, and the CPU
  flags line reads `V6 V7 VFP EDSP NEON VFPV3`. This is worth knowing on its own,
  because item 9 predicts exactly this for well-maintained libraries.
- **The two remap sinks.** `pyra.pa` stacks `speakers` and `headphones` on the
  4-channel ALSA sink to split the codec's outputs. Playing straight to the ALSA
  sink instead measures 10.6% against the remap sink's 10.5%, so the extra layer
  is free and the channel split is not the cost.
- **Making the source match.** The only remaining lever, and it backfires. The
  source here is Wine's DirectSound mixer, which is x86 code running under
  box86. Moving the resample there moves it from native ARM into emulation.

So this is understood, quantified, and currently unreachable. It is recorded
because the next person to look at audio should not spend the afternoon
rediscovering that `resample-method` is already `trivial`.

The one untested idea: the sink runs 4 channels because the codec puts speakers
and headphones on separate pairs. A 2-channel sink would halve everything
downstream of the conversion, at the cost of the output switching. `CHANNELS:
[1 5]` says the hardware allows it. Whether it is worth losing the headphone
split is a product decision, not a performance one.

### 11. The i2c interrupt floor

**Measured, and small enough to close.** At the login screen with no desktop
session, the machine is 7.4% busy and a third of that is interrupt handling for
two i2c buses:

| bus | interrupts per second | what is on it |
| --- | --- | --- |
| `48072000.i2c` | 457 | the two AS5013 analog nubs, keypad, fuel gauge, charger |
| `48070000.i2c` | 265–511 | Palmas PMIC, TWL6040 codec, USB hub |

That is 858 interrupts a second on an idle machine, against 211 a second for the
system timer. It costs 2–3% of one core, permanently, in hard IRQ time.

The nubs are polled by the kernel whether or not anything reads them. Stopping
`pyrainput.service`, which is the only thing holding `/dev/input/event1` and
`event2` open, does not change the rate: 457/s running, 451/s stopped, 455/s
restarted. The `as5013` driver is built in, exposes no module parameters and no
`poll_interval`, so changing this means a kernel patch.

Why it polls at all is now known, and it is not a tuning choice. The device tree
wires no interrupt to either chip, so probe falls back to a delayed work item and
a `#define` of 25 ms. The poll never stops because the driver has no close
callback, which is exactly what the measurement above shows and why stopping the
daemon changes nothing. The interesting version of this item is therefore not
"poll less often" but "wire the interrupt", which is a device tree question and a
much larger one.

The same reading is now the instrument for a correctness fault rather than a
performance one: a rate of zero after a resume is the nub bug that
`patches/0005` fixes. See `troubleshooting.md`.

Do not bother. There is exactly one cpuidle state on this kernel, `C1`, so the
wakeups are not blocking a deeper sleep, and the whole prize is 2–3% of one core
for a kernel change on an out-of-tree tree. Recorded so nobody re-derives it.

That single idle state is itself worth a look, but as a battery question rather
than a throughput one. It is item 12.

---

### 12. The retention idle state this kernel switches off

**Tried on 2026-09-12. It hangs the machine within two minutes. Closed.** The
rest of this item is kept because the reasoning was right and only the answer
was disappointing; the result is at the end.

The processor idles in exactly one state:

    $ cat /sys/devices/system/cpu/cpuidle/current_driver
    omap5_idle
    $ cat /sys/devices/system/cpu/cpu0/cpuidle/state0/desc
    CPUx WFI, MPUSS ON

One state, and it is the shallowest one there is: wait for an interrupt with
the whole processor subsystem left powered. Mainline has a second one for this
chip, `C2`, which puts both cores and the subsystem around them into retention.
This kernel does not, because this kernel comments it out:

    #if 0
            {
                    /* C2 - CPU0 RET + CPU1 RET + MPU CSWR */
                    .exit_latency = 48 + 60,
                    ...
    #endif

That is in `arch/arm/mach-omap2/cpuidle44xx.c`, and it is a change carried by
the Pyra's kernel tree rather than anything upstream. Mainline 5.6 has the
state enabled, and so does mainline today. The same tree adds a separate copy
of the driver for a related chip and leaves `C2` switched on there, so this was
a decision about this processor specifically, not a blanket removal.

**Why it might be worth a lot.** The commit that added the state upstream,
`7abdb0e23e7b` in 2016, reports the measurement that motivated it: idle power
on the reference board fell from about 1.7 W to about 920 mW. That board is not
a Pyra and the number will not transfer, but the fraction is not the kind of
thing any of the other items on this list can offer.

**Why it is dangerous.** The `#if 0` carries no comment, and nothing in the
packaging explains it. A silent `#if 0` around a low-power state almost always
means somebody found that it hung, and the failure mode for a broken retention
state is a machine that stops answering and needs the battery pulled. It is
also the same chip whose suspend path already declines to put five power
domains into their target state, which is not encouraging about how well
retention works here.

**How to try it, if you try it.** Build a kernel with the two `#if 0`/`#endif`
pairs removed, install it with `device/pyra-install-debug-kernel.sh` so the
stock kernel keeps its boot entry, and select it with `pyra-boot-kernel.sh` in
its one-shot mode, which reverts by itself if the machine does not come back.
Then check that a second state appeared and that its usage count moves:

    grep . /sys/devices/system/cpu/cpu0/cpuidle/state*/{name,usage}

Measure before and after with the fuel gauge over an hour of idle, the same way
`docs/troubleshooting.md` describes for suspend. Do this on a day when you can
afford to lose the machine to a hang, and not before the display fix is
confirmed, because a hang in the idle path and a hang in a modeset look the
same from the outside.

**What happened.** The state works exactly as advertised and the machine dies
anyway. Two boots on `5.6.19-c2`, both wedged with no warning and nothing in
the log. The governor had been reaching for the state constantly: in the first
minute of uptime the first core entered retention 25367 times and spent 31.7
seconds of that minute in it, more wall clock than it spent in the shallow
state.

| kernel | boots | how long each lasted |
| --- | --- | --- |
| `5.6.19-fix` | 4 | hours |
| `5.6.19-c2` | 2 | 48 s and 74 s |

Neither death left anything behind. Both ended mid-log with no warning, no
backtrace, no watchdog, and no response on either network interface, which
rules out the display hang: that one spins a core and leaves the machine
reachable, which is the only reason its backtrace trap works.

Two things in the log looked like the cause and are not. The `L3 Custom Error`
warning from the interconnect and a `blocked for more than 30 seconds` hung
task in the USB ethernet adapter's probe both appear on the C2 boots, and both
also appear on every fix and stock boot, including the healthy one running now.
They are pre-existing noise and have nothing to do with this.

So the evidence is entirely circumstantial and entirely one-sided: two for two,
within about a minute, against a kernel that is otherwise identical and runs
for hours. The `#if 0` in the tree is best read as somebody having found the
same thing. Reopening this would need a serial console, because whatever
happens takes the machine before it can write a word.

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

Recorded so that later runs have something to compare against. Rows marked with a
date have been changed deliberately since; everything else is as the image shipped.

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
| Compositor | Marco, compositing **off** since 2026-09-10, see item 3 |
| Display blanking | disabled, see `troubleshooting.md`. Was 600 s |
| Login | autologin, see `procedure.md` section 7. Was a greeter |
| 3D | gl4es 1.1.7.1 onto DDK 1.14.3699939, glxgears ~870 FPS, glmark2 246 |
