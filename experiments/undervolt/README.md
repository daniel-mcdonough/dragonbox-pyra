# Undervolting the CPU operating points

**Status 2026-09-28: 750 MHz steps clean down to 850 mV, the module's floor (−100 mV); 870 mV
saves 0.16 W at 30/750 with no change in frames. Applied from boot since 2026-09-29 (device clock)
by `device/pyra-undervolt.service`, at the owner's request, before the long soak.**

**How it is applied.** `device/pyra-undervolt` (in `/usr/local/sbin`) loads the module from
`/usr/local/lib/pyra-undervolt/` and sets `POINTS` (default `750000:870000`; override in
`/etc/default/pyra-undervolt`); the unit runs it at boot, before `pyra-governor-tune`. It does nothing on
any kernel but 5.6.19-m4-kbdled, so the l4 boot entry is the way back from an unstable setting. Changes on
the fly: `sudo pyra-undervolt set 750000 880000` (checked at 750 MHz under `pyra-cpu-pin`'s pin: the rail
followed, the pin held); `sudo pyra-undervolt off` puts every point back until the next boot;
`sudo systemctl disable pyra-undervolt` for good. `build-module.sh` copies a new build to `device/lib/`,
and `pyra-install-helpers.sh` installs it. **If the Pyra crashes or computes wrong from here on, suspect
this first.** The 2026-09-26 mechanism check is below the results.

## 2026-09-28: the 750 MHz point (SoH's shipped clock, Shipwright report 11 §11.14)

**Stepping** (`stepping/`, logs in `stepping/results-2026-09-28/`), 5.6.19-m4-kbdled, on the charger,
from the table's 950 mV in 10 mV steps. Each step: `stress-ng --cpu 2 --cpu-method all --verify` for
180 s (die ~62-70 °C), then SoH's frozen Market fixture pinned at 750 MHz in `RenderThread` 2, with
`SOH_BENCH_DUMP`.

| mV | stress-ng | Market frames |
| --- | --- | --- |
| 950 (3 runs) | pass | reference |
| 940, 930 | pass | pass (masked, across processes; see below) |
| 920 … 850 | pass | pass: 6 segments in one process, 12 frames, 0 pixels apart |

- **Nothing failed down to 850 mV, where the module stops** (it refuses more than 100 mV below the
  device tree). The chip's edge is somewhere below that and unknown.
- **The frame check has to be in-process.** Two stock runs differ in ~6,000 pixels, all in the
  dancing NPCs: the fixture freezes after a settle counted in rendered frames, so the dance phase
  depends on the frame rate. The first check (mask the pixels where the two stock runs differ)
  stopped 920 mV on 7 pixels of a fern uncovered by a new pose. Each step from 920 on instead runs
  six segments of one process (`bench.sh ab` of a no-op CVar against itself) and requires every
  segment to draw the same frozen frame: a stock control passed, 0 pixels.
