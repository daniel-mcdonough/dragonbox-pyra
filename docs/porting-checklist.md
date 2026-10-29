# Porting checklist

> **Type: instructions.** Steps to follow.

A practical sequence for bringing a game or graphical application to the Pyra.
Written to be worked through in order; each phase has a decision at the end of
it that is cheaper to take then than later.

Background for every item is in `hardware-overview.md` and the documents it
points at.

---

## Phase 0 — Before you write any code

The point of this phase is to find the blockers while it is still cheap to
decide not to proceed. Every one of these has stopped or redirected a port on
this project.

### 0.1 Does the renderer fit in GLES 2.0?

- [ ] **Does it require OpenGL 3.x or GLES 3.x core features?** Instancing,
      transform feedback, UBOs, MRT, integer attributes, `textureSize()`,
      `in`/`out` qualifiers, compute. There is no GLES3 path here and there
      never will be.
- [ ] **Count your varyings.** `MAX_VARYING_VECTORS = 8`. If the renderer
      generates shaders, enumerate the variant space and count statically. This
      is the single most common blocker and it fails at **runtime**, on one
      variant, potentially hours in.
- [ ] **Do you write `gl_FragDepth`?** `GL_EXT_frag_depth` is **absent**. Plan
      the fallback now.
- [ ] **Do you call `glBlitFramebuffer`?** Not available. It becomes a textured
      quad.
- [ ] **Do you `glReadPixels` from the target you are drawing to?** On a TBDR
      this forces a full pipeline flush and can cost more than the rest of the
      frame. Find every caller.
- [ ] **How many render targets and passes per frame?** Each switch ends a tile
      pass. Deferred rendering, SSAO, multi-tap bloom and shadow maps all need
      redesigning, not tuning. See `rendering-guidelines.md` §2.
- [ ] **What is your peak draw call count per frame?** Budget ~14.2 µs per draw,
      about 2,300 per frame at 30 fps.

### 0.2 Does the CPU side fit?

- [ ] **x86 SIMD?** `_mm_*`, `xmmintrin.h`, `immintrin.h`. Check they are gated
      on an x86 predicate and that a scalar or NEON fallback exists.
- [ ] **Inline assembly or `.S` files?** Check for x86 or AArch64 assumptions.
- [ ] **Hand-written NEON?** Check for `*_high_*` intrinsics, which are
      **A64-only** and will not compile on armhf. See `compiler-flags.md` §6.
- [ ] **64-bit pointer assumptions?** This is a **32-bit** userspace. Pointers
      are 4 bytes; `size_t` is 4 bytes; anything stuffing a pointer into a
      `uint64_t` or vice versa needs checking. Address space is ~3 GB per
      process, not 4 GB.
- [ ] **Endianness** — should go through compiler builtins, not casts.
- [ ] **How many worker threads does it want?** There are **two cores**, and one
      is shared with the X server and the audio daemon. Anything sizing a pool
      from `nproc` will size it to 2.
- [ ] **Does it need more than ~3 GB in one process?** 32-bit address space.

### 0.3 Build and deployment

- [ ] **Does the build system support cross-compilation to armhf?**
- [ ] **Are all dependencies available for armhf in trixie?** If not, what is
      the plan — vendor, build, or replace?
- [ ] **Is it a statically linked x86 binary you were hoping to run under
      box86?** That does not work; box86 needs dynamic linking.

**Decision point.** If the varying budget does not fit and cannot be made to
fit, and the renderer cannot be simplified, stop here. That is a rewrite, not a
port.

---

## Phase 1 — Get it running at all

Correctness before performance. Every number collected before this phase is
complete is meaningless.

- [ ] Cross-build for armhf. See `compiler-flags.md` §4.
- [ ] **Link against the DDK's GLES, not glvnd's.** `readelf -d` should show
      `libGLESv2.so.1`, not `.so.2`. Linking glvnd compiles, links, and then
      fails at runtime with shader errors and an empty info log.
