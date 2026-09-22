# Memory: one pool, everyone drinking from it

There is no VRAM on this machine. The two CPU cores, the SGX, the display
controller, the 2D engine and the audio DSP all reach the same 4 GB through the
same L3 interconnect and the same two memory controllers.

This document covers the bandwidth arithmetic, what it actually predicts, and —
importantly — the two occasions on this project where a correct bandwidth
argument produced no measurable improvement at all.

---

## 1. The arithmetic

| | | Source |
| --- | --- | --- |
| Capacity | 4 GB | Measured (3940 MB usable) |
| Controllers | 2x EMIF, `ti,emif-4d5`, Intelli PHY | Kernel DT |
| Clock | 531 MHz (~1062 MT/s) | Measured via `omapconf` |
| L3 / DMM / EMIF interconnect | 265 MHz — **already the top CORE operating point** | Measured |
| Theoretical peak | 2 x 32-bit x ~1062 MT/s ≈ **8.5 GB/s** | Reasoning |
| Single-core `memcpy`, userspace | **2130 MB/s**, i.e. ~4.3 GB/s of traffic | Measured |
| GC320 hardware blit | **1750 MB/s**, i.e. ~3.5 GB/s of traffic | Measured |
| Display scanout, continuous | **221 MB/s** of reads | Reasoning |
| Swap | **none configured** | Measured |

One core doing `memcpy` reaches about half the theoretical peak. That is a
respectable result and it also means **one core can saturate a meaningful
fraction of the machine's total memory bandwidth on its own**, leaving the GPU
and the display controller to contend for what is left.

> **A note on the memory type.** The Pyra's OMAP5432 is the DDR3/DDR3L variant
> of the part, and the board is built with 4 GB of DDR3L. `omapconf` reports
> "LP-DDR2", and the kernel's `emif` driver only carries LPDDR2 device tables
> (`drivers/memory/jedec_ddr_data.c`), which is the likely explanation for the
> reading. The discrepancy is recorded rather than resolved; it does not change
> any arithmetic here, because the clock is measured and the width is a property
> of the two EMIFs either way.

### 1.1 The permanent tenant

The panel is driven in DSI **video mode** — `OMAP_DSS_DSI_VIDEO_MODE` with
`OMAP_DSS_DSI_BURST_MODE`, from `drivers/gpu/drm/omapdrm/displays/panel-boe-w677l.c`.
That is a continuous-scanout mode. There is no panel-side framebuffer and no
partial update.

    720 x 1280 x 4 bytes x 60 Hz = 221 MB/s

DISPC reads that out of DDR whether the screen is changing or not, from boot to
shutdown. It is about 2.6% of theoretical peak, roughly 10% of what one core can
pull, and **it cannot be removed**. The only lever is the backlight: turning the
display off stops the scanout.

This is genuinely different from a modern phone, where a command-mode panel
holds its own frame and the SoC goes quiet on a static screen.

### 1.2 The one thing already at its ceiling

`omapconf show opp` puts the DMM, EMIF and L3 at 265 MHz, which is the **top
CORE operating point on an OMAP5432**. There is no faster memory setting to
find. Chasing memory clock on this machine is closed; the only lever is using
less of what there is.

---

## 2. Where the bandwidth is not the problem

This section exists because the obvious model of this machine is wrong in a way
that has cost this project two phases of work.

**The model:** shared memory, one pool, 8.5 GB/s theoretical and about half that
achievable, a permanent 221 MB/s display tenant. Therefore reduce traffic and
frames get faster.

**Test 1 — `GL_EXT_discard_framebuffer`.** Depth and stencil were being resolved
out to main memory at the end of every tile pass for data nothing ever reads.
About 4.6 MB per frame, **~140 MB/s at 30 fps**, entirely wasted. Discarding it
is two calls and no visual risk.

Implemented and measured: five interleaved A/B pairs, 60 s each, at thermal
equilibrium, frame cap raised so the limiter could not mask the result.

| | mean |
| --- | --- |
| without discard | 29.31 fps |
| with discard | 29.12 fps |
| **delta** | **−0.19 fps (−0.64%)** |

`t(4) = −0.99` against a critical value of ±2.776 — **not significant**, against
a design that could have resolved ±1.8%. A probe confirmed both call sites
executed and the driver returned `GL_NO_ERROR`, so this is a real null result
and not a silent no-op.

