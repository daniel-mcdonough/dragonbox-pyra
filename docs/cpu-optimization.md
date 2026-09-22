# CPU: Cortex-A15, and why it is usually not your problem

Two Cortex-A15 cores at 1.5 GHz. This document covers what the
microarchitecture rewards, where NEON pays and where it does not, and the two
things that actually limit CPU throughput on this machine — neither of which is
instruction count.

Companion documents: `compiler-flags.md` for what to build with,
`profiling-guide.md` for how to find out whether you are CPU-bound at all.

---

## 1. Start here: you are probably not CPU-bound

Before optimising anything on this page, establish that the CPU is the
constraint. The evidence from this project says it usually is not.

- A `perf record` of Ship of Harkinian at equilibrium shows **no dominant
  hotspot**. The largest bucket — `shared_ptr` refcounting, resource-cache
  lookups, `malloc`/`free`, hashing — is about 13%. The Fast3D interpreter is
  11%. The PowerVR driver and kernel are 8.5%. That is a flat profile, and a
  flat profile means there is no CPU change worth 20%.
- Halving the renderer's internal resolution gained **+75%**. Nothing on the CPU
  side of that workload is worth a quarter of that.
- The port audit concluded the ARM/CPU side was "essentially a non-event":
  pointers already went through `uintptr_t`, SSE paths were correctly gated,
  endianness went through builtins, there was no inline assembly.

The exception is emulation. Under box86 the emulated binary is 50–56% of all
busy CPU, and that *is* CPU-bound by construction. Native ARM code is a
different regime.

---

## 2. What the microarchitecture is

From the ARM Cortex-A15 TRM. Not measured here, but load-bearing for the advice
that follows.

| | |
| --- | --- |
| Issue | 3-wide decode, **out-of-order**, superscalar |
| Pipeline | 15 stages integer, up to 24 for some operations |
| L1 instruction | 32 KB, 2-way, 64-byte lines, per core |
| L1 data | 32 KB, 2-way, 64-byte lines, per core |
| L2 | 2 MB, 16-way, **shared between both cores**, on-die |
| L2 TLB | 512 entries, unified |
| Page table walk | 3 levels (`ARM_LPAE=y`) |
| FP/SIMD | VFPv4 + NEON (Advanced SIMD v2), fused multiply-add |
| Integer divide | **present in hardware** (`idiva`, `idivt`) |
| Revision here | r2p2, confirmed on the unit |

Two of these deserve emphasis because they invert advice written for older ARM
parts.

**It is out-of-order.** Manual instruction scheduling, software pipelining by
hand and load-hoisting tricks that pay on a Cortex-A8 do nothing here and often
hurt by increasing register pressure. Write straightforward code and let the
machine reorder it.

**It has hardware divide.** A great deal of ARM-targeted code still avoids
integer division, or carries reciprocal-multiply tricks, because `__aeabi_uidiv`
is a libgcc call on baseline ARMv7. On this part `udiv`/`sdiv` are single
instructions — but **only if the compiler is told the target supports them**.
Debian's armhf baseline does not assume it. `perf` on the un-tuned Ship of
Harkinian build showed 1.6% of time in `__aeabi_uidiv`; rebuilding for `armv7ve`
put 591 hardware divide instructions into a binary that previously had none.
See `compiler-flags.md`.

---

## 3. The two real limits

### 3.1 There are two cores. That is all there is.

Not two big and four little. Not four. Two, and one of them is running the X
server, PulseAudio, and everything else on the machine.

The whole-machine attribution across a heavy workload, both cores:

| process | run 1 | run 2 |
| --- | --- | --- |
| the game | 56.0% | 49.9% |
| `pulseaudio` | below noise | **14.0%** |
| `Xorg` | 13.6% | 12.3% |
| window manager | 3.6% | 3.4% |
| kernel threads and short-lived processes | 21.5% | 10.9% |
| **machine busy, both cores** | **87.9%** | **58.7%** |

An idle desktop is 5.9% busy. The login screen with no session is 7.4%, and a
third of *that* is hard IRQ time for two i2c buses polling the analog nubs at
25 ms intervals — 858 interrupts a second that nothing can turn off without a
kernel patch.

What follows for a port:

- **Thread pools sized from `nproc` will size themselves to 2**, and one of
  those is contending with the compositor and the audio daemon. A design that
  assumes four or eight workers will oversubscribe.
- **Moving work to "another thread" does not make it free.** It makes it
  concurrent with the X server. On a 2-core part, offloading is only a win if
  the work was actually blocking the critical path.
- **Work moved off the critical path still costs thermals.** See §6.

