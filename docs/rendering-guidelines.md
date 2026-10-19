# Rendering guidelines, and adapting a desktop renderer

`gpu-optimization.md` is the hardware model. This document is the practical
consequence: how to take a renderer written for desktop OpenGL and make it work
here, and how the display pipeline underneath it behaves.

---

## 1. The display pipeline

Know this before deciding what resolution to render at.

| | |
| --- | --- |
| Panel | BOE btl507212-w677l, **720x1280** native portrait, 60 Hz |
| Link | MIPI DSI, 4 lanes, RGB888, **video mode, burst** |
| Desktop | **1280x720**, rotated 270° |
| Rotation | Done by the **TILER in the display controller**. No CPU pass, no GPU pass |
| Scaling | DISPC has hardware scalers |
| Composition | X11, DRI3 + Present, `omap5` DDX. Desktop compositing is **off** |
| 2D acceleration | Vivante GC320, fills and blits |
| Swap | ~~`Option "SwapbuffersWait" "true"` — swaps tied to vblank~~ Decided by the window system library `libpvrDRI3WSEGL.so` and X's Present, not by any X config option. See §1.2 |

### 1.1 Rotation is free; do not re-implement it

This is the largest item that early planning got wrong on this project. The
panel is physically portrait and the desktop is landscape, which invites the
assumption that something is rotating a 3.5 MB framebuffer on the CPU sixty
times a second — 211 MB/s per copy, and a very attractive thing to go and fix.

It is not happening. The X device section carries `Option "TilerRotation" "270"`,
the driver confirms it, and the kernel boots with `drm.force_hw_rotation` and
`drm_kms_helper.fbdev_rotation=8`:

    (II) OMAP5(0): Buffer Flipping is Enabled
    (II) OMAP5(0): TILER rotation set to 270 degrees

> **Corrected 2026-10-18, from the driver source.** The first log line is about
> DRI2, not about games. "Buffer Flipping is Enabled" reports the DDX's `NoFlip`
> option, which only the DRI2 swap path reads (`armsoc_dri2.c:122`). GLES clients
> here present through DRI3 and Present, and that path cannot flip at all (§1.5).
> The rotation statement is unaffected: rotation really is free.

**Render landscape at 1280x720 and let the hardware handle orientation.** Do not
add a rotation pass, do not render portrait and rotate, do not ask for a
portrait mode.

### 1.2 Vsync quantises, and it will eat your frame rate

`SwapbuffersWait` is on, which is correct — it is what prevents tearing — but it
means presentation is quantised to 60/N: **60, 30, 20, 15 fps and nothing
between.**

A renderer at 35 ms/frame (28.7 fps) just misses the two-interval slot at
33.3 ms and falls into the three-interval slot at 50 ms. Measured directly on
this device: a configuration running at 28.7 fps with vsync off reported
**exactly 20.00 fps / 50.00 ms with vsync on.**

So on this machine vsync is not a small tax. It is a cliff, and 29 fps becomes
20 fps.

Guidance:

- If you can hold under 16.6 ms, leave vsync on. You get 60 and no tearing.
- If you can hold under 33.3 ms **reliably**, leave vsync on. You get a rock
  solid 30.
- If you are between 33.3 and 50 ms, **turn vsync off** and accept tearing, or
  lower the resolution until you fit in the 33.3 ms slot. The second is usually
  the better answer on a handheld.

This also means a benchmark that "mysteriously refuses to exceed 60" is not
mysterious, and any A/B must be taken with vsync off or the limiter hides the
change.

> **Corrected 2026-10-18, from source. The mechanism this section names does not
> exist.** `SwapbuffersWait` is not an option of `omap5_drv.so`: the string occurs
> nowhere in the 0.6 driver source, so X ignores the line. (X should list it
> among unused options in `Xorg.0.log`. That was not checked on the device.)
>
> For GLES clients, vsync is decided by `libpvrDRI3WSEGL.so`. Its source is
> `dri3wsegl-pyra` 0.4, archived in
> `pyra-packages-archive/packages.pyra-handheld.com/trixie/`, and that package's
> binary has the stock sha256 `d852ce4d…`. What it does, read from the source
> and **not measured**:
>
> - Each swap asks Present for `target_msc = last_msc + swap_interval` with
>   divisor 1 (`dri3_ws.c:806`). `last_msc` is the vblank count of the last
>   *completed* present, and it is only updated when the library polls events at
>   swap time.
> - A frame that arrives within the same refresh as the previous one waits for
>   the next vblank. A frame that took longer than one refresh already has a
>   target in the past, so X copies it at once, not aligned to vblank. Slow
>   frames can therefore tear.
> - A real wait for the previous frame's scanout exists (`dri3_ws.c:787`), but
>   only when the environment variable `DRI3_VSYNC` is set non-zero. Nothing on
>   this image sets it.
>
> So the window system, as configured here, does not quantise to 60/N. The
> measurement above (28.7 fps unsynced, exactly 20.00 fps "vsync on") still
> stands as a measurement, but its cause is not identified. One candidate is the
> application's own pacing: `profiling-guide.md` §1.3 already calls exactly
> 50.00 ms the signature of an internal 20 fps limiter. Another is the swap
> interval change, which makes the library rebuild its buffers. The guidance to
> take every A/B with vsync off stays correct either way. The three bullets on
> when to turn vsync off are unverified until the toggle is re-measured with
> `DRI3_VSYNC` unset and set.

