# An unlocked device tree: 250 MHz to 2 GHz

A Pyra owner, Asaggynoodle, published an unlocked device tree for the V5.3 on
the Pyra forums on 2022-04-03, along with their own `pyra-thermal.sh`:

https://pyra-handheld.com/boards/threads/20-c-cooler-and-now-with-water-resistance.99686/post-1706483

Both are attachments to that post. They are not copied here, because the post
states no licence for them. Download them from the post if you want them. This
directory holds what was made of them here:

    0007-arm-dts-omap5-add-the-intermediate-opps.patch   the safe half, as source
    0008-arm-dts-omap5-add-the-overclock-opps.patch      the rest, as source

The two patches are the same frequency table written back into this kernel's
own device tree source, split so the half that is not overclocking can be built
on its own. The shipped kernel already carries `0007`; see "You do not need
the blob" below.

**The published blob has not been booted on this machine, and neither has
`0008`.** No default build carries any of it: the two kernel variants that do
have to be asked for by name, and nothing in `docs/` depends on them.

## The measurements behind this table were taken on modified hardware

**This came to light on 2026-09-13, after all of the thermal work in this
repository was done, and it is the single most important piece of context for
reading any of it.** It changes no finding here. It changes how the findings
should be described to anyone else.

The [first post of the same thread](https://pyra-handheld.com/boards/threads/20-c-cooler-and-now-with-water-resistance.99686/),
from 2022-03-18, describes the cooling work done to the CPU board before the
frequency table was tuned:

- the CPU board components **conformally coated**, to allow clearances and
  interface materials that would otherwise risk shorting;
- the copper plate heatsink **soldered** to the main serrated copper thermal
  element;
- the stock thermal material removed — the author reports *"an insulating
  adhesive coating the contact side of the heatsink, which likely significantly
  impacts thermal transfer from the CPU/PMC to the heatsink"*;
- high-end thermal compound applied to the heatsink and to the RAM, CPU and
  PMC.

The reported result is **"about a 20-23°C temperature delta from stock"**,
which the author says *"now makes 1.5 GHz essentially perfectly usable outside
of long term heavy load"*. Airflow between the inside and outside of the case
is named as the next thing to tackle and had not been done.

### What that delta does to the numbers in this repository

Everything measured here was measured on a **stock, unmodified V5.3**: stock
heatsink, stock thermal interface with the adhesive in place, no coating, no
added airflow, closed case, room ambient. Across every run in
`../thermal-ladder/`, the fuel gauge's die temperature — the sensor the vendor
thermal daemon calls the battery — ranged from **43.8°C to 53.9°C**.

The vendor's ladder on that sensor caps at 44, 45, 47, 49 and 50°C.

| | gauge range observed | vendor's ladder |
| --- | --- | --- |
| this stock unit | 43.8 – 53.9°C | **permanently inside the capping band** |
| same unit, less 20-23°C | 21 – 31°C | never reaches the first rung |

So on the author's modified board that ladder never fires at all. **The
cooling work moved the board sensor out of the range in which the software
fault lives.** That is almost certainly why the author's own account of the
problem is about sustained SoC heat rather than about being capped to 1250 MHz
thirty seconds into any work, which is what a stock machine does.

### The author's symptom list is the fault this repository found

The same post describes, on the *unmodified* device:

> Throttling after about 10 minutes of heavy use. > Pushes clock into a
> downclock decay of 250 MHz, then cools, but immediately hits trip
> temperature back down to 250 MHz making system crippled.

250 MHz is the deepest rung of the vendor's battery ladder, at >50°C on the
fuel gauge die. This unit reached **53.9°C** on that sensor under two cores.
"Cools, but immediately hits trip temperature again" is the absence of
hysteresis: measured here as twelve ceiling changes in a single run, four of
them during the *idle* phase.

That is [fault 1 and fault 2](../thermal-ladder/README.md), described from the
outside by someone who did not have the sensor trace, and solved with copper
rather than with a threshold. The two approaches are complementary and neither
supersedes the other. On a stock machine the software fault is reachable
without opening the case.

### What this does and does not change

**It does not invalidate anything.** Every fault in
[docs/fixes.md](../../docs/fixes.md) is a logic fault, reproduced on stock
hardware, and three of them — the `cpufreq-set` call that is not installed, the
`setMaxFreq` overwrite, and the charger's input current limit — have no thermal
content at all.

**It reinforces the recommendation against `kernel-oc`.** The advice here has
always been not to boot the 2 GHz half, on the grounds that one core at
1.5 GHz already reaches the passive trip on this machine. The author agrees in
the warning below and now the reason is explicit: the headroom those steps
need is 20-23°C of hardware work that this unit has not had.

**It makes fix 7 more robust across cooling configurations, not less.** The
vendor's design makes the *board* sensor the one that decides in practice,
which is exactly the sensor a cooling change moves. Fix 7 makes the SoC sensors
primary and leaves the board rungs as a backstop above the worst uncapped
board temperature measured here. SoC rungs mean the same thing on a coated
board as on a bare one.

**It changes what the upstream reports must say.** Both thermal reports now
carry a statement of the thermal configuration they were measured on, because a
maintainer reading them on a modified unit will not reproduce "44°C within
thirty seconds of one core", and the board rung values proposed in them are
calibrated to a stock machine.

**It raises one cheap thing worth trying.** The insulating adhesive the author
describes on the heatsink's contact face is stock, on every unit. Removing it
and applying ordinary thermal compound is reversible, needs no coating and no
solder, and is the first and least invasive part of what produced that delta.
Nothing here has tried it and there is no measurement of it.

---

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

## You do not need the blob

The post's instructions overwrite the device tree in
`/boot/dtb/linux-image-5.6.19-daveiii-pyradef-aufs`, a directory that does not
exist on trixie. You don't need to do that here. Every kernel this repository
builds compiles its own device trees from source, and the table is already in
that source:

- the shipped kernel, `5.6.19-m4-kbdled`, carries `0007`, so a prepared card
  already has the five steps below 1.5 GHz, with the voltage fix described
  above;
- `./pc/pyra-crossbuild.sh kernel-oc` adds `0008`, the steps up to 2 GHz.

To try `kernel-oc`, install it beside the stock kernel and boot it once with
`pyra-boot-kernel.sh debug --once`, as in `docs/building.md` ("Boot slots" and
"Install it beside the stock kernel, not over it"). A kernel that hangs gets
one boot, and the next boot is back on the default. The new points above
1.5 GHz do nothing until the thermal daemon's ceiling is raised, so leave it at
1500 on the first boot and test the tree before anything is overclocked.

Read the warning above and "Result" below before you do: on a stock unit, one
core at 1.5 GHz already reaches the passive trip.

## The thermal script has two problems, and one is a safety problem

The `pyra-thermal.sh` attached to the post is the author's, offered as an
example rather than as something to install, and the post says so. Compared
against the script running on this device, it raises the default ceiling from 1500 to 1900, and moves the
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

## Result: it buys battery, not speed

Measured 2026-09-12 with `device/pyra-freq-profile.sh`, two full runs on each
kernel, on battery with the charger physically disconnected, governor and
thermal daemon untouched. The two runs of each kernel agreed closely enough
that the spread is smaller than every difference reported below.

**Idle, 120 seconds of doing nothing:**

| | `5.6.19-fix` | `5.6.19-freq` |
| --- | --- | --- |
| steps offered | 6 | 11 |
| mean frequency | 447 MHz | 388 MHz |
| power | 4.11 W | 3.84 W |
| share of the window at 1500 MHz | 7.3% | 0.1% |

That last row is the mechanism, and it was checked twice on each kernel because
it looked like noise the first time. It is not noise. With six steps the
governor spends **7.3% of an idle machine at full speed**, because the step
above 500 MHz is 750 and the ramp overshoots; with eleven it finds something
that fits and effectively never reaches the top. The saving is 0.27 W, about
6.5%. Against this unit's 21.3 Wh battery that is roughly **21 minutes more
idle runtime**, 5.2 hours becoming 5.5.

**Burst, 1200 short units of work with idle between them:**

| | `5.6.19-fix` | `5.6.19-freq` |
| --- | --- | --- |
| mean unit latency | 52.3 ms | 54.4 ms |
| best unit | 33.5 ms | 39.6 ms |
| p50 | 53.2 ms | 54.3 ms |
| p99 | 62.8 ms | 61.7 ms |
| power | 5.14 W | 4.87 W |

This is the phase the extra steps were supposed to help, and it is the phase
where they do not. Bursty work is about 4% slower on average and the best case
is 18% slower, because the governor now has somewhere comfortable to stop short
of the top and takes it. The tail is marginally better, 1.7% at p99. Power is
down by the same quarter-watt as at idle.

**Sustained:** no number, on either kernel. One core of `7z b` reaches the
100°C passive trip on both, and the profiler stops there. See the thermal
finding below; it is a property of the machine and not of either kernel.

**So the honest summary is the opposite of the hypothesis.** Item 1 of
`improvements.md` reasoned that coarse steps were making the machine sluggish,
and that finer ones would help responsiveness. Finer steps do not help
responsiveness; they cost a little. What they do is stop an idle machine
visiting 1.5 GHz, which is worth about 6.5% of idle power and twenty minutes of
battery. That is a real result and a modest one, and it is a better argument
for this patch than the one that motivated it.

None of this touches the governor's actual misconfiguration — `up_threshold 95`,
`io_is_busy 0`, a 250 MHz floor — which was untested when this was written. Finer
steps and a tuned governor are separate experiments, and the second one is now
more interesting than it was, because there is a finer table for it to work
with.

**Measured 2026-09-13 on this kernel, and those three are not the
misconfiguration.** `up_threshold` at 70 buys about 2% of burst latency,
`io_is_busy 1` about 1%, a 500 MHz floor about 2%. The setting that pays is
`sampling_down_factor`, which that list does not mention: 1 to 10 is 23.4% of
the mean and a third of the median. Setting all four together beats it by 1.1
points, which is inside the pass-to-pass spread, so the whole win is one value.
Method and numbers in `experiments/governor/README.md`; applied by
`device/pyra-governor-tune.sh`.

**A thermal finding that is not about either kernel.** The first attempt at a
sustained phase ran `7z b` on both cores and took the CPU zone from 64°C to
**107°C**, seven degrees past the 100°C passive trip, in under two minutes. It
was stopped by the profiler, not by the kernel. The zone is configured
correctly, so this is `step_wise` conceding one cooling state per poll while a
fanless case heats faster than that, with the userspace thermal daemon polling
every 20 seconds on top. Nothing was damaged and the 125°C critical trip was
never near, but the "five degrees of margin" quoted elsewhere in
`improvements.md` is not margin under a load heavier than box86. It is recorded
there as item 2. Every kernel here tops out at 1.5 GHz, so this belongs to the
hardware.

`kernel-oc` has still never been booted, and this finding is the strongest
argument yet against booting it.

**Note on the boot slot.** There is one test slot. Installing `kernel-freq`
into it points that slot away from `5.6.19-fix`, so with the one-shot revert
armed the next ordinary boot lands on the stock `5.6.19-pyradef`, which carries
none of the six fixes: suspend hangs, the nubs die on resume and the keyboard
can go silent. The fix kernel's files are still in `/boot`, they are simply not
referenced by a boot entry any more. Getting back to it is a reinstall of its
tarball, as `docs/building.md` describes under going back.
