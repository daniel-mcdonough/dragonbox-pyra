# Compiler flags for the Pyra

> **Type: reference.** How things are and why; not a procedure.

Short version, for anyone who wants the answer and not the reasoning:

```
-march=armv7ve+simd -mfpu=neon-vfpv4 -mfloat-abi=hard -mtune=cortex-a15 -mthumb -O2
```

The rest of this document says why each of those is there, which ones are
measured, and which of the tempting additions are worth nothing.

---

## 1. Start from what Debian gives you, because it is not enough

Debian armhf's baseline is:

    -march=armv7-a+fp -mfloat-abi=hard -mthumb

That baseline exists so packages run on every armhf device, including parts
older and weaker than this one. It costs two things on a Cortex-A15, and both
are silent.

### 1.1 It does not enable NEON

`-march=armv7-a+fp` gives you VFP but **not** Advanced SIMD, and therefore does
not define `__ARM_NEON`.

That macro is what nearly all hand-written NEON in the wild is guarded on. Code
guarded on it does not fail to build and does not warn — it compiles out to the
scalar fallback, and you never find out. This is exactly what happened to the
hand-written NEON audio mixer in Ship of Harkinian: it existed in the tree and
had never once been compiled for this platform.

**This is the single most valuable compiler flag on the platform.** Verify it:

```sh
echo | arm-linux-gnueabihf-gcc -dM -E -march=armv7ve+simd -mfloat-abi=hard - | grep __ARM_NEON
# #define __ARM_NEON__ 1
# #define __ARM_NEON 1
```

Set it in **two** places if you support on-device builds as well as cross
builds: the toolchain file, and the project's own `CMakeLists.txt`. Otherwise a
native build on the device quietly loses it again.

Write the project-side guard generically, not gated on a device name —

```cmake
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^armv7")
    add_compile_options(-march=armv7ve+simd -mfpu=neon-vfpv4 -mfloat-abi=hard)
endif()
```

— so it benefits any 32-bit ARM Linux target and is upstreamable as it stands.

### 1.2 It does not use the hardware divider

