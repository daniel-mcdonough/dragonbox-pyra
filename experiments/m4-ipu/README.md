# remoteproc for the two Cortex-M4s and the DSP

Making the OMAP5432's IPU subsystem — two Cortex-M4s — and its C66x DSP visible
to Linux, and then running code on them. **Booted on 2026-09-20, and both M4s
now execute**; the firmware that proves it is in `firmware/`. No default build
carries any of this; `kernel-m4` has to be asked for by name.

The reasoning, the measurements, the firmware problem and an honest assessment
of whether this is worth finishing are all in **`docs/m4-ipu.md`**. Read that
first. This file is about the four patches; `firmware/README.md` is about the
test program.

**Three of the four are only needed because this kernel is 5.6.19.** The letux
kernel is at 7.3 and already carries the device tree driver and the SoC-level
nodes, so on that tree `0009` and `0010` are dead weight. It also has the
atomic omap-prm reset poll that removes the sleep `0012` works around. Only
`0011`, and the timer finding behind it, still applies. Whether to move is a real
choice; `docs/m4-ipu.md` has the comparison.

    ./pc/pyra-crossbuild.sh kernel-m4

builds `5.6.19-m4` into its own `src-m4` tree and stages it as
`m4-kernel.tar.gz`, beside the stock kernel like every other variant.

## The four patches

    0009-remoteproc-omap-backport-the-device-tree-driver.patch
    0010-arm-dts-omap5-add-the-ipu-and-dsp-nodes.patch
    0011-arm-dts-pyra-enable-the-ipu-and-dsp.patch
    0012-iommu-omap-do-not-sleep-while-holding-the-iommu-spinlocks.patch

They are numbered from 0009 because `patches/` holds 0001 to 0006 and the
frequency experiment holds 0007 and 0008; `build_kernel_variant` gathers every
directory it is given into one place and applies them in name order, so the
numbers have to stay distinct across all of them.

`0009` is large — about 1400 lines — because it replaces
`drivers/remoteproc/omap_remoteproc.c` wholesale rather than editing it. The
file that 5.6.19 ships is the original 2011 driver with no device tree support
at all and a probe that cannot succeed on any board still in the tree, so there
is nothing to edit toward. The replacement is v5.9's file, which v5.10 ships
unchanged and which v6.6 is within three lines of. Three call sites needed
adjusting for interfaces that changed outside remoteproc between 5.6 and 5.9;
each is explained in the patch header.

`0010` is upstream's two nodes, verbatim. `0011` is this board's carveouts and
enablement, modelled on `omap5-uevm.dts` but **deliberately not copying its
timers** — upstream gives the IPU `timer9`, which on a Pyra is the display
backlight PWM. The backlight wins that fight (it reserves the timer during
boot; remoteproc only asks at `start`), so the panel is never at risk — what
you get instead is `-EBUSY` when starting the processor, with nothing to
connect it to a backlight. See the patch header and `docs/m4-ipu.md`.

`0012` is the odd one out: it is not needed to make anything work, it is needed
because what works is noisy in a way that should not be shipped. Starting the
IPU produces two `BUG: scheduling while atomic` splats every time, because
`omap_iommu_attach_dev()` sleeps in `pm_runtime_get_sync()` while holding two
spinlocks. Mainline has the same locking but no longer sleeps there: v5.8 made
the reset poll in `omap_prm.c` atomic. `0010`/`0011` are simply what make it
reachable on this board. The fix converts
both locks to mutexes, which is safe because every site that takes either one
is already a sleeping path. **Built and booted on 2026-09-20: the splats are
gone and `pyra-m4-run.sh` goes from 10 ok / 1 failed to 11 ok / 0 failed.**

Both `0009` and `0010` are GPL-2.0-only code taken from the mainline kernel,
and `0012` modifies GPL-2.0-only kernel code.

## The seven config symbols

They are not a patch. `build_kernel_variant` takes them as its fourth argument
and sets them with `scripts/config`, then checks they survived `olddefconfig`,
because unmet dependencies are dropped silently:

    REMOTEPROC  OMAP_REMOTEPROC=m  OMAP2PLUS_MBOX
    RPMSG  RPMSG_VIRTIO  RPMSG_CHAR=m  VIRTIO

`OMAP_REMOTEPROC` and `RPMSG_CHAR` are modules rather than built in. **The
original reason given for that was wrong**: it said nothing would touch the IPU
until somebody typed `modprobe`, and the first boot showed udev loading the
module anyway from the device tree modalias `of:NipuT(null)Cti,omap5-ipu`. The
driver probes during boot either way.

What `=m` actually buys is the ability to remove the module afterwards, and to
prevent it loading with a `modprobe.d` blacklist or
`modprobe.blacklist=omap_remoteproc` on the kernel command line. Since
`auto_boot` is true, that blacklist is what you want **before** installing any
firmware, because otherwise the cores start during boot with nothing typed.

`OMAP_REMOTEPROC` already allowed `SOC_OMAP5` in the 5.6 Kconfig; it has simply
never been turned on. `CONFIG_OMAP_IOMMU` and `CONFIG_IOMMU_API` are already on
in the stock config and both MMUs already probe on the running machine, which
is why they are not in the list.

## Checking it still says what it should

    ../../pc/pyra-m4-verify.sh --patches

asserts the three compat fixes are still in `0009`, that `0011` adds no timer
property, and that its carveout still covers what
`rsc_table_omap5_ipu.h` asks for. Without `--patches` it also checks the built
tree and decompiles the DTB. `device/pyra-m4-check.sh` is the on-device half.

## The firmware

`firmware/` holds a test program that runs on both M4s: a heartbeat in a
`TYPE_TRACE` buffer, about 900 bytes of code, built with plain
`arm-none-eabi-gcc` and no TI toolchain at all. `firmware/README.md` explains
why it needs no AMMU programming and how each of its three claims is defended.
`device/pyra-m4-run.sh` is the end-to-end test.

## What would come next

Nothing past a heartbeat can be tested without a real firmware. TI's own IPC repositories are
cloned at `~/git/dragonbox-pyra-m4-work/`; `ipcdev` is from 2024, OMAP5 is a
supported platform in it, and `ipc-examples` carries the OMAP5-specific AMMU
configuration and resource tables. `mobiaqua/ti-ducati-fw` is the easiest way
to get the toolchain, and the route to take if the goal is video decode rather
than running your own code.

Relevant to `0011` specifically: the canonical `rsc_table_omap5_ipu.h` asks for
6 MB of text, 48 MB of data and 1 MB of IPC data — **55 MB against the 56 MB
carveout here**, which is why upstream picked that figure. `ex41_forwardmsg`
ships its own copy wanting 156 MB of data, which would not fit; check the table
before assuming. Details in `docs/m4-ipu.md`.
