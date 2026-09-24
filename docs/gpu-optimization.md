# GPU: PowerVR SGX544MP2, and what a TBDR actually rewards

The GPU is the part of this machine most likely to decide whether a port works.
It is a 2012 mobile part with a tile-based deferred architecture, a strict
OpenGL ES 2.0 feature set, and a proprietary driver that is the only driver that
will ever exist for it.

This document is the hardware model. `rendering-guidelines.md` is the practical
"how do I adapt a desktop renderer" companion; read this first.

---

## 1. What it is

| | |
| --- | --- |
| Part | PowerVR SGX544MP2 — Series5XT, **2 shader cores** |
| Clock | 425 MHz, the **NOM** operating point of the VDD_MM rail |
| Architecture | Tile-Based Deferred Rendering (TBDR) |
| Shader core | USSE2, unified vertex/fragment, scalar-ish, weak flow control |
| API | OpenGL ES 2.0, GLSL ES 1.00, EGL 1.4. **OpenCL not exposed here** |
| Driver | `omap5-sgx-ddk-um-linux` 1.14.3699939-15, kernel module `pvrsrvkm_omap5_sgx544_116` |
| `GL_RENDERER` | `PowerVR SGX 544MP` |
| Window system | X11, DRI3 + Present, via `libpvrDRI3WSEGL.so` |

The rail is worth noting. `omapconf show opp` reports the graphics rail at
**NOM, not the top operating point**. There is a higher one on this part, worth
roughly a quarter of the GPU's throughput. Whether it can be reached safely is
unresolved and is **research, not a change** — raising a clock without
confirming the matching PMIC voltage is how silicon gets damaged, and voltage
readback on this unit is currently unavailable. See `improvements.md` item 5.

---

## 2. Measured limits — the numbers that block ports

All captured live on the device against a real GLES2 context.

| Limit | Value | Why it matters |
| --- | --- | --- |
| `MAX_VARYING_VECTORS` | **8** | The blocker. Modern parts report 15–32 |
| `MAX_VERTEX_ATTRIBS` | 16 | Exactly the worst case Fast3D needs |
| `MAX_FRAGMENT_UNIFORM_VECTORS` | 64 | Comfortable |
| `MAX_VERTEX_UNIFORM_VECTORS` | 128 | Comfortable |
| `MAX_TEXTURE_IMAGE_UNITS` | 8 | Comfortable |
| `MAX_VERTEX_TEXTURE_IMAGE_UNITS` | 8 | Vertex texture fetch is available |
| `MAX_TEXTURE_SIZE` | 4096 | Comfortable |
| `MAX_RENDERBUFFER_SIZE` | 4096 | Comfortable |
| `IMPLEMENTATION_COLOR_READ_FORMAT` | **`GL_BGRA_EXT`** | Not `RGBA`. Breaks naive readback |
| `IMPLEMENTATION_COLOR_READ_TYPE` | `GL_UNSIGNED_BYTE` | `UNSIGNED_SHORT_5_5_5_1` readback is invalid |

### 2.1 Eight varying vectors is the one that stops people

GLSL ES 1.00 mandates varying packing, so eight vectors is thirty-two floats
usable — but a renderer that wants eleven vectors' worth of interpolants does
not fit, packing or not.

The failure mode is what makes this dangerous: **a link error at runtime, on one
shader variant**. A renderer that compiles variants lazily by material or
combiner will link hundreds of shaders fine and then fail on the one that needs
a ninth varying, potentially hours into use. `glslangValidator` will not catch
it, because it does not enforce a device's varying budget.

If you are porting a renderer that generates shaders, **enumerate your variant
space and count varyings statically before writing any code.** In Ship of
Harkinian this was done by scanning the colour-combiner space with a helper
script; 317 unique variants exist game-wide, which is small enough to check
exhaustively.

Ways to get under eight, in rough order of preference:

1. Pack scalars into unused components of vectors you already have. Four clamp
   floats are one vector, not four.
2. Move a varying to a uniform if it is constant per draw. Many "per-vertex"
   values in a ported renderer are actually per-draw.
3. Recompute in the fragment shader from something already interpolated — but
   see §4, because this is exactly how dependent texture reads get created.
