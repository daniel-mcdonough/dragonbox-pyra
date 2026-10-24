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
| Eliminate framebuffer copies, fix TILER | Potentially enormous | **Rotation is already in hardware.** But fullscreen games are *copied* to the scanout by the GC320, not flipped (item 6) |
| Optimise gl4es / native GLES paths | Large | Real but unquantified. Measure before building |
| Sustained CPU clocks and thermals | Large | **Real, and measured 2026-09-13.** The governor was misconfigured, but not in any of the three ways named below — the one setting that pays is not on that list. Applied, and the thermal side became fixes 6 and 7 |
| Optimise 2D X rendering, EXA, pixman | Medium–large | **Fills and blits are already accelerated.** The gap is image readback |
| *(not on the original list)* Turn the compositor off | — | **Done and measured. 3.5% of all busy CPU, one command** |
| *(not on the original list)* Fix the modeset hang | — | **Outranks everything here.** See `troubleshooting.md` |
| *(not on the original list)* Transparent huge pages | — | **Not built at all.** One config symbol, plausible, unmeasured. See item 13 |
| *(not on the original list)* Kernel security options, traded for speed | — | **Surveyed 2026-09-20.** One is worth 1-3%, everything else nothing. See item 14 |
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

> **Corrected 2026-10-18.** The first of those lines is about DRI2. It reports
> the `NoFlip` option, which only the DRI2 swap path reads. GLES clients present
> through DRI3 and Present, which cannot flip in this driver (§6). The rotation
> claim stands.

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
this one. (Those five degrees turned out not to exist — a load heavier than
box86 walks seven degrees *past* the trip, and nothing in userspace was capping
at all. Item 2 has it.)

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
misconfigurations below, which were untested when this was written and were
measured the next day: a finer table and a tuned governor are separate
experiments, and the second is more interesting now that the first exists. All
three turned out to be worth 1–2% each — see the 2026-09-13 note at the end
of this item. Full numbers in
`experiments/thermals-and-frequency/README.md`. The same published table also
carries five steps above the part's rating; those are a separate patch and a
separate build, deliberately.

Effort: an afternoon. Risk: thermal, real but observable.

**Measured 2026-09-13, and this item named the wrong settings.** Full numbers
and method in `experiments/governor/README.md`. Two interleaved passes per
configuration on `5.6.19-freq`, on battery, thermal daemon stopped and the
ceiling pinned, pass-to-pass spread 0.0-2.3%.

Of the four settings listed above, three are worth nothing: `up_threshold` at
80 or 70 buys about 1% of burst latency, `io_is_busy` about 1%, a 500 MHz floor
about 2%. A 750 MHz floor buys 8.4% and costs 83% more idle frequency to do it.

The one that pays is `sampling_down_factor`, listed third here and passed over:
**1 to 10 is 23.4% of burst latency and a third of the median**, 53.5 ms to
36.0 ms, for 5.4% more idle frequency. Setting all four together is 24.5%,
which is the same number inside the spread, so the whole win is one value.

The reasoning in this item was that a core must be 95% busy across 20 ms before
the governor steps up and that ordinary work never triggers it. That describes
the setting correctly and draws the wrong conclusion: the work does trigger a
step up, and the time goes on the governor stepping back *down* between units.
`sampling_down_factor` is the setting that stops it.

Two things temper it. The tail barely moves — p99 improves 6.4% against a 33%
improvement at the median — because the clock is held up *between* units of a
burst but the first unit after real idle still pays the full ramp, and
"sluggish" is a description of a tail. And tuned `ondemand` is still 18% off
the `performance` governor, a larger gap than tuning closed.

**Applied 2026-09-13.** `device/pyra-governor-tune.sh` sets the one value and
`pyra-governor-tune.service` reapplies it at boot, since a sysfs write does not
survive one. Confirmed on the live machine after applying, with the ceiling
steady at 1500 MHz: 40.9 ms against 52.5 ms at stock and 35.6 ms against 52.0
at the median, which is -22.1% and -31.5% — the sweep predicted -23.4% and
-32.7%. `--undo` puts it back.

This item can be closed. What remains of it is the 18% gap to the `performance`
governor, which is the ramp itself and which no `ondemand` setting reaches.

**One thing left in it needs a rebuild, found 2026-09-20 while surveying the
config for item 14.** `CONFIG_CPU_FREQ_GOV_SCHEDUTIL is not set`, so the
governor that would attack the remaining 18% is not built. Every other governor
is. `schedutil` drives frequency from the scheduler's own utilization signal at
scheduler events, rather than from a sampled 20 ms window, which is exactly the
mechanism the ramp tail in this item is made of — the tail that
`sampling_down_factor` could not touch, because it holds the clock up *between*
units of a burst and the first unit after real idle still pays.

That is a reason to try it, not a prediction that it wins. It still ramps, this
is a two-core ARM32 without EAS, and a well-tuned `ondemand` is a harder
baseline to beat than an untuned one. It is one symbol in the same rebuild as
item 13 or 14 and it is measurable with the sweep already written in
`experiments/governor/`, so the cost of finding out is small. The one number to
beat is already recorded: 18% off `performance`.

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

  **And the userspace half is not running at all.** Found 2026-09-12 while
  asking why nothing clamped the frequency during those runs.
  `pyra-thermal.sh` shells out to `cpufreq-set`, which is not installed,
  because the package that provided it, `cpufrequtils`, is not in trixie at
  all — `apt-cache policy` reports no candidate. So every 20 seconds since the
  image's first boot the daemon has read the temperatures, decided on a
  frequency cap, and failed to apply it:

      pyra-thermal.sh[2000]: pyra-thermal.sh: 89: cpufreq-set: not found

  1031 of those in the current journal. The charge-current half of the same
  function still *runs*, because it is a plain redirection to
  `/dev/usb_max_current` on the next line and nothing aborts in between.

  **Correction, 2026-09-13.** This used to end "so the daemon has been managing
  charging correctly and managing frequency not at all". The second half is
  right and the first half is not. That redirection writes into an ordinary
  file that nothing reads — the symlink it was supposed to be was never created,
  because the udev rules that create it name `twl4030`. The daemon has been
  managing neither. See fix 8.

  This means the 107°C above was the kernel's `step_wise` unassisted, and that
  `step_wise` is the *only* frequency protection this image has. It also means
  the thermal ladder in that script — the one everybody tunes — has never done
  anything on trixie.

  **Fixed and confirmed on hardware the same day**, by
  `device/pyra-thermal-fix.sh`, which replaces that one call with a write to
  `scaling_max_freq` and nothing else. No package, no new dependency, and the
  vendor's thermal ladder untouched, because the ladder is the vendor's policy
  and only the one line was broken.

  The difference is not subtle. Single-core `7z b`, the load that reached 100°C
  before:

  | | before the fix | after |
  | --- | --- | --- |
  | peak CPU zone | 100°C, still climbing when stopped | **84°C, stable** |
  | frequency cap under load | never moved from 1500 MHz | 1500 → 1250 → 1500 |

  Sixteen degrees below the trip instead of at it, and the cap visibly moves
  and comes back.

  **It also answers this item's original question, from the other direction.**
  The oscillation between 1.5 and 1.25 GHz that others reported on this
  hardware is real, and it is not `step_wise`: it is this userspace daemon,
  which polls every 20 seconds and has no hysteresis, so it caps at 1250,
  cools four degrees, releases to 1500, heats four degrees and caps again on a
  roughly twenty-second cycle. That oscillation could not have been observed
  on this image before today, because the daemon was not capping at all. It is
  worth tuning — a hysteresis band, or a release threshold below the trigger —
  but a machine oscillating between the top two steps is far better than one
  that walks past its trip, so this is now an improvement rather than a fault.

  Still a packaging bug in the trixie image rather than anything this
  repository did, and still on the upstream list. Note that `/usr/share` is not
  a conffile location, so a package upgrade will silently revert it;
  `pyra-thermal-fix.sh --check` detects that.

  **And it gives back the headroom item 1 needs.** The governor tuning above
  was held back by five degrees of margin that turned out not to exist. With
  the daemon actually capping, a heavy load peaks at 84°C, so there is real
  room to raise `up_threshold` and test it.

  **Measured 2026-09-13: the oscillation above was the small half of it, and
  the ladder had three faults rather than one.** Full method and numbers in
  `experiments/thermal-ladder/README.md`; fixed by
  `device/pyra-thermal-ladder.sh` and by prep as fix 7.

  The sensor this daemon calls the battery is `bq27421-0`, the fuel gauge,
  reporting its own die temperature — the mainboard, not the cell. It rose
  2.0°C within ten seconds of one core being loaded, which no 6000 mAh cell
  can do. Its ladder caps from 44°C while `core_thermal` gives up nothing
  below 77°C, so it, and not the SoC sensor, is what throttled this machine in
  ordinary use: across that run the core peaked at 71.0°C and never reached
  its own first rung at all. Pinned at 1500 MHz with nothing capping, the
  board reads 48.4°C at the moment the core first reaches 77°C — by which
  point the vendor's board ladder has already demanded 750 MHz, three rungs
  deeper. The two ladders are inverted.

  `setMaxFreq` also compares against the constant `maxFreq` rather than
  against the cap already chosen, so the ladder that runs last wins whether or
  not it is the more restrictive, and the battery ladder runs last. Core at
  98°C wanting 250 MHz, board at an ordinary 44.5°C wanting 1250: the daemon
  picks 1250. That one is a loss of thermal protection.

  And the hysteresis this item asked for had to be sized against the machine
  rather than against the ladder. This core moves up to 6°C between
  five-second samples on one core and 10°C on two, so a 2°C band is below the
  controller's noise floor at a 20-second poll — it released correctly and
  still crossed the same rung six times in four minutes. A full rung, 5°C,
  takes one core of load from twelve ceiling changes to two, and because
  holding a cap regulates better than oscillating it also drops the peak from
  91.3°C to 88.7°C. (Published as 88.0°C until 2026-09-18; the artifact's maximum
  is 88.7°C. Corrected in `experiments/thermal-ladder/README.md`.)

  **And correcting all that broke the two-core case, which is the most
  important thing on this page.** Two cores flat out then reached 102°C with
  the ceiling never moving once. The machine goes from a 63°C idle to its
  100°C passive trip in sixteen seconds and the daemon polls every twenty, so
  its next look lands after the trip. The vendor never had this problem
  because its broken ladder left the machine permanently pre-capped — measured
  at 750 MHz, where two cores peak at a harmless 74°C. That was real
  protection obtained for entirely the wrong reason, and fixing the ladder
  took it away.

  So two more changes, and they are not optional: the poll goes from 20
  seconds to 2, and the ladder reads the hotter of `core_thermal` and
  `cpu_thermal` rather than `core_thermal` alone — the passive trip is on
  `cpu_thermal` and it leads the other by up to 12°C during a ramp, so even an
  instantaneous daemon on `core_thermal` would first act with `cpu_thermal`
  already at 91°C. Together those take two cores from 102°C to 87°C with the
  load running to completion.

  The cost is honest and worth stating: the machine now runs hotter than fix 6
  alone left it, because it is no longer giving thermal budget away to a sensor
  with no view of the SoC. 88.7°C on one core and 87.0°C on two against a 100°C
  trip, where fix 6 alone sat at 84°C — but it got that margin by throttling at
  70°C for no thermal reason.