- stress-ng from Debian links EGL and dies on the DDK's `libEGL` (`undefined symbol:
  eglCreatePlatformWindowSurface`); `LD_PRELOAD=/usr/lib/arm-linux-gnueabihf/libEGL.so.1` fixes it.
- The per-step screen is ~5 minutes: enough to find a hard edge, not a stability proof. 870 mV is
  30 mV above the last step tested and so at least 30 mV above any failure.

**Watts** (`../power-budget/thermcost.sh undervolt`, on battery, one game process at 30/750 in mode
2, the voltage switched live): 950 against 870 mV.

| | 950 mV | 870 mV | Δ |
| --- | --- | --- | --- |
| ABBA, 4 blocks each | 4.174 W | 4.015 W | **−0.159 W (t −18.7)** |
| 10-min holds (950, 870, 950 again) | 4.212, 4.144 W | 4.024 W | −0.154 W against their mean |
| CPU die, holds | 63.0, 63.8 °C | 61.9 °C | **−1.5 °C** (gpu −1.2, core −1.1) |
| frames lost, holds | 0.71%, 0.57% | 0.68% | none |

The stock holds drifted +0.8 °C over the run, so the temperature is ±0.4 °C. 0.16 W is ~3.8% of the
game's total and ~11% of what it costs above the desktop (1.4 W). Against the owner's 30/1000 of
09-28 (4.51 W, 67.6 °C, a separate run) 30/750 with the GL thread and 870 mV reads −0.49 W and −5.7 °C
(hold against hold; different runs, so ± the run-to-run drift).

**Not done:** a long soak at 870 mV (30-60 min of stress-ng, then real play). It is shipped without it.


Checked on the device:
- `smps123` follows the table exactly at 250/500/625/750/875/1000/1250 MHz (pinned,
  read back from the regulator). The voltage really does scale with the clock.
- `set 625000 890000`: the rail reads 890000 uV at 625 MHz. After `restore`, 625 MHz
  reads 900000 uV again, the module is unloaded and the governor is back on ondemand.
- Each refusal fired with its own message: the running point, 945 mV (off the grid),
  960 mV at 750 (above the device tree), 840 mV at 750 (more than 100 mV below it),
  and 1250 MHz (above the limit).
- 890 mV at 625 MHz ran for about a second at the desktop: that says nothing about
  stability.

## Why

The CPU's voltage comes from `operating-points` on `cpu0` (patch 0007's table,
`experiments/thermals-and-frequency/`). Those are device-tree values, not voltages
calibrated for this chip. The 625 and 875 MHz points are another owner's
interpolation. Switching power goes with V², so every 10 mV at 0.90 V is ~2% of
the CPU's switching power, and leakage falls as well. SoH ships at 20 fps and
625 MHz (Shipwright report 08 §8.45), so 625 MHz / 0.900 V is the first point to try.

Only the CPU rail (`smps123`) is touched. Leave the GPU/multimedia rail and the
core rail alone.

## What is here

| file | runs on | what |
|---|---|---|
| `pyra_undervolt.c`, `Kbuild` | – | module: rewrites one point's voltage in the live OPP table |
| `build-module.sh` | PC | builds and signs `pyra_undervolt.ko` against `src-m4-kbdled` (docker, out of tree) |
| `undervolt.sh` | device | `load`, `table`, `set <kHz> <uV>`, `restore` |

**How the module works.** 5.6 has `dev_pm_opp_adjust_voltage()` but does not
export it. The module finds it with `kallsyms_lookup_name()`, which 5.6 still
exports. The other route, `dev_pm_opp_remove()` + `dev_pm_opp_add()`, is wrong
on this kernel for a point from the device tree: remove drops an OPP-table
reference that only add takes. The OPP table is shared by both cores
(cpufreq-dt calls `dev_pm_opp_set_sharing_cpus` for a v1 table), so one change
covers both.

**What it refuses:**
- points above 1000 MHz;
- any voltage above the device tree's, or more than 100 mV below it;
- voltages off the Palmas SMPS's 10 mV grid (510 mV + n × 10 mV). The OPP core
  checks the grid when it adds a point, but not when it adjusts one.
- changing the point the CPU is running on. The OPP core applies a voltage only
  on a transition to that point, so `undervolt.sh set` pins one step above,
  changes the point, and pins back onto it.

Unloading the module (`undervolt.sh restore`) or rebooting puts every point back.

**Readback:** `omapconf` reads every rail as 0.000 V. The regulator's sysfs
`microvolts` asks the Palmas driver for its voltage register, so it shows the
voltage the PMIC was told to produce, not a measurement. It still confirms that
the change reached the PMIC.

## Procedure

1. `undervolt.sh load`; pin a few clocks; confirm `smps123` follows the table.
2. At 625 MHz, step down 10 mV at a time from 0.900 V. At each step:
   - a CPU stress test that checks its own results, on both cores
     (`stress-ng --cpu 2 --cpu-method all --verify`), cold and hot-soaked;
   - SoH's frozen Market fixture with `SOH_BENCH_DUMP`: the frames must be
     pixel-identical to a dump taken at 0.900 V.
3. At the first failure, stop. Take the last clean step and add 20-30 mV of
   margin. Failures from too little voltage are wrong results, not clean crashes.
4. `thermcost` ABBA at 20 fps / 625 MHz: stock voltage against the chosen one.

**Risk.** A voltage below this chip's need gives silent miscomputation and then
a crash. It cannot damage the silicon (only too much voltage does), but a crash
during a card write can corrupt the filesystem. Keep card writes to a minimum
while stepping, and `sync` before each step.