4. Split the draw into two passes. Last resort on a part where extra passes cost
   real bandwidth.

### 2.2 Extensions

Present and confirmed on the device:

```
GL_OES_rgb8_rgba8 GL_OES_depth24 GL_OES_vertex_half_float GL_OES_texture_float
GL_OES_texture_half_float GL_OES_element_index_uint GL_OES_mapbuffer
GL_OES_fragment_precision_high GL_OES_compressed_ETC1_RGB8_texture GL_OES_EGL_image
GL_OES_EGL_image_external GL_OES_required_internalformat GL_OES_depth_texture
GL_OES_get_program_binary GL_OES_packed_depth_stencil GL_OES_standard_derivatives
GL_OES_vertex_array_object GL_OES_egl_sync GL_OES_texture_npot GL_OES_surfaceless_context
GL_EXT_discard_framebuffer GL_EXT_blend_minmax GL_EXT_multi_draw_arrays
GL_EXT_multisampled_render_to_texture GL_EXT_shader_texture_lod
GL_EXT_texture_format_BGRA8888 GL_EXT_occlusion_query_boolean GL_EXT_texture_rg
GL_EXT_draw_buffers GL_EXT_shader_framebuffer_fetch GL_IMG_shader_binary
GL_IMG_texture_compression_pvrtc GL_IMG_texture_compression_pvrtc2 GL_IMG_texture_npot
GL_IMG_texture_format_BGRA8888 GL_IMG_read_format GL_IMG_program_binary
GL_IMG_uniform_buffer_object GL_IMG_multisampled_render_to_texture GL_KHR_debug
```

**Notably absent**, and each of these has bitten something:

- `GL_EXT_frag_depth` — **no `gl_FragDepthEXT`.** Any renderer with a
  depth-write path needs a third route: drop the depth write and accept the
  sorting inaccuracy. In Ship of Harkinian this is the N64 prim-depth mode.
- `GL_NV_framebuffer_blit` / `GL_ANGLE_framebuffer_blit` — no
  `glBlitFramebuffer`. Framebuffer-to-framebuffer moves must be a textured quad.
- `GL_OES_texture_3D` — no 3D textures.
- Anything GLES3.

**Present and worth exploiting:**

- `GL_OES_texture_npot` **and** `GL_IMG_texture_npot` — non-power-of-two
  textures work with full wrap modes. This removes a whole class of padding work
  that GLES2 ports normally carry.
- `GL_OES_packed_depth_stencil`, `GL_OES_depth24`, `GL_OES_rgb8_rgba8`,
  `GL_OES_required_internalformat` — sized internal formats behave. PR-style
  workarounds like `#define GL_RGBA8 GL_RGBA` are unnecessary here.
- `GL_OES_get_program_binary` / `GL_IMG_program_binary` — **take these.** The
  SGX GLSL compiler is slow and lazy shader compilation produces visible
  hitching on first encounter. A persistent on-disk cache of compiled programs
  removes it. This does not improve steady-state throughput; it improves feel,
  and feel is what a handheld is judged on.
- `GL_EXT_shader_framebuffer_fetch` — read the current framebuffer colour in the
  fragment shader with no copy. On a TBDR this is nearly free because the tile
  is already on-chip. It is the correct way to implement blend modes the fixed
  function pipeline cannot express. Unexplored here, and the most interesting
  unexplored thing on this list.
- `GL_EXT_multisampled_render_to_texture` — the TBDR-friendly MSAA path, where
  resolve happens on-chip at tile writeback rather than as a separate pass.

---

## 3. What TBDR means for you

This is the architectural difference that invalidates desktop instincts.

An immediate-mode GPU rasterises each triangle as it arrives, writing colour and
depth to memory. A tile-based deferred renderer does not. It:

1. Collects **all** geometry for the frame into a parameter buffer in memory.
2. Splits the screen into small tiles.
3. For each tile, resolves visibility for every triangle touching it **before
   running any fragment shader**.
4. Shades only the visible fragments, in fast on-chip tile memory.
5. Writes the finished tile out to memory once.

Five consequences, in order of how much they matter here.

### 3.1 Opaque overdraw is nearly free; blended overdraw is not