### 1.3 Render low, upscale in hardware

The strongest single lever on this device, by a wide margin.

Measured, Ship of Harkinian at thermal equilibrium, vsync off, cap raised:

| Internal resolution | Median FPS |
| --- | --- |
| 1.0x — 1280x720 | **16.4** |
| 0.5x — 640x360 | **26.7 – 28.7** |
| 0.25x — 320x180 | **37.5** |

Halving the internal resolution is worth **+75%**. Halving it again is worth a
further **+31%**.

Note this is *not* a fill-rate result. Raw fill rate measured 862 Mpix/s and
720p at 8x overdraw is only 221 Mpix/s — well inside budget. The resolution
sensitivity is fragment *shader* cost: fewer fragments means fewer shader
invocations, and shader invocations are what this GPU is short of.

**Render to an offscreen target at a fraction of native and draw it as one
fullscreen quad.** That final upscale costs one cheap pass. Expose the fraction
as a user setting; 0.5x is the right default for anything 3D on this machine.

### 1.4 Turn the desktop compositor off

Measured at **3.5% of all busy CPU, for one command**, with no measurable effect
on the X server's own cost:

```sh
gsettings set org.mate.Marco.general compositing-manager false
```

It is off on this image. Worth knowing because it is the largest confirmed win
in the whole project that costs nothing, and because a launcher or kiosk shell
built for this device should never enable compositing.

### 1.5 Fullscreen frames are copied, not flipped

Measured 2026-09-27: a fullscreen client's frames reach the scanout by **copy**.
Ship of Harkinian (vsynced, 30 fps) and `glmark2-es2 --fullscreen` both run
with zero `DRM_IOCTL_MODE_PAGE_FLIP`. Instead, Xorg submits GC320 (etnaviv) work
every frame to copy the back buffer into the TILER front buffer: 3.7 MB each
way per frame at 1280x720.

For a game, that means:

- **Do not add a second full-screen pass of your own** on top of it. Every
  fullscreen frame already pays one copy after the swap.
- **Rendering smaller does not shrink the copy.** It is the window's size. A
  fullscreen window at 1280x720 is copied at 1280x720 whatever the internal
  resolution.
- The cause and the options for removing it (a DDX flip, KMS-direct games,
  prerotation and where it would cost) are in `improvements.md` §6.

> **Cause identified 2026-10-18, from source.** The DDX builds its Present
> support with `//#define ARMSOC_PRESENT_FLIP 1` commented out
> (`armsoc_present.c:49`), so Present has no flip hooks and copies every frame by
> design. The stock binary agrees: it lacks the flip function's error string. If
> the flip were compiled in, rotation would still stop it, because the
> client's buffers are plain dumb buffers, not TILER buffers.
>
> **The copy is probably not in your frame time.** X submits the GC320 copy
> without waiting for it, and the window system keeps three buffers, so the
> client never waits for a copy to finish. The copy costs memory bandwidth and
> power. That is read from the source and not measured. What the swap *does*
> wait for is §1.6.

### 1.6 `eglSwapBuffers` waits for the GPU to finish the frame

Read from the window system's source on 2026-10-18; not yet measured directly.

Under X, every swap blocks the calling thread until the SGX has finished
rendering that frame. `WSEGL_SwapDrawable` calls `WaitForOpsComplete` on the
back buffer before it presents (`dri3_ws.c:792` in `dri3wsegl-pyra` 0.4). The
library does this because Present has no fence that could make X wait for the
SGX. The DDK itself does not wait: under the GBM window system, the swap took
~0.1 ms while the wait moved to buffer lock (`experiments/kms-plane/`, 0.75 to
12.5 ms by load).

It then makes a blocking round trip to X: `xcb_present_pixmap_checked` followed
by `xcb_request_check` (`dri3_ws.c:828`).

What follows for a renderer:

