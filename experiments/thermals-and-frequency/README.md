# An unlocked device tree: 250 MHz to 2 GHz

Third-party work, published on the Pyra forums and reproduced here with its
author's warning intact. **Untested on this machine.** Nothing in this
directory is installed by any script in this repository, and nothing in
`docs/` depends on it.

Two files:

    omap5-letux-cortex15-v5.3+pyra-v5.3.dtb   the unlocked device tree, April 2022
    pyra-thermal.sh                           the author's own thermal script, March 2022

## The author's warning, kept as written

> I take ZERO responsibility with how running this on your Pyra turns out. As
> it will probably result in lots of crashes, and needing to reflash your
> installation if you can't swap the dtb file out if it doesn't work for you.
>
> Each step has a tuned voltage for it as well, all steps are stable for my
> Pyra, but doesn't mean it will be for you. I would not use this if you don't
> have a backup installation on your SD card or eMMC to swap out the dtb file
> if it fails in your system, as you won't be able to boot up the device to do
> it from a single install.
>
> No, unless you've modified the cooling, you probably can't run 2 GHz I assure
> you. I hardly can.

That is the honest version and it should be read before anything below.

---

## What the blob actually contains

Read out of the blob rather than taken from the description. The only
functional change is the `operating-points` table on `cpu@0`, which is the
legacy `<kHz, microvolts>` form this kernel uses.

| MHz | volts | in the stock tree? |
| --- | --- | --- |
| 250 | 0.750 | yes |
| 375 | 0.800 | **new** |
| 500 | 0.850 | yes |
| 625 | 0.900 | **new** |
| 750 | 0.950 | yes |
| 875 | 1.000 | **new** |
| 1000 | 1.050 | yes |
| 1125 | 1.075 | **new** |
| 1250 | 1.100 | yes |
| 1400 | 1.200 | **new** |
| 1500 | 1.250 | yes |
| 1600 | 1.300 | **new, above the part's rating** |
| 1700 | 1.350 | **new, above the part's rating** |
| 1800 | 1.350 | **new, above the part's rating** |
| 1900 | 1.350 | **new, above the part's rating** |
| 2000 | 1.450 | **new, above the part's rating** |

Six steps become sixteen. Two things are worth separating, because they carry
completely different risk.

**Below 1.5 GHz the additions are interpolation at stock voltages.** Every
frequency the stock tree already has keeps the exact voltage the stock tree
gives it, to the microvolt. The five new steps underneath sit between them on
the same curve. Nothing there is overclocking, and that half is interesting on
its own: this machine's governor problem is a granularity problem as much as
anything, and 250 MHz gaps are what it has to work with today.

**Above 1.5 GHz is genuinely new territory.** The OMAP5432 is rated to
1.5 GHz. The top five steps are beyond that, three of them share one voltage,
and the last one asks for 1.45 V. This is the half the warning is about.

## What else it changes, which the description does not mention

Diffing the whole tree against the blob this repository's own kernel installs
turns up four more differences, all cosmetic, all evidently the author's
personal settings rather than part of the unlock:

- The logo and shoulder LED default triggers are rewired to `heartbeat`,
  `timer` and `mmc0` in place of the stock `none`, `default-on` and per-card
  triggers. The left blue LED loses its `bluetooth-power` trigger.
- The keyboard backlight default brightness level goes from 3 to 5.
- The screen backlight default brightness level goes from 13 to 14.

Nothing else differs. That is the reassuring part of the whole review: the blob
is not from a divergent tree, so swapping it in does not silently drop device
tree fixes that arrived between April 2022 and the image this repository
builds on. It is the shipped tree with a frequency table and some LED taste
applied to it.

## The installation instructions do not match this build

The forum post says to replace the file in
`/boot/dtb/linux-image-5.6.19-daveiii-pyradef-aufs`. No such directory exists
here. Trixie names the directories after the kernel packages actually
installed, and on this machine that is one directory per kernel:

    /boot/dtb/linux-image-5.6.19-pyradef      the stock kernel
    /boot/dtb/linux-image-5.6.19-fix          the patched kernel this repository builds
    /boot/dtb/linux-image-5.6.19-softlockup   the lockup-detector build

