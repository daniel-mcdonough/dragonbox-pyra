# The Pyra optimisation playbook

> **Type: reference.** How things are and why; not a procedure.

Index and triage for the hardware knowledge base. Two things live here:

1. **What the ten documents are**, and which to read for what.
2. **A triage of every optimisation proposed on this hardware so far** — across
   the system work in this repository and the Ship of Harkinian port in
   `docs/pyra/` in the Ship of Harkinian port (Shipwright-pyra) — saying which are worth pursuing, which are
   closed, and which are refuted by evidence that already exists.

Written on 2026-09-22 against the state of both projects on that date.

> **Updated later the same day.** The Ship of Harkinian side moved while this was being
> written. Three entries in §4 are now out of date and are marked in place rather than
> rewritten: item 2 is **closed**, the `TextureFilter` default is **shipped** and its number
> is larger than recorded here, and the rig now resolves 0.57% rather than 0.40%. The triage
> also earned its keep immediately — reading the two projects against each other caught item
> 7, a proposal to build something the project had already measured as harmful.

---

## 1. The documents

| Document | What it is for |
| --- | --- |
| [hardware-overview.md](hardware-overview.md) | **Start here.** The machine, the numbers, and the seven ways it differs from anything modern |
| [cpu-optimization.md](cpu-optimization.md) | Cortex-A15, NEON, the TLB, and why the CPU is usually not the problem |
| [gpu-optimization.md](gpu-optimization.md) | SGX544MP2, TBDR behaviour, measured limits, what costs and what is free |
| [memory-optimization.md](memory-optimization.md) | Shared bandwidth, the readback cliff, and why traffic reduction has not paid |
| [rendering-guidelines.md](rendering-guidelines.md) | The display pipeline, and adapting a desktop renderer |
| [compiler-flags.md](compiler-flags.md) | What to build with, and what is not worth adding |
| [profiling-guide.md](profiling-guide.md) | The measurement traps, and how to build a rig that resolves 0.4% |
| [porting-checklist.md](porting-checklist.md) | A phased checklist from feasibility to confirmation |
| [known-limitations.md](known-limitations.md) | Hard walls, and everything already tried that did not work |
| [kernel-notes.md](kernel-notes.md) | Tunables, what to change, and what to leave alone |

`device/pyra-hwreport.sh` collects the static hardware picture into one file.

### Using these as context for an AI assistant

`hardware-overview.md` plus `known-limitations.md` is the minimum useful pair —
the first establishes the model, the second prevents re-deriving closed
questions. Add `gpu-optimization.md` and `rendering-guidelines.md` for anything
touching a renderer, and `profiling-guide.md` before anything is measured.

The convention throughout is that every claim is marked **Measured**, **Spec**,
or reasoning, and that corrections are kept visible rather than edited away. An
assistant reading these should preserve that: do not promote an estimate to a
fact, and do not delete a superseded number — mark it.

---

## 2. What the evidence actually says

Three findings reshaped the model of this machine, and everything in the triage
below follows from them.

**Fragment shader instruction issue is what binds, not bandwidth and not the
CPU.** Removing two `texture2D` instructions per texture unit saved 17.75% of
frame time — **re-measured at 19.88%** once the benchmark was pinned to a
viewpoint somebody had actually chosen, rather than the one it had drifted to.
Removing three quarters of the *texels* read — bilinear to nearest — saved
0.1%, statistically zero. The texture unit filters in fixed-function
hardware; the shader instruction is what costs.

**Two correct bandwidth arguments produced null results.** Discarding 140 MB/s
of pointless depth writeback: −0.64%, not significant. A synthetic fill-rate
test showing 15x headroom: read as a prediction, and wrong.

**The thermostat is a first-class variable.** A 30% frame-rate swing between
cold and equilibrium, with no code change. Any measurement not taken at
equilibrium and interleaved is measuring it.

---

## 3. Triage — system level (this repository)

Ranked by what to do next, not by size. Full evidence in `improvements.md`.

### Do these

