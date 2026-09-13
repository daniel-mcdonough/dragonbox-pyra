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

| limit | battery current | window |
| --- | --- | --- |
| 2 A | 476 mA | 899 s |
| 3 A | 452 mA | 177 s |

No gain — the 3 A figure is if anything lower, and the battery was fuller by
then so some taper is expected. `DPM_STAT` stayed set throughout both arms
while the total input draw was well under 1 A. That combination has one
meaning: the chip is regulating against **VINDPM**, not against the limit. VBUS
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