- **Hardware.** Community reports of 20–23°C reductions from improved thermal
  contact are the largest single number anywhere in this document. That is a
  physical modification, out of scope for this repository, but it is the thing
  that would make every software change above free.

Do not chase 1.8 GHz. Sustained 1.5 GHz is worth more than a peak that
immediately collapses, and the part is a 1.5 GHz-rated GP device. That advice
predates the unlocked device tree now sitting in
`experiments/thermals-and-frequency/`, which offers 1.6 through 2.0 GHz, and it
is unchanged by it. The blob's own author says plainly that 2 GHz needs
modified cooling and that they can hardly run it. This sentence used to end
"this unit has five degrees of margin at 1.5 GHz under load", which is not true:
two cores flat out reached 107°C with nothing capping, seven degrees *past* the
passive trip, and with fix 7 doing its job they reach 87°C. There is margin at
1.5 GHz because something is now managing it, not because the machine has it to
spare.

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

The graphics rail is at its nominal operating point. ~~`dpll_core_m3x2_ck` reads
425.472 MHz in the clock summary, matching.~~

> **Corrected 2026-09-23.** `dpll_core_m3x2_ck` does not feed the GPU. The
> device tree gives `gpu_core_gclk_mux` / `gpu_hyd_gclk_mux` (`CM_GPU_GPU_CLKCTRL`,
> `cm_core` offset `0x1520`) exactly two parents, `dpll_core_h14x2_ck` and
> `dpll_per_h14x2_ck`, and the kernel shows them on `dpll_core_h14x2_ck` — which
> `clk_summary` reports as **33.77 MHz**, idle and under load alike. That figure
> is not the real clock either: the same evening the `~/pyra-probe/fill` probe
> measured **861.8 Mpix/s** at 1280x720 overdraw 8, identical to 2026-09-20's 862,
> and 33.8 MHz would need 25 pixels per clock from a two-core SGX. At 425 MHz it is
> 2.0 per clock, which is plausible. So: **the GPU is not throttled; the kernel's
> clock tree does not describe what the DDK set, and neither `m3x2` nor
> `clk_summary` measures the GPU clock.** Measured, not read from a register:
> `devmem2` returns 0 for every CM register (strict `/dev/mem`), including
> `CM_CLKMODE_DPLL_CORE`, which cannot be 0 on a running system. `omapconf` reads
> through the same `/dev/mem` and warns "no matching rate" for MPU and CORE, so its
> "GPU 425 MHz" is best treated as its OPP table's nominal value. The only
> measurement of the GPU clock this project has is the fill rate.
>
> **Reopened 2026-09-25: the registers read, and they agree with `clk_summary`.**
> On `5.6.19-m4`, `/dev/mem` through Python's `mmap` returns live CM registers
> where `devmem2` returned zeros. The values check out against known clocks:
> `CM_CLKSEL_DPLL_CORE` = `0x00011504` (M 277, N 4: 2127.36 MHz ×2, as the kernel
> says), H11 divider 8 (265.9 MHz, the L3), H12 divider 4 (531.8 MHz, the EMIF). And
> `CM_DIV_H14_DPLL_CORE` = `0x0000023f`: **divider 63, clock active, 33.8 MHz**.
> `CM_GPU_GPU_CLKCTRL` = `0x00060002` / `0x00000002` (both clock selects 0, meaning
> `dpll_core_h14x2`). Sampled at 100 Hz through a 53 fps SoH run: the module was
> functional in 64% of samples and idle in 36%, and H14 never changed. That
> contradicts the fill probe, which draws *blended* textured quads the ISP cannot
> reject, so 862 Mpix/s cannot come from a 33.8 MHz two-core SGX. **One of the two
> measurements is wrong, and it is not yet known which.** Divider 63 on H13 and H14
> is also what a bootloader leaves on outputs it does not use.
>
> Voltage readback is also available after all. `omapconf` reads 0.000 V, but the
> regulator framework reports the commanded voltages: `smps45` (VDD_MM) **1.030 V**,
> `smps123` (MPU) 1.050 V, `smps8` 1.000 V.
>
> **What the TRM (SWPU249AG) and the chip add, same day.** `CM_GPU_GPU_CLKCTRL`
> bit 24 = 0 selects `DPLL_CORE` HSDIVIDER H14 for `GPU_CORE_GCLK` (bit 25, the
> same for `GPU_HYD_GCLK`). The HSDIVIDER field is the divider itself: the ROM
> defaults in Table 28-12 (H13 34.3 MHz = 2128/62) match what H13 reads. The ROM
> sets `CORE_GPU_CLK` (H14) to 212.8 MHz and `PER_GPU_CLK` (`DPLL_PER` H14) to
> 192 MHz. On this unit something after the ROM set core H14 to **63 (33.8 MHz)**
> and PER H14 to **2 (384 MHz)**. So a 384 MHz GPU clock is programmed and never
> selected: the booted device tree's GPU node carries no `assigned-clocks`, rate
> or OPP table, so nothing moves the mux off its reset value. The AVS Class 0
> eFuses (TRM Table 18-98) give this chip's VDD_MM as **1027 mV at OPP_NOM** and
> **1031 mV at OPP_OD**. `smps45` at 1.030 V is the next 10 mV step above NOM,
> as the TRM's procedure prescribes. MPU fuses are 1024 mV NOM and 1216 mV HIGH,
> CORE 993 mV. The TRM does not give GPU frequency per OPP; that is in the Data
> Manual.
>
> **Resolved the same day: the GPU runs at 425.47 MHz, and 63 is a special code.**
> TRM Table 3-880: *"When a value of 63 is programmed in this register, HSdivider
> will perform division by 2.5 that is divided by 2 at top level"*, which is ÷5.
> 2127.36 / 5 = 425.47 MHz. The kernel's `ti,divider-clock` driver reads 63 as a
> literal ÷63, and that is the whole of `clk_summary`'s 33.77 MHz. Confirmed by
> experiment (`experiments/gpu-clock/`): switching both GPU clock selects to
> `DPLL_PER` H14 (384 MHz) cut fill rate to **0.908×** at 1280×720 overdraw 8 and
> 0.906× at 640×360, against 384/425.47 = 0.903. Switching back restored 860 →
> 862 Mpix/s. So the register reads were right, the "reopened" reading above was
> wrong in its decoding, and the earlier conclusion (425 MHz, `clk_summary`
> wrong) stands. 384 MHz is simply the alternative source, not a forgotten GPU clock. There is a higher operating point on
this part, and the difference is worth roughly a quarter of the GPU's
throughput — which would land directly on every glmark2 scene, every gl4es
frame and every emulator.

