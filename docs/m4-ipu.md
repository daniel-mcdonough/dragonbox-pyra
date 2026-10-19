# The two Cortex-M4s: what they are and what it costs to use them

Written 2026-09-20, against the running unit over SSH and against the kernel
source tree that `pyra-crossbuild.sh` unpacks.

The OMAP5432 has two Cortex-M4 cores that this machine had never started.
**Both of them now run code.** This document says what they are, what state the
shipped software leaves them in, exactly what it takes to make the kernel see
them, the test firmware that proves they execute, and what is left after that.

**Read the assessment at the end before starting.** The kernel side is small,
cheap and now proven on hardware in both halves. A useful firmware — rpmsg,
MessageQ, video decode — is still a separate and much larger job, and the
payoff for this project's actual goals is thin.

**And read "The other route" before building anything.** The letux kernel is at
7.3 and already carries `0009` and `0010`; whether to use it is a real choice
and not a foregone one. It does not fix `0012` — nothing does, upstream
included.

---

## What the hardware is

The cores are the **IPU subsystem**: a pair of Cortex-M4s sharing 64 KB of L2
RAM at `0x55020000`, behind an IOMMU, with a hardware mailbox to the A15s. TI
calls the subsystem Ducati or Benelli in older documents. The same framework
also reaches the **C66x DSP**, which comes along for free because the driver and
the device tree changes cover both.

Measured on the unit, 2026-09-20:

| | |
| --- | --- |
| SoC | `OMAP5432`, `ES2.0`, **`GP`** (`/sys/bus/soc/devices/soc0`) |
| IPU gate clock | **425 472 000 Hz** (`ipu_cm:clk:0000:0`) |
| DSP gate clock | **465 920 000 Hz** (`dsp_cm:clk:0000:0`) |
| IPU L2 RAM | 64 KB at `0x55020000` |
| RAM free for carveouts | 2 890 MB of 3 940 MB, with CMA at 64 MB and untouched |

Two cautions about that table.

**The clock figures are the subsystem gate clocks off `dpll_core`, not
core rates.** They are what `/sys/kernel/debug/clk/clk_summary` reports for
the clkctrl gates. **The M4s run at half the IPU figure: 212.8 MHz, measured
on 2026-10-18** — 425.472 / 2 is 212.736, and TI's published figure is about
half the gate clock too. The measurement is the demo firmware's (`make demo`,
`device/pyra-m4-demo.sh`): each core counts its own clock in SysTick, extended
to 32 bits in software, and Linux times the count against its own clock over
15 one-second samples. Both cores read 212.8 MHz, the per-second readings stay
within 211.5–214.3, and the total-over-time and per-second-median estimates
agree. The log is `experiments/m4-ipu/results/`.

Two things were learned on the way, both worth knowing before writing
firmware:

- **The IPU's M4s have no DWT cycle counter.** `DWT_CTRL` reads `0x4f000000`:
  four comparators, with `NOCYCCNT`, `NOPRFCNT`, `NOEXTTRIG` and `NOTRCPKT`
  all set. SysTick is the only cycle-rate counter inside the core.
- **Code running uncached from DDR is very slow.** The heartbeat's delay loop
  takes about 2 µs per iteration — on the order of 400 cycles for a handful of
  instructions — because with the unicache off every fetch and every stack
  access crosses the L3 to DDR. That is fine for a heartbeat and ruinous for
  anything else; real firmware has to turn the unicache on or run from the
  64 KB L2 RAM.

The same figure, 212.9 MHz, came back on `5.6.19-m4demo` after a reboot: the
M4-only kernel that `docs/m4-demo.md` hands to other people, which carries the
same four patches without the AESS or OPP work.

The DSP's gate clock (465.9 MHz) has not been measured against anything.

**`GP` matters.** This is a General Purpose part, not High Security, so
firmware does not have to be signed by TI to load. On an HS part none of what
follows would work without keys.

---

## What state it is in today

Nothing runs, and `/sys/class/remoteproc` does not exist. Three config symbols
are off in the shipped kernel:

    # CONFIG_REMOTEPROC is not set
    # CONFIG_OMAP2PLUS_MBOX is not set
    # CONFIG_RPMSG_VIRTIO is not set

But rather less is missing than that suggests, because the hard parts of the
plumbing are already present and already working.

**Both IOMMUs are probed and bound right now**, on the stock kernel, with no
changes:

    $ ls /sys/class/iommu/
    4a066000.mmu    55082000.mmu

Those are the DSP MMU and the IPU MMU, both matched by `ti,omap4-iommu`,
because `CONFIG_OMAP_IOMMU=y` and `CONFIG_IOMMU_API=y` already.

**The mailbox is already in the booted device tree**, with both channels:

    /sys/firmware/devicetree/base/ocp/interconnect@4a000000/segment@80000/
        target-module@74000/mailbox@0            compatible = ti,omap4-mailbox
        target-module@74000/mailbox@0/mbox_ipu
        target-module@74000/mailbox@0/mbox_dsp

> A note for anyone checking this themselves: `find /proc/device-tree -name ...`
> returns nothing at all, for every node, and it is lying. `/proc/device-tree`
> is a symlink and `find` does not follow symlinks without `-L`. Search
> `/sys/firmware/devicetree/base` instead. This cost an hour and produced a
> wrong conclusion before it was caught.

So what is actually absent is two device tree nodes and a driver.

### The shipped driver is dead code

`drivers/remoteproc/omap_remoteproc.c` in 5.6.19 is the original 2011 file:
235 lines, **no `of_device_id` table at all**, and a probe that immediately
dereferences `pdev->dev.platform_data` expecting an `omap_rproc_pdata` with
`device_enable` and `device_shutdown` function pointers.

