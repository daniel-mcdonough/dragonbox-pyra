# Why the Pyra goes flat on a charger

2026-09-13. One machine, DragonBox Pyra V5.3, Debian 13, kernel 5.6.19-freq.

## How this got found

It was not the question being asked. The question was whether the thermal
daemon's charge ladder — the half of `pyra-thermal.sh` that picks a charge
current from temperature — does anything useful, which was the last loose end
of [the thermal ladder work](../thermal-ladder/README.md). Answering it needed
a charger attached, so one was attached, and the battery went **down**.

That was written off once as a weak USB port. It happened again on a different
supply. The second time the numbers got read properly.

## The measurement

Idle, charger attached, nothing running but the desktop:

    /sys/class/power_supply/bq24297/online                 1
    /sys/class/power_supply/bq24297/status                 Not charging
    /sys/bus/i2c/.../max_current                      500000
    /sys/class/power_supply/bq27421-0/current_now     -617000
    /sys/class/power_supply/bq27421-0/status               Discharging
    /sys/class/power_supply/bq27421-0/capacity              21

REG08 read `0x0c`: power-good set, charge state `00` (not charging), and
`DPM_STAT` set — the chip was regulating against its input limit.

The machine draws about 620 mA at idle. The charger was admitting 500 mA. The
battery covered the difference. Nothing is broken in the sense of faulty; the
limit is simply lower than the machine's own appetite, so the cable cannot keep
up no matter what is on the other end of it.

