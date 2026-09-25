# Kernel notes

The Pyra runs an out-of-tree kernel: **5.6.19**, from the Letux/Pyra tree, not
mainline and not a Debian kernel. This document records what is in it that
affects performance, what is worth changing, and — more importantly — what is
not and why.

Kernel source used for every claim here:
`~/git/dragonbox-pyra-build/kernel/src`, and the `.config` that built the
running kernel is in the same directory. Device tree claims come from
`arch/arm/boot/dts/omap5*.dtsi` and `omap5-letux-cortex15-v5.3+pyra-v5.3.dts`.

**Do not make speculative kernel changes.** Every entry below either has
evidence or is explicitly marked as unmeasured.

---

## 1. What is already set correctly

Recorded so nobody spends an afternoon on it. This is **not** a distribution
kernel — `pyra_defconfig` has already been trimmed by somebody who knew what
they were doing, and most of what would be worth turning off on a Debian kernel
is either already off or not applicable here.

| Symbol | State | Comment |
| --- | --- | --- |
| `CONFIG_PREEMPT` | `y` | Right for a machine running a game and an audio thread |
| `CONFIG_HZ_100` | `y` | |
| `CONFIG_NO_HZ_IDLE` | `y` | |
| `CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE` | `y` | Not size |
| `CONFIG_ARM_PATCH_IDIV` | `y` | |
| `CONFIG_SLUB` | `y` | Rather than SLAB |
| `CONFIG_CPU_BPREDICT_DISABLE` | off | Correct |
| `CONFIG_INIT_ON_ALLOC_DEFAULT_ON` | already `n` | The biggest free win on a Debian kernel. Already taken here — `init_on_alloc=0` on the cmdline is a no-op |
| `CONFIG_DEBUG_LIST`, `DEBUG_SG`, `DEBUG_PREEMPT`, `SCHED_DEBUG`, `FUNCTION_TRACER`, `UBSAN`, `KASAN` | all `n` | A distro kernel ships several of these on |
| `CONFIG_ZRAM` | `m` | Available as a module if swap is ever wanted |
| `CONFIG_ARM_LPAE` | `y` | Required for 4 GB. Also makes page walks 3 levels deep |

---

## 2. Useful runtime tunables

These need no rebuild.

### 2.1 The one governor setting that pays

```sh
echo 10 > /sys/devices/system/cpu/cpufreq/ondemand/sampling_down_factor
```

**23.4% of burst latency, a third off the median** (53.5 → 36.0 ms), for 5.4%
more idle frequency. Confirmed on the live machine: 40.9 ms against 52.5 ms at
stock.

The mechanism is not the obvious one. `up_threshold 95` does not stop the
governor stepping up — the work does trigger a step. The time goes on the
governor stepping back **down** between units of a burst, and
`sampling_down_factor` is what stops it.

The other three settings people reach for are worth about 1–2% each:
`up_threshold` 95→70, `io_is_busy` 0→1, a 500 MHz floor. A 750 MHz floor buys
8.4% and costs 83% more idle frequency to do it.

A sysfs write does not survive a reboot. `device/pyra-governor-tune.sh` applies
it and `pyra-governor-tune.service` reapplies it at boot. `--undo` reverts.

Tuned `ondemand` is still **18% off the `performance` governor**, which is the
ramp itself, and no `ondemand` setting reaches it.

### 2.2 Thermal

Trips, from `arch/arm/boot/dts/omap4-cpu-thermal.dtsi`:

| Zone | Passive | Critical | Poll |
| --- | --- | --- | --- |
| `cpu_thermal` | 100 °C | 125 °C | 250 ms passive / 1000 ms |
| `gpu_thermal` | — | 125 °C | 250 / 500 ms |
| `core_thermal` | — | 125 °C | 250 / 500 ms |

Only `cpu_thermal` has a passive trip and a cooling map. `sustainable_power`
reads 0, so `power_allocator` is unavailable and `step_wise` is the only real
policy.

**`step_wise` alone is not enough on this hardware.** It concedes one cooling
state per poll, and two cores flat out took the CPU zone from 64 °C to
**107 °C** — seven degrees past the passive trip — in under two minutes, with
the run stopped by the profiler rather than by the kernel. Nothing was damaged
and the critical trip was never approached, but that is the real limit of a
fanless case.