**A quarter of GPU throughput is not a quarter of a frame.** It is a quarter of
whatever share of the frame is actually GPU-side, which for a benchmark like
glmark2 is nearly all of it and for a real application may not be. The Ship of
Harkinian port is the worked example: 5.05 ms of its 31.8 ms frame is spent in
the swap where the fragment pass lives, so a 25% GPU gain is bounded near **4% of
the frame** there — behind changes that cost nothing and carry no physical risk.
The ranking below is for the GPU-bound case; for any given workload, measure what
share is GPU-side before spending this item's risk budget on it.

This is the highest-value unexplored item in the document for a GPU-bound
workload, and also the one most likely to turn out to be impossible. Before getting attached to it, establish:

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

### 6. Fullscreen games are copied, not flipped — and what to do about it

**Measured 2026-09-27: a fullscreen client's frames reach the scanout by copy.
No page flip happens.** Method: `perf record -a -e raw_syscalls:sys_enter
--filter "id == 54"` (ioctl on ARM EABI) while the client runs, then tally the
request codes per process.

| Client | Frames in window | `PAGE_FLIP` (`c01864b0`) | etnaviv `GEM_SUBMIT` (`c0486446`), from Xorg |
| --- | --- | --- | --- |
| `glmark2-es2 --fullscreen`, build, 1280x720, unsynced ~255 fps | ~2 560 | 0 | 2 484, one per frame |
| Ship of Harkinian, fullscreen 1280x720, capped 30 fps, 10 s | ~300 | 0 | 893, about three per frame |

`/dev/dri/card2` is **etnaviv**, the GC320 (card0 omapdrm, card1 pvrsrvkm).
The submits come from the `Xorg` process, not the game. The game's own ioctls go
to the PVR bridge. So each frame is drawn by the SGX into the client's back
buffer, and then Xorg's EXA (`viv2d`) has the **GC320 copy it into the
TILER-backed front buffer**. That is 3.7 MB read and 3.7 MB written per frame,
about 220 MB/s at 30 fps. It costs little CPU, but it takes memory bandwidth ~~and
it sits inside the swap~~.

> **Corrected 2026-10-18, from source: probably not inside the swap.** X submits
> the copy without waiting for it, and the client never waits for a copy. See
> "What the source says" at the end of this item.

glmark2 alone would not have settled it: an unsynced client is always copied, and
the DDK ignores `--swap-mode fifo` (still ~255 fps). SoH is vsynced and is copied
anyway.

**Why no flip: not proven.** The likely reason is rotation. A plane rotated by
the TILER can only scan out a TILER buffer, and buffers the SGX driver
allocates are not TILER-backed. The DDX's own flip conditions could not be
observed: `omap5_drv.so` is stripped, and the Xorg entry points
(`DRI2SwapComplete`, `DRI2CanFlip`) are Thumb code, which ARM uprobes cannot
probe (`perf_event_open` returns EINVAL). Two things read from the DDX source
(`dragonbox-pyra-build/ddx/build/src`):

- DRI2 flips only if the back buffer was created as a scanout pixmap with an
  fb attached (`armsoc_dri2.c`, `canflip` and `ScheduleSwap`). Otherwise it
  copies silently. A failed `armsoc_bo_add_fb` would log "Falling back to
  blitting a flippable window". That line does not appear in the log.
- **The Present flip path is broken.** `armsoc_present_flip` passes
  `drmmode->fb_id`, the screen's own framebuffer, to `drmmode_page_flip`, not
  the client pixmap's (`armsoc_present.c:649`). It also treats a zero return as
  failure. Even if Present chose to flip, it would show the wrong buffer.

> **Resolved 2026-10-18, from source: no flip is ever attempted, because the flip
> is not compiled in.** `armsoc_present.c:49` reads `//#define ARMSOC_PRESENT_FLIP
> 1`. Without it, the `check_flip`, `flip` and `unflip` hooks are absent from
> `armsoc_present_screen_info`, and Present copies every frame. The stock
> `omap5_drv.so` agrees: "ARMSOC DRI3 init" is in it, and the flip function's
> "present flip failed" is not. The broken `armsoc_present_flip` above is
> therefore dead code. DRI2 is not on the games' path at all, since the window
> system is DRI3. Rotation would block a flip as well, because the client's
> buffers are dumb buffers, not TILER buffers. So "the likely reason is
> rotation" was a second cause hiding behind the first.

**The ~3.4 ms of SoH's swap that does not scale with pixels** is the right size
for this copy. That is inference. It has not been measured.

> **Probably wrong, 2026-10-18 (reasoning from source, not measured).** The swap
> does not wait for the copy. The part of SoH's frame that does not scale with
> internal resolution is better explained by the game's own 1280x720 present
> quad: Shipwright §8.42 measured it at 2.87 ms of 3D, and the swap waits for
> the GPU to finish it.

#### What could be done, cheapest first

0. **Size the prize first.** Confirm the copy is the ~3.4 ms: time the swap
   against the GC320 fence waits (`40186444`, etnaviv `WAIT_FENCE`, from Xorg),
   or compare a fullscreen window with a small one. If the copy is not most of
   it, stop here. Also find out whether the DDK's X11 path is DRI2 or DRI3.
   That choice decides between options 2 and 3.
   *(2026-10-18: DRI3 and Present, from the window system's source. The swap
   does not include the copy, so this sizing should be in watts, not ms.)*
1. **Hide the copy rather than remove it.** If the swap blocks until the copy
   retires, a third buffer, or a looser swap throttle, lets the SGX start the
   next frame while the GC320 copies. This is the pipelining question below.
   It is config, not code. Watch input latency at 30 fps on a 60 Hz panel.
   *(2026-10-18: already the case. Three buffers, and nothing waits for the
   copy. What the swap does wait for is the SGX: see the end of this item.)*
2. **Make X flip (only if the DDK uses DRI2).** Under DRI2 the DDX allocates
   the back buffers. It could allocate them the way it allocates the screen
   buffer (TILER-backed, rotated, scanout; `armsoc_driver.c:1101`), and flips
   would follow. This is a contained DDX change. Risk: page flips go through
   the same vblank wait that has wedged the display (`troubleshooting.md`).
   Under DRI3 the client allocates, and the SGX cannot allocate TILER buffers.
   Fixing that is a dead end in a closed driver, on top of the broken
   Present flip.
   *(2026-10-18: the DDK is DRI3, so the DRI2 half does not apply. The DRI3 half
   was wrong about the allocator. Under DRI3 the buffers are allocated by
   `libpvrDRI3WSEGL.so`, which is MIT source, not by the closed driver. It could
   ask omapdrm for TILER buffers. Whether the SGX renders correctly into one is
   untested. Proposal 4 below.)*
3. **Skip X for games, keeping hardware rotation.** A game driving KMS
   directly from the game-mode VT (SDL `kmsdrm`, GBM) has no X copy, and no
   Xorg or marco time either. Real play measured about 1.5 ms and 0.9 ms of CPU
   per frame for those two. **Test this first:** can the DDK render into a
   dma-buf allocated by omapdrm as a TILER buffer? If it can, rotation stays
   free and no game changes: zero copy, nothing rewritten. GBM exists for
   OMAP (`mplayer-mini` uses it), but SDL on it is untested.
