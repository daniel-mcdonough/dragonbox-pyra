# The cpufreq governor, measured

Item 1 of `docs/improvements.md` has been the top of the performance list since
it was written, and had never been measured. It is now. **The answer is that
item 1 named the wrong settings.** The three it blamed are worth nothing; the
one it listed third and passed over is worth 23%.

Measured 2026-09-13 on `5.6.19-freq` with `device/pyra-governor-sweep.sh`, two
interleaved passes per configuration, on battery, with the thermal daemon
stopped and the frequency ceiling pinned at 1500 MHz. Raw logs in this
directory.

## Result

Burst latency is the number item 1 is about: a short unit of work, with idle
between units, which is where a slow ramp is felt.

| config | what it changes | burst mean | vs stock | p50 | p99 |
| --- | --- | --- | --- | --- | --- |
| stock | — | 53.8 ms | baseline | 53.5 | 62.3 |
| `up80` | `up_threshold` 95 → 80 | 53.2 ms | −1.1% | 53.3 | 61.6 |
| `up70` | `up_threshold` 95 → 70 | 52.8 ms | −1.9% | 52.8 | 62.1 |
| `io1` | `io_is_busy` 0 → 1 | 53.1 ms | −1.2% | 53.2 | 61.8 |
| `min500` | floor 250 → 500 MHz | 52.8 ms | −1.9% | 52.8 | 59.7 |
| `min750` | floor 250 → 750 MHz | 49.3 ms | −8.4% | 49.3 | 56.2 |
| **`sdf10`** | **`sampling_down_factor` 1 → 10** | **41.2 ms** | **−23.4%** | **36.0** | **58.3** |
| `tuned` | all four together | 40.6 ms | −24.5% | 35.8 | 57.4 |
| `performance` | the ceiling | 34.5 ms | −36.0% | 33.9 | 43.4 |

Pass-to-pass spread was 0.0–2.3%, so every difference above except the four
small ones is many times the noise. The stock row is the clean second pass
only; see the honesty note below.

## What this says

**`sampling_down_factor` is the whole result.** It is the only knob that moves
anything, `tuned` beats it by 1.1 percentage points, and that last point is
inside the spread. Setting one value gets the entire win.

What it does is stop the governor dropping the clock at the first idle sample.
Stock is 1, meaning the clock falls the instant a unit of work ends; 10 means
it waits ten sampling periods. Bursty work stops paying the ramp on every unit
and pays it once, which is why the median improves by a third — 53.5 ms to
36.0 ms — while the mean improves by a quarter.

**The three settings item 1 actually blamed do nothing.** `up_threshold` at 80
or 70 is worth about 1%, `io_is_busy` about 1%, and a 500 MHz floor about 2%.
The reasoning in item 1 was that a core must be 95% busy across 20 ms before
the governor steps up, and that ordinary interactive work never triggers it.
That is a correct description of the setting and the wrong conclusion about the
consequence: the work does trigger a step up, and what costs time is the
governor stepping back *down* between units.

**The tail is the disappointment.** `sdf10` takes the median down 33% and p99
down only 6.4%. It keeps the clock up between units of a burst, so consecutive
work is fast, but the first unit after genuine idle still pays the full ramp.
Since "sluggish" describes a tail, the felt improvement will be smaller than
the mean suggests. `min750` is the only ondemand setting that does better on
the tail than the mean (−9.9% at p99), and it costs 83% more idle frequency to
get there.

**Tuned ondemand is still 18% off `performance`**, which is a larger remaining
gap than tuning closed. That gap is the ramp itself and no `ondemand` setting
reaches it.

## The cost

| config | idle mean freq | vs stock | % of idle at 1500 MHz |
| --- | --- | --- | --- |
| stock | 421144 kHz | baseline | 0.7% |
| `sdf10` | 443987 kHz | +5.4% | 3.5% |
| `tuned` | 616026 kHz | +46% | 10.2% |
| `min750` | 768982 kHz | +83% | 0.7% |
| `performance` | 1500000 kHz | +256% | 100% |

`sdf10` costs 5% on idle mean frequency, which is the cheapest of the lot: it
holds the clock up after work, and an idle machine has no work to hold it up
after. `tuned` costs 46% and ten percent of an idle machine at full speed,
which is the floor and `up_threshold` changes doing damage that `sdf10` alone
does not. That is the second argument for setting one knob rather than four.

**The idle power column of this run is not usable** below about 0.5 W, and it
is reported here only as the reason not to quote it. The recommendation above
rests on residency, which is measured cleanly, and on the burst numbers.

## Recommendation

Set `sampling_down_factor` to 10 and leave the other three alone. It is 23% of
burst latency and a third of the median for 5% of idle frequency, it is one
value, and it does not touch the floor or the thresholds.

It is not persistent: these are sysfs files and a reboot restores 1. Making it
stick is a separate change and has not been made.

## Honesty notes

Three things went wrong and are recorded because the numbers above only mean
something with them attached.

**The first run of the day is void, and it is in this directory as
`sweep-20260913-run1.log`.** It ran with the thermal daemon left alone, on the
reasoning that the daemon owns `scaling_max_freq` since fix 6 and a sweep
fighting it would be measuring the fight. That was the wrong conclusion from a
correct premise: leaving it alone did not avoid the fight, it hid it. The
vendor ladder caps on **battery** temperature as well as core —

    elif [ ${battery_temp} -gt 44000 ]; then setMaxFreq 1250

— and the battery sits at 42–45°C in ordinary use. It crossed 44°C partway
through, the ceiling fell from 1500 to 1250 MHz with the CPU at 59°C, and
every configuration measured afterwards ran under a lower ceiling than the
ones before it. That showed up as the second pass being uniformly slower than
the first, and as the `performance` governor — which ran last in each pass —
coming out *slower* than tuned ondemand, which is impossible. Pinning the
ceiling took the pass-to-pass spread from 6.7–23% to 0.0–2.3%.

**Rotation was added at the same time.** Interleaving the passes fixed drift
between passes but left every configuration in a fixed position within one, so
a drift inside a pass still landed on whatever ran last. Each pass now starts
one place further along.

**The stock configuration's first idle window is contaminated and was dropped.**
`pc/pyra-push-helpers.sh` was run against the device from the workstation while
that window was being measured, which is an rsync and an install landing in the
middle of a measurement of an idle machine. It reads 602890 kHz and 4.25 W
against 421144 kHz and 3.87 W for the clean second pass. The summary printed by
the script averages both and therefore overstates the stock idle baseline; every
idle figure quoted above is recomputed against the clean window. The burst
figure for stock is unaffected in any way that matters — 52.6 and 53.8 ms
across the two passes — because the install had finished before the burst
phase began.

The lesson for the harness, and the reason the sweep now records the backlight
around every power window: a sweep measures an idle machine, so anything done
to that machine while it runs is part of the measurement.