- **CPU and GPU do not overlap across frames.** Frame time is roughly CPU time
  plus the GPU's tail after the last submit, not the larger of the two. Work
  you move from CPU to GPU, or the reverse, does not hide behind the other side.
- **Swap time is a GPU measurement.** A long `eglSwapBuffers` here means the
  GPU's share of the frame, plus one X round trip. It does not mean a vsync wait
  or the X copy (§1.5).
- **Only the thread that swaps is blocked.** Game logic on another thread still
  overlaps with the GPU. The next frame's GL submission does not.

The fix is in the open-source library, not in your renderer: `improvements.md`
§6, "What the source says".

---

## 2. The desktop renderer adaptation guide

A worked translation. The left column is a typical PC renderer; the right is
what it has to become.

| PC renderer | Pyra renderer | Why |
| --- | --- | --- |
| Deferred lighting / G-buffer | **Forward, single pass** | MRT beyond `GL_EXT_draw_buffers` is unavailable, and a G-buffer is several full-resolution render targets on a part with no spare bandwidth and a tile pipeline that wants one pass |
| 4K textures | 512–1024, PVRTC or narrowed formats | `MAX_TEXTURE_SIZE` is 4096, so they *fit* — but residency and load time do not |
| SSAO | **Cut it** | A depth readback plus a wide blur is the worst possible shape for a TBDR: a mid-frame flush and heavy fragment ALU |
| Bloom / HDR | **Cut, or one cheap blur at quarter res** | No float framebuffers in practice; each post pass is a render target switch plus a full-screen fragment pass |
| Shadow maps | Baked lightmaps, or one low-res map | A shadow pass is a second full scene traversal with a render target switch |
| Multiple framebuffer passes | **One pass, then one upscale quad** | Every switch ends a tile pass |
| `glBlitFramebuffer` | Textured quad | The extension does not exist here |
| `gl_FragDepth` | Drop it, accept sort error | `GL_EXT_frag_depth` is absent |
| Instancing | Manual batching | No instancing in GLES2 |
| Uniform buffer objects | Individual uniforms | Core UBOs are GLES3. `GL_IMG_uniform_buffer_object` exists but is vendor-specific |
| `textureSize()` | Pass dimensions as a `vec2` uniform | GLES3 builtin |
| Compute shaders | CPU with NEON, or cut | Do not exist |
| Front-to-back opaque sorting | **Delete it** | TBDR resolves visibility before shading; the sort buys nothing |
| Back-to-front transparent sorting | **Keep it, and minimise the layers** | Blended fragments cannot be hidden-surface-removed |
| Ring-buffered `glBufferSubData` | ~~Plain `glBufferData` orphaning~~ **Client-side vertex arrays** | Ring buffer measured 4x worse; client arrays measured −13% of a real frame against orphaning (Shipwright §8.24) |
| Uniform-branch "uber-shaders" | Shader variants + program binary cache | USSE flow control is weak; branches may flatten |
| Shader-side filtering, clamping, coordinate maths | Sampler state, or vertex shader | Dependent reads stall the prefetcher; fragment instructions are the scarce resource |
| Render at native | Render at 0.5x, upscale | +75% |
| Rotation in software | TILER, already done | Free |

### 2.1 A worked example

```
PC renderer:
  - deferred lighting, 3 G-buffer targets at 1920x1080
  - 4K albedo/normal/roughness
  - SSAO pass, 2x blur
  - bloom: bright pass, 4 downsamples, 4 upsamples
  - FXAA
  - tone map
  → 11 full-screen passes, ~24 MB of render targets

Pyra renderer:
  - forward lighting, single pass, into one 640x360 RGBA8 target
  - lighting baked into vertex colour or a lightmap; at most 2 dynamic lights
  - 512-1024 textures, PVRTC where the asset pipeline allows
  - no SSAO; bake ambient occlusion into the lightmap
  - no bloom, or one 160x90 blur composited in the upscale shader
  - no FXAA; the upscale is doing bilinear filtering anyway
  - tone mapping folded into the final upscale shader
  → 2 passes, ~1.9 MB of render targets
```

The important structural move is the last line of each block. Eleven passes
become two. On a TBDR, pass count is the thing to minimise, because each one is
a flush, a resolve and a writeback of the whole screen.

---

## 3. Shader authoring rules for this part

In priority order, and all of them follow from §4 of `gpu-optimization.md`:
**fragment shader instruction issue is the scarce resource.**

1. **Count `texture2D` calls.** Each one costs roughly 3% of frame time in the
   one workload measured here. Do not emulate a filter, do not sample the same
   texture twice, do not sample "just to check".
