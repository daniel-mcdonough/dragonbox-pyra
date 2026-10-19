# Profiling on the Pyra

The hardest part of optimising this machine is not finding a change. It is
measuring one. This project spent two phases acting on numbers that turned out
to be artefacts of the thermostat, the governor, or a synthetic benchmark that
did not resemble the workload.

This document is the measurement discipline that came out of that, in the order
you need it.

---

## 1. Four traps, before any tool

Read this section before you measure anything. Each of these has produced a
confident, reproducible, wrong answer on this device.

### 1.1 The thermostat moves frame rate by ~30%

Cold, the SoC runs at 1.5 GHz. Under sustained load the frequency walks down
through 1.4, 1.25, 1.125, 1.0, 0.875, 0.75 GHz.

Measured: within a **single 50-second run**, frame rate fell 20.1 → 13.8 fps as
the die went 56 → 68 °C. No code changed.

> **Warm to thermal equilibrium (73–80 °C) before the first measured sample, and
> interleave your arms.**

Warm-up here means several minutes of the real load, not a few seconds. Even
16,000 warm-up frames was found not to be equilibrium — the reference arm still
drifted 1.44% across a run while the die went 46 → 77 °C, which is 3.6x the
rig's own resolution.

Since perfect equilibrium is not reachable in practice, **counterbalance**:
run arms as A-B-B-A pairs so that monotonic drift contributes equally to both.

### 1.2 Percentages lie, because the denominator moves

Identical work, same machine, same audio stream:

| condition | `pulseaudio` | clock |
| --- | --- | --- |
| `ondemand`, as shipped | **26%** of a core | 625 MHz |
| `performance` | **11%** of a core | 1500 MHz |

Nothing about the work changed. A small steady load reads as idle to
`ondemand`, which settles low, which roughly doubles the apparent cost.

> **Never compare `top` percentages taken at different clocks.** Either pin the
> governor for the duration, or — better — compare each process's cost **as a
> ratio to the workload's own cost**.

The ratio method is what made the compositor question answerable. The game's own
CPU varied from 30% to 88% of a core between runs, so absolutes were useless,
but `Xorg / game` reproduced to within 2%:

| | compositing on, run 1 | on, run 2 | off |
| --- | --- | --- | --- |
| `Xorg` / game CPU | 0.243 | 0.246 | 0.240 |
| `marco` / game CPU | 0.064 | 0.068 | below 0.010 |

Always record the CPU frequency trace alongside every run. Half of any result
set will turn out to be governor artefacts and there is no way to tell
afterwards.

### 1.3 Frame caps and vsync hide everything

Two independent limiters will silently clamp your measurement:

- **Vsync quantises to 60/N** — 60, 30, 20, 15 fps and nothing between. A change
  that moves you from 28.7 to 30.5 fps shows up as *no change at all* until it
  crosses 33.3 ms. Turn vsync off for A/B work.
  *(2026-10-18: the advice stands, but the mechanism is uncertain. As shipped,
  the window system only holds a frame for vblank when it arrives within one
  refresh of the last. Its real vsync wait needs `DRI3_VSYNC=1`, which nothing
  sets. `rendering-guidelines.md` §1.2.)*
- **The application's own frame cap.** Frame times pinned at exactly 50.00 ms
  with vsync off is the signature of an internal 20 fps limiter. Raise it.

But raising the cap can change the workload. In this engine, raising the cap to
60 made game logic run at 9.7 Hz instead of 20 — the frame became *more*
GPU-weighted than real gameplay. That is fine for a conservative null result and
wrong for a shipping-configuration number. Know which you are taking.

### 1.4 Synthetic benchmarks answer a different question

The most expensive mistake on this project. A synthetic fill-rate test — one
textured, blended, full-screen quad, no state changes — measured 862 Mpix/s and
was read as "the GPU has 15x headroom, so the bottleneck is CPU-side". A whole
phase of work was reprioritised on it.

