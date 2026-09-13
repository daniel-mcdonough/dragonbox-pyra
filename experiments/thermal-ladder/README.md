# The thermal daemon's ladder: what it decides, and why it was wrong

Measured 2026-09-13 on a Pyra V5.3, kernel `5.6.19-freq`, `pyra-trixie-t1`.

This follows directly from the governor sweep of the same day. That sweep's
first run was voided because the frequency ceiling moved underneath it, and the
reason it moved is the subject here.

**None of this was observable before 2026-09-12.** Until `pyra-thermal-fix.sh`
replaced a call to `cpufreq-set` — a program trixie cannot install — the daemon
read its sensors, decided a cap and failed to apply it, every twenty seconds
since first boot. Fixing that made the ladder's decisions visible for the first
time, and there turned out to be three things wrong with them — and then two
more, which the first three had been hiding.

---

## The question

`/usr/share/pyra/scripts/pyra-thermal.sh` picks a CPU ceiling from two sensors
every twenty seconds. One is `core_thermal`, the SoC. The other it calls the
battery. The two ladders are calibrated as if for very different things:

| `core_thermal` | | "battery" (`bq27421-0`) | |
| --- | --- | --- | --- |
| > 77°C | 1250 MHz | > 44°C | 1250 MHz |
| > 82°C | 1000 MHz | > 45°C | 1000 MHz |
| > 87°C | 750 MHz | > 47°C | 750 MHz |
| > 92°C | 500 MHz | > 49°C | 500 MHz |
| > 97°C | 250 MHz | > 50°C | 250 MHz |

That is only sane if the second sensor is measuring a battery. So: is it?

## What this was measured on

**Stock V5.3, unmodified.** Stock heatsink with the factory thermal interface
in place, no conformal coating, no aftermarket compound, no added airflow, case
closed, room ambient, on battery except where a run says otherwise.

This is stated because it is not the configuration the circulating Pyra
frequency work was tuned on. The author of the device tree in
[../thermals-and-frequency](../thermals-and-frequency/README.md) had soldered
the heatsink, stripped the factory adhesive, applied high-end compound and
conformally coated the board, and reports **20-23°C cooler than stock**.

Subtract that from what was measured here and the fuel gauge's die — the sensor
this whole document is about — moves from **43.8-53.9°C**, which is
permanently inside the vendor's 44/45/47/49/50°C capping band, to 21-31°C,
which never touches it. **The cooling work moves the board sensor out of the
range where the software fault lives.** That is the likely reason this fault
has been described from the outside as "throttles after ten minutes of heavy
use" rather than "caps to 1250 MHz thirty seconds into anything".

The board rung values chosen below are therefore stock-calibrated, and say so
wherever they appear. The structural faults are not: a sensor that is not
measuring what the code thinks it is, a ladder with no hysteresis, a cap that
overwrites a deeper one, a poll slower than the transient, and a sensor that
lags the trip are all wrong at any temperature.

---

## Method

`device/pyra-thermal-probe.sh`. Every thermal zone, the ceiling, the current
frequency and the battery current, logged every five seconds through an
idle → one-core-load → idle cycle. Two arms:

- **vendor** — the daemon running and deciding, which is the machine as shipped.
- **pinned** — the daemon stopped and the ceiling held at the top of the table.
  This arm exists because the daemon's own capping limits the heat, so it is
  the only way to see where the sensors sit when the machine is working flat
  out and nothing is intervening.

One core, not two, in both arms: two cores flat out took this machine seven
degrees past its passive trip in under two minutes back when nothing could cap,
and that is a property of a fanless case rather than of any ladder. The probe
refuses `PROBE_CORES=2` in the pinned arm for the same reason.

---

## Fault 1 — the sensor is on the board, not on the cell

`bq27421-0` is the fuel gauge, an I²C chip on the mainboard, reporting its own
die temperature. What it measures is the board it is soldered to.

| t | phase | `core_thermal` | `bq27421-0` | ceiling |
| --- | --- | --- | --- | --- |
| 182 s | load starts | 55.4°C | 42.2°C | 1500000 |
| 213 s | +31 s | 70.6°C | 44.6°C | **1250000** |

The gauge rose **2.0°C within ten seconds** of the load starting. A 6000 mAh
cell cannot change temperature that fast, and nothing in those ten seconds put
any current through it — the pack was discharging at well under 1 A throughout.

Across that whole run the core peaked at **71.0°C** and never once reached its
own first rung at 77°C. The entire throttling episode happened without the
sensor that watches the SoC being consulted.

The cap also outlives the work that caused it, because the board cools slowly
back through 44°C: still capped at 1250 MHz **350 seconds after the load
stopped**, with the core back down to 57.4°C.

## Fault 2 — no hysteresis