2. **Feed samplers directly from varyings.** No arithmetic on a texture
   coordinate inside the fragment shader. Move it to the vertex shader, or
   express it as sampler state.
3. **Use hardware sampler state instead of shader logic.** `GL_CLAMP_TO_EDGE`,
   `GL_REPEAT`, `GL_LINEAR`, mipmaps — all fixed function, all free.
4. **No dynamic branches in fragment shaders.** Compile a variant instead. Cache
   the variants with `GL_OES_get_program_binary`.
5. **Do ALU in the vertex shader where the result is linear.** You have 16
   attributes and 128 vertex uniform vectors. Vertex load is light here.
6. **Budget eight varyings from the start**, and pack scalars into spare
   components.
7. **Keep precision honest.** `GL_OES_fragment_precision_high` is present, so
   `highp` works in fragment shaders — but `mediump` is cheaper and is correct
   for colours and most texture coordinates. Do not blanket-`highp` a shader.
8. **No `discard` on large surfaces.** It defeats deferred visibility.
9. **Pass `vec2`, not `int`, for anything you will use as a float.** The
   fragment ALU is float; an `int` uniform converted per fragment is pure waste.
10. **Delete dead maths.** A `mod()` whose result a following `clamp()` makes a
    no-op still executes. Guard it out of the variants that do not need it.

---

## 4. Resolution, frame rate and what you are actually optimising

A warning that generalises well beyond this device, because it cost this project
two reports.

Ship of Harkinian couples game logic to rendering: one logic tick emits
`InterpolationFPS / 20` rendered sub-frames, with no catch-up. So

    game speed = render FPS / InterpolationFPS

A configuration chosen by maximising frame rate — cap 30, sustained 27.7 fps —
ran the game at **0.92x, permanently 8% slow**, including audio pitch. One
benchmark configuration with the cap raised to 60 ran it at **0.48x**.

Nobody caught it for two reports. Frame rate was measured throughout; game speed
never was. The device's owner noticed by looking at the screen.

The general rule: **a frame-rate cap is only a speed reference when the hardware
can actually reach it.** Setting it above sustained frame rate does not buy
smoothness, it buys slow motion. And more broadly — check that the number you
are optimising is the number you want.

---

## 5. Choosing defaults for this device

Ship the device-specific choices as a **profile applied when the key is absent
from the user's config**, not as a change to a shared default. That keeps
upstream's default intact for every other platform, leaves the setting
adjustable in the menu, and means a user who changes it keeps their change.

The pattern used here:

- Write each value only if the config key does not exist.
- Save immediately, so the values land on disk on first run rather than at a
  clean shutdown — they are then visible in the menu and survive a crash.
- Compile the block in only under the device preset.

And **say so in the UI** where a setting is unusually expensive on this hardware.
Three-point filtering costs 17.75% of frame time here and its menu description
gives no hint that it is the most expensive option on the page.

---

## 6. The audio side of the frame budget

Not a rendering matter, but it lands in the same budget and is the second
largest consumer on the machine.

The TWL6040 codec accepts **only `S32_LE` at 88200 or 96000 Hz**. There is no
44100 and no `S16_LE`. Every ordinary stream is therefore upsampled and widened
before it can play, and it is a cliff rather than a curve:

| Stream rate | PulseAudio cost |
| --- | --- |
| 22050 | 10.3% of a core |
| 44100 | 11.1% |
| 48000 | 10% |
| **88200 — matches the sink** | **3.5%** |

During a real game, the audio stack measured **18.4% of all busy CPU**; removing
audio entirely returned about 18 points and was worth +4.1% mean frame rate and
+11% on the steady tail. That is the ceiling on any audio-side work.

Three practical notes:

- **Matching the ratio does not help; only matching the rate does.** Moving a
  title from 32000 to 44100 Hz — a cleaner 2:1-ish ratio — measured **22.9%
  *more* PulseAudio CPU**, twice, because cost tracks output samples and input
  volume, not ratio cleanliness.
- **If your app synthesises audio at whatever rate it is asked for, ask for
  88200** and take the 10% → 2% cliff. If it has a fixed native rate, do not —
  you are only relocating the resample into your own process, where it is
  probably more expensive.
- **The real fix is the AESS**, the OMAP5's audio DSP, which accepts 44.1 and
  48 kHz natively. It is live silicon driven by this repository's patches; see
  `docs/audio.md`.

For measurement: `SDL_AUDIODRIVER=dummy` is the honest way to measure "without
audio". `pasuspender` and `SDL_AUDIODRIVER=alsa` both produce a convincing and
entirely false speedup on this machine — details in `docs/audio.md`.