### 3.2 The TLB reaches 2 MB

512 L2 TLB entries times 4 KB pages is **2 MB of address reach** — smaller than
the working set of essentially anything this machine runs. Every miss past it is
a page table walk, and with `ARM_LPAE=y` that walk is three levels deep: up to
three dependent memory accesses, on a part with no bandwidth to spare.

This is the one cost that does not appear in any profile. Time spent stalled in
a page walk is charged to whichever process was unlucky enough to be running; it
never shows up as a symbol.

What helps:

- **Locality of reference at the page level, not just the cache-line level.**
  Structures traversed together should live together. An array of structs beats
  parallel arrays here more often than it does on a machine with a large TLB.
- **Fewer, larger allocations.** Every `malloc` region that lands on a fresh
  page costs a TLB entry that something else wanted.
- **Transparent huge pages would cover 2 MB in one entry** — and this kernel
  does not build them. `CONFIG_TRANSPARENT_HUGEPAGE is not set`, while
  `HAVE_ARCH_TRANSPARENT_HUGEPAGE`, `COMPACTION` and `MIGRATION` are all already
  on. One config symbol. Unmeasured, plausible, and the caveats are in
  `kernel-notes.md` — including that `madvise` mode will probably measure zero
  because nothing on this machine asks.

---

## 4. NEON: when it pays and when it does not

### 4.1 First, check it is even enabled

Debian armhf's baseline is `-march=armv7-a+fp`. That does **not** define
`__ARM_NEON`. Any code guarded on that macro — which is most hand-vectorised
code in the wild — silently compiles out to the scalar fallback, with no
warning.

```sh
echo | arm-linux-gnueabihf-gcc -dM -E -mfpu=neon-vfpv4 - | grep ARM_NEON
```

This was exactly the situation in Ship of Harkinian: a hand-written NEON audio
mixer existed in the tree and had never been compiled on this platform.

### 4.2 It pays on

- **Audio mixing, resampling and envelope application.** The clearest win on
  this machine. Sixteen-bit samples, four or eight lanes at a time, no data
  dependencies between lanes, long loops. The NEON mixer in Ship of Harkinian
  does not appear in the profile at all; the three routines next to it that have
  no NEON path account for ~6% between them.
- **Image conversion and pixel format shuffling.** Especially widening and
  narrowing, where `vmovl`/`vqmovn` do in one instruction what costs a shift, a
  mask and a store scalar.
- **Software blitting and blending** where the GC320 cannot be used.
- **Particle and vertex transform loops** — anything applying the same short
  matrix to a long array.
- **Checksums, hashing and decompression inner loops** that are already
  structured as independent lanes.

### 4.3 It does not pay on

- **Anything already dispatching at runtime.** `libpixman-1` carries an
  `arm-neon` path and selects it on this CPU. So does ffmpeg. Rebuilding either
  with NEON flags gains close to nothing, because they were already using it.
  Check before rebuilding — the usual answer for a well-maintained library is
  that it already does this.
- **Short vectors.** A `vec3` transform is not four lanes of work, it is one
  lane of work with three components. The NEON/ARM register file transfer cost
  (`vmov` between core and SIMD registers) eats short operations.
- **Branchy code.** NEON has no lane-wise branching. Anything that needs
  per-element control flow must be written as select-and-mask, which often
  costs more than the scalar version on an out-of-order core that predicts well.
- **Code that is not the bottleneck.** See §1. A 4x speedup on 6% of the profile
  is 4.5% of the process, and this machine's measurement noise on a real
  workload was ±13% until a purpose-built fixture brought it to 0.4%.

### 4.4 A trap worth naming

NEON intrinsics are not portable between AArch32 and AArch64. The Ship of
Harkinian mixer was guarded on `__ARM_NEON` — correct — but its body used
`vmull_high_n_s16` and `vmull_high_s16`, which are **A64-only**. On aarch64
(Switch, Apple Silicon) `__ARM_NEON` is always defined so it compiled; on armhf
it was a hard compile error, not a graceful fallback.

If you are porting hand-written NEON from a 64-bit target, assume the high-half
intrinsics need rewriting. The AArch32 equivalent of a high-half widening
multiply is a widening multiply of the upper four lanes, obtained with
`vget_high_s16`.

---

## 5. Memory access patterns that matter here

Ordered by how often they have actually mattered on this project.

**Repeated `malloc`/`free` in a frame loop.** Shows up directly in the profile —
it is part of the 13% bucket that is the largest single item in the Ship of
Harkinian trace. Pool or arena anything allocated per frame.

