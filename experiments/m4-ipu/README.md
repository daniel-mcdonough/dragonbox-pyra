# remoteproc for the two Cortex-M4s and the DSP

The kernel half of making the OMAP5432's IPU subsystem — two Cortex-M4s — and
its C66x DSP visible to Linux. **Nothing here has been booted on this machine,
and there is no firmware for the cores to run**, so even a successful boot
would produce two idle `/sys/class/remoteproc/` entries and nothing more. No
default build carries any of it; `kernel-m4` has to be asked for by name.

The reasoning, the measurements, the firmware problem and an honest assessment
of whether this is worth finishing are all in **`docs/m4-ipu.md`**. Read that
first. This file is only about the three patches.

    ./pc/pyra-crossbuild.sh kernel-m4

builds `5.6.19-m4` into its own `src-m4` tree and stages it as
`m4-kernel.tar.gz`, beside the stock kernel like every other variant.

## The three patches

    0009-remoteproc-omap-backport-the-device-tree-driver.patch
    0010-arm-dts-omap5-add-the-ipu-and-dsp-nodes.patch
    0011-arm-dts-pyra-enable-the-ipu-and-dsp.patch

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
backlight PWM. See the patch header and `docs/m4-ipu.md`.

Both `0009` and `0010` are GPL-2.0-only code taken from the mainline kernel.

## The seven config symbols

They are not a patch. `build_kernel_variant` takes them as its fourth argument
and sets them with `scripts/config`, then checks they survived `olddefconfig`,
because unmet dependencies are dropped silently:

    REMOTEPROC  OMAP_REMOTEPROC=m  OMAP2PLUS_MBOX
    RPMSG  RPMSG_VIRTIO  RPMSG_CHAR=m  VIRTIO

**`OMAP_REMOTEPROC` is deliberately a module, not built in.** Built in, it
probes during boot and there is no way to stop it; as a module nothing touches
the IPU until somebody types `modprobe omap_remoteproc`, and it can be removed
again. Getting an IOMMU wrong on this SoC can wedge the L3 interconnect, so for
a first boot the difference between "load it when ready" and "it already ran
before you got a console" is the difference between an experiment you can
retry and one that needs the power button every time.
`RPMSG_CHAR` is a module for the same reason. The rest are built in because
they are inert until something registers with them.

`OMAP_REMOTEPROC` already allowed `SOC_OMAP5` in the 5.6 Kconfig; it has simply
never been turned on. `CONFIG_OMAP_IOMMU` and `CONFIG_IOMMU_API` are already on
in the stock config and both MMUs already probe on the running machine, which
is why they are not in the list.

## What would come next

Nothing here can be tested without firmware. The shortest path to a firmware
that exists is `mobiaqua/ti-ducati-fw`, whose build targets include OMAP5 and
which emits `omap5-ipu-fw.xem4` — the exact name `0010` asks for. Its
toolchain downloads were verified live on 2026-09-20. Details and the
alternative bare-metal path are in `docs/m4-ipu.md`.