## The one write

    echo 2000000 > /sys/bus/i2c/drivers/bq2429x_charger/*/max_current

Immediately: `REG00` `0x32` → `0x36` (IINLIM `010` → `110`), battery current
−617 mA → 0, then positive. Voltage 3.709 → 3.731 V within five seconds.

Then 899 seconds of it, sampled every second
([chgwatch-2A-20260913.tsv](chgwatch-2A-20260913.tsv)):

| | |
| --- | --- |
| battery current | mean **+476 mA**, min 202, max 531 |
| capacity | 21% → 23% |
| voltage | 3.766 → 3.782 V |
| `REG08` | `0x2c` on **all 815 samples** — fast charging, PG good |
| `REG09` | `00` on all 815 samples — no faults |

Same supply. Same cable. One register.

## Is 2 A the right number?

[chgwatch-3A-20260913.tsv](chgwatch-3A-20260913.tsv) is the same thing with the
limit at 3 A, the chip's ceiling and what the device tree calls
`usb_input_current`:

| limit | battery current | window | pack at the start |
| --- | --- | --- | --- |
| 2 A | **+476 mA** | 899 s, 815 samples | 21%, 3.766 V |
| 3 A | **+455 mA** | 267 s, 243 samples | 23%, 3.784 V |

No gain — the 3 A figure is lower, and the battery was fuller by then so some
taper is expected.

**Corrected 2026-09-18.** This table read "452 mA over 177 s" for the 3 A arm
until the numbers were recomputed from the committed TSV, which does not support
it. Where the discrepancy came from is not recoverable; what the file says is:

- The capture runs 339 s, but `iinlim` is 3000000 only for t=0–267 and drops
  back to 2000000 for the tail, so averaging the whole file gives 454 mA over
  339 s and is measuring two configurations at once.
- Over the 3 A segment alone, 243 samples: **+455 mA**.
- Discarding the first 90 s as settling, 161 samples: **+466 mA**. That is the
  177-second window in the old table, but not the figure that was printed
  beside it.

Either reading is below the 2 A arm's 476 mA, and the 2 A arm measured the same
way — from t=90 — gives 475 mA, so the comparison does not depend on where the
window starts. The conclusion is unchanged and slightly stronger. Reproduce with:

    awk -F'\t' 'NR>1 && $2==3000000 {n++; s+=$4} END {print s/n, n}' \
        chgwatch-3A-20260913.tsv

`DPM_STAT` stayed set throughout both arms while the total input draw was well
under 1 A. That combination has one meaning: the chip is regulating against **VINDPM**, not against the limit. VBUS
is sagging to the 4.36 V threshold.

That is the cable. The owner had already guessed as much — "the cable is pretty
long so that may impact it" — before any of this was measured, and the register
agrees. **A shorter or thicker cable is worth real charge rate here. A bigger
number in the config is not.**

2 A is also what this board's own device tree calls `adp_input_current`, so the
default follows the hardware description rather than an opinion.

## Why nothing ever set it

Three mechanisms, none of them working, each of which looks like it should.

### 1. The udev rules are for a different machine

`/lib/udev/rules.d/charging.rules` is the intended mechanism. Every rule in it
that works names **twl4030** — the OMAP3 charger, as found on the GTA04. This
is an OMAP5 with a bq24297. The Pyra rules are in the same file, immediately
below, under a comment the vendor wrote and which is entirely accurate:

    # 3. this is preparation for the Pyra but neither tested nor complete
    #    nor working

They also try to symlink `/sys%p/id`; the bq24297 has no `id` attribute. The
helper they invoke, `charging.sh`, reads `/dev/usb_id` and chooses between
500 mA and 851 mA from the ID-pin resistance of an **Openmoko wall charger**.

### 2. So the file the daemon writes to is not a symlink

Rule 3 was meant to make `/dev/usb_max_current` point into the charger's sysfs.
It never ran, so the first process to write that path as root created it:

    -rw-r--r-- 1 root root 7 /dev/usb_max_current      <- regular file 0:0

That process is the thermal daemon, which writes its charge-current decision
there on every poll. Nothing reads it. That half of the daemon has never had an
effect, on any Pyra running this image, ever.

This is a direct correction to the fix 6 write-up, which said the daemon "has
been managing the charger correctly". What had been verified there was that the
write did not fail. That is not the same claim, and the wrong one got made.

An earlier arm of [charge-probe-20260913-190806.tsv](charge-probe-20260913-190806.tsv)
had already produced the evidence and it was misread: with the daemon stopped
and `3000000` written to `/dev/usb_max_current` by hand, `input_current_limit`
did not move. That was recorded as an open question — "writing it produced no
observable change in either direction" — when it was the answer.

### 3. The driver parses the right numbers and drops them

From `dmesg` at probe:

    bq2429x_charger 1-006b: bq2429x_parse_dt,line=1537 chg_current = 2048000
        usb_input_current = 3000000 adp_input_current = 2048000
        bat_volt_max = 4200000

All four values are read out of the device tree. The input limit is then left
at whatever the chip powers up with.

## A register that was read wrong on the way

Partway through, `REG09` read `0x01`, which the driver logs as `HOT`, and this
was taken to mean a hardware NTC fault was blocking charging. It was not.
REG09 is read-to-clear: that was a stale latch, and across 815 subsequent
samples of an actively fast-charging battery it read `00` throughout.

The lesson is in the script now — `pyra-chgwatch.sh` says in its own header not
to conclude anything from one read of that register.

## A second, smaller thing the charger's sysfs gets wrong

While charging at half an amp with `REG08` reporting fast charge, the charger's
own `status` attribute reads `Not charging` while the gauge reads `Charging`.
Cosmetic, but it means any desktop indicator reading the charger rather than
the gauge will lie.

## What went in

`device/pyra-charge-current.sh` — config, an idempotent one-line helper, and a
udev rule in `/etc/udev/rules.d` that re-applies the limit on `add` and
`change`. The limit is a register and does not survive an unplug or a boot.

The rule was verified by knocking the register down to 500000 and firing each
event with `udevadm trigger`; it came back to 2000000 both times. **A physical
unplug and replug has not been tested.** That needs hands on the device.

Deliberately *not* done: connecting the thermal daemon's charge ladder to the
working knob. That ladder reads the fuel gauge's die temperature and caps at
500 mA above 44°C, and this machine idles with that sensor at 46–47°C. Wiring
it up before recalibrating it would re-impose the exact cap this work removed,
permanently. See [fault 1](../thermal-ladder/README.md).

## 2026-10-22: the ladder got connected, and the USB3 port

Kernel `5.6.19-m4-kbdled`, `pyra-hacks 0.38+pyra1`. A 15 W USB-C brick.

### The daemon's charge half was not disconnected any more

The section above says the ladder writes into a plain file that nothing reads.
On this date `/dev/usb_max_current` was a **symlink to the charger's
`input_current_limit`**, on two consecutive boots. It is a race: the stock
`charging.rules` and the daemon's first poll both go for the path, and
whichever is first decides what it is. In September the daemon won. Here the
rule did, and the ladder was driving the real limit.

The gauge die sits at 42–43.5 °C while charging, which is exactly where the
ladder's 3 A / 2 A / 1 A rungs are, and the charge ladder has no hysteresis.
The limit flapped every few seconds:

| log | limit changes in 300 s | time at 1 A |
| --- | --- | --- |
| [USB3 port](chgwatch-usb3-ladder-20261022.tsv) | 10, all in the first minute | 8 samples |
| [normal micro port](chgwatch-micro-ladder-20261022.tsv) | 21 | 62 samples, mean +297 mA into the battery |

Fix 8 now masks the stock rules with a `charging.rules` of its own in
`/etc/udev/rules.d`, so the link is never made. Checked live: after the
change the daemon's next poll wrote `1000000` into an ordinary file in `/dev`
and the charger stayed at 2 A.

### USB3 micro port against the normal micro port

Same brick throughout. Settled samples only: three seconds after any limit
change are discarded, because the gauge's `current_now` lags the register.

| path | limit | into the battery |
| --- | --- | --- |
| normal micro, long cable (2026-09-13) | 2 A | +476 mA |
| normal micro, USB-C→A adapter, short micro cable | 2 A | **+999 mA** (177 samples) |
| USB3 micro, USB-C adapter | 2 A | **+1312 mA** (237 samples) |

The short cable alone doubled the normal port, which bears out the cable
diagnosis above. The USB3 path gives another ~310 mA at the same limit. Both
had `DPM_STAT` set, so the gap is most likely VBUS lost along the adapter,
cable and connector on the micro path. That is not separated out: the two
paths differ in adapter as well as port.

On plug events the charger classified the brick as an adapter on the USB3
port (REG08 `0xac`, `VBUS_STAT` `10`) and as unknown on the normal port
(`0x2c`). After a boot with the cable already in, it reads `00` on either,
and `bq24297/online` reads `0` while charging at 1.2 A. Neither affects the
limit, which is set by the helper regardless.

### 2 A against 3 A, with nothing else touching the limit

USB3 port, 240 s each, back to back, 56% → 60%:

| limit | into the battery | REG08 |
| --- | --- | --- |
| [2 A](chgwatch-usb3-2A-20261022.tsv) | **+1342 mA** | `0x2c` on all 217 samples: input-limited |
| [3 A](chgwatch-usb3-3A-20261022.tsv) | **+1518 mA** | `0x24` on 216 of 217: not input-limited |

Unlike September, 3 A does buy something here (+176 mA), because this supply
and cable no longer sag to VINDPM. It also stops being the input limit that
binds, but the result still falls short of the 2048 mA charge setting
(REG02 `0x60`), and nothing in REG08 says why. The default stays at 2 A,
because the setting applies to every supply plugged in. A 3 A brick can be
given 3 A in `/etc/default/pyra-charge-current`.

### What protects the cell, now that nothing in software does

The charger's TS pin, on the pack's 10 k 103AT thermistor. A community
member measured that divider on a stock board
([forum thread](https://pyra-handheld.com/boards/threads/bq24297-thermistor-ntc-resistors-hot-fault.99405/)).
The design intends a hot cut-off at 45 °C. Because the CPU module's
R2001/R2002 sit in parallel with R710, the board actually trips at about
**38 °C**. That is conservative. This machine has latched the fault: the
kernel log on 2026-10-22 has `r9=11 UNPLUG HOT` at 165 s.

Those figures are from another board and have not been measured on this one.
The forum's own numbers don't agree with each other either (its two measured
trip points, worked back, give different top resistors), so treat 38 °C as
unconfirmed.

#### The thermistor is readable: Palmas GPADC channel 0 (measured 2026-11-19)

The thread says the thermistor line (BTEMP) also runs to the CPU module, pin
P2001:38, through R2001 100 k and R2002 33 k to ground. On this V5.3 board
(`5.6.19-m4-kbdled`) that tap is **`palmas-gpadc` channel 0**:
`/sys/bus/iio/devices/iio:device1/in_voltage0_input`, in mV (the device
number can change; match on `name` = `palmas-gpadc`). Read with `cat`, no
writes:

| state | IN0 | IN1 | IN10 (VBUS) | gauge temp |
| --- | --- | --- | --- | --- |
| battery, no charger | 111 mV | 5-9 mV | 0 | 27.1-27.5 °C |
| charger in, charging | 841 mV | 6-13 mV | 4948 mV | 27.6 °C |
| 20 min later | 800 mV | 9 mV | 4916 mV | 32.0 °C |

[The 20-minute log](gpadc-in0-charge-20261119.tsv) has 40 samples at 30 s,
charging at 335 → 199 mA, 85 → 86 %. Over it, IN0 falls as the bq27421
gauge's temperature rises: -10.2 mV per gauge °C, correlation -0.96, scatter
3.4 mV. That is the direction an NTC gives (warmer, lower resistance, lower
BTEMP). Three things say it is the thermistor:

- **It is only biased with a charger in.** The divider hangs off the
  bq24297's REGN, which is off without VBUS. On battery, IN0's 111 mV is the
  GPADC's own 5 µA channel-0 current source (`ti,channel0-current-microamp`
  in `omap5-board-common.dtsi`) across the divider: the resistor values
  predict 125 mV.
- **It lands where the divider says.** 33/133 of the TS window (2.15-3.53 V
  at REGN ≈ 4.8 V) is 0.53-0.88 V; 841 mV is inside it.
- **It tracks the pack while charging** (the log above).

**IN1 is not it.** Goldelico's `pyra-mainboard-common.dtsi` declares a
`linux,generic-adc-battery` (`battery-monitor`) whose "temperature" is
`<&gpadc 1>`. On this board IN1 reads under 15 mV with or without a charger.
That driver is built as a module (`generic-adc-battery.ko`) and binds
nothing here: the vendor's `pyra-config-modprobe` blacklists it
(`/etc/modprobe.d/pyra-noadcbat.conf`, since pyra-config 0.26, 2020), and
letux-current's driver matches only `adc-battery`, not the node's
`linux,generic-adc-battery` (checked at 7.4-rc3, 2026-11-19; report draft
`reports/letux-pyra-battery-monitor-gpadc.md`). Its voltage channel, IN6, does
follow the battery: 4006 mV against the gauge's 4046 mV while charging
(measured 2026-11-19). Its "current" channel, `<&gpadc 11>`, reads 0 too.
**The bq24297's `temp` is not a reading:** the driver returns a fixed
22.5 °C, or -10 / 60 °C from the fault bits.

**Converting IN0 to °C (estimated, not calibrated).** A circuit model fits
the log: REGN on a top resistor to BTEMP; BTEMP to ground through the NTC
(10 k, B 3435), R710 31.6 k and R2001 + R2002; plus 5 µA into the tap. With
the pack taken to be at the gauge's temperature, the best fit is a top
resistor of 4.7 k and REGN = VBUS - 0.02 V (rms error 4 mV). That gives,
at VBUS 4.91 V:

| pack °C | 0 | 10 | 20 | 25 | 30 | 35 | 40 | 45 | 50 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| IN0 mV | 1025 | 968 | 898 | 858 | 817 | 775 | 731 | 688 | 645 |

Don't build a guard on that table yet. The fit has two unknowns that trade
off against each other, and the bq27421 reports its own die temperature,
not the pack's: the predicted slope (-8.4 mV/°C) is shallower than the measured
-10.2, which suggests the pack and gauge temperatures differ. Calibrating it
needs IN0 at two known pack temperatures.

**The trip points, in IN0 terms (datasheet-derived).** The TS comparator
compares BTEMP to fixed fractions of REGN, so each trip maps to an IN0
voltage without the NTC curve. TI's BQ24296/BQ24297 datasheet (SLUSBP6D,
revised April 2023, §8.5 "Cold/hot thermistor comparator" and §9.3.3.3) gives
one window for charging, with no JEITA warm/cool steps:

| threshold | what it does | % of REGN (min / typ / max) | IN0 mV at VBUS 4.91 V (min / typ / max) |
| --- | --- | --- | --- |
| VTCO, falling | **hot cut-off while charging**: charge suspends | 44.2 / 44.7 / 45.2 | 660 / **666** / 672 |
| VHTF, rising | hot limit to start, or resume, a charge | 46.6 / 47.2 / 48.8 | 689 / **697** / 716 |
| VLTF, rising | cold limit: charge suspends | 73.0 / 73.5 / 74.0 | 1010 / **1016** / 1022 |
| VLTF − 0.4 % hysteresis, falling | cold recovery | 72.6 / 73.1 / 73.6 | 1005 / **1011** / 1017 |

So 0.447 (the forum's figure) and 0.475 (this README's alternative) were
not rival values for one threshold. 0.447 is VTCO, the trip during a charge, and it is the one a guard
must stay above. The ~0.47 figure is VHTF, the level BTEMP must climb back
over before charging restarts; the two together are the hot hysteresis,
2.5 % of REGN, about 30 mV at IN0. (Revision B of the datasheet changed the
VHTF typical to 47.2 % and its direction to rising; the earlier value is not in
the current revision.) The datasheet also lists VBHOTx/VBCOLDx thresholds;
those apply only in boost (OTG) mode and don't gate charging.

How the IN0 column is computed: with BTEMP held at the threshold, the tap is
IN0 = BTEMP × 33/133 + 5 µA × (100 k ‖ 33 k) = 0.2481 × f × REGN + 124 mV,
with REGN = VBUS − 0.02 V from the fit (here 4.89 V). The datasheet gives REGN
only at load (4.8 V typical, 4.7 V minimum, at VBUS 5 V and 20 mA) and says the
LDO is in dropout, so REGN sits close to VBUS at light load; the divider draws
well under 1 mA, so VBUS − 0.02 V is consistent with that but is the fit's
number, not the datasheet's. Two things make the column an estimate around the
datasheet values. The 5 µA source's 124 mV offset assumes 5.0 µA, and on battery
the source read 111 mV where 125 was predicted, so the real levels may be up to
about 13 mV lower. And REGN scales them: per 0.1 V of VBUS, VTCO moves 11 mV.
A guard should compute the trip from IN10 each time, not use the fixed column.

Checked against the provisional table: VTCO's 666 mV falls at about 47.6 °C,
VHTF's 697 mV at about 44 °C and the cold trip at about 2 °C. The table is not
calibrated, so those temperatures are estimates; they don't confirm or refute
the forum's 38 °C. The 20-minute log's lowest IN0 was 797 mV (VBUS about
4.91 V), about 130 mV above the hot cut-off.

**Leave it read-only.** IN2 is the volume wheel (`pyra_volumed`, fix 26),
read on the same ADC; a guard that reads IN0 must not reconfigure the GPADC.

The charge current, not the input limit, is what a guard should act on.

#### Logging the margin: `pyra-chgwatch.sh --ts` (measured 2026-11-20)

`device/pyra-chgwatch.sh --ts [FILE] [SECONDS] [INTERVAL]` logs the margin
without touching the charger or the GPADC. Run it with sudo so the kernel-log
column works. It reads IN0 and IN10 from the `palmas-gpadc` IIO device and
computes VTCO and VHTF from IN10 on every sample, with the formula above.
It also logs the gauge's temperature and current and the charger's status.
For faults it records the bq24297 driver's own `temp` (225 no fault, 600 HOT,
-100 COLD, from the driver's copy of REG09) and any new `r8=.. r9=..` lines
the driver put in the kernel log.

It doesn't read the driver's `registers` file. That file reads all eleven
registers straight off the chip, outside the driver's lock, and doesn't
update the driver's copy. So every read of it clears REG09's latch, and a
fault latched between two of the driver's reads can vanish before the
kernel log sees it. On this board the driver reads REG09 only on the
charger's interrupt (no "polling" warning at probe, and no polling after a
resume either: its suspend/resume hooks never run on 5.6, measured
2026-11-20), so a kernel-log line marks an event. The default mode still
reads `registers`; on the shipped kernel its reg09 column is the latch it
just cleared. `patches/0054` (developer kernels only so far) makes the file
print the driver's copy instead, so with it the default mode is safe too.

**How to read the margin.** `margin_mV` is IN0 − VTCO, computed for the VBUS
of that sample. It shrinks as the pack warms (IN0 falls). At 0 the bq24297
suspends charging and should log `HOT`. Charging restarts only once IN0 is
back above `vhtf_mV`, about 30 mV higher. It is NA without a charger: REGN is
off then, and IN0 is only the 5 µA source (about 111 mV). Two cautions:
the levels may be up to about 13 mV high (the 5 µA offset, above), so treat
a margin under about 15 mV as already at the trip; and one sample moves
with VBUS noise (IN10 spanned 4889-4988 mV in this run, which shifts VTCO by
±5 mV), so read the trend, not a single row.

**One charge** ([ts-margin-charge-20261120.tsv](ts-margin-charge-20261120.tsv),
`5.6.19-m4-kbdled`, release card, 10 s samples, desk at room temperature,
idle desktop): plugged in at 86 %, fast charge at 368 → 145 mA, then
`CHGTERM` after 27 min (the gauge still said 87 %). Over 164 samples with
the charger in:

| | start | end | min |
| --- | --- | --- | --- |
| IN0 | 839 mV | 786 mV | 778 mV |
| VTCO (computed) | 668 mV | 669 mV | 666-671 mV over the run |
| margin | 171 mV | 117 mV | **111 mV** |
| gauge temp | 27.5 °C | 32.9 °C | |

No `HOT` and no other fault: `chg_temp` stayed 225, and the only kernel-log
lines were the plug-in (`r9=10 UNPLUG`, then `ADAP FCHG`) and the
termination (`ADAP CHGTERM`). IN0 fell 9.9 mV per gauge °C (correlation
−0.95), matching the 2026-11-19 log's −10.2. Extrapolating that line
(estimated, and the gauge is not the pack), the margin would reach 0 near a
gauge reading of 44 °C. This run doesn't measure the trip (TODO E9 b): a
charge in a warm room, or under load, might.

## The charge voltage is 4.048 V, set by the driver from the vsys limit (checked 2026-11-20)

The charger stops at about 4.05 V, not the battery's 4.2 V. That is why a
charge ends `CHGTERM` with the gauge at 87 % (the run above: 4.04 V, 87 %).
Nothing in userspace sets it. The kernel driver does, at probe, on purpose,
from a device-tree value that isn't the battery's.

**The register.** `registers` on the release card read REG04 = `8a`. Per TI's
datasheet (SLUSBP6D, §9.6.1.5), bits 7-2 are VREG: offset 3.504 V, 16 mV
steps, so `100010` = 34 steps = **4.048 V**. Bit 1 (BATLOWV) is 1, 3.0 V, and
bit 0 (VRECHG) is 0, so a new charge starts once the cell falls 100 mV below
VREG (about 3.95 V). The chip's own default is `0xB2`, 4.208 V. So the 4.048 V
is a host write, not a power-on or watchdog reset. A watchdog expiry would
restore 4.208 V, and REG05 = `8c` shows the watchdog off anyway.

**The writer.** In `bq2429x_init_registers()` (5.6.19, the vendor's
`5.6.19-pyradef` and every kernel built here), the charge voltage is

    max_uV = min(max_VSYS_uV - 150000, battery voltage-max-design-microvolt)
    VREG bits = (max_uV - 3504000) / 16000          /* rounds down */