**Pointer-chasing data structures.** `shared_ptr` refcounting and hash-map
lookups are in the same 13% bucket. Every refcount is a read-modify-write on a
shared cache line; with 2 MB of L2 shared between both cores, false sharing
between the render thread and a worker is cheap to create and invisible in a
symbol profile.

**Uncached reads from GPU memory.** The most dramatic single number in the
project. X's `GetImage` from a GPU buffer runs at **62 MB/s**, against 1750 MB/s
for a hardware copy of the same rectangle — 27x slower. That is the signature of
a CPU reading uncached write-combine memory one cache line at a time with no
prefetch. Anything that pulls pixels back from the GPU pays this. Do not do it
per frame. → `memory-optimization.md`

**The X server's own software fallback paths.** X's software `fb` copy runs at
161 MB/s where a plain userspace `memcpy` on the same CPU at the same clock does
2130 MB/s — 13x slower. The gap is not the CPU; it is generic per-pixel code.
When a driver path falls back, it falls back a long way.

---

## 6. The governor and the thermostat are part of your CPU budget

This is the section most easily skipped and most often responsible for a
measurement being wrong.

### 6.1 Percentages lie under `ondemand`

Identical work, same machine, cost taken from `/proc/<pid>/stat`:

| condition | `pulseaudio` | clock |
| --- | --- | --- |
| `ondemand`, as shipped | **26%** of a core | 625 MHz |
| `performance` | **11%** of a core | 1500 MHz |

The absolute work did not change. Only the denominator did. A small steady load
reads as idle to `ondemand`, which settles low, which doubles the apparent cost.

**Rule: never compare percentage-of-CPU figures taken at different clocks.**
Either pin the governor, or compare each process's cost *as a ratio to the
workload's own cost*, which reproduces to within a few percent where absolute
figures vary by a factor of three.

### 6.2 The governor setting that pays

Measured across two interleaved passes per configuration. Of the four settings
that looked promising, three are worth about 1–2% each:
`up_threshold` 95→70, `io_is_busy` 0→1, a 500 MHz floor.

The one that pays is `sampling_down_factor`, **1 → 10: 23.4% of burst latency,
a third off the median** (53.5 ms to 36.0 ms), for 5.4% more idle frequency.

The mechanism is not what it looks like. `up_threshold 95` does not stop the
governor stepping up — the work does trigger a step. The time goes on the
governor stepping back *down* between units of a burst.
`sampling_down_factor` is what stops it.

Applied on this machine by `device/pyra-governor-tune.sh`. Tuned `ondemand` is
still 18% off the `performance` governor, which is the ramp itself, and no
`ondemand` setting reaches it. `schedutil` would be the thing to try and this
kernel does not build it.

### 6.3 The thermostat sets your sustained clock

Cold, 1.5 GHz. Under sustained load, the frequency walks down through 1.4, 1.25,
1.125, 1.0, 0.875, 0.75 GHz. Ship of Harkinian fell **20.1 → 13.8 fps within one
50-second run** as the die went 56 → 68 °C, with no code change.

Two cores flat out, unmanaged, reached **107 °C** — seven degrees past the
passive trip — in under two minutes.

Three things follow, and they are the practical content of this section:

1. **Warm up before measuring.** Anything under about five minutes of sustained
   load is measuring the thermostat. Every A/B in this project is taken at
   equilibrium, 73–80 °C, and interleaved (ABBA) so that residual drift hits
   both arms equally.
2. **Reducing total work buys sustained clock, even off the critical path.** A
   NEON conversion of an audio routine running on core 1 will not move frame
   rate. It will lower the die temperature, which raises the clock the render
   thread runs at. This is a real effect on a fanless machine and it is invisible
   to a profiler.
3. **Two cores flat out is not a benchmark this machine should be asked to run
   repeatedly.** `device/pyra-freq-profile.sh` deliberately uses one core and
   aborts at the trip.

---

## 7. Practical checklist

- [ ] Confirm you are CPU-bound before spending anything here (`profiling-guide.md`)
- [ ] Build with NEON actually enabled; verify `__ARM_NEON` is defined
- [ ] Build for `armv7ve` so hardware divide is used
- [ ] Check that hand-written NEON is not using A64-only intrinsics
- [ ] Check libraries you depend on for existing runtime NEON dispatch before rebuilding them
- [ ] Size thread pools from measurement, not from `nproc`
- [ ] Pool per-frame allocations
- [ ] Never read back from GPU memory on a per-frame path
- [ ] Pin the governor, or use ratios, before quoting any percentage
- [ ] Warm to equilibrium and interleave arms before quoting any delta