Nothing in the tree ever supplies that:

    $ grep -rn "omap_rproc_pdata\|omap-rproc" --include=*.c --include=*.h .
    include/linux/platform_data/remoteproc-omap.h:16: * struct omap_rproc_pdata
    include/linux/platform_data/remoteproc-omap.h:27:struct omap_rproc_pdata {

Two hits, both in the header that declares it. `arch/arm/mach-omap2/` contains
no reference to remoteproc whatsoever, and OMAP5 is device-tree only, so no
board file exists that could register the platform device. **Turning
`CONFIG_OMAP_REMOTEPROC` on in this kernel compiles code that can never probe.**

Device tree support was written by Suman Anna and Tero Kristo. Checked against
the actual trees rather than the changelogs:

| kernel | `omap_remoteproc.c` | `ipu`/`dsp` nodes in `omap5.dtsi` |
| --- | --- | --- |
| v5.6 (ours) | 235 lines, no DT | 0 |
| v5.7 | 1399 lines | 0 |
| v5.8 | 1399 lines | 0 |
| **v5.9** | **1398 lines** | **2** |
| v5.10 | 1398 lines | 2 |
| v6.6 | 1395 lines | 2 |

So the driver arrived whole in v5.7 and the omap5 nodes caught up in v5.9. It
has barely moved since — four lines across six releases — which is why v5.9 is
the backport target: a settled file, not a moving one.

---

## The kernel work: done, and it is small

**The work is three one-line fixes, two device tree nodes, a board stanza and
seven config symbols. It builds.** The patch *files* come to 1633 lines, but
1484 of those are `0009` carrying upstream's driver in whole, because there is
nothing in the shipped stub to edit toward. The part that had to be reasoned
about is small enough to quote in full, and is quoted in full below.

The patches are in `experiments/m4-ipu/` and the build target is:

    ./pc/pyra-crossbuild.sh kernel-m4

which produces `5.6.19-m4`, installing beside the stock kernel like every other
variant. It is the fix set from `patches/` plus the four patches below plus
seven config symbols, and it also carries two things that are not about the
M4s at all: the AESS series from `experiments/aess/`, because `l1` is the only
test slot on the device and both are wanted in the same boot, and
`0007-arm-dts-omap5-add-the-intermediate-opps.patch` from
`experiments/thermals-and-frequency/`, so that the vendor thermal daemon's
frequency cap has eleven steps to land on here rather than six. It does not
carry `0008`; nothing but `kernel-oc` raises the ceiling.

`OMAP_REMOTEPROC` is set to `m` rather than `y`, but **the reason first given
for that here was wrong and the first boot disproved it.** The claim was that
as a module nothing would go near the IPU until `modprobe omap_remoteproc`.
udev loads it anyway, from the device tree modalias:

    $ cat /sys/devices/platform/44000000.ocp/55020000.ipu/modalias
    of:NipuT(null)Cti,omap5-ipu

so the driver probes during boot either way, and `=m` buys no intervention
point at boot. What it does buy is real but different: the module can be
removed afterwards, and it can be stopped from loading at all with a
`modprobe.d` blacklist or `modprobe.blacklist=omap_remoteproc` on the kernel
command line. **If you want the cores genuinely untouched during boot, that
blacklist is the thing to use — not `=m`.**

| patch | what |
| --- | --- |
| `0009-remoteproc-omap-backport-the-device-tree-driver.patch` | replaces the 235-line stub with v5.9's driver, plus three compat fixes |
| `0010-arm-dts-omap5-add-the-ipu-and-dsp-nodes.patch` | the two SoC-level nodes, verbatim from v5.9 |
| `0011-arm-dts-pyra-enable-the-ipu-and-dsp.patch` | carveouts and enablement for this board |

### Why the backport is this cheap

Every kernel interface the v5.9 driver wants already exists in 5.6. Checked
symbol by symbol, not assumed: all twenty-one headers it includes are present;
`struct rproc_ops` already has the four members it assigns; and
`rproc_mem_entry_init`, `rproc_of_resm_mem_entry_init`, `rproc_add_carveout`,
`omap_iommu_domain_activate`, `devm_reset_control_array_get_exclusive`,
`syscon_regmap_lookup_by_phandle` and `of_reserved_mem_device_init_by_idx` are
all there with the signatures it expects.

Compiling it produced exactly three errors, all signature drift in interfaces
outside remoteproc, none a behaviour change:

```c
-timer->timer_ops->set_load(timer->odt, 0);      /* 5.6 still has autoreload */
+timer->timer_ops->set_load(timer->odt, 0, 0);

-static void *omap_rproc_da_to_va(..., size_t len)   /* int in 5.6 */
+static void *omap_rproc_da_to_va(..., int len)

-"invalid boot address 0x%llx..."                 /* bootaddr is u32 in 5.6 */
+"invalid boot address 0x%x..."
```

The first one is not a judgement call, which is worth knowing because it is the
only one that could have been. Upstream wrote that call as `set_load(odt, 0, 0)`
and only deleted the argument when `02e6d546e3bd` changed the dmtimer API
underneath it; `e6d05acd5701` is the commit that did the deleting, and it
carries the three-argument form in its diff. The patch restores exactly what
the author wrote against this API.

### Why the device tree change is this cheap

The v5.9 nodes drop straight in: the `target-module@55082000` block they sit
after and the `dmm@4e000000` block they sit before are **byte-identical**
between this tree and v5.9. And everything the nodes reference already exists
here — `mmu_ipu`, `mmu_dsp`, `mailbox` with both sub-nodes, `prm_core`,
`prm_dsp`, `scm_conf`, `ipu_clkctrl`, `dsp_clkctrl`. Decompiling the built DTB
confirms every phandle resolved.

Carveouts follow `omap5-uevm.dts`, which is the right template because this
machine already claims to be one — `/proc/device-tree/compatible` reads
`goldelico,lc15-v5.3 goldelico,lc15 ti,omap5-uevm ti,omap5`. 8 MB of DSP
carveout at `0x95000000`, 56 MB of IPU carveout at `0x95800000`, both
`reusable` so the pages return to the allocator whenever the processor is
stopped.

### The one Pyra-specific trap

**Do not copy `omap5-uevm.dts`'s timers.** Upstream gives the IPU
`ti,watchdog-timers = <&timer9>, <&timer11>`, and on a Pyra **timer9 is the
display backlight PWM** — `pyra-display.dtsi:26` declares `pwm9` on it and the
panel's backlight consumes it. timer8 is the keyboard backlight for the same
reason.

**It fails safe, and the backlight wins.** Traced through the source rather
than guessed at, because "two drivers want one timer" could mean anything:

- `pwm-omap-dmtimer.c` calls `request_by_node()` in its **probe** and only
  releases in its **remove**, so it holds timer9 for the life of the system.
  `CONFIG_PWM_OMAP_DMTIMER=y` here, so that happens during boot — before any
  module can load. Both `pwmchip0` and `pwmchip1` are bound on the running
  unit, and both backlights exist.
- `_omap_dm_timer_request()` skips any timer whose `reserved` flag is set.
- The remoteproc driver asks for its timers in `omap_rproc_enable_timers()`,
  reached only from `omap_rproc_start()` — **not from probe**. So the request
  happens when the processor is started, long after the backlight has claimed
  timer9.

So the ordering is deterministic rather than a race: the backlight keeps
timer9, `request_by_node` hands remoteproc a `NULL`, `omap_rproc_request_timer`
returns `-EBUSY`, and **starting the IPU fails**. The screen is unaffected. The
cost of getting this wrong is a confusing `-EBUSY` at `start` that has nothing
obviously to do with the backlight, not a dark panel — which is worth knowing
precisely because that error would otherwise send you looking at the IOMMU.

`0011` therefore omits both timer properties. They are optional:
`omap_rproc_probe` counts them with `of_count_phandle_with_args` and clamps a
negative count to zero, and the watchdog property is only read at all under
`CONFIG_OMAP_REMOTEPROC_WATCHDOG`. If firmware later wants a tick source,
timer3, timer4, timer10 and timer11 are all unclaimed here — confirmed against
the bound list in `/sys/bus/platform/drivers/omap_timer/`.

### What the build produces, and how to install it

Built 2026-09-20. `kernel-m4` goes through the same path as every other
variant, so `pyra-install-debug-kernel.sh` takes it unchanged — it reads the
release name out of the tarball rather than assuming one:

    scp m4-kernel.tar.gz device/pyra-install-debug-kernel.sh pyra@<address>:
    sudo ./pyra-install-debug-kernel.sh m4-kernel.tar.gz
    sudo pyra-boot-kernel.sh debug --once      # one boot, then back to stock
    sudo systemctl reboot

**There is one test slot, `l1`, and installing takes it.** If you already have
a test kernel there — this machine was running `5.6.19-freq` — its extlinux
entry is overwritten, though its `vmlinuz`, `initrd`, dtbs and modules all stay
on disk. Save `/boot/extlinux/user.cfg` first and add the old kernel back under
a spare label afterwards, which is all it takes to keep it bootable:

    sudo cp -n /boot/extlinux/user.cfg /boot/extlinux/user.cfg.before-m4
    # after installing, re-append the saved stanza with a different label

**Use `--once`.** U-Boot on this machine has no display driver, so the boot
menu only exists on the serial console and a test kernel has to become the
default — see the header of `pyra-boot-kernel.sh`. `--once` arms a service that
puts the default back to stock early in the next boot, so a kernel that boots
gets exactly one. A kernel that never reaches userspace is not recoverable from
the device at all: that needs the card in a PC and one word changed in
`/boot/extlinux/extlinux.conf`.

| | |
| --- | --- |
| release | `5.6.19-m4` |
| ready to install | `kernel/m4-kernel.tar.gz`, 23 MB |
| symbols | `kernel/src-m4/vmlinux` |

Verified in the tarball: `omap_remoteproc.ko` and `rpmsg_char.ko` under
`usr/lib/modules/5.6.19-m4/`, `vmlinuz-5.6.19-m4`, and this board's
`omap5-letux-cortex15-v5.3+pyra-v5.3.dtb` with both new nodes `status = "okay"`
and every phandle resolved. The only `ti,timers` properties anywhere in that
DTB are the two backlight PWMs, which is the check that the timer trap above
was actually avoided.

**On first boot nothing happens, and that is correct.** The driver is a module
and the cores stay in reset until it is loaded:

    sudo modprobe omap_remoteproc
    ls /sys/class/remoteproc/            # expect remoteproc0 and remoteproc1
    cat /sys/class/remoteproc/remoteproc0/{name,state,firmware}

`state` should read `offline`. Do not write `start` to it until there is a
firmware file for it to load — that is the next section, and it is not done.

**One thing to know before a firmware file ever exists, now observed rather
than predicted.** `rproc_alloc()` sets `auto_boot = true` and the omap driver
never overrides it, so the core is started automatically. The first boot shows
it trying, and failing only because the file is absent:

    [   22.478413] remoteproc remoteproc1: powering up 55020000.ipu
    [   22.515618] remoteproc remoteproc1: Direct firmware load for
                   omap5-ipu-fw.xem4 failed with error -2
    [   23.704182] remoteproc remoteproc1: request_firmware failed: -11

Combined with the udev autoload above, that means **the day
`/lib/firmware/omap5-ipu-fw.xem4` appears, the IPU starts during boot, with no
command typed and no step at which to reconsider.** Put the blacklist on the
kernel command line before installing firmware, not after.

### The first boot

**Booted on 2026-09-20 on the V5.3 unit, from `5.6.19-freq`.** It came back on
the network in about 25 seconds and the desktop came up: `lightdm` active,
`Xorg` running, `card0-DSI-1` and `card0-HDMI-A-1` present, the SGX module
loaded, both backlights alive.

Both processors enumerate, with the carveouts bound:

    omap-rproc 44000000.ocp:dsp: assigned reserved memory node dsp-memory@95000000
    remoteproc remoteproc0: 44000000.ocp:dsp is available
    omap-rproc 55020000.ipu: assigned reserved memory node ipu-memory@95800000
    remoteproc remoteproc1: 55020000.ipu is available

    remoteproc0: name=44000000.ocp:dsp  state=offline  firmware=omap5-dsp-fw.xe64T
    remoteproc1: name=55020000.ipu      state=offline  firmware=omap5-ipu-fw.xem4

`device/pyra-m4-check.sh` gives **13 ok, 0 failed** — the first exercise of the
branches that had never run.

**The carveouts cost nothing at rest.** Both are `reusable`, so they come up as
CMA pools the page allocator can still use:

    Reserved memory: created CMA memory pool at 0x95000000, size 8 MiB
    Reserved memory: created CMA memory pool at 0x95800000, size 56 MiB

and `CmaTotal` goes from 65 536 kB on `5.6.19-freq` to 131 072 kB here — the
global 64 MB plus these two — with `MemTotal` and free memory unchanged in
practice. Reserving 64 MB for the processors does not take 64 MB from the
system until something claims it.

No IOMMU faults, no L3 errors, and no new warnings in `dmesg` beyond the
`hwmod` / `ti_abb` / dummy-regulator noise this machine prints on every kernel.

**What this does not show.** Nothing has been *run on* the M4s. They are
enumerated and idle. The IOMMU is configured but never exercised, because that
happens when firmware loads.

---

## Running code on them

**2026-09-20. Both Cortex-M4s execute.** The firmware is
`experiments/m4-ipu/firmware/`, about 900 bytes of code built with plain
`arm-none-eabi-gcc`, and this is what it puts in
`/sys/kernel/debug/remoteproc/remoteproc1/trace0`:

    pyra-m4-hello: running on the OMAP5432 IPU (2 x Cortex-M4)
    text carveout da=0x00000000 len=0x00100000
    trace da=0x00002368 len=4096
    core0: state=alive beats=0000000247
    core1: state=alive beats=0000000247

`sudo ./device/pyra-m4-run.sh omap5-ipu-fw.xem4` installs it, starts the IPU,
checks it, stops it and removes the firmware again.

### Why those five lines are evidence and not decoration

Three separate claims, each of which can be got wrong in a way that still
produces output:

**The M4 wrote this, not the loader.** The buffer lives in `.bss`, so it is not
in the ELF file at all. The single `PT_LOAD` segment has `filesz 0x368` and
`memsz 0x3368`, and `rproc_elf_load_segments()` memsets the difference to
zero — so the buffer is zero at every boot and anything in it came from a core.
`pyra-m4-verify.sh` asserts the buffer's address is past `filesz`, because a
firmware that shipped the text in the file would make the on-device test pass
against a dead processor. That assertion is negative-tested against a
deliberately broken build.

**It is still executing.** The counters are sampled a second apart and must
have advanced. This too is negative-tested: a variant that writes the banner,
writes one beat and then spins forever passes every text check and fails on the
counter, which is exactly the point.

**Both M4s are running.** `core1`'s counter is only ever touched by the second
core. The device tree asks for both — `resets = <&prm_core 0>, <&prm_core 1>`
are RM_IPU_RSTCTRL bits 0 and 1, CPU0 and CPU1 — and nothing else in this
repository would have noticed if only one came up. TI meets the same problem
and answers it with `BIOS.smpEnabled = true`; this firmware answers it by
having the first core to arrive claim the name "core 0", which is safe because
`omap_reset_deassert()` polls RSTST to completion before the second reset line
is written.

The IOMMU was exercised for the first time here, and reported no fault: the
only thing mapped at device address 0 is the carveout, so the firmware running
at all is itself proof the translation worked.

### What it found: an upstream iommu bug

Starting the IPU produces two `BUG: scheduling while atomic` splats, every
time, with identical preempt counts:

    BUG: scheduling while atomic: pyra-m4-run.sh/6110/0x00000003
      usleep_range  <- sleeps
      omap_reset_deassert
      sysc_runtime_resume
      __pm_runtime_resume
      omap_iommu_attach_dev  <- holds two spinlocks
      iommu_attach_device
      rproc_boot

`omap_iommu_attach_dev()` takes `spin_lock(&omap_domain->lock)`,
`omap_iommu_attach()` takes `spin_lock(&obj->iommu_lock)`, and inside both
`iommu_enable()` calls `pm_runtime_get_sync()` — which here resumes the MMU's
ti-sysc target module, deasserts its hardreset line, and polls RSTST with a
`usleep_range`. The second splat is a consequence of the first:
`schedule_debug()` forces the count to 1, the two `spin_unlock()`s then take it
to −1, and that is the `0xffffffff` in the second report.

**This is not something `0009`–`0011` introduced.** Mainline today is
character-for-character identical: both locks are still spinlocks and
`iommu_enable()` still calls `pm_runtime_get_sync()` between them. What the
Pyra's config changes is only whether anyone is told — `CONFIG_PREEMPT=y` and
`CONFIG_SMP=y`, so `preempt_count` is maintained and `schedule_debug()`
notices. A `PREEMPT_NONE` vendor kernel sleeps under the same held locks and
says nothing. An OMAP5 or DRA7 that never attaches an IOMMU domain to the IPU
or DSP never reaches the code; `0010` and `0011` are what make it reachable
here.

`0012-iommu-omap-do-not-sleep-while-holding-the-iommu-spinlocks.patch` converts
both locks to mutexes, which is safe because every site that takes either one
is already a sleeping path — `omap_iommu_attach()`, `omap_iommu_detach()`,
`omap_iommu_attach_dev()`, `omap_iommu_detach_dev()`, and that is the complete
list. Neither lock is touched by `iommu_fault_handler()` or by the map/unmap
paths.

**Built and booted on 2026-09-20, and it works.** Both splats are gone across
two start/stop cycles, the test goes from 10 ok / 1 failed to **11 ok, 0
failed**, and the only `WARNING` left in the log is the `omap_l3_noc` one this
machine prints at t=2.5 s on every kernel including stock. Starting the IPU
also got quicker — 8 ms from `powering up` to `is now up`, against about
108 ms before, because the boot no longer goes through `__schedule_bug`
twice.

### And a test that lied

The first version of `pyra-m4-run.sh` reported **"10 ok, 0 failed"** straight
through both of those splats. It grepped the kernel log for
`remoteproc|ipu|iommu|mmu`, and a backtrace does not repeat the subsystem name
on every line — the only line that matched was the `Modules linked in:` dump,
which looks like noise. It now checks for `BUG:` and `WARNING:` by line prefix,
separately from anything topical.

That is the fourth defect found in these tests by attacking them rather than
running them, and the pattern in all four is the same: the check that never
fires is the one to distrust. Two of them were found this way in a single
afternoon — the `memsz > filesz` assertion above was the third, and it passed
against a firmware built specifically to violate what it claimed to check.

---

## The other route: letux 7.x already has all of this

**Corrected 2026-09-20, after the backport was built.** The first pass
concluded that whether a newer letux tree existed "could not be checked",
because `git.goldelico.com` serves a placeholder page. That was a failure of
searching, not a fact about the world: **the tree is mirrored on GitHub at
`goldelico/letux-kernel`**, it has about 2 480 branches, and it is at
**letux-7.3-rc3**. It tracks mainline closely and is actively maintained.

Read out of `letux-7.3-rc3`:

| | |
| --- | --- |
| `drivers/remoteproc/omap_remoteproc.c` | 37 614 bytes — the DT driver, not the 6 448-byte stub |
| `ipu`/`dsp` in `omap5.dtsi` | both present |
| this machine's board file | `omap5-letux-cortex15-v5.3+pyra-v5.3.dts`, present |
| `drivers/gpu/drm/pvrsgx/` | present, including `1.14.3699939` — the version this card's DDK blob wants — and newer |

So **patches `0009` and `0010` are unnecessary on letux 7.x.** They exist to
put into 5.6.19 what that tree already has.

Two things survive the move, and they are the two findings that were actually
this project's own rather than upstream's:

- **`0011` is still needed.** No letux board file enables the two processors —
  checked across `omap5-letux-cortex15-v5.3+pyra-v5.3.dts`, its parents,
  `pyra-mainboard-*.dtsi` and `omap5-board-common.dtsi`, and none of them
  mentions `&ipu`, `&dsp` or `reserved-memory`. Upstream only ever enables them
  on `omap5-uevm`. The carveouts and the enablement stanza still have to be
  written.
- **The timer trap is still there.** `pyra-display.dtsi` in letux 7.3 still
  puts `pwm9` on `timer9` and still feeds the panel backlight from it, so
  copying `omap5-uevm.dts`'s timer properties is just as wrong at 7.3 as at
  5.6.19.

### Which route to take

Not the same question as "which kernel is newer", and the backport is not
obviously the loser.

**The backport keeps one variable.** `5.6.19-m4` is this project's known-good
kernel plus four patches. Everything `docs/` says about the display, the SGX,
suspend, the nubs, the thermal behaviour and the governor still holds, because
it is the same kernel. If the M4s misbehave, the M4s are what changed.

**letux 7.x changes everything at once.** It is eighteen months of kernel
between this machine's known behaviour and the new one, and this repository's
entire display and GL stack is characterised against 5.6.19: the `omapdrm`
modeset race in `troubleshooting.md`, the six patches in `patches/`, the DDK
blob the card's userspace links against, the `armsoc` X driver ABI. The SGX
driver being in-tree at the right version is a good sign and nothing more —
**letux 7.3 has never been booted on this unit, and neither has any letux
kernel.** Finding out is its own project, and a considerably larger one than
the four patches here.

The honest ordering: if the goal is to try the M4s, build `kernel-m4` and keep
every other variable fixed. If the goal is to modernise the Pyra's kernel, that
is a separate piece of work with its own risks and its own payoff, and the M4
support arriving free is a side effect of it rather than a reason for it.

---

## A *useful* firmware: this is the actual work, and it is not done

The test firmware above proves the path works; it does not do anything. A
firmware that earns its keep needs the mailbox, rpmsg and a message protocol,
and none of that has been built. This section is about where that comes from.

A kernel that probes gets you `/sys/class/remoteproc/remoteproc0/` and nothing
else. Writing `start` to it looks for `omap5-ipu-fw.xem4` in `/lib/firmware`,
and there was no such file on this machine: `/lib/firmware/ti/` holds three
entries, all audio codecs and a VPDMA blob, and nothing OMAP5 anywhere else.
Debian does not package it. Whether TI's own `ti-linux-firmware` carries a
prebuilt one is still unchecked — `git.ti.com` does not respond from here — but
it no longer matters much, because the sources to build one are now cloned
locally. See option 1.

### The RPMsg guide in Downloads is for the wrong silicon

`RPMsg_Quick_Start_Guide.html` is the right *framework* and the wrong *device*.
It is written for the **PRUs** on Sitara parts — AM335x, AM437x, AM572x, K2G —
which are 200 MHz RISC cores programmed with TI's separate PRU code generation
tools, using `pruss_remoteproc` and `rpmsg_pru`. None of the device specifics
transfer: not the firmware names, not the compiler, not the drivers, not the
`/dev/rpmsg_pru30` character devices.

What does transfer is the shape: remoteproc loads an ELF, virtio and rpmsg ride
on top, and you talk to the core through a character device. That part is
accurate and worth reading for the model.

### Option 1: TI's own IPC, from the real repositories

**Updated 2026-09-20.** The first pass could not reach `git.ti.com` and fell
back on stale GitHub mirrors. The repositories have since been cloned locally
to `~/git/dragonbox-pyra-m4-work/`, and they are both newer and more useful
than anything the mirrors showed:

| clone | origin | last commit |
| --- | --- | --- |
| `ipcdev` | `git.ti.com/git/ipc/ipcdev.git` | **2024-04-04** |
| `ipc-examples` | `git.ti.com/git/ipc/ipc-examples.git` | 2019-12-04 |
| `ipc-metadata` | `git.ti.com/git/ipc/ipc-metadata.git` | 2020-02-04 |
| `ludev` | `git.ti.com/git/ipc/ludev.git` — LinuxUtils 4.0, CMEM | 2021-04-22 |
| `luppa` | `git.ti.com/git/ipc/luppa.git` — CMEM packaging | 2015-06-26 |

`ipcdev` at 2024 is a decade newer than `Hashcode/ipcdev` (2014), and OMAP5 is
a first-class platform in it, not a leftover. `ipc-bios.bld` maps
`PLATFORM=OMAP54XX` to `ti.platforms.sdp5430:IPU` for the M4 target and
`ti.platforms.sdp5430:DSP` for the C66x, and `products.mak` already has the
`ti.targets.arm.elf.M4` slot to point at a compiler.

**This is the general-purpose path, and it is the one to take.** `ipc-examples`
has `ex01_hello`, `ex02_messageq`, `ex11_ping`, `ex12_mmrpc` and others as XDC
templates, and its makefile still carries live OMAP5 rules:

    OMAP54XX_linux_elf: OMAP54XX_linux_elf_ex12_mmrpc
    OMAP54XX_linux_elf: OMAP54XX_linux_elf_ex02_messageq

Note that `OMAP54XX_linux_elf` is **commented out of the `release:` target**
while DRA7XX and AM572X are not, so OMAP5 is carried rather than tested. The
rules themselves are intact; expect to fix things nobody has run since 2019.

**The AMMU is not the obstacle I said it was.** The first pass called the
unicache AMMU bring-up "the part nobody hands you". It is handed to you:
`ex02_messageq/slave/` contains `IpuAmmu_omap5.cfg`, 176 lines of OMAP5-specific
AMMU programming — small pages, the 64 KB L2RAM mapped as four 16 KB pages
translating VA `0x20000000` to PA `0x55020000`, write-back and cache policy per
page — alongside `IpuAmmu_dra7xx.cfg` and the matching `DspAmmu.cfg`. There are
also resource tables: `ipcdev/packages/ti/ipc/remoteproc/rsc_table_omap5_ipu.h`
and `rsc_table_omap5_dsp.h`.

**The carveout in `0011` is the right size, and that is not luck.** The
canonical `rsc_table_omap5_ipu.h` asks for three `TYPE_CARVEOUT` regions:

| region | size |
| --- | --- |
| `IPU_MEM_TEXT` | 6 MB |
| `IPU_MEM_DATA` | 48 MB |
| `IPU_MEM_IPC_DATA` | 1 MB |
| **total** | **55 MB** |

against the 56 MB `ipu_memory_region` — upstream's `omap5-uevm.dts` figure was
chosen for exactly this table. It also hard-codes `PHYS_MEM_IPC_VRING` to
`0x95800000`, the same base `0011` uses. Worth knowing that
`ex41_forwardmsg` carries its own copy of the table with `IPU_MEM_DATA` at
**156 MB**, which would not fit; check the table before assuming the carveout
is big enough.

**Two things that are not resolved**, and should be expected to bite:

- The tables carry `TYPE_DEVMEM` entries at fixed physical addresses,
  `PHYS_MEM_IOBUFS` at `0xBA300000` among them. Nothing in `0011` reserves
  that, and on a 4 GB Pyra it is ordinary RAM the kernel will hand out.
  Whether the non-multimedia examples touch it has not been checked.
- These tables and configs were written against TI's own downstream kernel,
  not upstream's v5.9 remoteproc. Whether they load unmodified is exactly the
  kind of thing that cannot be settled by reading, only by trying.

### Option 1b: MobiAqua, if the goal is video decode

**MobiAqua** maintains forks of the same stack, still active — repositories
pushed in 2024, 2025 and 2026 — and `mobiaqua/ti-ducati-fw` is a build script
with a ready OMAP5 target:

    TARGET=ti.targets.arm.elf.M4
    PLATFORM=OMAP54XX
    HW_TYPE=OMAP5
    HW_VER=ES20
    OUTEXT=xem4
    OUTNAME=omap5-ipu-fw

producing `omap5-ipu-fw.xem4`, precisely the filename the device tree asks for.
It fetches its own dependencies and its own toolchain, **both of which were
verified live on 2026-09-20** — the real risk with a 2020-vintage stack:

| | | |
| --- | --- | --- |
| XDCtools `3_62_00_08` | `HTTP 200`, 100 658 936 bytes | `software-dl.ti.com` |
| TI CGT ARM `20.2.7.LTS` | `HTTP 200`, 45 845 018 bytes | `dr-download.ti.com` |

It builds **IPUMM**, the multimedia firmware: video decode driving the IVA-HD.
That is an application, not a blank slate. Take this route if the goal is the
video decode use case; take option 1 if the goal is running your own code.
Either way the toolchain is the same, and `ti-ducati-fw` is the easier way to
obtain it.

#### What video decode would actually take (surveyed 2026-09-24)

These repositories are cloned: fifteen MobiAqua repositories plus `yocto` in
`~/git/dragonbox-pyra-m4-work/mobiaqua/`, alongside the TI clones. Nothing
below has been run. It comes from reading the source, and from `readelf` and
`strings` on the firmware binary.

**The firmware exists prebuilt.** MobiAqua's yocto tree carries
`meta-ti/recipes-bsp/libdce/libdce-firmware/omap5-ipu-fw.xem4` (3.7 MB,
committed 2024-05-31). Its version block reads `IPUMM commit 3783a4c version
MMIP 3_00_15_00 IPC 3_50_01_00`. It links these codecs:

| decode | encode |
| --- | --- |
| H.264 `02.00.22.01`, MPEG-4 `01.00.17.01`, MPEG-2 `01.00.18.01`, VC-1 `01.00.02.08`, MJPEG `01.00.16.01` | H.264 `02.00.09.01`, MPEG-4 `01.00.02.01`, MJPEG `01.00.17.01` |

There is no HEVC, VP8, VP9 or AV1. The IVA-HD predates them all. Its ceiling
is 1080p30 H.264.

**The catch: MobiAqua ships none of this on OMAP5.** Their machines are
`panda` (OMAP4), `beagle` (AM57xx), `beagle64` and `igep0030`. The recipe's
`do_install` exists only for `panda` and `beagle`. The OMAP5 image gets built
because `ti-ducati-fw` loops over three targets, and there is no evidence
anyone has ever booted it. Treat it as untested. If it needs rebuilding, the
toolchain URLs checked above still work.

**What the firmware demands of the kernel**, from
`ti-ipumm/platform/ti/dce/baseimage/custom_rsc_table_omap5_ipu.h`:

- **Carveouts:** 6 MB text, 43 MB data and 1 MB IPC data, 50 MB in all. That
  fits `0011`'s 56 MB region.
- **`IPU_MEM_IOBUFS`:** a `TYPE_DEVMEM` covering **90 MB at fixed PA
  `0xBA300000`**. On a 4 GB Pyra that is ordinary RAM, so it **must** get a
  `no-map` `reserved-memory` node. Otherwise the IPU writes over live kernel
  pages. This is the single most important thing to get right.
- **`IPU_MEM_IPC_VRING`:** a `TYPE_DEVMEM` covering 1 MB at `0x95800000`. That
  is the start of `0011`'s CMA pool, so it would alias memory the pool hands
  out. The vrings themselves are `FW_RSC_ADDR_ANY` since MobiAqua's
  "dynamic vring" commit, so this mapping may be dead weight. Check it before
  trusting it.
- **Peripheral windows:** direct mappings of L4CFG (which includes the PRCM),
  L4PER, L4EMU, the IVA-HD config and SL2, the DMM, and the three TILER
  apertures.
- **IVA-HD power:** the firmware brings up the IVA-HD itself. `ivahd.c` writes
  `RM_IVAHD_RSTCTRL`, `CM_IVAHD_CLKSTCTRL` and `CM_IVAHD_CLKCTRL` directly, so
  no kernel IVA driver is needed. The risk is that the kernel's own PM code
  powers the IVA domain back down under it. On OMAP4, MobiAqua needed
  `0011-iva-timer3-always-on.patch` for something in this area.

**Kernel patches to carry onto 5.6.19-m4.** They come from
`yocto/meta-ti/recipes-kernel/linux/linux-ti_5.10/`, the oldest and closest
set:

| patches | purpose | size |
| --- | --- | --- |
| `rpmsg-rpc/0050`–`0060` | the `rpmsg_rpc` driver: `/dev/rpmsg-dce`, the `RPPC_IOC_*` ioctls, dma-buf fd to IPU address translation including TILER stride | `0052` alone is 3 016 lines |
| `remoteproc/0001`, `0002` | `rproc_get_id()`, `rproc_pa_to_da()`, which `rpmsg_rpc` calls | small |
| `ti/0017` | restores the `OMAP_BO_MEM_*` flags in `omap_gem.c` | medium |
| `0020-restore-dmabuf-map` | puts back `dma_buf_kmap` | small |
| `ti/0014` | omap-iommu hwmod transitions | small |

That set also carries `ti/0015-iommu-omap-convert-spinlocks-to-mutexes` on 6.x,
which is independently the same fix as our `0012`. That is good confirmation
of `0012`, and it means one conflict to resolve by keeping ours. Going from
5.10 back to 5.6 is a short distance for rpmsg and remoteproc.

**Userspace is the smallest part:**

- `ti-libmmrpc` is 3 commits, and `ti-libdce` is autotools. Both build against
  the kernel's `uapi/linux/rpmsg_rpc.h`. `libdce` allocates its buffers as
  omapdrm dumb buffers and exports them as dma-buf.
- **The player is the real limit.** In `mpv-mini`, `vd_omap_dce.c` decodes
  (1 169 lines) and `vo_drm_omap.c` displays (665 lines). The output is
  **KMS-only**: atomic commits and `drmModeSetPlane` onto an overlay plane. It
  needs DRM master, so **it cannot run under X**. On the Pyra that means a VT
  switch away from X, the way the game-mode launcher would start it.
  `mplayer-mini`'s `vo_omap_drm_egl` goes through GBM, which is also KMS-only.
- **Rotation is unsolved.** The panel is portrait and X gets landscape through
  TILER rotation. `vo_drm_omap` does not set a rotation on its video plane, and
  a rotated NV12 plane needs TILER-backed buffers, not the dumb buffers
  `libdce` allocates. Expect real work here.
- Playback inside an X window, through Xv on `armsoc` or an NV12 EGLImage on
  SGX DDK 1.14, is a separate open-ended project. Nothing here provides it.

**Estimate:**

| milestone | effort | main risks |
| --- | --- | --- |
| firmware boots, `/dev/rpmsg-dce` appears | 3–6 evenings | the patch backport; reserved memory; a first-ever boot of this firmware image |
| a decoded frame lands in memory (`libdce` test) | 2–5 evenings more | IVA-HD power fighting the kernel PM; TILER address translation |
| full-screen playback with `mpv-mini` from a VT, correctly rotated | 1–2 weeks more | rotation; plane format support on DISPC |
| playback inside X | open-ended | Xv or EGL import against a closed DDK |

**Realistically that is 3–5 weeks of evenings to watch a correctly rotated
H.264 file from a console.**

**Weigh it against software decode.** Two A15s at 1.5 GHz decode 720p H.264,
the panel's native resolution, in software with FFmpeg's NEON paths. That is
unmeasured on this unit but well inside what the core does elsewhere, and it
works under X today. Hardware decode would buy battery life and 1080p
headroom, but only for H.264, MPEG-2/4 and VC-1 content, and only outside X.
Most web video is now VP9 or AV1, which the IVA-HD cannot touch. **Measure
software decode first** with `mpv --hwdec=no` on a 720p H.264 file, reading
CPU load and `bq27421` current. Only if that disappoints is this project
worth starting.

### Option 2: bare metal — done, and it works

remoteproc will run a bare-metal ELF; all it requires is a `.resource_table`
section. `experiments/m4-ipu/firmware/` is one, it is about 900 bytes of code,
it builds with the `arm-none-eabi-gcc` any distribution ships, and **both M4s
run it**. See "Running code on them" above.

**An earlier version of this section said you would still have to program the
AMMU. That was wrong, and the firmware disproves it.** The reasoning that
replaces it: the M4s fetch their vector table from logical address 0 *through*
the AMMU, and SYS/BIOS's own AMMU-programming code is itself code at a low
logical address, so large page 0 — logical `0x00000000`, 512 MB, translation
disabled — cannot require programming or nothing could ever boot. TI's
`IpuAmmu_omap5.cfg` only adds cacheability to it. A firmware that stays inside
`0x00000000..0x1fffffff` and leaves the unicache off therefore needs no AMMU
work at all, and the cache being off is also why Linux sees its writes without
any flushing.

The AMMU does come back the moment you want a peripheral, because the reset
window does not cover the mailbox at `0x4a0f4000`. That has a way round it too:
a `TYPE_DEVMEM` resource can map `da 0x10000000 -> pa 0x4a0f4000`, and the
AMMU passes the low device address straight through to the IOMMU. So the AMMU
is avoidable for longer than this document previously claimed, and TI's
configuration is there for when it is not.

### Not a route: uClinux on the M4s

`EmcraftSystems/linux-emcraft` is uClinux **2.6.33** for Cortex-M3 and M4, and
it answers a different question: it runs Linux *on* an M-core as that chip's
only OS. Its machine ports are `mach-stm32`, `mach-kinetis`, `mach-lpc178x`,
`mach-lpc18xx`, `mach-a2f` and `mach-m2s` — standalone microcontrollers with
their own boot path and their own external RAM. There is no OMAP IPU port and
writing one would mean booting a subsystem that has no bootloader, because it
is started by remoteproc from the host.

It is also the wrong shape for what these cores are. The IPU has 64 KB of local
RAM; anything else is DDR reached through the AMMU and the IOMMU, which the M4
must program before any kernel could run — so the hard part does not go away,
it just arrives before a 2010 kernel instead of before a firmware image. And it
would take the IPU *away* from the A15 Linux rather than offering it: no
mailbox link, no rpmsg, no trace buffer, no coredump, none of which remoteproc
charges for.

Worth knowing it exists. Not worth pointing at this SoC.

### JTAG

The other path, and the expensive one. OMAP5 needs an XDS110/XDS200-class
emulator and Code Composer Studio; a plain FTDI cable is not an OMAP5 JTAG
probe. Whether the Pyra mainboard even exposes usable JTAG pads was not
investigated. Note that remoteproc gives you the firmware's trace buffer and a
coredump on crash without any of this, which covers most of what JTAG would be
wanted for.

---

## Assessment: probably not worth it, and here is why

The kernel half is genuinely cheap — a small, low-risk patch, now proven on
hardware end to end: both M4s run code, the IOMMU translates, and the carveouts
cost nothing at rest. It does carry one debt that was invisible until something
actually started the IPU, an upstream `omap-iommu` sleep-under-spinlock; `0012`
fixes it in twenty lines, and that fix is built and booted too.

**Getting a bare-metal program running turned out to be much cheaper than this
document first estimated**, because the AMMU does not need programming for code
that stays inside its reset window. That is a real reduction in the work, and
it is worth being clear about what it does *not* reduce: a program that only
writes to its own memory is a long way from one that talks to Linux.

The firmware half got cheaper once TI's own repositories were in hand. It is
no longer "write AMMU bring-up against a TRM nobody has": OMAP5 is a supported
platform in `ipcdev`, the AMMU configuration and the resource tables are
written, and the carveout in `0011` is already the right size for them. What is
left is a 2019-era XDC/SYS-BIOS build that upstream carries without testing on
this platform, against a kernel driver from a different lineage than the one
those tables were written for. That is an ordinary unpleasant porting job
rather than a research problem — but it is still a job, and none of it has been
built, let alone run.

**What the M4s cannot do for this project.** Two cores somewhere between 200
and 425 MHz, behind an IOMMU, with 64 KB of fast local RAM and everything else
across a cached carveout, will not help box86, gl4es, X rendering, or any game.
They are not general-purpose compute you can throw work at. Nothing in
`improvements.md` gets faster because of them.

**What they might plausibly do.** One thing, and it needs measurement first:

- **Video decode.** Option 1's firmware already exists and does exactly this.
  This is the one path where the work is mostly already written.

There used to be a second entry here — low-power background offload, to let the
A15s idle deeper — carried as "plausible, but unmeasured". **It is now refuted,
and not for want of measuring it.** The next section is why.

If video decode is not the goal, this is a curiosity.

### Why the M4s cannot buy the A15s a deeper sleep

Asked on 2026-09-20: could an M4 take over background work so the A15s reach a
deeper idle state, the way a microcontroller does on other SoCs? No — and it
fails twice over, on two independent grounds. This is read out of the kernel
tree rather than measured, because both are topology facts with nothing to
measure.

**The M4s are in the wrong power domain.** The IPU is not an island:

    /* arch/arm/mach-omap2/clockdomains54xx_data.c */
    static struct clockdomain ipu_54xx_clkdm = {
            .name   = "ipu_clkdm",
            .pwrdm  = { .name = "core_pwrdm" },

It sits inside CORE, and its 64 KB of L2 RAM is not even its own memory — it is
a retention bank of the CORE power domain, next to the unicache:

    /* arch/arm/mach-omap2/powerdomains54xx_data.c */
    static struct powerdomain core_54xx_pwrdm = {
            .pwrsts         = PWRSTS_RET_ON,
            .pwrsts_mem_ret = {
                    [3] = PWRSTS_OFF_RET,   /* ipu_l2ram    */
                    [4] = PWRSTS_OFF_RET,   /* ipu_unicache */

So an executing M4 pins CORE at ON, which holds the L3 interconnect clocked;
and because only 64 KB is local, any real workload reaches DDR across the AMMU
and the IOMMU, which holds EMIF out of self-refresh. The offload would burn the
expensive half of the chip in order to run the cheap half. The same fact kills
the other shape of the idea — an M4 left running as a wakeup source across a
suspend — since CORE cannot reach RET while the IPU is in it.

TI did build the part this idea wants; it is just not this one. On AM335x the
power-management coprocessor sits in the always-on domain with its own SRAM:

    /* arch/arm/mach-omap2/omap_hwmod_33xx_data.c */
    .clkdm_name = "l4_wkup_aon_clkdm"

    /* arch/arm/boot/dts/am33xx.dtsi */
    wkup_m3: wkup_m3@100000 {
            compatible   = "ti,am3352-wkup-m3";
            reg-names    = "umem", "dmem";
            ti,pm-firmware = "am335x-pm-firmware.elf";

That M3 stays alive while everything else including DDR goes down, which is the
whole trick, and precisely what a coprocessor inside CORE cannot do. Ducati is
a media accelerator that happens to be a CPU.

**And there is no deeper A15 state to unlock in the first place.** This machine
idles in exactly one state, `C1 — CPUx WFI, MPUSS ON`. The retention state
below it is `#if 0` in this kernel tree, and `experiments/c2-idle/` has already
tried switching it back on: it works exactly as advertised, the governor
reaches for it constantly — and **the machine hangs within two minutes**, twice
out of two attempts. `docs/improvements.md` item 12 has the detail.

That is the part that settles it. Offload cannot deepen a state that is
unreachable, so the M4 can only ever be *additive*: the A15s go on paying
MPU-ON no matter what the M4 does, and the IPU's CORE-domain draw is added on
top of that. There is no trade here, only a second bill.

**A third reason, smaller but real: there is nothing left worth moving.** The
duties anyone would hand to a microcontroller already live in dedicated silicon
with interrupt lines — `ti,tca8418` scans the key matrix in hardware,
`ams,as5013` for the nubs (whose interrupt is unusable on this board, so they
are polled — but by the A15s at 2–3% of one core), `ti,bq24297` for charging, `ti,bq27421` for the fuel
gauge, `ti,tca6424` for GPIO, all in `pyra-mainboard-common.dtsi`. They draw
microamps and keep working with the OMAP powered down. An M4 in CORE cannot
compete with a 400 µA I²C part.

**If some future power claim about the IPU does need settling**, the instrument
is the fuel gauge — `/sys/class/power_supply/bq27421-0/current_now`, which
`pyra-idle-profile.sh` and eight other scripts already read. It measures the
whole battery, which is the right granularity for "does this cost more than it
saves".

An earlier draft of this section pointed at the board's `ti,ina231` instead,
calling it the power monitor to reach for. That was wrong twice over and is
worth recording, because the mistake is an easy one to repeat. The device tree
calls it what it is — `/* modem current sensor */` — so it watches the Gemalto
PLS8 rail and cannot see the SoC at all. And on this unit it cannot be read
even for that: the driver is correct and the device instantiates, but probe
fails with `error configuring the device: -121`, `-EREMOTEIO`, because no modem
is fitted, the rail is down, and the sensor is powered from the rail it
measures. `device/pyra-modem-power.sh` has the full diagnosis.

---

## What has not been verified

Stated plainly, because everything above is either measured or built and these
are neither:

- ~~**Nothing has run on hardware.**~~ **Booted on 2026-09-20**; see "The first
  boot" above. Both processors enumerate and sit `offline`.
- ~~**There is no firmware, so nothing has been run on the M4s.**~~ **Both
  cores ran code on 2026-09-20**; see "Running code on them" above. What is
  still untested is everything a *useful* firmware needs: the mailbox, rpmsg,
  MessageQ, and anything at all on the DSP.
- ~~**A misprogrammed IOMMU on this SoC can wedge the L3 interconnect.**~~ The
  IOMMU has now been programmed from a resource table and used, with no fault
  and no L3 error. The warning still stands for firmware that reaches outside
  its carveout, which this one deliberately does not.
- ~~**`0012` is compile-tested, not booted.**~~ **Built and booted on
  2026-09-20**; the splats are gone and the test is clean. What is still
  unknown is whether any *other* caller of `iommu_attach_device()` in the tree
  is in atomic context, which the mutex conversion would now catch. Nothing on
  this machine is — the only iommu domains here belong to the ipu and the dsp.
- **The clock rates are gate clocks**, not confirmed core rates. See above.
- **`git.ti.com` still does not respond from here**, so nothing was checked
  against it directly. That gap is now mostly closed a different way: the
  repositories are cloned under `~/git/dragonbox-pyra-m4-work/` and option 1 is
  written from those working copies, not from mirrors.
- **Nothing in the TI stack has been built.** Option 1 is read out of
  makefiles, `.bld` files and resource tables. `OMAP54XX_linux_elf` is carried
  but not in the examples' `release:` target, so it has not been exercised
  upstream since 2019 either; expect breakage, and expect the fixed-address
  `TYPE_DEVMEM` entries to need attention.
- **Nothing about the letux route has been booted either.** Its state was read
  out of the tree, not run.

---

## The tests

Three scripts, because the halves fail in different places.

    ./pc/pyra-m4-verify.sh            # the patches, the built tree and the
                                      # firmware, on a PC
    ./pc/pyra-m4-verify.sh --patches  # patches and firmware only, no build
    ./device/pyra-m4-check.sh         # the running machine, read-only
    sudo ./device/pyra-m4-run.sh omap5-ipu-fw.xem4   # actually start the IPU

`pyra-m4-verify.sh` asserts the findings in this document against the patch
set and the built artifacts: the three compat fixes are still in `0009`, both
processors are `okay` in the compiled DTB, `OMAP_REMOTEPROC` is still `m`, and
the two that the file mostly exists for —

- **no timer property on `ipu` or `dsp`**, checked both in `0011` and in the
  compiled blob, where the assertion is that the *only* two `ti,timers` in the
  whole tree are `pwm8` and `pwm9`;
- **the carveout still covers the resource table**, read live out of
  `ipcdev/packages/ti/ipc/remoteproc/rsc_table_omap5_ipu.h` when TI's clones
  are present. Today that prints `table wants 55 MB: text 6, data 48, ipc 1;
  carveout is 56 MB`.

It also checks the test firmware, where the load-bearing assertion is that the
trace buffer's address is past the segment's `filesz` — i.e. that it is
zero-filled by the loader rather than carried in the file, which is the entire
basis for "an M4 wrote this".

It needs `dtc`, and falls back to a container when the PC has none, because
those are the assertions worth having. **30 ok, 0 failed** on 2026-09-20.

**Both of its load-bearing assertions were negative-tested**, which is the only
way to know an assertion is wired up: reintroducing `omap5-uevm.dts`'s
`ti,watchdog-timers = <&timer9>, <&timer11>` and shrinking the carveout to
16 MB each produce a `FAIL` and a non-zero exit. That found a real bug — the
first version of the timer check matched the patch's own comment explaining
why the property is absent, and so failed a correct patch. A second bug was
worse: an unparseable carveout size printed a shell error and was counted as
neither pass nor fail, so the check silently did not run while the script still
reported success.

The firmware assertion was negative-tested the same way, and it failed the
test. The first version checked `memsz > filesz`, which sounds right and is
not: a build that deliberately moved the trace buffer into the file still
passed, because `.bss` merely shrank rather than vanishing. It now checks the
buffer's own address against `filesz`, and that version does fail the broken
build.

`pyra-m4-check.sh` reports the machine's state and changes nothing; it never
writes a remoteproc `state` file. It is safe on the stock kernel and detects
that case rather than failing, so it can be run before and after installing
`5.6.19-m4` and the outputs compared. Run on `5.6.19-freq` on 2026-09-20 it
gives **10 ok, 0 failed, 1 skipped**: both IOMMUs bound, the mailbox and both
channels present, both backlights alive, no `ipu` node and no
`/sys/class/remoteproc`, and the two clock rates quoted at the top of this
document reproduced independently.

On `5.6.19-m4` it gives **13 ok, 0 failed**, which was the first exercise of
the branches that had never run: the per-processor `name`/`state`/`firmware`
reporting and the assertion that there are two remoteproc devices.

`pyra-m4-run.sh` is the only one of the three that changes anything. It
installs the firmware, starts the IPU, samples the trace buffer twice, stops
the processor and **removes the firmware again** — not tidiness: `auto_boot` is
true, so a file left in `/lib/firmware` starts both M4s during every boot with
nothing typed. `--keep` opts into that, and
`modprobe.blacklist=omap_remoteproc` is how to take it back.

It was negative-tested against a firmware built to write the banner and then
stop, which passes every text check and fails the counter check, and it is
what caught the `scheduling while atomic` splats — after its first version
reported success through them. On the kernel with `0012` it gives **11 ok, 0
failed**.

---

## Reproducing the survey

Everything in the "what state it is in today" section, on the device:

    ssh pyra@<addr>
    cat /sys/bus/soc/devices/soc0/*                    # OMAP5432 ES2.0 GP
    ls /sys/class/iommu/                               # both MMUs, already bound
    ls /sys/class/remoteproc/                          # ENOENT, as expected
    zcat /proc/config.gz | grep -E "REMOTEPROC|RPMSG|OMAP2PLUS_MBOX|OMAP_IOMMU"
    sudo grep -E "ipu_cm|dsp_cm" /sys/kernel/debug/clk/clk_summary
    find /sys/firmware/devicetree/base -iname "*mailbox*"   # NOT /proc/device-tree

And the kernel side, on the PC:

    ./pc/pyra-crossbuild.sh kernel-m4

---

## Sources

Kernel:

- [`remoteproc/omap: Add device tree support`, PATCHv4 series](https://lkml.kernel.org/lkml/843ca3bd-a1b8-b427-e9a1-64b079a64647@ti.com/T/)
  — Suman Anna and Tero Kristo, the work being backported
- [`e6d05acd5701 remoteproc/omap: Fix set_load call in omap_rproc_request_timer`](https://github.com/torvalds/linux/commit/e6d05acd5701)
  — the commit that proves the three-argument `set_load` form
- [`ti,omap-remoteproc.yaml` binding](https://www.kernel.org/doc/Documentation/devicetree/bindings/remoteproc/ti,omap-remoteproc.yaml)
- [v5.9 `omap5.dtsi`](https://raw.githubusercontent.com/torvalds/linux/v5.9/arch/arm/boot/dts/omap5.dtsi)
  and [v6.6 `omap5-uevm.dts`](https://raw.githubusercontent.com/torvalds/linux/v6.6/arch/arm/boot/dts/ti/omap/omap5-uevm.dts)
  — the two node sets, and the carveout template

The letux kernel:

- [`goldelico/letux-kernel` on GitHub](https://github.com/goldelico/letux-kernel)
  — the mirror. `git.goldelico.com` serves a placeholder page and is not the
  way in; this is.
- [`letux-7.3-rc3` `drivers/remoteproc`](https://github.com/goldelico/letux-kernel/tree/letux-7.3-rc3/drivers/remoteproc)
  and [its `arch/arm/boot/dts/ti/omap`](https://github.com/goldelico/letux-kernel/tree/letux-7.3-rc3/arch/arm/boot/dts/ti/omap)
  — the driver and the Pyra board files, for checking the table above
- Note that `work/hns/pyrav5` is a **4.4.0-rc6** work branch and carries the
  same dead stub 5.6.19 does; it is older than this machine's kernel, not
  newer. Branch names in that tree do not imply recency.

Firmware:

- `~/git/dragonbox-pyra-m4-work/` — local clones of TI's own `ipcdev`,
  `ipc-examples`, `ipc-metadata`, `ludev` and `luppa` from `git.ti.com`, which
  does not respond from this network. **Start here**, and specifically at
  `ipc-examples/src/examples/templates/ex02_messageq/slave/IpuAmmu_omap5.cfg`
  and `ipcdev/packages/ti/ipc/remoteproc/rsc_table_omap5_ipu.h`.
- [`mobiaqua/ti-ducati-fw`](https://github.com/mobiaqua/ti-ducati-fw) — the
  build script with the OMAP5 target; the easiest way to get the toolchain,
  and the route to take if the goal is video decode
- [MobiAqua's other forks](https://github.com/orgs/mobiaqua/repositories) —
  ti-ipcdev, ti-sysbios, ti-ipumm, ti-libdce, all still maintained
- [TI Processor SDK: IPC](https://software-dl.ti.com/processor-sdk-linux/esd/docs/06_00_00_07/linux/Foundational_Components_IPC.html)
  — the `.xem4` convention and the IPC model
- `~/Downloads/ti_processors_wiki_backup/RPMsg_Quick_Start_Guide.html` — right
  framework, wrong silicon; see above

Hardware:

- [OMAP5432 EVM user guide (SWCU130)](https://www.ti.com/lit/ug/swcu130/swcu130.pdf)
- TI's Processors Wiki was end-of-lifed in December 2020 and most OMAP5
  material is gone from ti.com. Local backups are worth keeping.

---

## See also

- `docs/m4-demo.md` — the demo kit, for running this on somebody else's Pyra
- `experiments/m4-ipu/` — the four patches, each with its reasoning in the
  header, and `firmware/`, the test program that runs on both cores
- `docs/building.md` — how `pyra-crossbuild.sh` works and why the kernel builds
  in a bookworm container
- `docs/improvements.md` — the performance work these cores do *not* help with