4. **Skip X and pre-rotate, if option 3's buffer sharing fails.** On an
   unrotated plane, omapdrm can scan out an ordinary buffer, so a game that
   renders portrait flips with no copy. On the GPU this is nearly free: the
   same pixel and tile count on the SGX. **But only if the rotation goes into
   the game's own final pass.** SoH composites its frame from an offscreen
   buffer, so rotating that last quad is small and contained. A *generic*
   version (gl4es or SDL renders landscape, then draws it rotated at swap time)
   adds a full-screen read and write. That is the same copy moved from the
   GC320 to the SGX, and it gains nothing. Rewriting every game's coordinates
   instead (projection, viewport, scissor, `gl_FragCoord`, `glReadPixels`,
   input) is per-game work and fragile.
5. **Make the copy itself cheaper.** Three GC320 submits per frame where one
   copy should do is worth a look. It is a small win. 16-bit colour would
   halve the traffic, but it changes the whole desktop and costs quality. No.

**Size of the win.** Removing the copy and X is worth up to ~3.4 ms of swap
plus ~2.4 ms of CPU per frame. SoH runs capped at 20 fps / 625 MHz by choice, so
this arrives as headroom (a lower clock, less heat, or 30 fps where it now needs
more clock), not as frame rate. Moderate, not transformative.
*(2026-10-18: the ~3.4 ms part rests on the inference corrected above. The CPU
part stands.)*

**The pipelining question still stands.** Is the client a frame ahead of the
GPU at all? On a tile-based deferred renderer the CPU should be. If the swap
blocks until the previous frame's tile pass retires, SoH's ~5.0 ms swap is
serialised dead time rather than overlapped work. The EGL buffer count decides
which. Option 1 above is the same question from the copy's side.

> **Answered 2026-10-18, from source: the client is not a frame ahead.** The
> swap blocks until *this* frame's render has retired, not the previous one's.
> The buffer count is not what decides it. The wait is an explicit call in the
> window system. Below.

#### What the source says (2026-10-18)

Read from source and checked against the shipped binaries. **Nothing here has
been measured on the device.** The sources:

- `libpvrDRI3WSEGL.so` is `dri3wsegl-pyra` 0.4, MIT licensed. Source is in
  `pyra-packages-archive/packages.pyra-handheld.com/trixie/dri3wsegl-pyra_0.4.tar.xz`.
  The .deb beside it carries the stock sha256 `d852ce4d…`, so this is the code
  that runs. 0.5 differs only in its changelog. TI's upstream, without the Pyra
  vsync changes, is cloned at `~/git/dragonbox-pyra-repos/dragonbox-pyra-supporing-repos/dri3wsegl`.
- The DDX is the 0.6 source in `dragonbox-pyra-build/ddx/build/src`.

**What a GLES frame under X does:**

1. The client renders into one of three dumb buffers. The library creates them
   with `DRM_IOCTL_MODE_CREATE_DUMB` on the omapdrm fd that DRI3 hands it
   (`-DBO_TYPE=DUMB` in `debian/rules`). They are linear, not TILER.
2. On swap, the library calls `WaitForOpsComplete` on that buffer
   (`dri3_ws.c:792`). **The calling thread sleeps until the SGX has finished
   the frame.** The DDK does not do this by itself: under the GBM window system
   the swap took ~0.1 ms and the wait moved to buffer lock
   (`experiments/kms-plane/`). The wait exists because Present here has no
   fence that could make X wait for the SGX.
3. It sends `PresentPixmap` and blocks on a round trip to X
   (`xcb_request_check`, `dri3_ws.c:828`).
4. X copies the buffer to the screen through EXA. The GC320 stream is committed
   asynchronously (`_Viv2DStreamCommit(v2d, TRUE)`), and Present reports the
   buffer idle once the copy is submitted. With three buffers, the client never
   waits for a copy.

**Vsync.** The library targets `last_msc + swap_interval` (`dri3_ws.c:806`),
where `last_msc` is the last completed present as of the last event poll. A frame
slower than one refresh is therefore copied at once, not at vblank. The real
wait is only active when the `DRI3_VSYNC` environment variable is set, and
nothing on this image sets it. `SwapbuffersWait` in the X config is not an
option this driver has (see the end of this document). That fits glmark2
ignoring `--swap-mode fifo`, but it has not been measured.

**What this changes.** SoH's ~5.0 ms swap is most likely the SGX finishing the
frame while the render thread waits, with one X round trip on top. The X copy
costs bandwidth and watts, not swap time.

**Proposals, ranked.** All four are changes to MIT code. None touches the
PowerVR binaries. A test build can be loaded per process, with no system
change: a private copy under the same name on `LD_LIBRARY_PATH`, or a
`powervr.ini` in the working directory (the kms-plane method). Measure on the
Shipwright rig: ABBA, CPU pinned, vsync off.

1. **Present from a worker thread.** The swap marks the buffer busy, queues it
   and returns. A per-drawable thread waits for the SGX and then presents. The
   existing busy-buffer wait in `WSEGL_GetDrawableParameters` already stops a
   client running more than two frames ahead. **Prize: up to the GPU-wait part
   of the swap, ~5.0 ms of SoH's 31.8 ms, but only when the CPU has work for the
   next frame to overlap with it.** Under a frame cap it arrives as headroom.
   Cost: up to one frame of extra input latency, so measure latency as well as
   frame time.
2. **Unchecked `PresentPixmap`, with a flush.** This removes one blocking X
   round trip per frame. Small, and it costs more when Xorg is busy on the
   other core. Same build as 1.
3. **Make vsync behave.** Honour the swap interval without `DRI3_VSYNC`. Use
   `XCB_PRESENT_OPTION_ASYNC` for interval 0, and a target Present computes
   itself for interval 1. Judge it on frame-time variance and tearing, not mean
   fps. Then re-take `rendering-guidelines.md` §1.2's 28.7 → 20.00 fps
   measurement, whose mechanism is now unknown.
4. **Flip without a copy, keeping hardware rotation.** The library would allocate
   TILER buffers through omapdrm's `OMAP_GEM_NEW` with a tiled flag, and the
   DDX would compile in the Present flip and fix it
   (`reports/pyra-armsoc-present-flip-fb-id.md`). **First, the gate, which is
   cheap and decides it:** does `PVRSRVMapDmaBuf` accept a TILER dma-buf, does
   the SGX render correctly at its stride, and how fast? kms-plane only showed
   that the GBM backend cannot import one. This library controls its own
   allocation, so it has not been tested. The test changes only `create_buffer`;
   X keeps copying while it runs. Prize: 7.4 MB of copy traffic per frame,
   mostly as watts (~0.1 W by analogy with Shipwright §8.54, an estimate).
   It also removes the copy racing a scan that runs perpendicular to it under
   270° rotation. Little frame time, if the source reading above is right.
   Risks: flips go through the vblank path, and TILER container space is
   finite.

While the library is being rebuilt, fix the dma-buf double close in source:
drop the `close(buffer->dmabuf_fd)` at `dri3_ws.c:324`, replacing the binary
patch (`reports/pyra-ddk-dri3-wsegl-double-close.md`).

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

One class of program turned out to need nothing built at all, only a symlink:
anything using a toolkit that links the archive's `libGLESv2` was getting
glvnd's dispatcher rather than the blob and rendering nothing. Qt Quick runs on
the SGX at 117 fps once that is corrected. See `docs/qt-gles.md`.

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

*The chain itself, the diagnostic order for silence, and the traps are in
`audio.md`. This item is the performance survey.*

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

#### Update 2026-09-20: the percentage you see is mostly the governor

Everything above still measures true. What it does not say is that **the
number on screen depends on the clock the governor happens to be at**, and
that turns out to explain the gap between "16% of one core" here and the
20–30% a user actually reports seeing in `top`.

Same single stereo 44.1 kHz sine, same machine, cost taken from
`/proc/<pid>/stat`:

| condition | pulseaudio | clock |
| --- | --- | --- |
| `ondemand`, as shipped | **26%** of a core | 625 MHz |
| `performance` | **11%** of a core | 1500 MHz |

Identical absolute work — only the denominator moved. Audio is a small steady
load and `ondemand` reads it as idle, settling at 625–750 MHz, so the
percentage roughly doubles. This matters for item 1 above: the governor fix is
worth more than its own benchmark suggests, because it also silently halves the
apparent cost of everything that behaves like audio.

It also means **20–30% is the correct reading for this configuration and is not
a leak**, which is the first thing to tell anyone who reports it.

**Idle is genuinely free.** `module-suspend-on-idle` is loaded, and with nothing
playing the daemon measures 1 tick in 6 seconds — call it zero. There is no
standing drain to reclaim. The whole cost exists only while audio is playing,
so "turn audio off to save power at rest" has nothing to collect.