The ceiling changed **twelve times** in that one run. Seven of them fall inside
a 116-second window while the gauge sat between 44.8°C and 45.5°C:

| t | ceiling | `bq27421-0` |
| --- | --- | --- |
| 415 s | 1250000 → 1000000 | 44.8°C |
| 435 s | 1000000 → 1250000 | 45.0°C |
| 455 s | 1250000 → 1000000 | 44.9°C |
| 475 s | 1000000 → 1250000 | 45.1°C |
| 496 s | 1250000 → 1000000 | 45.0°C |
| 511 s | 1000000 → 1250000 | 45.0°C |
| 531 s | 1250000 → 1000000 | 45.5°C |

Four more happened during the **idle** phase, with the machine doing nothing at
all and the gauge hovering between 44.1°C and 44.6°C. An idle Pyra flapping
between its top two frequency steps is the 1.5/1.25 GHz oscillation this
hardware is known for.

## Fault 3 — the second ladder overwrites the first

`setMaxFreq` tests its argument against the constant `maxFreq`, 1500, rather
than against the cap already chosen. So whichever ladder runs last wins,
whether or not it is the more restrictive. The battery ladder runs last.
Reduced from the vendor's own helpers, unmodified:

```sh
maxFreq=1500
setMaxFreq() { if [ "$1" -lt "$maxFreq" ]; then current_maxFreq=$1; fi; }

current_maxFreq=$maxFreq
core_temp=98000       # the core ladder's deepest rung, 250 MHz
battery_temp=44500    # the battery ladder's shallowest rung, 1250 MHz

if [ ${core_temp} -gt 97000 ]; then setMaxFreq 250; fi      # -> 250, correct
if [ ${battery_temp} -gt 44000 ]; then setMaxFreq 1250; fi  # -> 1250
```

A core at 98°C asks for 250 MHz and gets 1250, because the board happens to be
at an entirely ordinary 44.5°C. The deeper the core rung, the larger the
overwrite, so this is worst exactly when it matters most. Unlike the other two
it is a loss of thermal protection rather than a loss of speed, and it is the
reason this went into `pc/pyra-trixie-prep.sh` as a seventh fix rather than
being left as a tuning preference.

---

## Where the new thresholds come from

The pinned arm, which is the only measurement of this machine with nothing
capping it. One core, ceiling held at 1500 MHz, on battery:

| `core_thermal` | `bq27421-0` |
| --- | --- |
| 59.0°C (idle) | 44.5°C — *already above the vendor's 44°C threshold* |
| 77°C — the core ladder's **first** rung | **48.4°C** |
| 82°C — the core ladder's second rung | 49.3°C |
| 86.2°C (peak) | 50.5°C |

This is the whole argument in one table. By the time the core is hot enough for
its own ladder to give up a single step, the board is at 48.4°C — where the
vendor's board ladder has already demanded 750 MHz, three rungs deeper. The two
ladders are not merely differently calibrated, they are inverted: the sensor
with the worse view of the SoC was making the more aggressive decisions.

The rule used, so it can be re-derived on another machine: **the first board
rung is the worst board temperature observed with nothing capping, rounded up,
plus 3°C**, and each rung above it is 2°C further. Worst observed was 50.5°C,
so the rungs are 54, 56, 58, 60 and 62°C. That makes the board ladder a genuine
backstop — it fires only if something heats the board without heating the SoC
die, which is ambient, the GPU or the charger, and is the only thing this
sensor is actually good for.

## The hysteresis, and getting it wrong the first time

The first attempt used a 2°C band, chosen against the ladder's 5°C rung
spacing. That was the wrong reference. Sized against the machine instead: this
core moves up to **6°C between five-second samples** under one core and **10°C
under two**, so across one 20-second poll of this daemon it can travel further
than any small band. A 2°C band released correctly and still crossed the same
rung six times in four minutes.

It is now a full rung, 5°C. The fine regulation was never this daemon's job in
any case — the kernel's `step_wise` governor polls the same zone every 250 ms,
and this one is the slow backstop.

---

## Verification

One core, daemon active, the machine as a person would use it:

| ladder | ceiling changes | core peak | `cpu_thermal` peak |
| --- | --- | --- | --- |
| vendor, capping on the gauge at 44°C | 12 | 71.0°C (throttled) | — |
| fixed, 2°C band | 7 | 85.0°C | 91.3°C |
| **fixed, 5°C band** | **2** | **81.8°C** | **88.0°C** |

With a full rung it caps once when the core crosses 77°C, holds 1250 MHz for
the whole load, and releases once idle. Holding a cap regulates better than
oscillating, so the wider band is both quieter *and* cooler: the peak fell from
91.3°C to 88.0°C.

Applying and reverting the fix on a live machine, within the same minute and at
the same board temperature, moves the ceiling 1250000 ↔ 1500000. That is the
cleanest single demonstration that the ladder, and nothing else, was
responsible.