Which matters for more than a path. Each extlinux entry names its own
`fdtdir`, so the device tree is selected per boot entry, not globally. The post
treats the device tree as one file to overwrite and back up carefully. Here it
does not have to be, and overwriting is the wrong way to do it.

## A safer way to try it, using what is already here

Give the unlocked tree its own directory and its own boot entry, leave every
existing entry untouched, and boot it once. `device/pyra-boot-kernel.sh`
already arms a service that puts the default back early in the next boot, so a
machine that boots at all gets exactly one boot on the unlocked tree and
returns by itself.

    # a directory of its own, seeded from the patched kernel's
    sudo cp -a /boot/dtb/linux-image-5.6.19-fix /boot/dtb/linux-image-5.6.19-oc
    sudo cp omap5-letux-cortex15-v5.3+pyra-v5.3.dtb \
            /boot/dtb/linux-image-5.6.19-oc/

    # a boot entry of its own: copy the l1 block in /boot/extlinux/user.cfg,
    # rename the label to l2, change only the fdtdir line to
    #   fdtdir /dtb/linux-image-5.6.19-oc

Then boot it once. Note that `pyra-boot-kernel.sh` has the test label wired to
`l1`; point `DEBUG_LABEL` at `l2` or make `l2` the default by hand, and arm the
revert either way.

**Do not raise the thermal ceiling on the first boot.** Leave the stock
`pyra-thermal.sh` in place, which caps at 1500. The extra steps below 1.5 GHz
become available, nothing runs faster than it does today, and you find out
whether the tree boots and whether the finer steps behave before anything is
overclocked. That is one variable at a time, and it is the boot where a bad
voltage table shows up.

The recovery story the post describes still applies if you ignore all of the
above and overwrite the stock file: the machine may not boot, and the fix is
the card in a PC. This repository's `pc/` scripts are how you would do that.

## The thermal script has two problems, and one is a safety problem

`pyra-thermal.sh` here is the author's, offered as an example rather than as
something to install, and the post says so. Compared against the script running
on this device, it raises the default ceiling from 1500 to 1900, and moves the
core ladder from throttling at 77°C to throttling at 88°C. Those are choices.
The following two are not.

**Four branches of the battery ladder are unreachable.** The chain tests
`-gt 50000` first and then `-gt 55000`, `-gt 53000`, `-gt 51000` and `-gt 50000`
after it. Anything hot enough to satisfy the later tests satisfies the first
one, so they never run. The stock script has the same ladder ordered correctly,
descending from 50000, so this was introduced here. What actually executes is:
above 50°C clamp to 250 MHz, between 49 and 50°C allow 1500, between 48 and
49°C only raise the charge current. The intermediate steps the author wrote do
not exist at runtime.

**The hot-battery charge current is raised more than threefold.** The stock
script drops charging to 500 mA once the battery passes 42°C and holds it there
all the way up. This one asks for 1.6 A at every temperature above 50°C. That
is a lithium cell being charged at three times the stock current while it is
above the temperature at which the stock policy had already backed off, and it
is the one change here that can damage hardware rather than merely hang it.
Whatever else you take from this directory, do not take that.

If you want the author's ceiling, change `maxFreq` and the core ladder in the
copy of the script that is already on the device, and leave its battery section
alone.

## No source was published, and that is fixable

What the forum post offers is a compiled blob, not the device tree source it
was built from. That is a real limitation here, because this repository builds
its own kernel and emits its own device trees from
`pc/pyra-crossbuild.sh kernel-fix`. A prebuilt blob cannot follow a kernel
rebuild; it has to be copied back over the freshly built one every time, which
is exactly the kind of step that gets forgotten once and then produces a
confusing result.

The table above is the whole functional change and it is now written down, so
the better form of this is a patch to the device tree source in the kernel
tree, alongside the six in `patches/`. Then the unlock is built rather than
copied, it survives every rebuild, and the LED and backlight changes are left
out because they were never part of it. Whoever picks this up should write that
patch rather than install this blob permanently.

## Status

Not tried on this machine, so there is no result section yet. It sits in
`experiments/` for the same reason `c2-idle` does: the reasoning is recorded so
that trying it is a decision rather than a rediscovery. Unlike `c2-idle`, this
one has not been closed, and the sub-1.5 GHz half looks worth a measured run
against item 1 of `docs/improvements.md`.
