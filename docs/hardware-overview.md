# The Pyra as a target: what this hardware is, and how it differs

> **Type: reference.** How things are and why; not a procedure.

Entry point for the optimisation playbook. Read this before any of the other
documents in the set; each of them assumes the model of the machine built here.

Everything marked **Measured** came off this unit and has a dated entry in
`improvements.md`, `verification-log.md`, or in the Ship of Harkinian port
reports under `docs/pyra/` in the Ship of Harkinian port (Shipwright-pyra). Everything marked **Spec** comes
from a datasheet, a technical reference manual or the kernel source and has not
been confirmed here. Everything else is reasoning and is labelled as such.

---

## 1. The one-paragraph version

The Pyra is a 2012-era mobile SoC in a fanless handheld. Two out-of-order ARM
Cortex-A15 cores at 1.5 GHz, a PowerVR SGX544MP2 tile-based deferred GPU at
425 MHz, 4 GB of DDR3L behind two memory controllers that every block on the
chip shares, and a 720x1280 panel driven in DSI **video mode**, which means the
display controller reads the whole framebuffer out of DDR sixty times a second
whether or not anything changed. The CPU cores are far better than their age
suggests and are not usually the problem. The GPU is a generation behind what
"OpenGL ES 2.0" implies elsewhere, and is where almost every port's time goes.
The thermal envelope, not the clock ceiling, decides what the machine sustains.

---

## 2. Quick reference

| | | Source |
| --- | --- | --- |
| SoC | TI OMAP5432 ES2.0 GP, "STANDARD performance (1.5 GHz)" | Measured |
| CPU | 2x Cortex-A15 r2p2, ARMv7-A, 250–1500 MHz | Measured |
| CPU features | `neon vfpv3 vfpv4 idiva idivt vfpd32 lpae thumbee` | Measured |
| L1 cache | 32 KB I + 32 KB D per core, 64-byte lines | Spec (A15 TRM) |
| L2 cache | 2 MB, shared by both cores, on-die | Spec (OMAP5432) |
| L2 TLB | 512 entries, unified — **2 MB of reach with 4 KB pages** | Spec (A15 TRM) |
| GPU | PowerVR SGX544MP2, 2 cores, 425 MHz (NOM rail) | Tool-reported (`omapconf`); consistent with 862 Mpix/s measured fill. `clk_summary`'s 33.77 MHz for the GPU mux is wrong — see improvements.md §5 |
| GPU API | OpenGL ES 2.0 only, GLSL ES 1.00. **No GLES 3 path exists** | Measured |
| RAM | 4 GB, 2x EMIF, 531 MHz, **no swap configured** | Measured |
| Memory peak, theoretical | ~8.5 GB/s (2 x 32-bit x ~1064 MT/s) | Reasoning |
| Memory, single-core `memcpy` | **2130 MB/s** — i.e. ~4.3 GB/s of traffic | Measured |
| L3 / DMM / EMIF interconnect | 265 MHz — already the top CORE operating point | Measured |
| Panel | BOE btl507212-w677l, 720x1280, 60 Hz, MIPI DSI 4-lane, **video mode burst** | Kernel source |
| Desktop orientation | 1280x720, rotated 270° **in hardware** by the TILER | Measured |
| Display scanout cost | 221 MB/s of DDR reads, continuous, unavoidable | Reasoning |
| 2D engine | Vivante GC320 ("bb2d"): fills and blits; the X driver also uses it for Xv's YUV conversion and scaling (rendering-guidelines.md §1.7) | Measured (fills, blits); driver source (Xv) |
| Audio codec | TWL6040, accepts **only S32_LE at 88200 or 96000 Hz** | Measured |
| Audio DSP | OMAP5 AESS — live silicon, driven only by this repo's patches | Measured |
| Thermal trips | passive 100 °C on `cpu_thermal`, critical 125 °C | Kernel source |
| Cooling | fanless, and the SoC heatsink ships with insulating adhesive on it | Community report |
| Idle states | exactly one, `C1` (WFI, MPUSS ON). `C2` retention hangs the machine | Measured |
| Userspace | Debian 13 trixie, armhf, **32-bit**, hard float | Measured |
| Kernel | 5.6.19, out-of-tree Pyra/Letux tree, `PREEMPT`, `HZ=100`, `ARM_LPAE=y` | Measured |

---

## 3. Block diagram, in words

```
   +-----------------+   +-----------------+
   | Cortex-A15 #0   |   | Cortex-A15 #1   |    1.5 GHz, out-of-order,
   | 32K I + 32K D   |   | 32K I + 32K D   |    NEON + VFPv4, hw divide
   +--------+--------+---+--------+--------+
            |     2 MB shared L2           |
            +--------------+---------------+
                           |
        =============== L3 interconnect @ 265 MHz ===============
          |            |            |            |           |
      +---+---+   +----+----+  +----+----+  +----+---+  +----+----+
      | SGX544 |  |  DSS /  |  |  GC320  |  |  AESS  |  | 2x M4   |
      |  MP2   |  | DISPC   |  |   2D    |  |  audio |  |  IPU    |
      | 425MHz |  | + TILER |  |         |  |  DSP   |  | (idle)  |
      +---+----+  +----+----+  +----+----+  +---+----+  +----+----+
          |            |            |           |            |
        ================ 2x EMIF, 531 MHz, DDR3L ================
                           |
                        4 GB, shared by everything above
```