**Test 2 — the synthetic fill-rate benchmark.** A textured, blended full-screen
quad measured 862 Mpix/s and was read as "the GPU has ~15x headroom, so the
bottleneck must be CPU-side". The real workload turned out to be **strongly
fragment-bound**: halving internal resolution gained +75%.

**What the two have in common** is that both reasoned from traffic and both were
answered by shader issue rate. The measurement that finally explained it:
switching texture filtering from bilinear (four texels per fetch) to nearest
(one texel) changed frame time by **0.1%, statistically zero** — while removing
two `texture2D` *instructions* per texture unit saved **17.75%**.

> **The conclusion for this machine: memory traffic is scarce, and it is not
> what binds a GLES2 game workload. Fragment shader instruction issue is.**

### 2.1 So why reduce traffic at all

Three honest reasons, none of them "frames get faster":

1. **Thermals.** Memory traffic is power, and power is die temperature, and die
   temperature is sustained clock on a fanless machine that walks 1.5 GHz down
   to 0.75 GHz under load. Traffic you do not generate is clock you keep.
2. **CPU contention.** Bandwidth the GPU does not consume is bandwidth the CPU
   cores get. On a flat CPU profile this is diffuse, but it is real, and it is
   the cost that never appears as a symbol.
3. **It is usually free.** Clearing instead of preserving, discarding at end of
   pass, not copying buffers you do not need to copy — these cost nothing to do
   correctly and are right on every other TBDR part.

What changes is the *expectation*. Budget them as hygiene, not as wins, and do
not sequence a work plan around them.

---

## 3. The cost that does not appear in any profile

The Cortex-A15's L2 TLB has **512 entries**. With 4 KB pages that is **2 MB of
address reach** — smaller than the working set of essentially anything on this
machine. Past that, every access is a page table walk, and `CONFIG_ARM_LPAE=y`
(which this machine has because it has 4 GB) makes that walk **three levels
deep**: up to three dependent memory accesses for one miss.

This is the only major cost on the machine that a `perf` profile structurally
cannot attribute. Stall time in a walk is charged to whichever process happened
to be running.

### 3.1 What helps

- **Page-level locality.** Structures traversed together should live on the same
  pages. On a machine with 2 MB of TLB reach, an array of structs frequently
  beats parallel arrays, which is the opposite of the usual SIMD advice — weigh
  them against each other rather than assuming.
- **Fewer, larger allocations.** Arena or pool allocators, sized once. Every
  small `malloc` that lands on a fresh page evicts a TLB entry something else
  wanted.
- **Contiguous asset storage.** Streaming assets into one large mapping beats
  many small ones.

### 3.2 Transparent huge pages: built out, plausible, unmeasured

The running kernel says:

    # CONFIG_TRANSPARENT_HUGEPAGE is not set

while everything it depends on is already enabled — `HAVE_ARCH_TRANSPARENT_HUGEPAGE`
(free from `ARM_LPAE=y`), `COMPACTION=y`, `MIGRATION=y`. `PMD_SHIFT` is 21, so
a huge page here is **2 MB — one TLB entry covering what 512 currently cover**.

It is one config symbol, not a patch. It is also the only mechanism on this
project's list that attacks the unattributed cost directly.

Three caveats that could make it worth nothing, and they are not small:

- **`madvise` mode will probably measure zero.** It only promotes mappings that
  asked, and nothing on this machine asks. To find out whether there is an
  effect at all, test with `echo always > /sys/kernel/mm/transparent_hugepage/enabled`
  and decide the permanent setting from the number.
- **khugepaged is a jitter risk.** 4 GB, no swap, an SD card rootfs. Compaction
  stalls surface as frame hitches, and on a handheld a stutter is worse than a
  mean throughput gain is good. **The acceptance test is frame consistency, not
  a mean.**
- **It may be below the noise** of any workload whose own cost varies by a
  factor of three.

Verify it is happening before measuring whether it helps:

```sh
grep AnonHugePages /proc/meminfo
grep -i huge /proc/$(pgrep -f yourgame)/smaps_rollup
perf stat -e dTLB-load-misses,iTLB-load-misses -p $(pgrep -f yourgame) -- sleep 30
```