The userspace daemon that is supposed to help had five faults and is fixed by
`device/pyra-thermal-fix.sh` and `device/pyra-thermal-ladder.sh`. Two of those
faults are worth knowing as hardware lessons rather than as bugs:

- **`cpu_thermal` leads `core_thermal` by up to 12 °C during a ramp.** A
  controller watching the wrong zone acts far too late. Read the hotter of the
  two.
- **This core moves up to 6 °C between five-second samples on one core and
  10 °C on two.** A 2 °C hysteresis band is below the controller's noise floor.
  A full rung (5 °C) took one core of load from twelve ceiling changes to two,
  and dropped the peak from 91.3 °C to 88.7 °C — holding a cap regulates better
  than oscillating.
- **The machine crosses its passive trip in 16 seconds from idle** under two
  cores. A 20-second poll lands after the trip. The poll is now 2 seconds.

### 2.3 Rotation is already in hardware

Boot cmdline carries `drm.force_hw_rotation` and
`drm_kms_helper.fbdev_rotation=8`; X carries `Option "TilerRotation" "270"`.
Confirmed in the log. Leave it alone.

### 2.4 Display blanking

Every DPMS transition is a modeset, and the modeset path can wedge the display
driver hard enough to require a reboot. Blanking is disabled on this image. Be
careful with anything that toggles DPMS in a loop. See `docs/troubleshooting.md`.

---

## 3. Worth trying, with a rebuild

Both need a kernel build, and both should be installed beside the stock kernel
with `device/pyra-install-debug-kernel.sh` and selected with
`device/pyra-boot-kernel.sh` in its one-shot mode, which reverts by itself if
the machine does not come back.

### 3.1 `CONFIG_CPU_FREQ_GOV_SCHEDUTIL` — not built

    # CONFIG_CPU_FREQ_GOV_SCHEDUTIL is not set

Every other governor is. `schedutil` drives frequency from the scheduler's own
utilization signal at scheduler events, rather than from a sampled 20 ms window
— which is exactly the mechanism the remaining 18% gap to `performance` is made
of. `sampling_down_factor` holds the clock up *between* units of a burst; the
first unit after real idle still pays the full ramp, and "sluggish" is a
description of a tail.

That is a reason to try it, not a prediction that it wins. This is a two-core
ARM32 without EAS, and a well-tuned `ondemand` is a harder baseline than an
untuned one. The number to beat is recorded: 18%. The sweep to measure it
already exists in `experiments/governor/`.

### 3.2 `CONFIG_TRANSPARENT_HUGEPAGE` — not built

    # CONFIG_TRANSPARENT_HUGEPAGE is not set
    CONFIG_HAVE_ARCH_TRANSPARENT_HUGEPAGE=y
    CONFIG_COMPACTION=y
    CONFIG_MIGRATION=y

Everything it depends on is already on. `PMD_SHIFT` is 21 under LPAE, so the
huge page here is **2 MB — one TLB entry covering what the entire 512-entry L2
TLB covers today**.

This is the only item on the list that attacks the *unattributed* cost. Time
spent stalled in a three-level page walk is charged to whichever process was
running and never appears as a symbol.

**Unmeasured, and three things could make it worth nothing:**

- `madvise` mode will probably measure zero — nothing on this machine asks. Test
  with `echo always > /sys/kernel/mm/transparent_hugepage/enabled` first.
- khugepaged is a jitter risk: 4 GB, no swap, SD card rootfs. Compaction stalls
  surface as frame hitches. **The acceptance test is frame consistency, not a
  mean.** If the mean improves and the machine hitches, the answer is no.
- It may simply be below the noise of any real workload.

Verify it is happening before measuring whether it helps:

```sh
grep AnonHugePages /proc/meminfo
grep -i huge /proc/$(pgrep -f yourgame)/smaps_rollup
```

**Do not combine this with §5 in one build.** Both change memory behaviour and
neither result would be attributable.

---

## 4. Do not change