The important structural fact is the bottom row. There is no VRAM. There is no
separate display buffer. The SGX, the display controller, the 2D engine, the
audio DSP and both CPU cores all pull from the same 4 GB through the same L3 at
265 MHz. Every one of them steals bandwidth from the others.

---

## 4. Seven ways this differs from anything modern

These are the ones that actually change how you write code. Each is expanded in
the document named at the end of the line.

### 4.1 There is no GLES 3, and there never will be

`GL_VERSION` is `OpenGL ES 2.0 build 1.14@3699939`, shading language `GLSL ES
1.00`. Not "GLES 3 is slow here" — the entry points do not exist. No uniform
buffer objects (except `GL_IMG_uniform_buffer_object`), no instancing, no
transform feedback, no `textureSize()`, no integer attributes, no `in`/`out`
qualifiers, no MRT beyond `GL_EXT_draw_buffers`, no `gl_FragDepth` (the
extension that would provide it, `GL_EXT_frag_depth`, is **absent**).

Mesa's PowerVR driver begins at Rogue. SGX544 is not supported by it and will
not be. The proprietary DDK blob is the only driver that exists. → `known-limitations.md`

### 4.2 Eight varying vectors

`MAX_VARYING_VECTORS = 8`. Modern hardware reports 15 to 32 and nobody checks.
Renderers written against desktop GL routinely want more — the Fast3D shader
generator in libultraship wants about 11 worst case — and the failure mode is a
**link error at runtime**, on a specific shader variant, on a specific texture
combiner, potentially hours into play. This single number has blocked more of
the Ship of Harkinian port than anything else. → `gpu-optimization.md`

### 4.3 Draw calls cost ~14 µs

Measured on device: 14.2 µs per draw with a realistic set of state changes
(bind texture, two attribute pointers, a uniform). That is roughly 70,000 draws
per second, total, for the whole machine. A modern desktop driver is one to two
orders of magnitude cheaper per call.

At 30 fps that is a budget of about 2,300 draws per frame before the driver
alone eats the frame. That is enough for most ports — but it means the usual
desktop habit of "just issue it, the driver will sort it out" has a hard floor
here, and it means anything issuing tens of thousands of draws needs
restructuring before anything else is worth measuring. → `gpu-optimization.md`

### 4.4 Fragment shader instructions are expensive; texture filtering is free

This is the least intuitive one and it is backed by the cleanest measurement in
the set.

Switching Ship of Harkinian from bilinear to nearest-neighbour filtering — four
texels per fetch down to one — changed frame time by **0.1%, statistically
zero**. Switching from the game's software three-point filter to bilinear saved
**17.75% of frame time**. Both changes alter how many texels are read. Only one
of them altered how many *instructions* the fragment shader issues.

The SGX texture unit filters in fixed-function hardware, so the extra taps never
become shader work. What costs is the `texture2D` instruction itself and the ALU
around it. The rule that follows: **count fetch instructions and ALU ops in your
fragment shader, not texels.** → `gpu-optimization.md`, `rendering-guidelines.md`

### 4.5 Bandwidth arguments have failed twice, in a row, on a bandwidth-starved part

The tempting model of this machine is "shared memory, therefore bandwidth-bound,
therefore reduce traffic". It has been tested twice and both times it bought
nothing:

- `GL_EXT_discard_framebuffer`, which removes about 140 MB/s of pointless
  depth/stencil writeback per frame, was implemented and measured across five
  interleaved A/B pairs. Result: **−0.64%, not significant.**
- The synthetic fill-rate benchmark that reported 15x headroom and concluded
  "the bottleneck must be CPU-side" was **wrong in its ordering**; the real
  workload turned out to be strongly fragment-bound.

Bandwidth is genuinely scarce here, and the arithmetic in `memory-optimization.md`
is sound. It is simply not the binding constraint for a GLES2 game workload —
fragment shader issue is. Reduce traffic because it helps thermals and helps the
CPU, not because you expect frames to get faster. → `memory-optimization.md`

### 4.6 The thermostat, not the clock, sets the frame rate

Cold, the SoC runs at 1.5 GHz. Under sustained load it walks down through 1.4,
1.25, 1.125, 1.0, 0.875 and 0.75 GHz. Within one 50-second run, Ship of
Harkinian fell from 20.1 to 13.8 fps as the die went 56 °C to 68 °C — a **30%
swing with no code change at all.**