| # | Item | Why | Cost |
| --- | --- | --- | --- |
| 1 | **Fix the modeset hang** | Not a performance item and it still comes first. A wedged display spins a core at 100% in a fanless case until reboot. Candidate fix written, cannot be confirmed until it next fails to happen | Unknown; waiting |
| 2 | **Finish the AESS audio DSP path** | The largest confirmed non-game consumer on the machine. Audio costs 18.4% of all busy CPU during a game; removing it entirely was worth +4.1% mean frame rate and +11% on the tail. The DSP takes 44.1 and 48 kHz natively and the 4-channel remap goes away for free | In progress |
| 3 | **Build `CONFIG_CPU_FREQ_GOV_SCHEDUTIL`** | One symbol. Attacks the 18% gap that `ondemand` tuning could not close, by the right mechanism — scheduler utilization rather than a sampled 20 ms window. The sweep to measure it already exists | One build, one evening |
| 4 | **Build `CONFIG_TRANSPARENT_HUGEPAGE`** | One symbol, and the only item that attacks the *unattributed* cost — 2 MB of TLB reach against working sets far larger. Test with `always`, accept `madvise` will measure zero, and **judge on frame consistency, not a mean** | One build, one evening |

### Worth a look, cheaply

| Item | Why | Caveat |
| --- | --- | --- |
| **The 2-channel PulseAudio sink** | Everything downstream of conversion moves four channels to deliver two, and that pipeline is ~15% of a core. `CHANNELS: [1 5]` says the hardware allows two | Costs the speaker/headphone split. A product decision, not a performance one |
| **`speex-fixed-1` instead of `trivial`** | `trivial` is the cheapest resampler and also the worst. Nobody chose this trade deliberately; it was inherited | Costs some of the 8-point conversion penalty back |
| **The TWL6040 96000 Hz mode** | Two mixer writes, fully reversible. The machine is currently tuned for 44.1 kHz music and *against* 48 kHz games | Does not save CPU — 96000 is more output samples. It is a quality lever |
| **XLibre, for the AIGLX fix only** | If it has fixed Xorg 21.1.16's AIGLX DRI2 NULL dereference, it retires fix 4 and gives the machine back desktop GLX — which unblocks Wine's 3D path | Check the diff. Do **not** port the server on spec. No performance value |
| **`nodiscard` + weekly `fstrim`** | Inline discard on an SD card can stall writes | One `fio` run to find out |
| **Present from a worker thread in `libpvrDRI3WSEGL.so`** *(added 2026-10-18)* | The window system makes every swap wait for the SGX to finish the frame, so CPU and GPU never overlap. Its source is MIT and archived. Up to ~5 ms of SoH's 31.8 ms frame, if the CPU has next-frame work to overlap | From source, not measured. Up to one frame of extra latency. Testable per process, no system change. `improvements.md` §6 |

### Closed — do not re-derive

| Item | Verdict |
| --- | --- |
| 3D on the SGX rather than software Mesa | Done and verified. `glxgears` ~870 fps, glmark2 246 |
| Framebuffer copies / TILER rotation | Rotation is already in hardware; the 211 MB/s CPU-copy arithmetic describes a different machine. **One copy does exist:** Xorg has the GC320 copy each fullscreen game frame to the scanout, with no flip. Open, `improvements.md` §6. **2026-10-18:** the cause is that the DDX's Present flip is compiled out. From the source, the copy costs watts, not swap time. The same reading found the swap waiting for the GPU every frame, which is the larger lead: see the row added under "Worth a look, cheaply" |
| Desktop compositing | Off. 3.5% of all busy CPU, one `gsettings` call |
| Governor tuning | Done. `sampling_down_factor` 1→10 is the whole win, 23% of burst latency |
| Thermal daemon and ladder | Fixed. Five faults in one function; 107 °C → 87 °C on two cores |
| Memory clock | Already at the top CORE operating point |
| EXA / pixman / 2D rebuilds | Fills and blits already accelerated. Ceiling for a driver rebuild is a *fraction* of 9.3% of busy CPU |
| Blanket NEON archive rebuild | pixman, ffmpeg and PulseAudio already dispatch NEON at runtime |
| C2 retention idle | Hangs the machine within 90 seconds. Two for two |
| i2c interrupt floor | 2–3% of one core for a kernel patch, and one idle state means it blocks nothing |
| Finer CPU frequency steps | 4% slower on the mean. Buys idle battery, not responsiveness |
| M4 offload to deepen A15 sleep | Nothing to deepen; an executing M4 holds CORE on |
| XLibre for performance | Same code, same architecture |
| Stripping legacy X code | Dead code costs nothing at runtime |
| Kernel security options for speed | Already a trimmed defconfig. Only Spectre v2 has a nameable mechanism, at 1–3% |
| Writing an open SGX driver | Mesa starts at Rogue. Multi-year, and not a performance task |