#### Update 2026-09-20 (later): a real game profiled, and matching the ratio backfires

The earlier numbers here were taken with `paplay` on an otherwise idle machine.
This pass measures a real title under load — Ship of Harkinian, an ARM-native
build, so none of item 9's box86 caveats apply.

**What it asks for**, which closes one of `audio.md`'s open questions:
`s16le 2ch 32000Hz`, resampled `trivial` to 88200. That is a ratio of
**2.75625:1** — ragged, the case `trivial` handles worst.

**What audio costs this title.** `perf record -F 999 -a` for 50 s at thermal
equilibrium, with the thermal profile holding the clock at 1.0 GHz:

| process | share of all busy CPU |
| --- | --- |
| the game | 55.4% |
| `alsa-sink` + `pulseaudio` + `PulseMainloop` | **18.4%** |
| `Xorg` + `marco` + `mate-panel` | 10.8% |

Against a run with audio removed entirely, the game's own share rises to 75.1%
and the audio stack falls to 1.2% — so **about 18 points come back**, worth
+4.1% on mean frame rate and +11% on the steady tail. That is the ceiling on
any audio-side work, and it is the number to beat.

Note it is a ratio of busy samples, so unlike a `top` reading it is not a
governor artefact. The clock still matters for a different reason: audio work
is fixed per wall-second because the codec must be fed 88200 Hz regardless,
while the game's work is elastic. Holding the clock at 1.0 instead of 1.5 GHz
therefore *grows* audio's slice of the machine by about half again. The
frequency cap and the audio cost compound against whatever is running.

**The experiment: make the ratio exact.** `trivial` at 2:1 is a clean
zero-order hold, so moving the game from 32000 to 44100 should sound better.
The engine takes the rate as a parameter — `gAudioSpecs[].frequency` with
pitch corrected by `resampleRate = 32000.0f / frequency` — so it is a small
change, and one spec row already shipped at 22050.

It costs **more**. Two interleaved pairs, `pulseaudio`'s own
`utime + stime` over a 35 s window, second pair at an identical 78->79 C:

| game output rate | pulseaudio | |
| --- | --- | --- |
| 32000 Hz (as shipped) | 536 jiffies | 15.3% of a core |
| 44100 Hz | 658 jiffies | **18.8% of a core** |
| | **+122** | **+3.5 points, +22.9%** |

Both pairs agreed to within a tenth of a point (+22.9%, +22.8%).

The mechanism is visible in the two rates: input to the daemon rose 37.8%
while output stayed pinned at 88200. So the cost is part input-proportional
(format widening, stream reads) and part output-proportional (resample, mix,
the two remaps) — and a cleaner *ratio* cannot help, because `trivial` already
costs the same per output sample whatever the ratio is.

**This partly disagrees with the `paplay` table above** and the disagreement is
not resolved. That table has 22050 at 10.3% and 44100 at 11.1% — doubling the
input rate for +7.8% — and concludes "the input rate barely matters". Here a
37.8% rise in input rate cost +22.9%. The two differ in more than one variable:
idle versus a machine with both cores loaded, `paplay`'s large file-backed
buffers versus a game handing over one frame at a time, and a clock at 1.0 GHz
where cache pressure from the extra input data is likelier to show. Worth
re-running the `paplay` sweep under load before trusting either slope.

**So the app-side lever is closed.** Matching the *ratio* is a quality change
that costs CPU. Only matching the *rate* — 88200, the copy path at ~3.5% of a
core — reaches the cheap path, and for this title that would mean synthesising
2.76x as many samples inside the game, whose own audio routines already measure
~2.5% of all busy CPU. A back-of-envelope on that is roughly break-even, which
is not enough to justify the disruption. Untested.

What does remain untested and now looks more valuable: **the 2-channel sink**.
Everything downstream of conversion currently moves four channels to deliver
two, and that pipeline is the 15% measured above rather than a rounding error.

**A warning for whoever measures this next.** Two obvious-looking ways to test
"without PulseAudio" are both traps on this machine and both produce a
convincing, entirely false speedup — a killed `pasuspender` leaves every sink
suspended, and `SDL_AUDIODRIVER=alsa` never opens the codec at all. Both make
the machine silent while looking like they worked. Details in `audio.md`. The
18-point figure above is the honest version of that measurement, and it is
correctly labelled as "audio off", not "audio faster".

**One more rate, the one that matters for games.** The table above has 22050,
44100 and 88200 but not 48000, which is what most SDL titles and all video ask
for:

| stream | pulseaudio |
| --- | --- |
| 44100 | 10% of a core |
| 48000 | **10%** |
| 88200 (matches the sink) | 2% |

Which confirms the cliff from the other side: 48000 is no cheaper than 44100
despite being no further from the sink rate. Context-switch rate stayed at
30–42/s across all three, so this is data-path cost and not wakeups.

#### A correction, and a quality lever the original entry missed

The entry above reads `RATE: [88200 96000]` as "there is no 44100", which is
right. But the second number is not decoration, and it is selectable: the
TWL6040 runs its PDM link at **88200 in Low-Power PLL mode and 96000 in
High-Performance**, exposed as the `PLL Selection` and `TWL6040 Power Mode`
mixer enums. This machine is in Low-Power.

That does **not** buy back any CPU. By the cliff finding above, cost tracks
output samples, and 96000 is more of them than 88200, so switching would cost
slightly *more* and draw more power in the bargain. What it changes is
**which content converts cleanly**:

| link rate | 44.1 kHz content | 48 kHz content |
| --- | --- | --- |
| 88200 (now) | exact 2:1 | ragged non-integer |
| 96000 | ragged non-integer | exact 2:1 |

This matters because `resample-method` is `trivial` — nearest source sample.
At an exact 2:1 that is a clean zero-order hold, every sample used twice. At a
non-integer ratio it duplicates irregularly, which is audible as aliasing and
zipper artifacts. So the machine is currently tuned for 44.1 kHz music and
against 48 kHz games, and N64-era content at 32 kHz is ragged in either mode.

**Untested.** The rate range comes from `--dump-hw-params` and the mode enums
are visible in `amixer`, but nobody has flipped them and listened, or measured
what High-Performance costs at the battery. If game audio on this machine
sounds gritty, this is the first thing to try, and it is two mixer writes and
fully reversible.

The quality dimension deserves stating plainly on its own: **`trivial` is the
cheapest resampler and also the worst**, and the original entry's "nothing to
gain" is true only about CPU. `speex-fixed-1` would sound considerably better
and cost some of that 8-point conversion penalty back. Nobody has decided that
trade deliberately; it was inherited.

#### If the goal is to switch audio off

Worth writing down because the obvious method does not work:

- **Muting saves nothing.** PulseAudio still resamples and mixes the stream and
  multiplies by zero at the end. If the goal is CPU, mute is the wrong lever.
- **`SDL_AUDIODRIVER=dummy` is the one that works**, per app. It removes the
  app's own decode and mixing *and* the conversion PulseAudio would do behind
  it. No system state changed, nothing to undo.
- Stopping the daemon outright reclaims the same, but some apps hang or fail
  against a missing server rather than running silently, so it wants the dummy
  driver anyway — at which point the dummy driver alone was enough.

#### Can an app avoid the conversion by sending 88200?

Sometimes, and it is worth being precise about when, because the answer above
("making the source match backfires") was reasoned from one case — Wine's
DirectSound mixer under box86 — and generalises less than it looks.

- **An app that synthesises audio** and will render at whatever rate it is
  asked for genuinely skips the conversion: that is the 10% → 2% row.
- **An app with a fixed native rate** — 32 kHz for N64 content, 44.1 for music
  files, 48 for video — does not. Asking it for 88200 relocates the resample
  into the app, where it is likely *more* expensive, because PulseAudio's is
  `trivial` while the app's is probably properly filtered. That is a quality
  gain paid for in CPU, not a saving.

`pactl list sink-inputs` prints each live stream's sample spec, so what a given
title actually asks for is a measurement rather than a guess.

#### Update 2026-09-20 (later still): "no configuration avoids it" is true, but the hardware does not need one

Everything above stands as a statement about *software*. What it misses is that
the OMAP5 has a dedicated audio DSP for exactly this job, and it is sitting
idle: the **AESS**, whose front-end DAIs accept what applications actually
produce —

    MultiMedia1: 44100 | 48000, S16_LE | S32_LE, stereo