### 4.1 `CONFIG_ARM_ERRATA_798181`

`y`, and **active on this silicon**. Not a security option and not a candidate
at any price: it is a data corruption erratum — a page moved while a process is
accessing it.

It is already runtime-gated. `erratum_a15_798181_init()` in
`arch/arm/kernel/smp_tlb.c` reads MIDR and REVIDR at boot; this machine is
**r2p2**, which lands in the branch that selects either the partial handler or
the full broadcast one depending on REVIDR bit 4. So it is running, and the full
variant adds an **IPI to the other core on every `flush_tlb_*`**
(`broadcast_tlb_mm_a15_erratum`).

Expensive, mandatory, and the failure mode is silent corruption. Leave it.

It is worth knowing about for a different reason: it means TLB shootdowns on
this machine are more expensive than on a normal ARMv7 part, which reinforces
everything in `memory-optimization.md` §3 about allocation patterns.

### 4.2 `CONFIG_SECCOMP_FILTER`

Processes without a filter pay nothing, and systemd's `SystemCallFilter=`
depends on it. Removing it breaks service startup to buy nothing.

### 4.3 The C2 retention idle state

`arch/arm/mach-omap2/cpuidle44xx.c` has it behind `#if 0`, with no comment. It
was enabled and tested: **two boots, both wedged at 48 s and 74 s**, no warning,
no backtrace, no network. The same kernel without it runs for hours. See
`experiments/c2-idle/RESULT.md`.

Upstream reports idle power falling from ~1.7 W to ~920 mW on the reference
board, so the prize is real — but it is not reachable here without a serial
console to find out what is actually happening.

---

## 5. The Spectre v2 workaround, which is unusually expensive on an A15

Surveyed against the config and the kernel source. **Not measured.** The ceiling
below is reasoning and it is low enough that it may not clear the noise floor of
any load this machine runs.

Meltdown does not apply to this processor. Spectre v2 does, and the workaround
ARM specifies for this core is unusually expensive.

Every other ARMv7 part invalidates the branch predictor with `BPIALL`, which is
cheap. **The A15's BTB is not invalidated by `BPIALL`**, so the kernel falls
back to `ICIALLU` — invalidate the entire **32 KB L1 instruction cache**. In
`arch/arm/mm/proc-v7-bugs.c` the A15 case selects
`harden_branch_predictor_iciallu`. Confirm on the machine with
`dmesg | grep -i spectre`.

That would be cheap if it were rare. It is wired into the context switch:

    arch/arm/mm/proc-v7.S:628
        globl_equ  cpu_ca15_switch_mm,  cpu_v7_iciallu_switch_mm

So every switch to a different address space throws away the I-cache.

**Why the ceiling is low anyway** — and this is the important part. Kernel
threads use lazy TLB and never call `switch_mm`, so the i2c interrupt threads
that dominate the idle profile do not pay it. A game is one process running long
slices. What is left is the game / `Xorg` / `pulseaudio` rotation, a few
thousand switches a second, each costing only the refill of whatever is
re-executed before the next switch — not a full 32 KB.

**Estimate: 1–3% on a context-switch-heavy load, close to zero on a
compute-bound inner loop.** A single thermal throttle step is larger than that.

There is **no cmdline opt-out** — `nospectre_v2` is not parsed anywhere under
`arch/arm` in 5.6. It is `CONFIG_HARDEN_BRANCH_PREDICTOR=n`, reached by turning
off `CONFIG_CPU_SPECTRE`, and a rebuild, or it stays.

**What is actually traded.** The realistic attacker for Spectre v2 is JavaScript
in a browser. If this machine browses, that is a live vector and the trade is
real for 1–3%. If it is a game appliance that never opens a browser, there is no
attacker and the trade is free. That is a decision about how the machine is
used, not about the kernel.

This is also the best argument for `-mthumb` in userspace
(`compiler-flags.md`): on a machine that throws away its 32 KB I-cache
thousands of times a second, code size is not cosmetic.

`CONFIG_THUMB2_KERNEL` is off, and turning it on would cut the kernel's own
instruction footprint by roughly a quarter — mildly interesting next to the
above, but a large change to the whole kernel for an unmeasured second-order
effect, and not the first thing to try.