### And then two cores failed, because of this fix

Two cores flat out reached **102°C** with the ceiling never moving once. The
ramp says why:

| t | `core_thermal` | `cpu_thermal` | ceiling |
| --- | --- | --- | --- |
| 61 s — load starts | 64.6°C | 63.2°C | 1500000 |
| 67 s | 67.0°C | **77.7°C** | 1500000 |
| 72 s | 80.2°C | **91.7°C** | 1500000 |
| 77 s | 85.8°C | **98.1°C** | 1500000 |

Sixteen seconds from a 63°C idle to the 100°C passive trip, against a daemon
that polls every twenty. It never got a turn.

The A/B, same machine, same load, same minute:

| ladder | starting ceiling | two cores flat out | `cpu_thermal` peak |
| --- | --- | --- | --- |
| vendor | **750000** | ceiling never moved | **74°C** |
| corrected, poll untouched | **1500000** | aborted | **102°C** |

The vendor was sitting at 750 MHz because the board was at 47°C, and two cores
at 750 MHz is harmless here. **That accidental cap was doing real safety work,
and correcting the ladder removed it.** This was a regression introduced by
this change, not a pre-existing hazard merely exposed; the first write-up
claimed the latter, before the A/B had been run, and was wrong.

Hence faults 4 and 5, and the reason this ships as one change rather than
three:

- **`interval` 20 → 2.** The poll has to become fast enough to do on purpose
  what the broken ladder was doing by accident.
- **The ladder reads the hotter of `core_thermal` and `cpu_thermal`.** The
  trip is on `cpu_thermal` and it leads `core_thermal` by up to 12°C during a
  ramp, so even an instantaneous daemon on `core_thermal` alone would first act
  with `cpu_thermal` already at 91°C.

| configuration | two cores flat out | outcome |
| --- | --- | --- |
| as shipped, pre-capped at 750 MHz | 74°C | safe, but throttled at idle too |
| ladder corrected only | 102°C | aborted |
| ladder corrected, 2 s poll, both sensors | **87°C** | ran to completion |

It caps within two seconds of the ramp, hunts briefly, holds 1000 MHz for 205
seconds and releases once idle.

**The honest cost: the machine runs hotter than fix 6 alone left it.** It now
uses thermal budget it was previously giving away to a sensor with no view of
the SoC. 88°C on one core and 87°C on two against a 100°C passive trip, where
fix 6 alone sat at 84°C — but it got that margin by throttling at 70°C for no
thermal reason. Nothing here approaches the 107°C that fix 6 was written to
stop. If more margin is wanted, the clean knob is the core ladder's first rung
at 77°C, which is the vendor's own policy on the correct sensor and is
deliberately left alone.

---

## What the faster poll costs

Dropping the poll from 20 seconds to 2 makes the daemon wake ten times as
often, and this is a fanless handheld where idle power is a live concern. That
is worth measuring rather than asserting. Three 300-second windows, bracketed
2 s / 20 s / 2 s so drift shows up as a disagreement between the first and
third ([pollcost-20260913.log](pollcost-20260913.log)):

| interval | daemon CPU over 300 s | share of one core | idle mean frequency |
| --- | --- | --- | --- |
| 2 s | 349 jiffies | 1.163% | 392 MHz |
| 20 s | 32 jiffies | 0.107% | 392 MHz |
| 2 s (repeat) | 355 jiffies | 1.183% | 397 MHz |

So the poll costs about **1.07% of one core**, or half a percent of this
two-core machine, and the two 2-second windows agree to within 2%.

**It does not show up in frequency residency at all.** Idle mean frequency is
the same to within a percent across all three, and the proportion of idle spent
at the top step was *highest* in the 20-second window (2.10% against 1.35% and
1.89%) — noise, in the direction opposite to the one the cost would predict.
The daemon's extra wakeups are short enough that the governor never notices
them.

Nearly all of that 1% is fork overhead rather than work: at 2.3 jiffies per
poll the daemon is spending about 23 ms to read three sysfs files, because in
dash each `$(cat …)` is a fork and an exec, and `sleep` is an external command
too. At an idle 392 MHz those are not cheap. Replacing the reads with `read x <
file` builtins should remove most of it; that is a follow-up, and it will be
measured the same way rather than assumed.

**Measured, and shipped:** half a percent of the machine at idle, in exchange
for the difference between 102°C and 87°C on two cores. That is not a close
call.

One caveat on the numbers above: two of the three windows logged `cp: cannot
create regular file '/tmp/up0': Permission denied`, left over from an earlier
root-owned run. The per-window sample totals came out at 30001, 30002 and 30003
— all three consistent with one 300-second window at 100 Hz, not with a stale
baseline — so the residency figures are sound. The error is in the log and is
named here rather than quietly cropped.