- [ ] **Set the two SDL environment variables** if you use SDL2:

      export SDL_VIDEO_X11_FORCE_EGL=1
      export SDL_VIDEO_GL_DRIVER=/opt/omap5-sgx-ddk-um-linux/lib/libGLESv2.so.1

- [ ] **Print `GL_RENDERER` at startup and assert on it.** Check it is non-NULL
      *and* contains `PowerVR`. The failure mode where a context is created and
      every entry point resolves to NULL looks exactly like success.
- [ ] Get a frame on screen. Any frame.
- [ ] Walk the whole content set looking for shader link failures — this is when
      the varying budget bites.
- [ ] Check the audio path opens. The codec accepts **only 88200 or 96000 Hz,
      `S32_LE`**; anything else is resampled for you at a cost.
- [ ] Write a launcher script that sets the environment, `cd`s to the game
      directory, and knows how to stop the process. See `device/pyra-soh` as a
      worked example — including the detail that the game ignores `SIGTERM`, so
      an ordinary `timeout` leaves it running.

---

## Phase 2 — Make it measurable

Do this **before** optimising. This project optimised before it had a rig and
had to redo the work.

- [ ] Build a **deterministic fixture** — fixed scene, fixed camera, fixed frame
      count, no simulation advance.
- [ ] Put both A/B arms **in one process** behind a switch.
- [ ] Add frame-time logging with a stable format.
- [ ] Add a way to raise or disable the internal frame cap.
- [ ] Add a way to disable vsync.
- [ ] **Validate the rig A-vs-A** and record its minimum detectable effect.
- [ ] Log die temperature and CPU frequency alongside frame times.

Target: a rig that resolves single-digit percentages. The one built for this
project resolves 0.40%. Full method in `profiling-guide.md` §5.

---

## Phase 3 — Take the settings, they are the largest lever

Almost everything here is a configuration value, and between them they are worth
more than every code change measured on this project combined.

- [ ] **Internal resolution to 0.5x**, rendered offscreen and upscaled. Measured
      **+75%**. This is the single strongest lever on the device.
- [ ] **Vsync off**, unless you can hold under 33.3 ms reliably — otherwise
      29 fps quantises down to 20.
- [ ] **Frame cap set to what the hardware sustains**, not to an aspiration. If
      game speed is coupled to frame rate, a cap above sustained frame rate buys
      slow motion, not smoothness.
- [ ] **MSAA off.**
- [ ] **Bilinear filtering.** Free relative to nearest; any shader-emulated
      filter is not. Measured at **17.75% of frame time** for one such filter.
- [ ] **Mipmaps on.** Fixed-function, improves texture cache behaviour.
- [ ] **Shadows, ambient occlusion and post-processing off** by default.
- [ ] Ship all of the above as a **device profile applied only when the key is
      absent from the user's config**, not as a change to shared defaults.
- [ ] Note in the UI where a setting is unusually expensive on this hardware.

**Measure after this phase.** It is common for it to be enough.

---

## Phase 4 — Environment, outside your program

Cheap, and it is competing for the same two cores.

- [ ] **Desktop compositing off** — measured at 3.5% of all busy CPU.
- [ ] **Governor `sampling_down_factor` to 10** — 23% of burst latency.
      `device/pyra-governor-tune.sh` does it; a sysfs write does not survive a
      reboot.
- [ ] **Check the thermal daemon is actually capping.** On a stock trixie image
      it is not, and the machine will walk past its passive trip.
- [ ] **Audio:** find out what rate your app asks for with
      `pactl list sink-inputs`. If it synthesises at an arbitrary rate, ask for
      88200 and take the 10% → 2% cliff. If it has a fixed native rate, leave it
      alone — relocating the resample into your process is worse.
- [ ] Screen blanking disabled, if the session will be left running. Every DPMS
      transition is a modeset and the modeset path can wedge the display.