Hidden surface removal happens before shading, so drawing an opaque wall and
then an opaque object in front of it costs one shaded fragment, not two — no
matter what order you submit them in. Front-to-back sorting, the standard
desktop optimisation, buys you **nothing** here.

Blended geometry defeats this entirely. Alpha-blended fragments cannot be
discarded by depth, so every layer shades. Measured on this device: full-screen
textured blended quads at 1280x720 ran 353 fps at overdraw 1 and 117 fps at
overdraw 8 — a near-linear cost in layers.

**So: sort your transparents, minimise blended layers, and do not bother sorting
your opaques.**

### 3.2 `discard` and alpha-test are expensive

A fragment shader containing `discard` (or writing depth, if it could) cannot
have its visibility resolved ahead of time, because the hardware does not know
whether it will survive. The deferred stage has to fall back for that geometry.

Use `discard` sparingly and keep it out of shaders used for large areas. Where
foliage or fences need it, they are exactly the case that hurts most, because
they are also high-overdraw.

### 3.3 Anything that forces a mid-frame flush is catastrophic

The tile pipeline wants to accumulate the whole frame. Anything that requires
the current render target's contents to be correct in memory *right now* forces
a flush of the entire accumulated scene:

- `glReadPixels` against the framebuffer you are drawing to
- `glCopyTexImage2D` / `glCopyTexSubImage2D` from it
- Binding a texture you rendered to earlier in the same frame, then rendering to
  it again
- `glGetError` in a tight loop, in some drivers
- Any synchronous query of results produced this frame

On a desktop GPU these are slow. On a TBDR they can cost more than everything
else in the frame combined. The Ship of Harkinian audit found a `GetPixelDepth`
path that does exactly this — and then found it had **no callers**, which is the
only reason it was not the most expensive thing in the frame.

Audit your renderer for these before you profile. They will not show up as a
symbol; they show up as the whole frame being slow.

### 3.4 Clear, don't preserve

At the start of a render pass, `glClear` on all attachments you are going to
write tells the driver it does not need to load the previous tile contents from
memory. Preserving contents costs a full-resolution read.

At the end, `GL_EXT_discard_framebuffer` on attachments nothing will read tells
it not to write them back.

**Measured here: the discard half bought nothing.** Five interleaved A/B pairs,
60 s each at equilibrium, frame cap raised: −0.64%, `t(4) = −0.99`, not
significant, against a design that could have resolved ±1.8%. The calls were
confirmed to execute and return `GL_NO_ERROR`, so this is a real null result and
not a silent no-op.

Why: the workload is fragment-shader bound, not bandwidth starved, and the
driver very likely already elides the writeback — the depth attachment is a
renderbuffer that is never sampled, and EGL's default `EGL_SWAP_BEHAVIOR` is
`EGL_BUFFER_DESTROYED`.

Do it anyway — it is two calls, it is correct, and it helps on other TBDR parts.
Do not expect a number.

### 3.5 Render target switches are not free

Each one ends a tile pass: flush, resolve, write out. A desktop renderer that
ping-pongs between targets for post-processing pays a full-screen write and read
per switch. Batch all drawing to one target before moving to the next.

---

## 4. The thing that costs, measured

This is the most important measurement in the set, because it overturns the
obvious model.

**Experiment**: Ship of Harkinian, deterministic fixture, static scene,
640x360 internal, five ABBA pairs of 600 frames, at thermal equilibrium. Rig
resolves 0.40%.

| Comparison | Frame time | Result |
| --- | --- | --- |
| Three-point filtering → bilinear | 34098 µs → 28047 µs | **−17.75%**, t = −154.8 |
| Bilinear → nearest | 28064 µs → 28037 µs | **−0.1%, not significant**, t = −1.04 |

Read those two rows together.

Bilinear reads **four texels** per fetch. Nearest reads **one**. That difference
is unmeasurable. The SGX texture unit filters in fixed-function hardware, so the
extra taps never become shader work.

Three-point filtering is the N64's filter, and Fast3D emulates it *in the
fragment shader*: three `texture2D` instructions plus `fract`/`step`/`sign`/`abs`
per texture unit — six fetch instructions in 2-cycle mode where bilinear issues
two. That costs 17.75%.

