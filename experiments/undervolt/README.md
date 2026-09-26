# Undervolting the CPU operating points

**Status 2026-09-26: the mechanism works on the device (5.6.19-m4-kbdled). No
stability stepping yet; nothing is left loaded.**

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
