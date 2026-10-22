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
The same thread says the thermistor line also reaches the CPU module. If so,
a real cell temperature may be readable through the Palmas GPADC. That is the
sensor a software guard would need, and the charge current, not the input
limit, is what it should act on.