### Research, not a change

**The GPU rail above NOM.** Worth roughly a quarter of the GPU's throughput and
the highest-value unexplored item on the device. Also the one most likely to be
impossible: no `devfreq` node, no GPU OPP table, voltage readback unavailable.
**Raising a clock without confirming the matching voltage is how silicon gets
damaged.** If the voltage side cannot be verified, the correct outcome is to
close the item.

---

## 4. Triage — application level (Ship of Harkinian port)

Against the nine-item catalogue in `docs/pyra/08-optimisation-opportunities.md` in the Ship of Harkinian port (Shipwright-pyra).

### Two things that outrank the whole catalogue

**The save-file corruption bug.** Report 7 §7.7 records spdlog's file sink
failing 37 times in one run and its writes landing in a reused descriptor,
producing a log line written *into* a save file. It reproduced in a solo run, so
it is not a concurrency artefact. It is marked "not yet investigated".

This is a data-loss bug in the thing the port exists to deliver. It outranks
every item below, and it should be diagnosed before the port is used for real
play — let alone before more frame time is chased.

> **Acted on, 2026-09-22. Mechanism closed, cause still open.** Report 10 in the
> Shipwright tree has it. The two symptoms have one mechanism and it reproduces
> byte for byte: something closes spdlog's descriptor without telling spdlog,
> `EBADF` while the number is unallocated, then the next `fopen` — the save — is
> handed the same number because Linux allocates the lowest free one, and the
> logger's next flush writes into it. `SaveManager` now reads back what it wrote
> and renames only on a match, so a corrupt write costs one save rather than the
> save; `SaveGlobal`, which had no temp file at all, gained one.
>
> **The close itself is still unattributed.** Nothing in either source tree calls
> `close()` on Linux, so it is in SDL2, libzip, the audio stack or the PowerVR
> blob. `Shipwright/scripts/pyra/fdguard.c` is an `LD_PRELOAD` that names the
> caller with a backtrace and catches the descriptor being handed on; it is built
> and verified against a reproduction, and needs one device run with a save in it.
> Until that runs, every other descriptor in the process is still exposed — the
> log is the noisiest victim, not the only possible one, and `Config::Save()` has
> the same unchecked-write defect.
>
> This triage was right to put it above the catalogue.

**Re-baseline on the report 9 harness.** Every absolute FPS figure in report 7
predates both the audio DSP move and the 0.40% rig. The catalogue is currently
being ranked against numbers that are known stale. One baseline run makes every
subsequent judgement cheaper and is a few hours.

> **Partly done, 2026-09-22, and the reason it mattered is worse than "stale
> numbers".** The harness was not measuring the viewpoint its own documentation
> described: the player-position override was applied on a single frame and
> ordinary player update walked him off it over the remaining settle window, so
> every run since the rig was built had measured wherever he drifted to. The pin
> is now held every settle frame and verified after it, the fixture was placed by
> hand rather than picked by entrance index, and re-measuring the one result that
> existed moved it 17.75% → 19.88%. Ratios survived; the viewpoint they described
> did not. Report 9 §9.9.
>
> The rig also now pins the CPU to 1.25 GHz for the duration of a run, which
> improves its resolution from 1.02% to **0.57%** at the new fixture — validated
> with a same-arm null A/B. That is a clock-step fix, not a thermal one: drift is
> still present and is still what ABBA cancels. Report 9 §9.5.
>
> Still outstanding: the report 7 absolutes have not been re-taken.

### The catalogue