> **The rule: on this GPU, count fragment-shader instructions — especially
> `texture2D` calls — not texels and not bytes.**

Corollaries that follow directly:

- **Use bilinear.** It is free relative to nearest, and looks better.
- **Use mipmaps.** Trilinear costs one extra fixed-function tap, not a shader
  instruction, and it improves texture cache behaviour.
- **Never emulate a filter in a shader** if a hardware sampler state can express
  it.
- **Every `texture2D` you remove from a fragment shader is worth roughly 3% of
  frame time** in this workload. Every ALU op around it counts too.

### 4.1 Dependent texture reads

PowerVR SGX can prefetch texel data only when the texture coordinate arrives
**directly from a varying with no fragment-side arithmetic**. Any computation on
the coordinate before the fetch makes it a *dependent read*, which stalls the
prefetch pipeline.

This is the best-documented performance characteristic of the architecture, and
desktop-derived renderers violate it constantly:

```glsl
// dependent — coordinate computed in the fragment shader
vec2 uvAdj = clamp(vTexCoord, 0.5 / texSize, vec2(vClampS, vClampT));
vec4 c = texture2D(tex, uvAdj);

// not dependent — coordinate straight off the varying
vec4 c = texture2D(tex, vTexCoord);
```

Fixes, in order:

1. **Do the arithmetic in the vertex shader** and interpolate the result. This
   is the answer most of the time, and it costs a varying — which is why §2.1
   and this section are in tension and have to be solved together.
2. **Use a hardware sampler state instead.** The commonest case is a shader-side
   clamp that exists because the source API clamps at an arbitrary value rather
   than at the texture edge. When the clamp value *coincides* with the edge —
   usually the common case — `GL_CLAMP_TO_EDGE` is exactly equivalent and the
   coordinate passes through untouched. Detect that case at texture-setup time
   and emit a variant with no fragment-side maths.
3. **Specialise the shader.** If only some draws need the arithmetic, do not
   make every draw carry it.

**Status on this project:** this is the top open candidate. Its premise —
fragment fetch cost is a real constraint — was confirmed by the filtering
measurement above. Its magnitude has not been measured. It should be prototyped
crudely on one shader variant before the general case is written.

### 4.2 Flow control in fragment shaders

The USSE has weak flow control. A dynamic branch on a uniform may be *flattened*
by the compiler — both sides executed, the result selected — in which case every
fragment pays for both paths.

That makes a very common pattern actively harmful:

```glsl
if (filter_mode[id] == THREE_POINT) {   // branch on a uniform int array
    return filter3point(tex, uv, texSize);
}
return texture2D(tex, uv);
```

If this flattens, every textured fragment issues all four fetches, including the
ones that only wanted one.

**Prefer shader variants over uniform branches.** Bake the decision into the
variant key at compile time so the generated shader contains exactly one path
and no test. This costs variant count — which is cheap, given
`GL_OES_get_program_binary` for caching — and it is portable good practice for
every GLES target, not just this one.

Whether the IMG compiler actually flattens any given branch is a property of the
driver and must be checked, not assumed. The cheap check is to A/B a
branch-free variant against the branching one.

---

## 5. Draw calls and state

Measured on device with a 1x1 scissor, so fragment cost is ~zero and only
driver/CPU cost is visible. 16 triangles per batch, 300 batches per frame:

| Per-draw state changes | µs/draw | draws/s |
| --- | --- | --- |
| draw only | 11.4 | 88,000 |
| + `glVertexAttribPointer` x2 | 10.8 | 92,000 |
| + `glBindTexture` | 14.5 | 69,000 |
| + `glUniform4f` | 11.9 | 84,000 |
| **all three (realistic)** | **14.2** | **70,000** |

The cost is genuinely per-call and does not degrade with batch count from 300 to
1000 batches per frame.

**Budget:** at 30 fps, 14.2 µs allows about **2,300 draws per frame** before the
driver alone consumes the entire frame. A realistic scene from a
fifth-generation console title is a few hundred. Draw call overhead is real and
is an order of magnitude worse than a modern driver, but it is **not** the
limiting factor for this class of workload.