— and whose back-end drives the codec. It handles 44.1 by reclocking its own
scheduling loop (`EVENT_GENERATOR_COUNTER_44100 = 2228-1` against a default of
`2048-1` in `sound/soc/ti/aess/aess_utils.c`), which is why the TWL6040 has an
88200 mode and a 96000 mode at all. Both rate families were meant to be native;
the software resample exists only because nothing drives the AESS.

On the running machine the driver is built in (`CONFIG_SND_SOC_OMAP_AESS=y`),
`ti,aess` is in the live device tree, `aess_fclk` is clocked at 196.608 MHz,
`/lib/firmware/omap_aess-adfw.bin` is present and loads without error, and
`MultiMedia1`, `MultiMedia1 LP`, `Voice`, `Tones` and `MODEM` all appear in
`/sys/kernel/debug/asoc/dais`. Then nothing connects them, and the card
registers with the direct McPDM link instead.

**The hardware is live.** `device/pyra-aess-probe.sh`, run 2026-09-20: the
register block reads (`REVISION` 0x40000000, `SYSCONFIG` 0x38,
`EVENT_GENERATOR_COUNTER` 0xFFFF), all three memories round-trip, DMEM decodes
across the full 64 KiB, and SMEM masks 0xFFFFFFFF to **0x00FFFFFF** — the
24-bit sample width the ABE architecture specifies, which a floating or
aliased bus cannot fake. `PM_ABE_PWRSTST` reads 0x337: domain ON, logic ON,
both memory banks ON.

**What is missing is three pieces of software**, in increasing size:

1. `omap_abe_add_aess_dai_links()` in `sound/soc/ti/omap-abe-twl6040.c:451` is
   an empty stub — four locals declared, none used, `return 0`. This is the
   whole reason the path is dead.
2. The aess device's runtime PM reads `unsupported`, so `pm_runtime_active()`
   is false — and every accessor in `sound/soc/ti/aess/aess_mem.h`
   (`omap_aess_write`, `omap_aess_read`, `omap_aess_reg_write`,
   `omap_aess_reg_read`, `omap_aess_clear`) is wrapped in
   `if (pm_runtime_active(aess->dev))`. **Every register and memory write the
   driver makes is silently dropped and every read returns 0.**
3. The AESS init sequence in `omap_aess_pcm_probe()` sits inside an `#if 0`,
   commented "failed firmware load leads to missing/wrong opp and failed
   omap_aess_init_mem".
**Corrected 2026-09-20: items 2 and 3 are not independent blockers — they are
consequences of item 1.** `omap_aess_pcm_probe()` *does* call
`pm_runtime_enable()`, at `omap-aess-pcm.c:475`, and the `#if 0` init sits
inside that same function. It is simply never executed: it is the `.probe` of
`omap_aess_platform`, and an ASoC component's probe runs when the component is
bound **into a card**, not when `snd_soc_register_component()` is called. With
the DAI-link stub empty, nothing references the AESS component, so it is never
bound, so the probe never runs, so runtime PM is never enabled. One root cause,
two consequences. An earlier revision of this section presented them as three
separate dead switches; that was wrong, and it matters, because it means the
fix is to fill in the stub rather than to sprinkle `pm_runtime_enable()` calls.

4. `abe_54xx_pwrdm` in `arch/arm/mach-omap2/powerdomains54xx_data.c` sets
   `pwrsts_mem_on` to `PWRSTS_OFF_RET` for both banks where OMAP4's
   `abe_44xx_pwrdm` sets `PWRSTS_ON`. Not biting today — `PM_ABE_PWRSTCTRL`
   has both ONSTATE fields at ON from reset and the table has never been
   applied — but it would put AESS memory into retention the moment anything
   drives the domain's memory states.

What this is worth, from the table at the top of this item: streams that match
the sink cost 3.5% of a core against 11.1% for anything that needs conversion.
It is a cliff, and the AESS moves every 44.1 and 48 kHz stream onto the free
side of it. The 4-channel design that forces the two remap sinks also goes
away, because DL1 and DL2 are separate AESS back-ends — that is the "one
untested idea" above, for free. Ship of Harkinian asks for 32000, which
`MultiMedia1` does not list, so that title needs its `gAudioSpecs[].frequency`
moved to 48000 to collect anything.

#### The DSP core executes, and the rate mechanism works

`device/pyra-aess-run.py`, run 2026-09-20 on stock `5.6.19-pyradef`. It decodes
the firmware container, loads all four memories, **builds the scheduler table
the driver never builds**, and starts the engine. Results, reproduced twice:

| | |
| --- | --- |
| `LOOPCOUNTER` (map entry 77, DMEM+0x6a4) | 3601 → 5203 → 6804 → 8405 → 10006 |
| loop rate, `EVENT_GENERATOR_COUNTER` = 2047 | **3999.3 / s** |
| loop rate, counter = 2227 | **3676.4 / s** |
| measured ratio | **0.9193** |
| expected ratio 2048/2228 | **0.9192** |

The ABE's scheduling loop is specified at 4 kHz. The first number is 0.015% off
that. The ratio is the real evidence, though: a free-running counter, or memory
moving for any reason other than the DSP, would not track the event-generator
divisor to four decimal places. It also demonstrates the 44.1 kHz family
reclock — the mechanism this whole item turns on — working on OMAP5 silicon.
Stopping the generator freezes the counter; restarting resumes it; with the
engine stopped, zero DMEM words change in a second.

**So the hardware is not the risk.** The OMAP4 firmware blob runs on the OMAP5
AESS, at the right rate, with the rate-family switch functioning. Everything
between here and working audio is software in the four items above.

#### Audio does not flow yet, and the reason is specific

`device/pyra-aess-dl-probe.py`, 2026-09-20. It injects a known constant into
`SMEM_MM_DL`, runs the engine, and reads the downlink buffers back. Across all
four phases — no injection; injection alone; plus output gains `DL1_L/R`,
`DL2_L/R`; plus mixer gains `MIXDL1_MM_DL` and `MIXDL2_MM_DL` at 0 dB — the
engine turns over at the correct 4000 loops/s, the injected value stays put in
`SMEM_MM_DL`, and **every downstream buffer reads exactly the firmware image**.
`SMEM_DL1_M_EQ`, `SMEM_EARP_48_96`, `SMEM_IHF_48_96` and `DMEM_MCPDM_DL_FIFO`
are all still zero.

That is expected once you see the mechanism. The 42 tasks in the config's
`init_table` are only the always-resident base schedule. A port's processing
tasks are written into `MultiFrame` when that port is *enabled*, by
`omap_aess_enable_data_transfer()` (`sound/soc/ti/aess/aess_port.c:1159`)
through `omap_aess_update_scheduling_table()` and `omap_aess_update_io_task()`
at lines 234 and 250. No port is enabled, so no DL task is ever dispatched and
the mixer gains have nothing to act on.

**The port-enable path was tried next, and it is where `/dev/mem` stops paying.**
`device/pyra-aess-port-enable.py` decodes the config's port table — 17 entries
of `struct omap_aess_port`, 228 bytes each, a stride confirmed by the compiler
and by the decoded fields being obviously sane (rates of 96000/48000/8000,
plausible protocols, the trailing entries landing exactly inside the blob):

| id | port | rate | dir | protocol | tasks |
| --- | --- | --- | --- | --- | --- |
| 6 | `MM_DL` | 48000 | in | DMAREQ | `MultiFrame[18][0] = 0x0d14` |
| 11 | `PDM_DL` | 96000 | out | MCPDMDL | `MultiFrame[7][0]`, `[19][0] = 0x0d64` |
| — | ping-pong | 48000 | in | — | `MultiFrame[18][0] = 0x0ca4` |

Adding `MM_DL`'s task to the schedule works — the engine dispatches it — and
still nothing moves, because that is only the `update_scheduling_table()` half
of `omap_aess_enable_data_transfer()`. A port must first be *connected*:
`omap_aess_connect_cbpr_dmareq_port()` → `omap_aess_init_io_tasks()` and
`omap_aess_init_atc()` write the port's IO descriptor and ATC descriptors into
DMEM. Reimplementing those means `init_atc` (~104 lines),
`clean_temporary_buffers` (~114), `init_io_tasks`, plus two descriptor layouts
— 400+ lines of intricate undocumented work in a place where every mistake is
an asynchronous external abort.

**That is the wrong direction, and the recommendation is to stop it.** The
kernel already holds all of it, working, in `aess_port.c`'s 1683 lines. The
`/dev/mem` work has done its job: it has removed the hardware risk, which was
the only question it could answer cheaply. Everything past this point is
reachable by filling in one empty function, and re-deriving it in userspace is
strictly worse than that.