It was wrong. The real workload is strongly fragment-bound: halving internal
resolution gained **+75%**. Overdraw, small triangles, texture binds, state
churn and per-fragment branches behave nothing like one big quad on a tile-based
deferred renderer.

> **A synthetic number is an upper bound on a best case, not a prediction.**

Corollary: a deterministic *fixture* — a frozen frame of the real game — is a
much better rig, and still is not the game. It tells you a frame got cheaper to
draw, not that the game got faster. Anything that screens well in a fixture has
to be confirmed in real play.

---

## 2. The first question: CPU-bound or GPU-bound?

Answer this before anything else. The cheapest discriminator on this machine
does not need a profiler.

### 2.1 The resolution test

Halve the renderer's internal resolution and measure.

| Result | Meaning |
| --- | --- |
| Frame rate rises a lot (here: +75%) | **GPU-bound**, and fragment-bound specifically |
| Frame rate barely moves | **CPU-bound**, or bound by draw call count |

This takes two minutes, needs no tooling, and on this device it has been more
informative than any profile. It works because resolution scales fragment work
and nothing else.

### 2.2 The corroborating signs

**CPU-bound looks like:**

- One or both cores pinned near 100% while frame time is flat
- Frame rate insensitive to resolution
- Frame time spikes correlated with simulation events, not with what is on screen
- `perf` shows time in your own code, the allocator, or a library

**GPU-bound looks like:**

- CPU cores well below 100% and the process blocking in `eglSwapBuffers` or
  `glFinish`
- Frame rate strongly sensitive to resolution
- Frame rate sensitive to shader complexity and to overdraw
- `perf` shows time in `libGLESv2`/`pvr` symbols, `_SegmentListInsert`, PVR
  mutexes and spinlocks — that is the driver *waiting*, not working

Under X on this image, `eglSwapBuffers` always waits for the frame's GPU work
to finish, even in a frame that is not GPU-bound. The window system does it
explicitly (`rendering-guidelines.md` §1.6). So swap time measures the GPU's
unoverlapped share of the frame plus one X round trip. Frame time is roughly CPU
time plus that tail, not the larger of the two, and that changes how a saving
on either side shows up. Read from source, 2026-10-18; not measured.

**Bound by draw calls looks like:**

- Insensitive to resolution **and** insensitive to shader complexity
- Scales with the number of objects, not their size
- Check against the budget: ~14.2 µs per draw, ~2,300 draws per frame at 30 fps

That budget is a **floor, not a forecast**. It was measured with a 1x1 scissor and
16-triangle batches, so it is the driver's own per-call cost and nothing else. In
Ship of Harkinian, non-swap frame time divided by draws is ~80 µs at two different
fixtures (2026-09-24). Whatever the other ~66 µs is, it is not in that budget, and
a plan that treats the synthetic figure as the real per-draw cost will conclude
draw calls are free when they may not be.

### 2.3 Careful with the driver's share

In the Ship of Harkinian profile the PowerVR driver and kernel accounted for
8.5%. That is not 8.5% of work you can remove — a good part of it is the process
blocking on the GPU, which is the *symptom* of being GPU-bound, not a cost to
optimise.

### 2.4 Computing or waiting? Measure it, do not infer it

§2.2's signatures describe what each case *looks* like. There is a direct
measurement, and it is cheaper than a profile.

**Compare on-CPU time against wall time, per thread.**

```sh
perf stat --per-thread -p $(pgrep -f yourgame) -- sleep 30
```

Read `task-clock` for the thread that draws against the 30 s elapsed. Per thread
matters: a render thread at 40% and an audio thread at 60% average to something
that looks busy and is not. A program can also read its own with
`clock_gettime(CLOCK_THREAD_CPUTIME_ID)` at two points and print it next to its
frame timings, which costs nothing and makes every later run carry the
diagnostic.

| Reading | Meaning | Next step |
| --- | --- | --- |
| On-CPU ≈ elapsed, IPC ~1+ | Genuinely computing | `perf record`, §3.2 |
| On-CPU ≈ elapsed, IPC ~0.2 | Stalled on memory, not on work | `perf stat -e cycles,instructions,cache-misses` |
| On-CPU well below elapsed | **Blocked.** A sampling profile will not show this at all | below |

