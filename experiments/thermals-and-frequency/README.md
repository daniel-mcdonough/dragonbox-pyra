# An unlocked device tree: 250 MHz to 2 GHz

Third-party work, published on the Pyra forums and reproduced here with its
author's warning intact, plus the work that was made of it here.
**Nothing in this directory has been booted on this machine.** No default
build carries any of it: the two kernel variants that do have to be asked for
by name, and nothing in `docs/` depends on them.

What arrived, and what was made of it:

    omap5-letux-cortex15-v5.3+pyra-v5.3.dtb   the unlocked device tree, April 2022
    pyra-thermal.sh                           the author's own thermal script, March 2022
    0007-arm-dts-omap5-add-the-intermediate-opps.patch   the safe half, as source
    0008-arm-dts-omap5-add-the-overclock-opps.patch      the rest, as source

The blob is what was published. The two patches are the same frequency table
written back into this kernel's own device tree source, split so the half that
is not overclocking can be built on its own. If you build your own kernel, use
those and ignore the blob.

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
| 1125 | 1.075 | **new, and rejected at boot — see below** |
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

**One of those five does not work, and that was only found by booting it.**
The supply these points drive, `smps123`, is a Palmas SMPS whose low range is
510000 uV plus a multiple of 10000. Ten millivolts is the granularity, and
1.075 V is not on that grid. The OPP core drops the whole point at boot:

    core: _opp_supported_by_regulators: OPP minuV: 1075000 maxuV: 1075000,
          not supported by regulator
    cpu cpu0: _opp_add: OPP not supported by regulators (1125000000)

Two lines in a log nobody reads, and a frequency table quietly one step
shorter than the one in the source. So the published blob is a sixteen-step
table that delivers fifteen steps, on any Pyra running it, and has been since
2022. The patch below uses 1.080 V instead, rounding up rather than down
because the voltage is there to hold the frequency. Every other voltage in the
table, including all five of the overclock points, is already on the grid.

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

## A safer way to try the blob, if you are not building a kernel

Skip this section if you are. Building `kernel-freq` or `kernel-oc` from the
patches below is both safer and less work, and it survives a rebuild. What
follows is for running the published blob on a kernel you did not build.

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

## No source was published, so the table was rewritten as source

What the forum post offers is a compiled blob, not the device tree source it
came from. That does not survive contact with this repository, which builds its
own kernel and emits its own device trees. A prebuilt blob has to be copied
back over the freshly built one after every kernel build, which is exactly the
kind of step that gets forgotten once and then produces a confusing result.

The table is the whole functional change and it is now written down, so it is
carried here as source instead:

    0007-arm-dts-omap5-add-the-intermediate-opps.patch
    0008-arm-dts-omap5-add-the-overclock-opps.patch

Both edit `arch/arm/boot/dts/omap5-letux-cortex15-common.dtsi`, which is where
the board's six points are set today. They are split along the line this
document keeps drawing, so the half that is not overclocking can be built and
measured without the half that is. `0007` adds the five steps below 1.5 GHz and
changes no ceiling. `0008` raises the ceiling to 2 GHz and has to be applied on
top of `0007`.

`0008` also resolves something already in the tree. The board's own device tree
carries a 1700 MHz point behind an unexplained `#if 0` marked "potentially
overclocking", asking 1.25 V, where the published table asks 1.35 V for the
same frequency. Two answers for one frequency, and the patch takes the higher
one, which is the one that comes with a report of having been run.

The LED and backlight changes are deliberately left out. They were never part
of the unlock.

### Building it

    ./pc/pyra-crossbuild.sh kernel-freq    # the fix set plus 0007
    ./pc/pyra-crossbuild.sh kernel-oc      # the same, plus 0008

Each builds under its own release name, `5.6.19-freq` and `5.6.19-oc`, into its
own source tree, and installs beside the stock kernel rather than over it. From
there it is the ordinary one-shot route in `docs/building.md`, which is what
makes this safer than swapping a file: a kernel that hangs gets exactly one
boot.

Note that `/boot` was 41% used with three kernels on it. Each of these adds a
fourth and a fifth.

### What was checked

**`kernel-freq` has been booted on the device, `kernel-oc` has not.** Both
patches apply to a clean tree, apply in order, and are idempotent, so a rebuild
over a patched tree reports them as already applied rather than failing. The
compiled blob was read back and carries the table byte for byte; against the
forum blob it differs only in the LED and backlight properties that were left
out on purpose.

Booting it is what found the 1.075 V problem described above, which no amount
of reading the diff would have shown. The first build offered ten frequencies
where the source asked for eleven. That is the whole argument for the one-shot
boot being part of the procedure rather than an optional last step.

The supply is constrained to 1.5 V in `omap5-board-common.dtsi` and the device
agrees at runtime, so the 1.45 V the 2 GHz point asks for is inside the
regulator's range. Everything else about the voltages is somebody else's
measurement on somebody else's unit, and the one of them that has now been
tested against this board turned out to be wrong.

## Status

**`kernel-freq` boots and the machine is healthy on it.** 2026-09-12. Two
one-shot boots, the first of which found the 1.075 V defect and the second of
which confirmed the correction. No failed units, no OPP rejections, network and
desktop intact, and the system reports itself running.

All eleven steps are used. Residency over the first minute of an idle-ish boot,
in jiffies, with the governor and the thermal cap left exactly as they were:

| MHz | 250 | 375 | 500 | 625 | 750 | 875 | 1000 | 1125 | 1250 | 1400 | 1500 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| jiffies | 2214 | 4660 | 1174 | 382 | 299 | 182 | 166 | 199 | 195 | 221 | 2981 |

3019 transitions. The shape is the interesting part: 375 MHz, which did not
exist before, is the single most-occupied state, ahead of the 250 MHz floor the
governor used to fall back to. That is consistent with the complaint in item 1
of `docs/improvements.md` — the governor was not choosing 250 MHz because it
wanted 250 MHz, it was choosing it because the next step up was a 100% jump.

That is one minute on one boot and it is not a measurement of anything anyone
cares about. It says the steps work and get used, not that the machine is
faster or cooler. The comparison that would settle it is the same workload
profiled on `5.6.19-fix` and `5.6.19-freq`, which has not been done.

`kernel-oc` has still never been booted.

**Note on the boot slot.** There is one test slot. Installing `kernel-freq`
into it points that slot away from `5.6.19-fix`, so with the one-shot revert
armed the next ordinary boot lands on the stock `5.6.19-pyradef`, which carries
none of the six fixes: suspend hangs, the nubs die on resume and the keyboard
can go silent. The fix kernel's files are still in `/boot`, they are simply not
referenced by a boot entry any more. Getting back to it is a reinstall of its
tarball, as `docs/building.md` describes under going back.