**One more upstream bug found on the way.** `omap_aess_write_gain()` computes
`map[SMEM_GTARGET1].offset + (id << 2)` for gain IDs up to 35
(`MAX_NBGAIN_CMEM` is 36, needing 144 bytes), but this firmware declares
`GTARGET1` as **56 bytes — 14 slots**. Every mixer gain from id 14 up, which
is all of them, is written past the end of the declared buffer. The firmware
image has all 36 slots zeroed, so nothing else is visibly clobbered, but the
driver and the firmware disagree about the size of the gain table.

**And a rule that cost six aborts to learn:** all ABE memory access must be
32-bit. A byte-wise slice copy raises an asynchronous external abort. Because
the aborts are asynchronous they surface at whatever access happens next, so
they appear to blame innocent reads — bisecting by "which access died" leads
somewhere wrong. `pyra-aess-run.py` was doing byte-slice reads of DMEM and
getting away with it; that is fixed.

**Caveats before anyone commits a week.** The driver is TI's out-of-tree OMAP4
AESS code (9210 lines under `sound/soc/ti/aess/`) and the compatible is
`ti,omap4-aess`. Whether `letux-7.3` still carries the directory has not been
checked.

**Two hazards, both caused on 2026-09-20, both now guarded in the scripts.**
Reading past a bank's real size raises an asynchronous external abort that
wedges the L4 ABE interconnect; the device tree is not a safe source for those
sizes, because it maps PMEM and CMEM as `0x1000` when both are at least 8 KiB
and says `CHECKME` while doing it. Once wedged, handing the module back to
ti-sysc oopses in `sysc_disable_module`, leaves the device in `RPM_SUSPENDING`
permanently, and then hangs systemd shutdown for minutes — which costs a forced
power-off and an unclean unmount. Clean shutdown works fine as long as no abort
happened, which is what the size clamps are for.

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

Why it polls at all is now known, and it is not a tuning choice. Probe falls
back to a delayed work item and a `#define` of 25 ms. The poll never stops
because the driver has no close callback, which is exactly what the measurement
above shows and why stopping the daemon changes nothing.

**Wiring the interrupt is not possible on this board — checked on 2026-09-24.**
The device tree does name one: `interrupts` on gpio6_175 (left) and gpio6_174
(right), with the pads muxed as GPIO inputs with pull-ups, `0x11e`, the same as
the keypad's working interrupt pad. The driver discards it — it looks for a
Pandora-style `gpios` property with `of_get_gpio()`, finds none, and sets
`client->irq = 0` over what the i2c core supplied — so nothing has ever used
those lines, and a driver fix was the obvious next step. It would fire nothing:

- **Both pins read low 100% of the time**, pull-up and all, and the GPIO edge
  detector counted zero edges on either, idle or with a nub being moved.
- **They should be pulsing.** Per the datasheet (rev 1.11), `0Fh` resets to
  `F0h`: Idle mode, `INT_disable` = 0, `INT_function` = 0, which drives INTn
  (open drain, active low) low 450 µs after each Y readout and releases it on
  the ACK of the `11h` read. With the driver reading every 25 ms, that is a
  release per read per chip.
- **The chip is not what holds them low.** Writing `F8h` to `0Fh`
  (`INT_disable`, INTn fixed to Hi-Z) on each chip in turn left its pin at 0
  in 200 of 200 reads. With the chip's output floating and the pad pulled up,
  something on the board is driving the line low.

So the INTn net either does not reach the OMAP ball the device tree names, or
something else sits on it. That is a schematic question, not a software one,
and at 2–3% of a core and 25 ms of stick latency it is not worth chasing.
Closed.

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

**One escape hatch that is not one.** With C2 unreachable, the tempting move is
to offload background work onto one of the SoC's Cortex-M4s so the A15s need to
wake less often. That was examined on 2026-09-20 and fails twice over: the IPU
lives in the CORE power domain, so an executing M4 holds CORE at ON and DDR out
of self-refresh; and — the decisive half — with C1 the only reachable A15 state
there is nothing for offload to deepen, so the M4 can only be an additional
consumer rather than a trade. `docs/m4-ipu.md` carries the citations, under
"Why the M4s cannot buy the A15s a deeper sleep".

### 13. Transparent huge pages, which this kernel does not build

**Written 2026-09-20 from the config, not from the device. Nothing here has
been measured yet.** It is on this list rather than in "smaller items" because
it is one config symbol against the machine's worst-understood cost, and
because every part it depends on is already built.

The config that built the running kernel says:

    # CONFIG_TRANSPARENT_HUGEPAGE is not set

Everything it needs is already on. From the same `.config`:

    CONFIG_HAVE_ARCH_TRANSPARENT_HUGEPAGE=y
    CONFIG_COMPACTION=y
    CONFIG_MIGRATION=y

So this is not a patch and not a backport. It is one symbol in
`pyra_defconfig`, and the arch support comes free from `CONFIG_ARM_LPAE=y`,
which this machine has because it has 4 GB of RAM. `arch/arm/Kconfig:1580`
selects the arch capability; `pgtable-3level.h:36` sets `PMD_SHIFT` to 21, so
the huge page here is 2 MB.

**Why it should pay on this processor specifically.** The Cortex-A15 has a
512-entry unified L2 TLB. With 4 KB pages that is 2 MB of reach — smaller than
the working set of anything on the "what the whole machine is actually doing"
table above. Every miss past it is a page table walk, and LPAE makes that walk
three levels deep, so a miss costs up to three dependent memory accesses on a
machine already at the top CORE operating point with nothing left to give on
bandwidth. One 2 MB entry covers what 512 entries cover today.

This is the one mechanism on this list that attacks the *unattributed* cost.
The attribution table accounts for where the CPU goes by process; it cannot see
time spent stalled in a walk, because that time is charged to whatever process
was unlucky enough to be running.

**The test is Anno 1602 under box86 and x86 Wine.** `pyra-anno1602-test.sh`
already runs it bounded and with a thermal guard, and `docs/box86.md` has the
setup. It is the right load for this question for a reason beyond being the
heaviest one documented: it stacks three layers of anonymous memory that all
want the same TLB — the game's own heap inside the Wine prefix, box86's
dynarec blocks, and gl4es's buffers underneath both. A native ARM program with
a small working set would show nothing here and prove nothing.

    ./pyra-anno1602-test.sh -d 300 -p

Use the ratio method from item 0: `1602.exe` cost relative to the machine's own
busy total, across two runs, not absolute frame numbers. The game's own CPU
swings from 30% to 88% of a core depending on what is on screen.

**How to build it.** A `kernel-thp` variant in `pyra-crossbuild.sh` off the fix
kernel, its own `CONFIG_LOCALVERSION`, installed beside stock with
`pyra-install-debug-kernel.sh` and selected with `pyra-boot-kernel.sh` in
one-shot mode, exactly as item 12 describes. Nothing about this can hang the
machine the way C2 did — it is a memory management option, not an idle state —
but the one-shot path costs nothing and keeps the habit.

**Measure that it is actually happening before measuring whether it helps.**
Three places say so, and the first two are free:

    grep AnonHugePages /proc/meminfo
    grep -H . /proc/$(pgrep -f 1602.exe)/smaps_rollup | grep -i huge
    perf stat -e dTLB-load-misses,iTLB-load-misses -p $(pgrep -f 1602.exe) -- sleep 30

Check `perf list` first for that third one; whether this PMU exposes those two
event names is not known and the ARMv7 mapping is not the same on every part.
If `AnonHugePages` is near zero the rest of the measurement is meaningless, and
that is the likely failure mode — see the next paragraph.

**Three honest caveats, all of which could make this worth nothing.**

- **`madvise` mode will probably measure zero.** It is the safe default and it
  only promotes mappings that asked. Wine, box86 and the game ask for nothing.
  To find out whether there is an effect at all, measure with
  `echo always > /sys/kernel/mm/transparent_hugepage/enabled`, which is a
  runtime knob and needs no second kernel once the option is built in. Decide
  the permanent setting afterwards, from the number.
- **khugepaged is a jitter risk on this machine.** 4 GB, no swap, and an SD
  card rootfs. Compaction stalls show up as frame hitches, and on a handheld a
  stutter is worse than a mean throughput gain is good. So the acceptance test
  is frame *consistency*, not a mean. If the mean improves and the machine
  hitches, the answer is no.
- **It may simply be too small to see** under the noise of a game whose own
  cost varies by a factor of three. Two runs before and two after, ratios only,
  and be willing to call it unproven.