**A sampling profiler cannot see waiting.** A sleeping thread takes no samples,
so time spent blocked simply vanishes from `perf report` — and a driver that
*spins* instead appears as work you cannot remove (§2.3). This is the trap
behind reading an 8.5% driver share as an 8.5% opportunity.

When the answer is "blocked", find the call site rather than the symptom:

```sh
perf list | grep sched:                        # confirm the tracepoints exist
perf sched record -p $(pgrep -f yourgame) -- sleep 20 && perf sched timehist
perf trace -e ioctl -p $(pgrep -f yourgame)    # or: strace -c -f -e trace=ioctl
```

Counting **ioctls per frame** is the bluntest useful version of this on a
PowerVR stack: submission goes through `/dev/pvrsrvkm`, so ioctls per frame
against draws per frame says directly whether the frame is shaped by draw calls.
The same counting trick answered `improvements.md` §6. Record every process's
ioctls and tally the request codes:

    sudo perf record -a -e raw_syscalls:sys_enter --filter "id == 54" -- sleep 10
    sudo perf script | sed -n 's/^ *\([^ ]*\) .*NR 54 ([^,]*, \([0-9a-f]*\),.*/\1 \2/p' | sort | uniq -c | sort -rn

(`54` is `ioctl` on ARM EABI.) `c01864b0` is `DRM_IOCTL_MODE_PAGE_FLIP` and
`c0486446` is etnaviv `GEM_SUBMIT`. Two things did not work: `-p <pid>` with
uprobe events (perf refuses it per-thread; use `-a`), and uprobes on Thumb code
at all, which covers Xorg's exported functions (EINVAL from `perf_event_open`).

Status: the on-CPU-versus-wall comparison and the ioctl count are **method, not
yet results on this device** — written down 2026-09-24 because the Ship of
Harkinian port has 65% of its frame unattributed and no way to tell which of
these three rows it is in.

---

## 3. Tools that work here

### 3.1 In this repository

None of these need a rebuild and none of them touch DPMS (see §4):

| Question | Tool |
| --- | --- |
| Where is all the CPU going, by process, whole machine | `device/pyra-cpu-attribution.sh` |
| What share is the X server, and is the 2D engine moving | `device/pyra-x-load-profile.sh` |
| A real, repeatable, bounded, thermally-guarded load | `device/pyra-anno1602-test.sh` |
| Driver fallback costs against hardware paths | `device/pyra-exa-fallback-bench.c` |
| What each frequency rung costs | `device/pyra-ceiling-cost.sh` |
| Frequency and thermal behaviour under load | `device/pyra-freq-profile.sh`, `device/pyra-thermal-probe.sh` |
| Collect the whole hardware picture in one file | `device/pyra-hwreport.sh` |

`pyra-cpu-attribution.sh` is the one to run first on any new workload. It
accounts for **all** the busy CPU on the machine by process, which repeatedly
turned out to change the ranking more than any single-subsystem measurement —
it is how PulseAudio was found to cost more than the compositor and nearly as
much as the X server, on a project that had never looked at audio.

Since 2026-09-26 it also prints busy time **per core**, and `-t <process name>`
lists that process's threads by name with their CPU over the window (as a share
of one core and of all busy time): `-d 120 -t soh.elf` splits a game's main
thread from its audio and driver threads. A thread that starts or exits inside
the window is left out and counted as such.

### 3.2 Standard tools

**`perf`** works. Use it.

```sh
perf record -F 999 -a -g -- sleep 50        # whole machine, 50 s
perf report --sort=comm,dso
perf top -p $(pgrep -f yourgame)
perf stat -p $(pgrep -f yourgame) -- sleep 30
```

Sampling the whole machine (`-a`) rather than one process is usually right here,
because the interesting finding is often in a different process. Note that a
sample-share profile is a **ratio of busy samples**, so unlike a `top` reading
it is not a governor artefact — which makes it the better instrument when the
clock is moving.