`max_VSYS_uV` is the `regulator-max-microvolt` of the charger's `vsys`
regulator node. `pyra-mainboard-common.dtsi` sets it to 4200000, and the
battery node also says 4200000. So the result is min(4.05, 4.2) V = 4.05 V,
which rounds down to 34 steps, 4.048 V. Boot log on the release card:

    bq2429x_parse_dt,line=1547 ... bat_volt_max = 4200000
    found regulator-max-microvolt = 4200000

The driver's comment gives the reason: VSYS can sit up to 150 mV above a full
battery when running from VBUS, so to keep VSYS under its limit it lowers
the battery voltage. The datasheet agrees on the 150 mV (§7.5: VSYS_MAX
4.35 V typical with VBAT up to 4.2 V and the BATFET off). The code and the
4.2 V vsys value date from the driver's first commit (2014) and the Pyra
board DT split (2019). Current letux still has both unchanged (checked
2026-11-20). So every Pyra kernel has charged to 4.05 V. The 150 mV offset is
deliberate. Nothing written down says whether 4.2 V is a real VSYS rating or
the battery's number copied into the regulator node. The chip's default
mode, before Linux probes it (charging while off, U-Boot), uses 4.208 V and
lets VSYS reach about 4.35 V.

**No runtime knob on 5.6.** This driver has no `constant_charge_voltage`
property, and the image has no udev rule, unit or pyra-hacks tool that
touches REG04 (grep of `/usr/lib/udev`, `/etc/udev`, `/etc/systemd`,
`/usr/lib/systemd`, `/usr/local`, `/usr/bin`, `/usr/sbin` on the release
card; `i2cset` isn't installed; the pyra-hacks, pyra-settings, pyra-sound
and pyra-backlight sources have no `i2cset`, `0x6b` or charge-voltage
write). Only the device tree changes it. Current letux exposes
`constant_charge_voltage_max` as writable. Patches 0042 and 0054 don't touch
this path.

**What it costs and buys.** Measured: one charge ended at 4.04 V with the
gauge at 87 % (2026-11-20, above). Estimated, from general Li-ion behaviour
and not measured on this pack: stopping about 150 mV short gives up roughly
10-15 % of capacity and gives the cell noticeably more cycle life. With the
thermal daemon's charge ladder disconnected (fix 8), the TS pin is the only
cell protection, so the lower voltage is also the gentler default. Raising it
means setting the vsys `regulator-max-microvolt` to 4350000, which gives
VREG 43 steps = 4.192 V because the battery's 4.2 V caps it and the encoding
rounds down. Do that only after the schematic shows that everything on VSYS
is rated for 4.35 V.