---

## 6. Deprecated or misleading interfaces

- **`cpufreq-set` does not exist on trixie.** The `cpufrequtils` package is not
  in the archive at all. The vendor thermal daemon shells out to it every 20
  seconds and has failed on every cycle since the image's first boot — 1031
  failures in one journal. Write `scaling_max_freq` directly.
- **`/dev/usb_max_current`** is an ordinary file that nothing reads. The udev
  rules that were supposed to create it as a symlink name `twl4030`, which is
  not this machine's PMIC. The vendor daemon's charge ladder has never
  influenced charging on any image.
- **`/sys/class/power_supply/bq27421-0/temp` is not the battery.** It is the
  fuel gauge's own die temperature — the mainboard. It rose 2.0 °C within ten
  seconds of one core being loaded, which no 6000 mAh cell can do. The vendor
  daemon throttles from it at 44 °C while the SoC gives up nothing below 77 °C,
  which is why a stock machine throttles in ordinary use for no thermal reason.
- **The device tree is not a safe source for AESS memory bank sizes.** It maps
  PMEM and CMEM as `0x1000` when both are at least 8 KiB, and says `CHECKME`
  while doing it. Reading past a bank's real size raises an asynchronous
  external abort that wedges the L4 ABE interconnect.
- **`omapconf` reports every voltage rail as 0.000 V and the PMIC as
  `ES UNKNOWN`** on this unit. Voltage readback is unavailable, which is what
  makes the GPU rail question in `known-limitations.md` §2.5 unsafe rather than
  merely unexplored.

---

## 7. Hardware facts recorded from the device tree

Useful when reasoning about the machine, and cheaper to read here than to
re-derive.

| Fact | Where |
| --- | --- |
| CPU OPPs in-tree: 1000 MHz @ 1.06 V, 1500 MHz @ 1.25 V | `omap5.dtsi` cpu0 |
| Clock latency 300 µs | `omap5.dtsi` |
| GPU: `ti,omap5-sgx544-116`, `img,sgx544`, IRQ 21 | `omap5.dtsi:300` |
| DMM (TILER) at `0x4e000000` | `omap5.dtsi:219` |
| 2D engine: `vivante,gc` at `0x59000000`, IRQ 125 | `omap5.dtsi:226` |
| Two EMIFs, `ti,emif-4d5`, Intelli PHY, `ti,no-idle-on-init` | `omap5.dtsi:236` |
| Panel: `boe,btl507212-w677l`, 720x1280 @ 60 Hz | `pyra-display.dtsi` |
| DSI: 4 lanes, RGB888, **video mode, burst**, HS clock 125–450 MHz | `panel-boe-w677l.c:617` |
| Panel total timing: 888 x 1440, pixel clock ~76.7 MHz | `panel-boe-w677l.c:77` |
| Backlight: PWM on timer 9, 16 brightness levels, 8300 Hz on V5.x | `pyra-display.dtsi` |
| Touchscreen: TSC2007 on i2c4, rotated to 1280x720 | `pyra-display.dtsi` |
| AESS: `ti,aess`, `aess_fclk` at 196.608 MHz | live DT |
| Nubs: AS5013 on i2c, **interrupt lines held low on the board**, 25 ms polled | `improvements.md` item 11 |

Five steps below 1.5 GHz — 375, 625, 875, 1125 and 1400 MHz — exist in a
third-party table and are carried by `pc/pyra-crossbuild.sh kernel-freq`. Every
original step keeps its stock voltage to the microvolt, so that half raises no
ceiling. **Measured: finer steps do not improve responsiveness** — bursty work
is ~4% slower on the mean and 18% slower in the best case, because the governor
gains somewhere comfortable to stop short of the top. What they buy is idle
power: the top step is reached 0.1% of an idle machine's time instead of 7.3%,
worth about 0.27 W, roughly 21 minutes of the 21.3 Wh battery.

The same published table carries five steps *above* the part's rating. Those are
a separate patch and a separate build, deliberately, and
`known-limitations.md` §2.4 is why they should stay that way on a stock unit.