Check `perf list` before relying on any PMU event name. Whether this part
exposes `dTLB-load-misses` and `iTLB-load-misses` is not established, and the
ARMv7 event mapping is not the same on every implementation.

**Inside one function, sample counts overstate slow instructions.** On the
Cortex-A15, samples skid onto the instructions after a `VDIV.F32` (~14 cycles,
not pipelined) or a `VMRS` flag transfer, and the sampled PCs can even land
mid-instruction. In Shipwright report 8 §8.26 this attribution put ~0.9 ms per
frame on divides that the interpreter repeats. Removing about 40,000 of them saved 0.19 ms:
the core runs other work under a divide. Use in-function attribution to pick a
candidate, and an A/B to size it. If the binary has no line tables, bin the
`perf script -F ip` addresses (minus the mmap base) against `llvm-objdump
--triple=thumbv7a-linux-gnueabihf`.

The fix itself is still worth knowing: `x / 255.0f` compiles to a `VDIV`
without `-ffast-math`, because 1/255 is inexact. A 256-entry table of
`i / 255.0f` gives the bit-identical float.

**Off-CPU time** is not something `perf record` reports by default; see §2.4 for
`perf sched` and for the on-CPU-versus-wall comparison that tells you whether you
need it.

**`ftrace`** is available for scheduler and interrupt-level questions.
`/proc/interrupts` sampled twice a second is often enough and is much cheaper —
it is how the 858-interrupts-per-second i2c floor was found.

**`valgrind` / `callgrind`** run, but the slowdown changes the thermal and
frequency behaviour completely, so treat them as correctness and allocation
tools rather than as performance instruments.

**`gprof`** requires instrumentation and distorts small functions. `perf` is
better in every case here.

**GPU profiling: PVRTune works.** This section used to say there was none. Nobody had tried it.
Imagination's legacy "PVRTune for SGX" (SDK 17.1) server runs on the stock `5.6.19-m4` kernel
and DDK and streams HWPerf data: TA and 3D start/end per kick, tiler and renderer utilisation,
vertex and pixel load, HSR efficiency, memory traffic. apitrace (EGL/GLES2) records a game's
call stream on the device and replays it on the desktop as a frame debugger. Both are set up
in `experiments/gpu-tools/`, with the first measurement: Ship of Harkinian's GPU is ~20% busy
at its 30 fps cap. There are still no GL timer queries, and no in-process GPU timings beyond
`GL_EXT_occlusion_query_boolean`.

---

## 4. Do not use `x11perf` on this machine

It disables and restores DPMS around **every single test**. Each of those is a
full modeset in the `omap5` driver, and the modeset path can wedge the display
hard enough to need a reboot, spinning a core at 100% in a fanless case while it
does. Two hangs came from it on 2026-09-10.

The `x11perf` numbers that appear in `improvements.md` were taken before this
was understood. They stand as a record; do not reproduce them that way.

More generally: **be careful with anything that toggles DPMS or changes modes in
a loop.** Ordinary idle blanking is enough to hit this. See
`docs/troubleshooting.md`.

---

## 5. Building a rig that can resolve a small change

Reports 7 and 8 of the Ship of Harkinian port both ended at the same wall: the
rig could not resolve anything smaller than about **±13%**, which is wider than
most changes worth making. A purpose-built rig got that to **0.40%**, about 33x
better. What it does is worth copying.

### 5.1 Hold the workload constant

The original rig ran the title-screen attract demo for a fixed wall-clock window
and compared mean frame rate. That is not a fair comparison when game speed is
coupled to frame rate: **the faster arm travels further through the scene** and
ends up rendering different geometry. The two arms are not measuring the same
work, and no amount of repetition averages it away, because the confound is
correlated with the thing being measured.

The fix is a **deterministic fixture**: a fixed scene, a fixed camera, a fixed
entry point, no simulation advance, a fixed number of *frames* rather than a
fixed number of seconds.