| # | Item | Verdict | Reasoning |
| --- | --- | --- | --- |
| 2 | Kill dependent texture reads via `GL_CLAMP_TO_EDGE` | ~~**Top candidate. Do this next**~~ → **Closed, 2026-09-22. Already implemented** | Prototyped, as this row asked. Instrumented at the fixture: of 480,000 tile setups, 268,500 (55.9%) already take `GL_CLAMP_TO_EDGE` and only 11,400 (2.4%) carry a fragment-side clamp. `interpreter.cpp` has made that choice since before the port. Forcing the remainder off measured −3.6%, but both surviving cases are inexpressible in GLES2 — `MIRROR\|CLAMP` has no sampler state, and a clamp rectangle narrower than the texture clamps where the edge is not — so the 3.6% is the price of correct N64 semantics, not headroom. Report 8 §8.15 |
| — | **Ship `TextureFilter=1` as a Pyra default** | **Done, 2026-09-22.** Still the largest single lever found | Re-measured at the replacement fixture: **19.88%**, `t = −54.3` over five ABBA pairs, 27.10 → 33.85 FPS — three-point sits *below* the 30 FPS target and bilinear above it. Verified visually first: RMSE 1.5% against three-point and no difference at 3× zoom, with three-point-vs-nearest at 2.7% as the control proving the comparison could see a difference. Shipped in `Fast3dWindow.cpp` as the default when the key is absent. The "device profile, not upstream's default" caveat was overtaken by the fork going Pyra-only the same day. Report 8 §§8.13–8.14 |
| 5 | Conditional `mod()` in 1-cycle variants | **Take it** | Small, but the rig now resolves 0.57% with the CPU pinned, so a 1–2% gain is demonstrable rather than invisible. Nearly free |
| 6 | `int` → `vec2` size uniforms | **Take it** | Same. The fragment ALU is float; an `int` converted per fragment is pure waste. No behaviour change |
| 8 | Program binary cache | **Take it, for feel** | 317 variants game-wide — the whole set can be cached or pre-warmed. Removes first-encounter hitching. Does not move steady-state FPS, and a handheld is judged on hitching |
| 9 | NEON the three scalar audio routines | **Take it, for thermals** | ~6% of a core on core 1, off the critical path. Will not move frame rate. Will lower the die temperature, and on a machine that walks 1.5 → 0.75 GHz under load that is sustained clock for the render thread. The ranking argument in §8.11 undersells this: it treats "does not move FPS" as the end of the question, and on a fanless part it is not |
| 3 | Native texture formats instead of RGBA8888 | **Prototype one format, then decide** | Its case is footprint and bandwidth, and both bandwidth arguments tested here came back null. But neither test varied the working set, so the residency effect is genuinely unmeasured. Lossless and mechanical, which makes a single-format prototype cheap |
| 1 | Filtering into the shader variant key | ~~**Low priority, but still correct**~~ → **Closed on this fork, 2026-09-22** | `o_three_point_filtering` is a compile-time substitution, not a uniform: with the `FILTER_LINEAR` default now shipped, the branch is absent from the generated shader entirely and `hookTexture2D` is a bare `texture2D`. The refactor's goal is already obtained. Remaining scope is users who re-enable three-point in the menu. Report 8 §8.16 |
| 4 | `GL_EXT_discard_framebuffer` | **Closed. Done, no gain** | −0.64%, not significant, calls confirmed executing. Keep the code; it is correct and helps other TBDR parts |
| 7 | VBO ring buffer with `glBufferSubData` | **Refuted — do not build this.** Acted on 2026-09-22 | See below. Report 8 §8.6 now carries the refutation, and `gfx_opengl.cpp` carries the comment report 5 asked for and never got |

### Item 7 is refuted by report 5

Worth stating separately because it is the one place the two reports contradict
each other and the index's "which numbers are still good" table does not catch
it.

Report 8 §8.6 proposes: *"A ring buffer with `glBufferSubData` into a
pre-allocated VBO would avoid the per-draw reallocation."*

Report 5 §5.3 already measured exactly that:

| Strategy | µs/draw |
| --- | --- |
| `glBufferData` per draw — what the code does today | 68 |
| single `glBufferData` per frame + offsets | 60 |
| client-side vertex arrays | 58 |
| **`glBufferSubData` into a ring buffer** | **221** |

and concluded: *"The actionable finding is negative: do not 'optimise' this into
`glBufferSubData` — it is ~4x worse on this driver."*

Item 7 is listed as "unsized, needs a draw-call count". It does not need a
draw-call count. It needs deleting, and the existing `glBufferData` orphaning
needs a comment saying why it is there, so the next person does not reach for
the same idea.

(The one variant report 5 does *not* refute is a single `glBufferData` per frame
with offsets, at 60 µs against 68 — but that is 12% of a path measured at ~14 µs
of driver cost in a frame-bound workload, and it is inside the noise of what it
would take to build. Not worth it either.)

> **Superseded 2026-09-24 (Shipwright report 8 §8.24) — Measured.** The ordering
> above was right; the conclusion was not. In the game, client-side vertex arrays
> in place of per-draw `glBufferData` cut the frame by **13.4% at the Market
> (27.5 → 23.8 ms) and 7.3% at Hyrule Field**, identical picture, t = −51 and
> −24. The driver goes to the kernel for fresh device memory every few uploads
> (~28 → ~15 bridge ioctls per frame at Hyrule Field); the microbenchmark, with
> nothing else in flight, did not show that. The same section measured
> state-setting GL calls at ~0.1 µs each: removing 43% of all GL calls saved
> 0.5%. **On this driver the cost is per draw and per upload, not per call.**

### Two more, not in the catalogue

**Audit for mid-frame pipeline flushes.** The report found `GetPixelDepth`
forcing a TBDR flush and then found it had no callers — which is the only reason
it was not the most expensive thing in the frame. That audit should be a
standing check, not a one-off: any `glReadPixels`, `glCopyTexImage2D`, or
render-to-texture-then-render-to-it-again introduced later will not show up as a
symbol, it will show up as the whole frame being slow.

~~**Check whether the IMG compiler actually flattens branches.** Item 1's entire
magnitude rests on an assumption nobody has tested. It is one A/B of a
branch-free variant against a branching one, and it would firm up or retire the
item for an afternoon's work.~~

> **Moot for item 1, 2026-09-22, and it did not take an afternoon.** On the
> shipped default there is no branch to flatten — see item 1 above. On the
> three-point path the existing filtering A/B cannot isolate flattening, because
> both `filter3point` and the branch are present in one arm and absent in the
> other; separating them needs a third arm that would only describe a
> configuration this fork does not ship. The general rule — prefer variants over
> uniform branches — still applies to items 5 and 6, which remain unmeasured.

---

## 5. The generic lessons

These transfer to any target and are the most reusable part of the project.

**Measure the workload, not a microbenchmark.** A synthetic fill test measured
862 Mpix/s and sent a whole phase in the wrong direction. A synthetic number is
an upper bound on a best case.

**Design the pair of measurements, not the single one.** The filtering result is
only interpretable because a second comparison — bilinear against nearest — was
taken alongside it. Alone, the first supports the wrong model.

**Report a detection threshold with every null result.** "No difference
observed" is not a finding. "No effect, and the rig could have found one as
small as 0.26%" is.

**Validate the rig against itself before trusting it.** Same arm against same
arm; true effect zero by construction. Anything it reports is its own noise.

**Hold the workload constant.** If a faster arm travels further through the
scene, the two arms are not measuring the same work, and no amount of repetition
averages that away.

**Counterbalance what you cannot eliminate.** Thermal drift could not be removed
on this machine. ABBA pairing cancelled it.

**Keep corrections visible.** Every report in both projects carries the places
where it was wrong. That is what stopped a superseded number being acted on
three separate times, and it is why the index in
`docs/pyra/README.md` in the Ship of Harkinian port (Shipwright-pyra) exists at all.

**Check that the metric is the goal.** Frame rate was optimised for two reports
while game speed silently ran 8% slow. The owner of the device found it by
looking at the screen.

**Look at the screen.** Two of the most valuable findings on this project — the
slow motion, and the insulating adhesive on the heatsink — came from somebody
looking rather than measuring.