Cortex-A15 has `udiv` and `sdiv` in hardware (`idiva` and `idivt` are both in
the device's feature list). Baseline ARMv7-A does not assume they exist, so GCC
emits a call to `__aeabi_uidiv` in libgcc for every integer division.

Measured: `perf` on the untuned build showed **1.6% of time in `__aeabi_uidiv`**.
Rebuilding for `armv7ve` put **591 hardware divide instructions** into a binary
that had none.

`-march=armv7ve` is "ARMv7-A with virtualization extensions", which implies the
integer divide instructions. It is the flag that turns that 1.6% into roughly
nothing.

The honest caveat: **the effect was never isolated.** 1–2% was below the noise
floor of the measurement rig at the time (±13%), so this is justified on
mechanism rather than by a measured delta. A rig that resolves 0.40% now exists
(`profiling-guide.md`), so it could be confirmed properly if anyone cares to.

---

## 2. The flags, one at a time

### `-march=armv7ve+simd`

ARMv7-A plus virtualization extensions plus Advanced SIMD. Gets you NEON and
hardware divide in one flag.

**Cost:** the binary will not run on an ARMv7 part without the divide
instructions — older Cortex-A8 and A9 devices, most notably. If you need one
binary for a fleet of armhf handhelds, use `-march=armv7-a+neon-vfpv4` instead
and accept the libgcc division calls.

### `-mfpu=neon-vfpv4`

Redundant with `+simd` on modern GCC, harmless, and worth spelling out because
plenty of build systems still key off `-mfpu`. `neon-vfpv4` is the correct
value: it gives NEON **with** fused multiply-add, which `neon` alone (which
means `neon-vfpv3`) does not.

### `-mfloat-abi=hard`

Non-negotiable. The whole userspace is hard-float; a soft-float object will not
link against it.

### `-mtune=cortex-a15`

Tunes scheduling for this core without restricting the instruction set. Prefer
this over `-mcpu=cortex-a15`, which also sets the architecture and pins the
binary to this part.

Do not expect much from it. The A15 is **out-of-order** — it reorders around the
compiler's scheduling decisions. Instruction scheduling flags matter far more on
an in-order A7 or A8 than they do here.

### `-mthumb`

Debian's default, and keep it. Thumb-2 code is roughly 25–30% smaller than ARM
code at similar performance, and **instruction cache footprint is a real concern
on this part specifically**: 32 KB of L1 I-cache per core, and the Spectre v2
workaround on the A15 invalidates the *entire* I-cache on every `switch_mm`
(see `kernel-notes.md` §5). Smaller code refills faster.

### `-O2`, not `-O3`

`-O3` adds aggressive loop unrolling and vectorisation that inflate code size,
and on a 32 KB I-cache with a permanent invalidation tax that trade is not
obviously good. **No win from `-O3` was measured here.**

This is a judgement, not a measurement — and it is the flag most worth
re-testing now that a 0.40% rig exists. If you do test it, test `-O3` on the
hot translation units only, not the whole tree.

### `-ffast-math`

Reasonable for games; it is what the Switch build of Ship of Harkinian already
uses. It relaxes IEEE semantics, so do not apply it to code that depends on NaN
propagation, signed zero, or reproducible floating point across platforms —
which includes anything doing deterministic simulation or replay.

---

## 3. What is not worth adding

**LTO.** Unmeasured here. Plausible on paper for the same I-cache reason as
`-mthumb`, and it substantially increases build time and memory on a cross
build. If you try it, measure it; do not assume it.

**`-funroll-loops`.** See `-O3`. Code size on a 32 KB I-cache.

**PGO.** Would probably pay on the Fast3D-style interpreter loop that dominates
this class of workload, and nobody has tried it. Recorded as an idea, not a
recommendation.

**A blanket archive rebuild with these flags.** This one is a genuine trap and
it is worth stating plainly, because it is the obvious idea and it is wrong.

The two libraries that would matter most **already dispatch NEON at runtime**.
`libpixman-1.so.0` carries an `arm-neon` path and selects it on this CPU.
ffmpeg does the same. PulseAudio detects NEON and logs `sconv_neon.c`,
`mix_neon.c` and `remap_neon.c` initialising. Rebuilding any of them buys close
to nothing, and the cost is permanent divergence from the Debian archive — a
maintenance burden that outlasts the speedup.

**Rebuild the thing you profiled, not the archive.** What is worth targeting is
code with no runtime dispatch and a hot inner loop: emulator cores,
decompression, specific image and audio codecs, and your own project.

---

## 4. Cross-building

The practical setup used here is a Docker container with
`arm-linux-gnueabihf-gcc` and a CMake toolchain file. Two things that are easy
to get wrong:

**Link against the right GLES library.** `find_library(GLESv2)` finds libglvnd's
`libGLESv2.so`, whose `DT_NEEDED` is `libGLESv2.so.2`. The DDK's SONAME is
`libGLESv2.so.**1**`. A build that links glvnd compiles cleanly, links cleanly,
and then **fails at runtime with shader compilation errors and an empty info
log** — which looks like a shader bug and is a linkage bug. Point the build at
the DDK explicitly. Full detail in `gpu-optimization.md` §7.

**A program that links GLES directly and an SDL that `dlopen`s GLES must resolve
to the same library.** They do not by default on this machine.

---

## 5. Verifying a build actually got what you asked for

Do all four. Each of these has caught a real mistake on this project.

```sh
# 1. NEON really enabled?
echo | arm-linux-gnueabihf-gcc -dM -E $YOUR_FLAGS - | grep __ARM_NEON

# 2. Hardware divide actually emitted?
arm-linux-gnueabihf-objdump -d yourbinary | grep -cE '\b(udiv|sdiv)\b'

# 3. NEON instructions actually present?
arm-linux-gnueabihf-objdump -d yourbinary | grep -cE '\bv(mla|mul|add|ld1|st1)\b'

# 4. Right GLES SONAME?
arm-linux-gnueabihf-readelf -d yourbinary | grep GLESv2
# want: libGLESv2.so.1   not: libGLESv2.so.2
```

And on the device, at startup, print `GL_RENDERER` and check it is non-NULL and
contains `PowerVR`. The silent-NULL context failure mode looks exactly like
success until the first draw.

---

## 6. A trap in hand-written NEON

NEON intrinsics are **not** portable between AArch32 and AArch64, and the usual
`__ARM_NEON` guard does not distinguish them.

The Ship of Harkinian audio mixer was guarded correctly on `__ARM_NEON`, but its
body used `vmull_high_n_s16` and `vmull_high_s16` — **A64-only intrinsics**. On
aarch64 targets `__ARM_NEON` is always defined, so it compiled everywhere it was
tested. On armhf it is a hard compile error:

    error: implicit declaration of function 'vmull_high_n_s16'

So that path had **never** been buildable on 32-bit ARM, and it failed loudly
rather than degrading to the scalar reference.

If you are porting hand-written NEON from a 64-bit target, assume every
`*_high_*` intrinsic needs rewriting. A high-half widening multiply is a
widening multiply of the upper four lanes — `vmull_s16(vget_high_s16(a), ...)`.