### 5.2 Switch arms inside one process

Two arms that each need their own process launch are minutes apart, and the die
moves in between. Put both configurations in one binary behind a switch, and
alternate segments within a single run.

### 5.3 Counterbalance and pair

Run **ABBA** segments, and analyse as a **paired** comparison — each A segment
against its adjacent B segment, not pooled means. Monotonic thermal drift then
contributes equally to both arms and cancels in the pairs.

### 5.4 Throw away the transient

Drop the first samples of every run: shader compilation, page faults on
first-touch pages, and the initial thermal ramp all live there. The rig here
drops 16,000 warm-up frames and the first three 5-second windows of each run.

### 5.5 Report a detection threshold, not just a delta

Compute the paired t-statistic and, crucially, the **minimum detectable effect**
— the smallest delta that would have reached significance given the observed
variance. Then a null result means something:

```
paired n=5  mean_delta_us=-26.74  sd_us=57.53  t=-1.039  df=4   mde_us=71.52 (0.26%)
```

That says "no effect, and the rig could have found one as small as 0.26%",
which is an actionable statement. "No difference observed" on its own is not.

### 5.6 Validate the rig against itself

Before trusting it, run **the same arm against itself** — A vs A, true effect
exactly zero by construction. Anything it reports is its own noise.

On this device that check produced ten identical segments spanning 1.15%
peak-to-peak, standard deviation 0.37%, `t = −0.72` against a critical value of
±2.776 — correctly not significant, **through a 22 °C excursion and a 1.5 →
1.25 GHz throttle**. A rig that reports a difference on that test is broken.

---

## 6. Worked example: the measurement that changed the model

Included because it shows the whole method and because its result was the most
counter-intuitive on the project.

**Question.** Is fragment texture fetch cost a real constraint on this GPU?

**Rig.** Deterministic fixture — Kokiri Forest, fixed viewpoint, static scene.
640x360 internal on a 1280x720 fullscreen window. 16,000 warm-up frames, then 5
ABBA pairs of 600 measured frames each. Vsync off, frame cap raised, thermal
equilibrium.

**Two comparisons, chosen so that one interprets the other:**

| Arm A | Arm B | Frame time | Result |
| --- | --- | --- | --- |
| three-point filtering | bilinear | 34098 → 28047 µs | **−17.75%**, `t = −154.8` |
| bilinear | nearest | 28064 → 28037 µs | **−0.1%**, `t = −1.04`, n.s. |

**Interpretation.** Bilinear reads four texels; nearest reads one. Unmeasurable
— the texture unit filters in fixed-function hardware, so extra taps never
become shader work. Three-point is emulated in the fragment shader as three
`texture2D` instructions plus ALU per texture unit, and costs 17.75%.

**What made it good.** The second comparison is what makes the first
interpretable. Measuring only the first would have supported "texture reads are
expensive", which is the wrong model. The pair isolates *shader instruction
issue* from *texel traffic*, and that distinction now drives every
recommendation in `gpu-optimization.md`.

**Caveats stated with the result**, because they matter:

- 17.75% is **viewpoint-specific**. Fragment cost as a percentage depends on
  what else is in the frame, and this frame is not representative. The
  magnitude is far too large for the sign to change, but the figure is not
  scene-independent.
- The fixture was still not at equilibrium; ABBA cancelled the drift rather than
  the machine being steady.

---

## 7. A checklist for any A/B on this device

- [ ] Deterministic workload — fixed scene, fixed frames, no simulation drift
- [ ] Vsync off, application frame cap raised
- [ ] Warmed to thermal equilibrium (73–80 °C) before the first measured sample
- [ ] Both arms in one process, alternated ABBA
- [ ] Governor pinned, or results expressed as ratios
- [ ] CPU frequency and die temperature logged through the run
- [ ] Transient samples discarded
- [ ] Paired statistic **and** a minimum detectable effect reported
- [ ] Rig validated A-vs-A before it was trusted
- [ ] Fixture result confirmed in real play before it ships