---

## Phase 5 — Code-level optimisation

Only now, and only against a measurement. Ordered by what the evidence on this
device supports.

**Fragment shader work — this is where the time is.**

- [ ] Count `texture2D` instructions per fragment shader and remove every one
      you can. Each is worth roughly 3% of frame time in the one workload
      measured.
- [ ] **Eliminate dependent texture reads.** Feed samplers directly from
      varyings; move coordinate arithmetic to the vertex shader or express it as
      sampler state.
- [ ] **Replace uniform branches with shader variants**, and cache the variants
      with `GL_OES_get_program_binary`.
- [ ] Remove dead fragment ALU — a `mod()` that a following `clamp()` makes a
      no-op still executes.
- [ ] Pass `vec2`, not `int`, for anything used as a float.
- [ ] Reduce blended overdraw. Do **not** front-to-back sort opaques; the TBDR
      does that for you.

**CPU side.**

- [ ] Confirm NEON is actually enabled (`__ARM_NEON`), and build for `armv7ve`.
- [ ] Pool per-frame allocations.
- [ ] Look for atomic refcounting on objects shared between threads.
- [ ] NEON the audio synthesis routines — worth heat and battery rather than
      frame rate, which on a thermally throttled handheld is not nothing.

**Cheap and certain.**

- [ ] Program binary cache — removes first-encounter hitching. Feel, not
      throughput.
- [ ] `glClear` every attachment at the start of a pass.
- [ ] `GL_EXT_discard_framebuffer` at the end. Correct, free, and **measured at
      no gain here** — take it as hygiene, not as a win.

**Things to leave alone.**

- [ ] Do **not** convert `glBufferData` orphaning into a `glBufferSubData` ring
      buffer. Measured **4x worse** on this driver. Client-side vertex arrays
      are what beat it: −13% of a real frame (Shipwright report 8 §8.24).
- [ ] Do **not** spend effort trimming redundant GL state calls for speed.
      Removing 43% of a frame's calls saved 0.5%; draws and uploads are the cost.
- [ ] Do **not** rebuild `pixman` or `ffmpeg` with NEON flags. They already
      dispatch NEON at runtime.
- [ ] Do **not** expect memory traffic reduction to move frame rate. Two
      correct bandwidth arguments have produced null results here.

---

## Phase 6 — Confirm

- [ ] Re-measure in **real play**, not in the fixture. A fixture tells you a
      frame got cheaper to draw, not that the game got faster.
- [ ] Check the thing you optimised is the thing you wanted — if game speed is
      coupled to frame rate, verify game speed.
- [ ] Check sustained behaviour over 10+ minutes, not a 60-second window. The
      thermostat has the last word.
- [ ] Check frame *consistency*, not just the mean. On a handheld a stutter is
      worse than a mean throughput gain is good.
- [ ] Look at the screen. Two of the most important findings on this project —
      the game running in slow motion, and the insulating adhesive on the
      heatsink — came from somebody looking rather than measuring.

---

## Quick triage: is this port worth attempting?

| Signal | Verdict |
| --- | --- |
| Needs GLES 3 / GL 3 core features and cannot fall back | **No.** Rewrite, not port |
| Needs more than 8 varyings and cannot be reduced | **No**, without renderer surgery |
| Deferred renderer with no forward path | **Large**, redesign the renderer |
| Forward renderer, GLES2-capable, x86 SIMD gated | **Moderate.** This is the normal case |
| Already ships a GLES2 backend | **Small.** Mostly deployment and defaults |
| 2D / software-rendered | **Small.** Watch allocations and readback |
| x86 binary, dynamically linked, 2D | **box86.** See `docs/box86.md` |
| x86 binary, needs Direct3D | **Blocked today** — Wine's 3D path needs desktop GLX, which fix 4 removes |
| Needs more than ~3 GB in one process | **No.** 32-bit |