Effort: one config symbol, one build, one evening of measurement. Risk: low to
the machine, real to the frame times — which is the thing to measure, not the
thing to assume.

### 14. The Spectre v2 workaround, which costs more on an A15 than on anything else

**Surveyed 2026-09-20 against the config and the kernel source. Not measured.**
The ceiling below is reasoning, not a number, and it is low enough that it may
not clear the noise floor of any load this machine runs.

Meltdown does not apply to this processor. Spectre v2 does, and the workaround
ARM specifies for this particular core is unusually expensive.

Every other ARMv7 part invalidates the branch predictor with `BPIALL`, which is
cheap. The A15's BTB is not invalidated by `BPIALL`, so the kernel falls back to
`ICIALLU` — invalidate the **entire 32 KB L1 instruction cache**. In
`arch/arm/mm/proc-v7-bugs.c`, the A15 case selects
`harden_branch_predictor_iciallu` and logs the method. Confirm it on the
machine:

    dmesg | grep -i spectre        # CPUn: Spectre v2: using ICIALLU workaround

That would be cheap if it happened rarely. It does not — it is wired into the
context switch itself:

    arch/arm/mm/proc-v7.S:628
        globl_equ  cpu_ca15_switch_mm,  cpu_v7_iciallu_switch_mm

So every `switch_mm`, meaning every switch to a different address space, throws
away the instruction cache and refills it from L2. The only other call site is
`arch/arm/mm/fault.c:141`, which fires on a fault that is already about to
signal the process, and is nothing.

**Why the ceiling is low anyway, and this is the important paragraph.** Kernel
threads use lazy TLB and never call `switch_mm`, so the two i2c interrupt
threads that dominate the idle profile are not paying it at all. The game under
box86 is one process that runs for long slices. What is left is the
`1602.exe` / `Xorg` / `pulseaudio` rotation — a few thousand switches a second —
and each one costs only the refill of whatever gets re-executed before the next
switch, not a full 32 KB. The estimate is **1-3% on a context-switch-heavy load
and close to zero on a compute-bound inner loop.** A single thermal throttle
step is larger than that, and item 2 says this machine takes those.

**There is no cmdline opt-out.** `nospectre_v2` is not parsed anywhere under
`arch/arm` in 5.6. It is `CONFIG_HARDEN_BRANCH_PREDICTOR=n`, reached by turning
off `CONFIG_CPU_SPECTRE`, and a rebuild — or it stays.

**What is actually traded.** The realistic attacker for Spectre v2 is
JavaScript in a web browser. If this machine browses, that is a live vector and
not a theoretical one, and the trade is a real one for 1-3%. If it ends up a
game appliance that never opens a browser, there is no attacker and the trade
is free. That is a decision about how the machine gets used, not about the
kernel.

**Do not combine this with item 13.** Both change memory behaviour, one build
carrying both makes neither result attributable, and item 13 is the one with
the larger plausible payoff. Measure that first.

Effort: one symbol, one build. Risk: none to stability.

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

**Trading the rest of the kernel's security options for speed.** Surveyed
2026-09-20 against `../dragonbox-pyra-build/kernel/src/.config`, the config
that built the running kernel. The conclusion is that there is almost nothing
here, and the reason is worth recording so it is not re-derived: **this is not
a distribution kernel.** `pyra_defconfig` has already been trimmed by somebody
who knew what they were doing, and most of what would be worth turning off on a
Debian kernel is either already off or not applicable to this hardware.

Item 14 is the one exception and is the only one with a mechanism big enough to
name. Everything else:

| Option | State | Why it gives nothing |
| --- | --- | --- |
| `INIT_ON_ALLOC_DEFAULT_ON`, `INIT_ON_FREE_DEFAULT_ON` | already `n` | This is the single biggest free win on a Debian-built kernel — zeroing every allocation costs real memory bandwidth on a part that has none spare. This tree does not enable it. Nothing to turn off, and `init_on_alloc=0` on the cmdline is a no-op here |
| `CPU_SW_DOMAIN_PAN` | not applicable | Depends on `!ARM_LPAE`, and this machine is `ARM_LPAE=y` because it has 4 GB. The DACR write around every `copy_{to,from}_user` is not happening. On a non-LPAE ARMv7 this would be worth more than item 14 |
| `HARDENED_USERCOPY` | `y` | A bounds check per user copy (`check_object_size`, `thread_info.h:152`). Real, but it is a handful of instructions against a copy that already touches memory. Sub-1%, and the failure it catches is a kernel heap overread reaching userspace |
| `STACKPROTECTOR_STRONG` | `y` | A canary load and compare per function with a stack array. Spread across the whole kernel, which means it is everywhere and nowhere — around 1% of kernel time, and kernel time is 35% of this machine's busy total, so the ceiling is ~0.3% overall |
| `SLAB_FREELIST_RANDOM`, `SLAB_FREELIST_HARDENED` | `y` | Slab allocation locality and a pointer XOR. Measurable only in an allocator microbenchmark |
| `FORTIFY_SOURCE` | `y` | Almost entirely compile-time. The runtime residue is checks the compiler could not fold, on paths with a known size |
| `AUDIT`, `AUDITSYSCALL` | `y` | Compiled in, but gated on `TIF_SYSCALL_WORK`, which nothing sets unless audit rules are loaded. `auditd` is not installed. The cost is already zero and `audit=0` changes nothing measurable |
| `SECCOMP_FILTER` | `y` | **Do not turn this off.** Processes without a filter pay nothing, and systemd's `SystemCallFilter=` on units depends on it. Removing it breaks service startup to buy nothing |
| `MODULE_SIG` | `y` | Build-time only. Turning it off saves signing time in `pyra-crossbuild.sh`, not cycles on the device |
| `SECURITY_APPARMOR` + `SELINUX` | `y`, AppArmor is `CONFIG_DEFAULT_SECURITY` | The only one worth a look, and it needs no rebuild to answer. LSM hooks sit on every `open`, `exec` and `mmap`. But the hooks cost nothing if no profiles are loaded — check `cat /sys/kernel/security/apparmor/profiles` on the device, and if it is empty there is nothing here. If it is not, `apparmor=0` on a second `extlinux` entry tests it for the price of a reboot |
| `ARM_ERRATA_798181` | `y`, and active | Not a security option and not a candidate at any price. It is a data corruption erratum — moving a page while a process is accessing it. It is already runtime-gated: `erratum_a15_798181_init()` in `arch/arm/kernel/smp_tlb.c` reads MIDR and REVIDR at boot. This machine is **r2p2**, which lands in the branch that selects either the partial handler or the full broadcast one depending on REVIDR bit 4, so it *is* running, and the full variant adds an IPI to the other core on every `flush_tlb_*` (`broadcast_tlb_mm_a15_erratum`). Expensive, mandatory, and the failure mode is silent corruption |
| `DEBUG_LIST`, `DEBUG_SG`, `DEBUG_PREEMPT`, `SCHED_DEBUG`, `FUNCTION_TRACER`, `UBSAN`, `KASAN` | already `n` | All of them. A distro kernel ships several of these on; this one does not |

**And the knobs that are already set the way you would set them.** Recorded so
nobody spends an afternoon on it: `CC_OPTIMIZE_FOR_PERFORMANCE=y` (not size),
`HZ=100`, `NO_HZ_IDLE=y`, `PREEMPT=y` — which is the right choice on a machine
running a game and an audio thread, and is also what makes the lockup detector
work in `building.md` — `ARM_PATCH_IDIV=y`, `SLUB` rather than `SLAB`, and
`CPU_BPREDICT_DISABLE` correctly off. `THUMB2_KERNEL` is off and would cut the
kernel's instruction footprint by roughly a quarter, which is mildly
interesting next to item 14's I-cache problem, but it is a large change to the
whole kernel for an unmeasured second-order effect and it is not worth being
the first thing tried.

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
- ~~**`Option "SwapbuffersWait" "true"`** ties buffer swaps to vblank. That is
  almost certainly correct — it is what prevents tearing — but it caps
  fullscreen throughput at 60 FPS and should be named as a deliberate choice
  rather than discovered during a benchmark that mysteriously refuses to exceed
  60.~~ **Corrected 2026-10-18:** `omap5_drv.so` has no such option. The string
  is in neither the 0.6 source nor the binary, so the line does nothing. Vsync
  for GLES clients is decided by `libpvrDRI3WSEGL.so` (§6, "What the source
  says"). The line can go, or stay with a comment saying it is inert.

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