(Check `perf list` first — whether this PMU exposes those two event names is not
known, and the ARMv7 event mapping is not the same on every part.)

---

## 4. The readback cliff

The single most dramatic ratio measured on this machine.

| Path | Throughput |
| --- | --- |
| userspace `memcpy`, for reference | 2130 MB/s |
| GC320 hardware copy | 1750 MB/s |
| X server software `fb` copy | 161 MB/s |
| `PutImage` into a GPU surface | 318 MB/s |
| `PutImage` via `MIT-SHM` | 988 MB/s |
| **`GetImage` — reading pixels back out** | **62 MB/s** |

Readback is **27 times slower** than an accelerated copy of the same rectangle,
and 34 times slower than `memcpy` on the same CPU at the same clock. That is the
signature of a CPU reading uncached, write-combine GPU memory one cache line at
a time with no prefetching and no write combining to help it.

Two rules follow and they are absolute:

1. **Never read pixels back on a per-frame path.** Not `glReadPixels`, not
   `XGetImage`, not a mapped buffer object you read from. On a TBDR this is also
   a full pipeline flush (`gpu-optimization.md` §3.3), so you pay twice.
2. **Upload through `MIT-SHM` if you are going through X**, which is three times
   the plain path and already what well-behaved clients do.

Note what this is *not*: the write-combine mapping itself costs nothing
measurable. Identical software paths run against a GPU write-combine buffer and
against plain `malloc` give the same numbers — 5.7 Mpix/s either way for an XOR
fill, 34.5 against 33.9 MB/s for a depth-8 copy. The cost is in the direction of
travel, not in the mapping.

---

## 5. Allocation patterns

**Good:**

- Allocate once, reuse forever. Ring buffers, arenas, object pools.
- Size buffers for the worst case at startup rather than growing them.
- Keep hot data contiguous and page-aligned where it is large.
- Free memory back to a pool, not to the allocator.
- Use the 4 GB. Capacity is not the constraint here and trading space for
  traffic or for allocator churn is usually the right trade.

**Bad:**

- `malloc`/`free` inside the frame loop. In the one profile taken on this
  machine, `malloc`/`free` shares the largest single bucket (13%) with
  `shared_ptr` refcounting and hash lookups.
- Large temporary buffers allocated and released per frame — they churn the page
  tables as well as the allocator.
- `memcpy` of data that could have been produced in place.
- Atomic refcounts on objects touched by both threads. With 2 MB of L2 shared
  between two cores, false sharing is easy to create and invisible in a symbol
  profile.

**There is no swap.** 4 GB, `swap 0`, and about 2.5 GB free at idle. This is
fine for a game and becomes a problem the first time a browser is opened. If it
does, `zram` with `lz4` is the cheap answer — compressing into RAM rather than
writing to an SD card. Nothing here should be tuned on the assumption that swap
will catch an overshoot, because it will not; the OOM killer will.

---

## 6. The rootfs is an SD card

`f2fs` with `background_gc=on,discard`, `lazytime` and `relatime`.

Inline `discard` on an SD card can stall writes. `nodiscard` plus a weekly
`fstrim` timer is usually better, and is worth one `fio` run to confirm. The
practical consequence for a port is that **asset streaming from disk is on a
slow, latency-variable device**, and that `io_is_busy` is 0 in the stock
governor configuration — so time blocked on the card does not count as load and
anything I/O bound stays at the bottom of the frequency table.

Load assets up front where you can afford the memory. You have 4 GB.

---

## 7. Checklist

- [ ] Account for the permanent 221 MB/s display tenant in any bandwidth budget
- [ ] Do not expect frame-rate wins from traffic reduction; budget it as thermal hygiene
- [ ] Clear every attachment at the start of a pass; discard at the end
- [ ] Never read back from GPU memory on a per-frame path
- [ ] Upload through `MIT-SHM` where X is involved
- [ ] Pool per-frame allocations
- [ ] Prefer fewer, larger, contiguous allocations — the TLB reaches 2 MB
- [ ] Check for false sharing between the render thread and workers
- [ ] Do not assume swap will save you; there is none
- [ ] Load assets up front; the card is slow and I/O wait does not raise the clock