Texture binds are the most expensive single state change in that table. Group
draws by texture where it is free to do so; do not restructure a renderer for it
without measuring first.

### 5.1 Vertex upload: one thing to avoid

| Strategy | µs/draw |
| --- | --- |
| `glBufferData` per draw (orphaning) | 68 |
| single `glBufferData` per frame + offsets | 60 |
| client-side vertex arrays, no VBO | 58 |
| **`glBufferSubData` into a ring buffer** | **221 — avoid** |

(Taken without the scissor, so these include fragment cost; only the ordering is
meaningful.)

The standard modern advice is a persistently-mapped ring buffer with
`glBufferSubData`. On this driver that is **about four times worse** than naive
per-draw orphaning. Buffer orphaning with `GL_STREAM_DRAW` is within noise of
the best option and needs no change. ~~needs no change~~ — **superseded, see
below.**

**Measured in a real renderer (Shipwright report 8 §8.24, 2026-09-24):** switching
Fast3D from per-draw `glBufferData` to client-side arrays (no buffer bound,
attributes pointed at a CPU array that never moves) cut the frame **−13.4% at a
261-draw scene and −7.3% at a 167-draw one**, mostly render-thread CPU (−3.4 ms /
−1.6 ms). Bridge ioctls per frame roughly halved. The microbenchmark's 68 → 58
µs/draw understated it by several times. Client-side arrays are the upload
strategy to use on this DDK; the ring-buffer warning stands.
Real play confirmed it (§8.25): −13.6% of render-thread CPU over 25 paired blocks,
t = −4.7, with no visible glitches. Guard the change with `#ifdef` for GLES2 if the
renderer is shared: a desktop GL core profile rejects client arrays
(`GL_INVALID_OPERATION`).

This is worth a comment in any renderer targeting this device, because it is
exactly the "optimisation" a competent graphics programmer will reach for.

---

## 6. Textures

### 6.1 Formats

| Format | Support | Note |
| --- | --- | --- |
| RGBA8888 / RGB888 | yes | The default everything uses |
| `GL_RGBA` + `UNSIGNED_SHORT_5_5_5_1` | yes | Half the footprint, lossless for 16-bit sources |
| `GL_RGBA` + `UNSIGNED_SHORT_4_4_4_4` | yes | |
| `GL_RGB` + `UNSIGNED_SHORT_5_6_5` | yes | |
| `GL_LUMINANCE_ALPHA` | yes, core | Half the footprint for intensity/alpha sources |
| `GL_EXT_texture_rg` | yes | `GL_RED_EXT`, `GL_RG_EXT` |
| **ETC1** | yes, `GL_OES_compressed_ETC1_RGB8_texture` | **RGB only, no alpha** |
| **PVRTC / PVRTC2** | yes, `GL_IMG_texture_compression_pvrtc*` | 2 and 4 bpp, this is the native format |
| ETC2 / EAC | **no** | GLES3 core; not available |
| ASTC | **no** | |
| S3TC / DXT | **no** | |
| BGRA8888 | yes | `GL_EXT_texture_format_BGRA8888` — matches the readback format |
| Float / half-float textures | yes | `GL_OES_texture_float`, `_half_float` |
| Depth textures | yes | `GL_OES_depth_texture`, `GL_OES_depth24` |
| NPOT | yes, fully | `GL_OES_texture_npot` + `GL_IMG_texture_npot` |

**If you are shipping compressed assets, PVRTC is the native choice** — it is
what the hardware was designed around, and it supports alpha, which ETC1 does
not. It requires power-of-two, square textures. ETC1 is the portable fallback
and needs a separate alpha channel.

**A caution.** Compressing textures on this part reduces footprint and sampling
bandwidth. Both of those have now failed to produce a measurable frame-rate win
twice (§3.4, and `memory-optimization.md` §4). Compress for memory residency and
load time, and treat any frame-rate gain as a bonus you have to demonstrate.

### 6.2 Narrowing formats: what it is and is not worth

A renderer that expands every source texture to 32 bpp — which is the normal
thing for a desktop-derived codebase to do — can often narrow losslessly:

| Source format | Exact GLES2 equivalent | Saving |
| --- | --- | --- |
| 16-bit RGBA5551 | `GL_RGBA` + `UNSIGNED_SHORT_5_5_5_1` | 2x |
| 4/8-bit intensity | `GL_LUMINANCE_ALPHA` | 2x |
| 4/8/16-bit intensity+alpha | `GL_LUMINANCE_ALPHA` | 2x |
| Palettised with a 16-bit palette | `GL_RGBA` + `UNSIGNED_SHORT_5_5_5_1` | 2x |

One trap: if the source semantics are "alpha equals intensity", `GL_LUMINANCE`
is **wrong** — it forces alpha to 1.0. `GL_LUMINANCE_ALPHA` reproduces it
exactly.

Status: **open, confidence lowered.** The argument for this is footprint and
bandwidth, and the two bandwidth arguments tested so far both came back null.
The counter-argument is that neither test varied the working set — both arms
used identical textures — so the residency effect is genuinely unmeasured.
Prototype one format and measure before converting everything.

### 6.3 The readback format is BGRA

`IMPLEMENTATION_COLOR_READ_FORMAT` is `GL_BGRA_EXT`, not `GL_RGBA`. Code that
assumes RGBA readback will get channel-swapped results or an `INVALID_OPERATION`
depending on how it asks. And `IMPLEMENTATION_COLOR_READ_TYPE` is
`GL_UNSIGNED_BYTE`, so a 5551 readback is simply invalid here.

(That said — see §3.3. The best readback is the one you do not do.)

---

## 7. Getting a GLES2 context at all

This is a deployment problem that will silently waste every performance number
you collect if you get it wrong. Full detail in `docs/qt-gles.md`; the short
version:

The DDK ships `libEGL.so.1` and `libGLESv2.so.**1**`. The Debian archive ships
libglvnd's `libGLESv2.so.**2**`. Nothing on the machine bridges the two SONAMEs,
and the only glvnd EGL vendor registered is Mesa's.

| What you do | What happens |
| --- | --- |
| Nothing | `GLX is not supported` — loud, obvious failure |
| `SDL_VIDEO_X11_FORCE_EGL=1` alone | Context created, **`glGetString` returns NULL** — silent |
| `+ SDL_VIDEO_GL_DRIVER=<DDK>/libGLESv2.so.1` | `PowerVR SGX 544MP` ✅ |
| Link against glvnd's `libGLESv2.so` | Compiles, links, **shader compilation fails with an empty info log** |

For an SDL2 program, exactly two environment variables are needed:

```sh
export SDL_VIDEO_X11_FORCE_EGL=1
export SDL_VIDEO_GL_DRIVER=/opt/omap5-sgx-ddk-um-linux/lib/libGLESv2.so.1
```

The system `libEGL.so.1` routes to the DDK on its own; only the GLES *client*
library must be forced.

For a program that links GLES directly, the link target and whatever SDL
`dlopen`s **must be the same library**. Point the build at the DDK.

**Always print `GL_RENDERER` at startup and check it is non-NULL and contains
"PowerVR".** The silent-NULL failure mode above looks exactly like success until
the first draw.

---

## 8. Known-bad and known-good, at a glance

**Cheap here:**

- Opaque geometry, in any order
- Bilinear and trilinear filtering
- Non-power-of-two textures
- Vertex shader work (the USSE is unified and vertex load is usually light)
- Clearing every attachment at the start of a pass
- Fill rate: 862 Mpix/s peak measured; 720p at 8x overdraw is 221 Mpix/s

**Expensive here:**

- Every `texture2D` instruction in a fragment shader (~3% of frame time each, in
  the one workload measured)
- Fragment ALU generally
- Dependent texture reads
- Dynamic branches in fragment shaders
- Blended overdraw
- `discard`
- Render target switches
- Draw calls, at ~14 µs each

**Catastrophic here:**

- `glReadPixels` from the target you are drawing to
- Rendering to a texture, sampling it, and rendering to it again in one frame
- Any synchronous readback of this frame's results
- `glBufferSubData` ring buffers (4x worse than the naive path)

**Does not exist here:**

- GLES 3 anything
- `gl_FragDepth`
- `glBlitFramebuffer`
- 3D textures
- ETC2, ASTC, S3TC