## Things that went wrong in this measurement

**The pinned arm was contaminated partway through**, by the charger being
plugged in at t=178 for a different test. Everything the thresholds are derived
from is from before that point, and the analysis splits the file on the charger
zone rather than trusting the whole of it. 35 clean samples, 14 discarded.

**`bq24297` was called "a constant in the driver, not a measurement"**, on the
strength of it returning exactly 22500 on all 252 samples of a battery-only
run. That was wrong as stated — it reads 60000 with the charger plugged in — and
the correction that replaced it, "a real sensor", was wrong too, which took a
third look to notice. It takes exactly two values, 22500 offline and 60000
online, and has never varied within a run in either state across about 1500
samples; 1123 of those were taken while the pack warmed 1.4°C and the charge
current swung between 202 and 531 mA, and it did not move once. It reports
whether a cable is attached. The probe script was printing the first bad
conclusion and now reports what it saw without drawing one.

**The first hysteresis implementation biased the charging decision too.** The
release pass re-evaluated a single combined ladder on temperatures 2°C higher
than the real ones, which would have clamped the charger to 500 mA at a board
temperature where the vendor allows 2 A. Caught by a unit test against the
generated ladder before it ever reached hardware. Frequency and charging are
now separate functions and only frequency is debounced; the selftest asserts
the charging ladder is byte-identical to the vendor's.

---

## The charging ladder: tested, not settled here, and settled elsewhere

**Superseded.** What this section could not resolve was resolved the next
evening, and the answer is in
[experiments/charging](../charging/README.md): the daemon's charge-current
decision goes into `/dev/usb_max_current`, which on this machine is an ordinary
file that nothing reads. The write succeeds and reaches nothing. The open
question recorded below — "writing it produced no observable change in either
direction" — was the answer, and it was filed as a mystery instead.

The original text follows unedited.

### (original)

The charging ladder steers on the same misidentified sensor and is deliberately
**not** changed here. The prediction was that a warm Pyra charges at 500 mA,
since the machine idles at 42.0–42.3°C on that sensor — already inside the 2 A
band — and half a minute of one core puts it past 44°C where only 500 mA is
allowed.

Tested with `device/pyra-charge-probe.sh`, bracketed arms:

| arm | asked for | charger gave | battery | status |
| --- | --- | --- | --- | --- |
| daemon deciding | 500 mA | 500 mA | −431 mA | Not charging |
| daemon stopped, 3 A written | **3000 mA** | **500 mA** | −442 mA | Not charging |

`input_current_limit` never left 500000 in either arm and the pack lost a
percent while plugged in. But the supply reported `type: USB`, `present: 0`,
`current_max: 500000` — a standard 500 mA USB port. The source limit and the
ladder's limit are the same number, so this run cannot tell them apart. **The
prediction is untested, not confirmed.** It needs a supply that can deliver 2 A
or more.

One thing it did establish, which qualifies a claim made in the fix 6 report:
writing `/dev/usb_max_current` produced **no observable change** in the
charger's `input_current_limit`, in either direction, with the daemon stopped.
That report says the charging half of this daemon works, on the grounds that
its redirection succeeds where the `cpufreq-set` call does not. That is true of
the write and unverified of its effect. Whether this daemon has ever influenced
charging at all is now an open question.

---

## Artifacts

| file | what it is |
| --- | --- |
| `sensor-correlation-20260913.tsv` | the first run, which found all three faults. Vendor ladder, daemon deciding, one core. 252 samples |
| `probe-vendor-20260913-184536.tsv` | the same shape from the committed probe script, before the fix |
| `probe-pinned-20260913-190153.tsv` | daemon stopped, ceiling pinned. The threshold calibration. Contaminated from t=178 |
| `probe-vendor-20260913-192420.tsv` | after the fix, 2°C band, one core |
| `probe-vendor-20260913-193329.tsv` | after the fix, 2°C band, two cores |
| `probe-vendor-20260913-194702.tsv` | after the fix, 5°C band, one core |
| `charge-probe-20260913-190806.tsv` | the charging test that did not settle |
| `probe-vendor-20260913-195818.tsv` | two cores with the ladder fixed but the poll untouched — the 102°C run |
| `ab-vendor/`, `ab-new/` | the two-core A/B: vendor ladder pre-capped at 750 MHz against the corrected ladder at 1500 |
| `ab2/` | two cores with the 2-second poll and both sensors, the 87°C run |
| `pollcost-20260913.log` | the 2 s / 20 s / 2 s idle-cost brackets |
| `pollcost.sh` | the script that produced them. It edits `interval=` in the vendor file directly and leaves it at 2 |

Reproduce with `sudo pyra-thermal-probe.sh`, `sudo pyra-ceiling-cost.sh` and
`sudo pyra-charge-probe.sh`; each says what it changes and puts it back.
