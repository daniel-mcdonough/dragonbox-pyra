# The two Cortex-M4s: what they are and what it costs to use them

Written 2026-09-20, against the running unit over SSH and against the kernel
source tree that `pyra-crossbuild.sh` unpacks.

The OMAP5432 has two Cortex-M4 cores that this machine has never started. This
document says what they are, what state the shipped software leaves them in,
exactly what it takes to make the kernel see them — which was built and is in
`experiments/m4-ipu/` — and what is left after that, which is the larger half
and has not been done.

**Read the assessment at the end before starting.** The kernel side is small,
cheap and proven. The firmware side is neither, and the payoff for this
project's actual goals is thin.

**And read "The other route" before building anything.** The letux kernel is at
7.3 and already carries two of the three patches here; whether to use it is a
real choice and not a foregone one.

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
confirmed core rates.** They are what `/sys/kernel/debug/clk/clk_summary`
reports for the clkctrl gates. TI's published figure for the OMAP5 M4s is
roughly half this, which would mean an internal divider this measurement cannot
see. Treat 425 MHz as an upper bound and check the TRM before planning
anything that depends on the number.

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
variant. It is the fix set from `patches/` plus the three patches below plus
seven config symbols.

`OMAP_REMOTEPROC` is set to `m` rather than `y` on purpose. Built in, it probes
during boot with no way to intervene; as a module, nothing goes near the IPU
until `modprobe omap_remoteproc`, and it can be unloaded again. Since getting
an IOMMU wrong here can wedge the L3 interconnect, that is the difference
between an experiment and a machine that needs the recovery path.

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
    sudo ./device/pyra-boot-kernel.sh          # choose the test slot, then reboot

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

**One thing to know before a firmware file ever exists:** `rproc_alloc()` sets
`auto_boot = true` and the omap driver never overrides it, so once
`/lib/firmware/omap5-ipu-fw.xem4` is in place, `modprobe omap_remoteproc` will
try to start the core by itself — there is no separate `start` step to think
better of. Right now the asynchronous firmware request simply finds nothing and
the core stays offline, which is why loading the module today is safe.

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
kernel plus three patches. Everything `docs/` says about the display, the SGX,
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
the three patches here.

The honest ordering: if the goal is to try the M4s, build `kernel-m4` and keep
every other variable fixed. If the goal is to modernise the Pyra's kernel, that
is a separate piece of work with its own risks and its own payoff, and the M4
support arriving free is a side effect of it rather than a reason for it.

---

## The firmware: this is the actual work, and it is not done

A kernel that probes gets you `/sys/class/remoteproc/remoteproc0/` and nothing
else. Writing `start` to it looks for `omap5-ipu-fw.xem4` in `/lib/firmware`,
and there is no such file on this machine: `/lib/firmware/ti/` holds three
entries, all audio codecs and a VPDMA blob, and nothing OMAP5 anywhere else.
Debian does not package it. Whether TI's own `ti-linux-firmware` carries one
could not be checked, because `git.ti.com` did not respond at all on
2026-09-20 — see the unverified list at the end.

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

### Option 1: TI's IPC stack, via MobiAqua

The best thing found in this investigation. **MobiAqua** maintains forks of the
whole TI IPC/SYS-BIOS stack for exactly these SoCs and is still active —
several repositories pushed in 2024, 2025 and 2026. `mobiaqua/ti-ducati-fw` is a
build script whose targets include:

    TARGET=ti.targets.arm.elf.M4
    PLATFORM=OMAP54XX
    HW_TYPE=OMAP5
    HW_VER=ES20
    OUTEXT=xem4
    OUTNAME=omap5-ipu-fw

producing `omap5-ipu-fw.xem4` — precisely the filename the upstream device tree
`firmware-name` asks for. It fetches its own dependencies (ti-sysbios, ti-ce,
ti-fc, ti-osal, ti-xdais, ti-codecs, ti-ipcdev, ti-ipumm) and downloads its own
toolchain.

**Both toolchain downloads were verified live on 2026-09-20**, which was the
real risk with a 2020-vintage stack:

| | | |
| --- | --- | --- |
| XDCtools `3_62_00_08` | `HTTP 200`, 100 658 936 bytes | `software-dl.ti.com` |
| TI CGT ARM `20.2.7.LTS` | `HTTP 200`, 45 845 018 bytes | `dr-download.ti.com` |

The caveat: this builds **IPUMM**, the multimedia firmware. It is an
application — video decode driving the IVA-HD — not a blank slate for your own
code. For arbitrary code you want the rpmsg examples in `ti-ipcdev` instead,
which the same toolchain builds.

### Option 2: bare metal

remoteproc will happily run a bare-metal ELF; all it requires is a
`.resource_table` section. The obstacle is the **AMMU**, the attribute MMU
inside the M4's unicache. It sits closest to the core, ahead of the IOMMU, and
it is **self-programmed by the M4** in its own early boot code. Code and data
regions have to be identity-mapped, because otherwise the remoteproc loader
cannot line the ELF's sections up with the IOMMU mappings the kernel
programmed for them.

That bring-up code is the part nobody hands you, and it is the reason "just
write a hello world" is not a weekend.

### JTAG

The other path, and the expensive one. OMAP5 needs an XDS110/XDS200-class
emulator and Code Composer Studio; a plain FTDI cable is not an OMAP5 JTAG
probe. Whether the Pyra mainboard even exposes usable JTAG pads was not
investigated. Note that remoteproc gives you the firmware's trace buffer and a
coredump on crash without any of this, which covers most of what JTAG would be
wanted for.

---

## Assessment: probably not worth it, and here is why

The kernel half is genuinely cheap — a small, proven, low-risk patch, mostly
costing hardware test time rather than development. The firmware half is a
2020-vintage XDC/SYS-BIOS toolchain and a codebase last touched in 2021, or
writing AMMU bring-up yourself against a TRM that TI has largely pulled from
the web.

**What the M4s cannot do for this project.** Two cores somewhere between 200
and 425 MHz, behind an IOMMU, with 64 KB of fast local RAM and everything else
across a cached carveout, will not help box86, gl4es, X rendering, or any game.
They are not general-purpose compute you can throw work at. Nothing in
`improvements.md` gets faster because of them.

**What they might plausibly do.** Two things, both needing measurement first:

- **Video decode.** Option 1's firmware already exists and does exactly this.
  This is the one path where the work is mostly already written.
- **Low-power background offload** — polling sensors, input, or an audio loop
  so the A15s can reach a deeper C-state. This connects to the `c2-idle` and
  governor experiments. But it is only a win if the IPU power domain costs less
  than the A15 residency it buys, and **that has not been measured**. It is
  entirely possible that waking a 425 MHz subsystem to avoid waking an A15 is a
  net loss.

If neither of those is the goal, this is a curiosity.

---

## What has not been verified

Stated plainly, because everything above is either measured or built and these
are neither:

- **Nothing has run on hardware.** The kernel builds; it has never been booted.
  "It probes" is an expectation, not an observation.
- **There is no firmware**, so the driver cannot be end-to-end tested at all.
  The first real test needs option 1 completed first.
- **A misprogrammed IOMMU on this SoC can wedge the L3 interconnect.** The
  failure mode for getting this wrong is not a clean error message. Have the
  recovery path from `troubleshooting.md` ready.
- **The clock rates are gate clocks**, not confirmed core rates. See above.
- **`git.ti.com` could not be reached** on 2026-09-20 — it fails to connect
  entirely, not a 404 — so TI's own `ipc/ipcdev` could not be consulted
  directly. The GitHub mirrors that do respond are stale: `Hashcode/ipcdev`
  2014, `liyaoshi/ipcdev` 2016, `bradfa/ti-ipumm` 2016. MobiAqua's forks are
  the live ones.
- **Nothing about the letux route below has been booted either.** Its state was
  read out of the tree, not run.

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

- [`mobiaqua/ti-ducati-fw`](https://github.com/mobiaqua/ti-ducati-fw) — the
  build script with the OMAP5 target; start here
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

- `experiments/m4-ipu/` — the three patches, each with its reasoning in the header
- `docs/building.md` — how `pyra-crossbuild.sh` works and why the kernel builds
  in a bookworm container
- `docs/improvements.md` — the performance work these cores do *not* help with