Two cores flat out, with nothing capping, reached **107 °C**, seven degrees past
the passive trip, in under two minutes. That is the real limit of this hardware
and it is a property of a fanless case, not of any kernel.

Consequences: any A/B taken without a warm-up measures the thermostat. Any
percentage-of-CPU reading taken under `ondemand` measures the governor, because
the denominator moves. Any optimisation that reduces total work — even work off
the critical path — buys back thermal headroom, which is worth something real on
a machine that throttles. → `profiling-guide.md`, `cpu-optimization.md`

### 4.7 The display controller reads the whole screen, sixty times a second, forever

The panel is driven in DSI **video mode** (`OMAP_DSS_DSI_VIDEO_MODE`,
`OMAP_DSS_DSI_BURST_MODE` in `panel-boe-w677l.c`), not command mode. There is no
panel-side framebuffer and no partial update. DISPC scans 720x1280x4 bytes out
of DDR at 60 Hz — **221 MB/s, continuously, whether the screen is changing or
not**, and it is on the same EMIFs as everything else.

You cannot remove this cost. You can avoid *adding* to it: every extra
full-screen pass, every framebuffer copy, every CPU readback is stacked on top
of a channel that already has a permanent tenant. → `memory-optimization.md`

---

## 5. What this hardware is actually good at

The playbook would be misleading if it were only a list of walls. Several things
are genuinely strong here, and ports routinely leave them on the table.

**The CPU cores are good.** Cortex-A15 is a 3-wide out-of-order superscalar
design with a decent branch predictor and hardware integer divide. It is not an
in-order A7/A8 and should not be optimised like one. The Ship of Harkinian port
found the CPU side to be "essentially a non-event" and a `perf` profile of the
running game shows **no dominant hotspot** — the largest single bucket is 13%.
That is the profile of a machine that is not CPU-bound.

**NEON is present, fast, and frequently unused.** Debian armhf's baseline is
`-march=armv7-a+fp`, which does **not** define `__ARM_NEON`. Any code guarded on
that macro silently compiles out to scalar. This is the single most valuable
compiler flag on the platform and it is free. → `compiler-flags.md`

**Fill rate is not scarce.** 862 Mpix/s peak measured at 720p. Rendering at
native 1280x720 with 8x overdraw is 221 Mpix/s — comfortably inside budget. When
resolution hurts here, it hurts through fragment *shader* cost, not through
raw fill.

**Texture filtering is free**, as above. Use bilinear. Use mipmaps.

**2D fills and blits are accelerated** by the GC320 at 1750–2400 MB/s, and X's
EXA hooks for them are enabled. Rotation is done by the TILER in the display
controller at no CPU cost. The CPU-side 2D paths people assume they need to
avoid are largely already avoided.

**There is a real audio DSP.** The AESS can take 44.1 and 48 kHz streams
natively and feed the codec, removing the resample that otherwise costs 15–18%
of a core. It is live silicon; this repository's patches are what drive it.

**4 GB is a lot for this class of machine.** Memory *capacity* is not a
constraint. Memory *bandwidth* and *TLB reach* are. Trading space for traffic is
usually the right trade here, which is the opposite of the instinct a 2012
handheld invites.

---

## 6. The two mistakes that have cost this project the most

Both are measurement mistakes rather than engineering ones, and both are general.

**Synthetic benchmarks answer a different question than they appear to.** A
single textured blended quad measured 862 Mpix/s and was read as "the GPU has
15x headroom, so the bottleneck is the CPU". The real workload — overdraw, small
triangles, texture binds, state churn, per-fragment branches — behaves nothing
like that on a tile-based deferred renderer. The synthetic number was an upper
bound on a best case, and it was read as a prediction. It sent a whole phase of
work in the wrong direction.

**Optimising the metric instead of the goal.** Ship of Harkinian couples game
speed to frame rate (`game speed = render FPS / InterpolationFPS`). A
configuration chosen by maximising frame rate ran the game permanently 8% slow.
Nobody noticed for two reports, because frame rate was measured throughout and
game speed never was. The owner of the device noticed it by looking at the
screen.

Both generalise: **screen with a fixture, confirm in the real workload, and
check that the thing you optimised is the thing you wanted.**

---

## 7. Where to go next

| If you are... | Read |
| --- | --- |
| Deciding whether a port is feasible at all | `porting-checklist.md`, then `known-limitations.md` |
| Writing or adapting a renderer | `rendering-guidelines.md`, then `gpu-optimization.md` |
| Chasing CPU time | `cpu-optimization.md` |
| Chasing memory, cache or bandwidth | `memory-optimization.md` |
| Setting up a build | `compiler-flags.md` |
| Trying to find out where the time goes | `profiling-guide.md` |
| Considering a kernel change | `kernel-notes.md` |
| Looking for what is already known not to work | `known-limitations.md` |
| Looking for what is already measured on this unit | `improvements.md` |
