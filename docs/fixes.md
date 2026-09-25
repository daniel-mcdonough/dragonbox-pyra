# The eleven fixes, and what they actually do

The procedure that applies them is `procedure.md`. The dated record of each one
being checked against the image and the hardware is `verification-log.md`.


### Fix 1 — Xorg segfault at startup (SUPERSEDED, see fix 4)

**This fix does not work. Keep reading only for the diagnosis; fix 4 is what
you actually apply.** The prep script *removes* the symlink if it finds one: it
solves nothing and only makes the Xorg log harder to read.

Symptom as shipped:

    (EE) AIGLX error: dlopen of .../dri/armsoc_dri.so failed (No such file or directory)
    (EE) AIGLX error: unable to load driver armsoc
    (EE) Segmentation fault at address 0x0
    (EE) Caught signal 11 (Segmentation fault). Server aborting

The documented fix symlinks `armsoc_dri.so` to `kms_swrast_dri.so`. On the real
t1 image that changes the message and nothing else:

    (EE) AIGLX error: armsoc exports no extensions
         (/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so: undefined symbol: __driDriverExtensions)
    (EE) Segmentation fault at address 0x0

Why no symlink can ever work: Xorg's AIGLX builds the symbol it looks up from
the DRI2 driver name the DDX reports. `xf86-video-armsoc` hardcodes that name
as `armsoc`, so Xorg dlopens `armsoc_dri.so` and asks for
`__driDriverGetExtensions_armsoc`, falling back to the pre-2013
`__driDriverExtensions`. Mesa 25.0.7 has collapsed every DRI driver into
`libdril_dri.so`, its DRI-legacy stub, which exports exactly one
`__driDriverGetExtensions_<name>` per driver name it was *built* for — 58 of
them, and `armsoc` is not among them — and does not export the legacy symbol at
all. The symlink target is irrelevant: the lookup is by name, and the name is
wrong. Verified with `nm -D` on the image's own `libdril_dri.so`.

Things that were tried on the device and did **not** work:

| Attempt | Result |
| --- | --- |
| Symlink to `kms_swrast_dri.so` (the documented fix) | Segfault, different message |
| C shim exporting `__driDriverGetExtensions_armsoc`, forwarding to `kms_swrast` | Lookup succeeds, then `Error creating gpu or npu`, segfault |
| Same shim forwarding to `swrast` | Segfault |
| Either shim with `LIBGL_ALWAYS_SOFTWARE=1` and/or `GALLIUM_DRIVER=llvmpipe` | `Error creating gpu or npu`, segfault |
| `Section "ServerFlags" Option "AIGLX" "off"` | No effect — the option no longer exists; the string is absent from the 21.1.16 binary |
| `Section "Extensions" Option "DRI2" "Disable"` | No effect — does not stop the AIGLX probe |

The shim is worth understanding because of *where* it fails. Once the symbol
resolves, mesa's stub tries to build a gallium screen on the omapdrm fd and
cannot, because there is no gallium driver for omapdrm and its software
fallback does not take over. It returns failure, and Xorg 21.1.16 then
segfaults.

That is the actual bug, and it is bigger than the missing driver: **every**
failure path in 21.1.16's AIGLX DRI2 probe NULL-derefs instead of returning
cleanly. Xorg is supposed to fall back to software GLX when that probe fails,
which is exactly what bookworm's 21.1.7 does with the identical missing driver.
There is no way to make the probe *succeed* on this hardware, so the only
remedy is to stop it running.

### Fix 2 — first-run wizard powers the unit off

With X fixed you boot to the fullscreen Pyra wallpaper and then the device
powers off. Nothing crashed. `pyra-first-run.sh` sets the wallpaper, then shows
a zenity question dialog whose cancel button is labelled "Shutdown". In that
bare xinit session the dialog gets no usable input, so the script takes the
cancel branch and calls `poweroff`.

The script marks the run done and creates offline the user the wizard would
have created.

Caveat from the original report: the wizard was never retested *after* X was
properly fixed, so it may well behave now. Skipping it is the path known to
work.

### Fix 3 — dead nubs

A genuine packaging bug. `funkeymonkey-pyrainput` 0.1.19 in the **trixie** repo
ships without `/lib/systemd/system/pyrainput.service`. The identical version in
the **bookworm** repo has it. The script writes the unit and enables it offline.

Verified by pulling both `.deb`s and diffing their contents. Same version
0.1.19 in both suites; bookworm's ships `lib/systemd/system/pyrainput.service`
and trixie's does not. The unit the script writes is byte-identical to
bookworm's, so this is a faithful restore rather than a reconstruction.

`/etc/pyrainput.cfg` is a separate, smaller problem. No package in *either*
repo ships it, so this is not a trixie regression, but `libpyrainput` logs
`ERROR: Could not open config file` when it is missing and the unit is
`Restart=on-failure`. The script now creates it empty, which is exactly what
`pyrainputctl` does on first use and leaves the module on its built-in
defaults.

Worth filing upstream so the package gets rebuilt, rather than everyone working
around it forever:
https://dev.pyra-handheld.com/packages/funkeymonkey-pyrainput

Not to be confused with the other way the nubs come out dead, which is a kernel
bug rather than a packaging one: without `patches/0005` the driver stops polling
them at the first suspend and never starts again. See `troubleshooting.md`.

---

### Fix 4 — disable the GLX extension (this is the one that works)

    # /etc/X11/xorg.conf.d/20-pyra-glx.conf
    Section "Extensions"
        Option "GLX" "Disable"
    EndSection

Xorg then skips GLX entirely, never runs the AIGLX probe, never reaches the
broken error path, and starts normally. The log carries one line about it:

    (**) Extension "GLX" is disabled

`Section "Module" Disable "glx"` would also work; the `Extensions` form is the
documented one and leaves the module alone.

**What this costs.** No GLX on the X server at all. Bookworm has software GLX
here, so this is a real regression against bookworm, and `glxinfo` and anything
that insists on desktop GL will not work. GTK4 applications fall back to the
cairo renderer.

**What this does not cost.** `DRI3` and `Present` are untouched, and those are
what `libpvrDRI3WSEGL` uses, so the hardware path — GLES2 through the SGX blob
via EGL — is unaffected. Desktop GL never touched the SGX on this platform
anyway; GLX was always software rendered, so nothing that was ever fast has
been lost.

Also remove the useless symlink from fix 1 while you are here:

    rm -f /usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so

This is a workaround for an upstream Xorg bug and should be reverted whenever
Debian ships a 21.1.x whose AIGLX probe fails gracefully, or whenever mesa
grows an omapdrm-capable stub. Both are worth reporting:

- xorg-server: AIGLX DRI2 probe NULL-derefs on every failure path in 21.1.16
  rather than returning NULL and falling back to swrast.
- mesa: `libdril_dri.so` cannot create a screen for omapdrm and reports
  `Error creating gpu or npu`.

---

### Fix 5 — USB is dead after a warm reboot

Cold boot, and every USB device works. `reboot`, and nothing behind the
on-board hub comes back: no ethernet adapter, no mouse, no keyboard dongle.
`lsusb` shows only the root hub, which reads as a failed controller. It is not
one. `dmesg` shows `ehci-omap` starting normally and the root hub finding its
three ports, so the controller is fine and nothing behind the hub enumerated.

The USB3503 hub chip is reset over i2c when its driver probes. After a warm
reboot the reset GPIO is still deasserted from the previous boot, so the
sequence is a no-op and the hub never connects. `dmesg` gives it away:

    usb3503 0-0008: reset gpio state 1

On a cold boot that reads `0`. Rebinding the driver re-runs the reset from a
known state, and everything behind the hub returns within seconds:

    echo 0-0008 | sudo tee /sys/bus/i2c/drivers/usb3503/unbind
    echo 0-0008 | sudo tee /sys/bus/i2c/drivers/usb3503/bind

The prep script installs that as `pyra-usb3503-rescue.service`: the script at
`/usr/local/sbin/pyra-usb3503-rescue`, the unit in `/etc/systemd/system/`,
enabled in `multi-user.target`. Both files are copied from this directory rather
than embedded, so the repository stays the one source of truth for the rescue
logic; if either is missing the prep script aborts in its preconditions, before
any fix has written anything. Checked offline against the real image on
2026-09-09 — see `verification-log.md`. It checks the USB bus for the hub before doing
anything, so on a cold boot it exits without touching a thing, and the unit
carries `ConditionPathExists` on the usb3503 driver so it is inert on anything
that is not a Pyra.

**Why this matters more than it sounds.** The USB ethernet adapter is very
likely how you are talking to the machine. Without this fix, one `reboot` over
SSH and the unit is off the network with no way back in except the screen.

This is a workaround, not a fix. The GPIO should be reasserted on shutdown, or
the driver should drive the reset unconditionally rather than trusting the pin
state it inherits. That belongs in the driver or the device tree.

---


## Fix 6 — the thermal daemon has never capped a frequency

**What is wrong.** `/usr/share/pyra/scripts/pyra-thermal.sh` reads the core and
battery temperatures every 20 seconds, works out a maximum CPU frequency from
its ladder, and applies it by calling `cpufreq-set`. That program is not
installed and cannot be installed: it came from `cpufrequtils`, which is not in
trixie and has no candidate version. So the call has failed on every cycle
since the image's first boot:

    pyra-thermal.sh[2000]: pyra-thermal.sh: 89: cpufreq-set: not found

The next line of the same function writes the charging limit, and that one is a
plain redirection with no `set -e` to stop in between, so it has run all along.
The daemon has therefore been reporting itself active and healthy while doing
nothing to the CPU.

**Correction, 2026-09-13.** This section used to go on to say that the daemon
"has been managing the charger correctly". That is wrong, and it was wrong when
written. The write succeeds; it reaches nothing. Its target,
`/dev/usb_max_current`, is supposed to be a symlink into the charger's sysfs and
on this machine it is an ordinary file that the daemon itself created on its
first write. Every charge-current decision the daemon has ever made has gone
into that file and stopped there. What was verified at the time was that the
write did not fail — not that it had an effect, which is a different claim and
the one that was made. Fix 8 is the whole story.

**Why it matters.** It leaves the kernel's `step_wise` governor as the only
thing limiting frequency for heat, and on its own that is not enough on a
fanless case. Two cores of `7z b` took a working machine from 64°C to **107°C**,
seven degrees past its 100°C passive trip, in under two minutes, and the run
was stopped by the measuring script rather than by the kernel. The 125°C
critical trip was never approached and nothing was damaged, but the thermal
ladder everybody tunes has never had any effect on this image.

**The fix.** Replace that one call with a write to `scaling_max_freq`, which is
all `cpufreq-set -u` ever did and needs nothing installed. The vendor's ladder
is left exactly as it is: the ladder is the vendor's policy, and only the one
line was broken.

Measured on hardware on 2026-09-12, same single-core load before and after:

| | before | after |
| --- | --- | --- |
| peak CPU zone | 100°C, still climbing when stopped | **84°C, stable** |
| cap under load | never left 1500 MHz | 1500 → 1250 → 1500 |

**Where it is applied.** `pc/pyra-trixie-prep.sh` applies it offline to a
mounted card, and `device/pyra-thermal-fix.sh` applies it to a running machine
and verifies it by forcing the cap down and watching the daemon put it back.
Both use the same transformation: prep calls the device script's
`--emit-patched` mode rather than carrying a second copy of it. The vendor's
original is kept alongside as `pyra-thermal.sh.before-pyra-thermal-fix`, so the
card carries its own undo.

**A caveat that the others do not have.** This one edits a file shipped by a
package, in a location that is not a conffile, so a later upgrade of the Pyra
scripts will silently put the broken version back.
`pyra-thermal-fix.sh --check` says whether that has happened. The proper home
for this is upstream, and it is on the report list.

**One thing it exposes rather than fixes.** With the daemon capping, the
frequency now oscillates between 1500 and 1250 MHz on a roughly 20-second
cycle, because the ladder has a 20-second poll and no hysteresis. That is the
oscillation others have reported on this hardware, and it could not have been
seen on this image before, because nothing was capping. It is worth tuning with
a release threshold below the trigger. Oscillating between the top two steps is
a much better place to be than walking past the trip.

**That last paragraph turned out to be the small half of it.** Fixing the
ladder is fix 7.

---

## Fix 7 — the ladder itself: five faults in the daemon's decision

Fix 6 made the daemon able to apply a decision. This one is about *which*
decision, and *when*. None of it was observable before fix 6, because until
then nothing was applied at all; all five were found within a day of fixing
that.

### Fault 1 — it throttles on the fuel gauge's die temperature

`doThermal()` picks a ceiling from two sensors. One is `core_thermal`, the SoC.
The other it calls the battery, and it is `bq27421-0` — the fuel gauge,
reporting its own die temperature. It is an I²C chip on the mainboard, and what
it measures is the board it is soldered to.

The two ladders are calibrated as if for very different things:

| `core_thermal` | | `bq27421-0`, "battery" | |
| --- | --- | --- | --- |
| > 77°C | 1250 MHz | > 44°C | 1250 MHz |
| > 82°C | 1000 MHz | > 45°C | 1000 MHz |
| > 87°C | 750 MHz | > 47°C | 750 MHz |
| > 92°C | 500 MHz | > 49°C | 500 MHz |
| > 97°C | 250 MHz | > 50°C | 250 MHz |

Measured on this machine with one core loaded, everything logged every five
seconds, on battery and discharging gently throughout:

| t | `core_thermal` | `bq27421-0` | ceiling |
| --- | --- | --- | --- |
| 182 s — load starts | 55.4°C | 42.2°C | 1500000 |
| 213 s | 70.6°C | 44.6°C | **1250000** |

The gauge rose **2.0°C within ten seconds** of the load starting. A 6000 mAh
cell cannot change temperature that fast, and nothing in those ten seconds put
any current through it. The core peaked at **71.0°C** across that whole run and
never reached its own first rung at 77°C: the entire throttling episode
happened without the core ladder being consulted once.

There is also no second opinion available while the machine is on battery. The
other sensor on the charge path, `bq24297`, returned **exactly 22500 on all 252
samples** of that run — but that run was on battery with the charger offline.
Plugged in, the same zone reads 60000. It takes exactly those two values and
neither of them is a measurement. Across
roughly 1500 samples in both states — including 1123 taken while the pack
warmed 1.4°C and the charge current swung between 202 and 531 mA — it has never
once varied within a run. It is keyed to whether a charger is present, not to
any temperature. An earlier draft called it a constant on battery-only
evidence, and a later one over-corrected to "a real sensor" on the strength of
it changing when the cable went in. Two values keyed on plug state are not a
temperature either way. So no cell temperature is exposed on this machine at
all.

The cap also outlives the work that caused it, because the board cools slowly
back through 44°C: the machine was still capped at 1250 MHz **350 seconds after
the load stopped**, with the core back down to 57.4°C.

### Fault 2 — no hysteresis

A cap is handed back at the first sample below the threshold that took it, one
poll before the heat that caused it returns. Same run: the ceiling changed nine
times, six of them oscillating between 1250 and 1000 MHz inside a 116-second
window while the gauge sat between 44.8°C and 45.5°C. This is the 1.5/1.25 GHz
oscillation reported on this hardware, and fix 6 is what made it visible.

### Fault 3 — the second ladder silently overwrites the first

This is the serious one, and unlike the other two it is a loss of thermal
protection rather than a loss of speed. `setMaxFreq` tests its argument against
the constant `maxFreq`, 1500, rather than against the cap already chosen, so
whichever ladder runs last wins whether or not it is the more restrictive. The
battery ladder runs last. Reduced from the vendor's own helpers, unmodified:

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
overwrite, so the fault is worst exactly when it matters most.

### Fault 4 — a 20-second poll on a machine that trips in 16

Two cores flat out take this machine from a 63°C idle to its 100°C passive trip
in **sixteen seconds**. The daemon polls every twenty. Logged every 2 seconds,
with the ceiling as the daemon's output:

| t | `core_thermal` | `cpu_thermal` | ceiling |
| --- | --- | --- | --- |
| 61 s — load starts | 64.6°C | 63.2°C | 1500000 |
| 67 s | 67.0°C | **77.7°C** | 1500000 |
| 72 s | 80.2°C | **91.7°C** | 1500000 |
| 77 s | 85.8°C | **98.1°C** | 1500000 |

The ceiling never moved, because the next poll had not arrived yet.

### Fault 5 — it watches the slower sensor

The passive trip is on `cpu_thermal`. The daemon reads `core_thermal`. At idle
they agree within a degree, but during a fast ramp they do not: at t=67 above,
`cpu_thermal` was 10.7°C ahead. Even an instantaneous daemon reading
`core_thermal` would first act with `cpu_thermal` already at 91°C.

### Why 4 and 5 only matter once fault 1 is fixed

Fault 1 was masking them. Because the board sensor sits above 44°C in ordinary
use, the machine was **permanently pre-capped** — measured at 750 MHz, where two
cores flat out peak at a harmless 74°C. The daemon never needed to be quick,
because its broken ladder had already put the machine somewhere nothing bad
could happen. Real protection, obtained for entirely the wrong reason.

This is why fix 7 is one change and not three. Measured on this machine:

| | two cores flat out | outcome |
| --- | --- | --- |
| as shipped | 74°C | safe, but throttled at idle too |
| ladder corrected, poll and sensor untouched | **102°C** | aborted by the harness |
| ladder corrected, 2 s poll, both sensors | **87°C** | ran to completion |

Correcting the ladder on its own makes this machine *less* safe than leaving it
alone. That was measured the hard way, on hardware, before it was written down.

### The fix

The vendor's core rungs and the vendor's charging ladder are kept exactly as
they are. Five things change:

- the frequency rungs on the gauge move to board temperatures, derived from
  what the board actually reads when the SoC is at full speed, so that ladder
  becomes a backstop rather than the primary control;
- every frequency decision goes through a helper that takes the **lower** of
  the cap chosen so far and the one being asked for;
- a release requires the temperature to have fallen clear of the rung that took
  the step, rather than merely back across it, by a full rung — sized from the
  machine, since this core moves up to 6°C between five-second samples on one
  core and 10°C on two, which puts any smaller band below the noise floor;
- `interval` goes from 20 seconds to 2;
- the frequency ladder reads the hotter of `core_thermal` and `cpu_thermal`.

The frequency ladder and the charging ladder are split into separate functions
so the release hysteresis applies only to frequency. Combining them would mean
a release pass deciding charge current from a temperature 2°C higher than the
real one, which would clamp the charger to 500 mA at a board temperature where
the current code allows 2 A. **The charging thresholds and currents are not
changed**, and the selftest asserts that byte for byte.

### Where it is applied

`pc/pyra-trixie-prep.sh` applies it offline as fix 7, immediately after fix 6
and through the same `--emit-patched` door, so there is one implementation.
`device/pyra-thermal-ladder.sh` applies it to a running machine, refuses a
ladder it does not recognise, checks the result parses as `/bin/sh` before
installing it, and asks the daemon what it would decide right now before
trusting it with the machine.

The card ends up carrying two backups, so the two fixes undo independently and
in the order they were applied:

    pyra-thermal.sh.before-pyra-thermal-fix      the vendor's file
    pyra-thermal.sh.before-pyra-thermal-ladder   vendor + fix 6
    pyra-thermal.sh                              vendor + fix 6 + fix 7

**Same caveat as fix 6:** it edits a packaged file in a location that is not a
conffile, so an upgrade silently reverts it.
`pyra-thermal-ladder.sh --check` says whether that has happened.

---

## Fix 8 — the machine cannot charge while it runs

**What is wrong.** Plug a charger into a Pyra running this image and the
battery goes down. Measured at idle on 2026-09-13, charger attached, `online=1`
and the charger's power-good bit set:

| | |
| --- | --- |
| `input_current_limit` | 500000 (500 mA, the USB floor) |
| battery `current_now` | **−617000** (617 mA *out* of the battery) |
| battery `status` | Discharging |

This machine's idle draw is about 620 mA. The charger was admitting 500. The
battery supplied the rest, so it drained with the cable in, and it had got down
to 21% before anyone looked at the right register.

One write is the whole fix:

    echo 2000000 > /sys/bus/i2c/drivers/bq2429x_charger/*/max_current

| | 500 mA | 2 A |
| --- | --- | --- |
| battery current | −617 mA | **+476 mA** mean over 899 s |
| capacity | falling | 21% → 23% |
| `REG08` | `0x0c`, not charging | `0x2c`, fast charging, on all 815 samples |

Same supply, same cable, one register.

**Why it sits at 500 mA.** Nothing on this machine ever sets it. Three things
were supposed to and none of them do.

1. `/lib/udev/rules.d/charging.rules` is the mechanism, and the rules in it
   that work name **twl4030** — the OMAP3/GTA04 charger. This is an OMAP5 with
   a bq24297. The rules for the right chip are directly beneath them, under the
   vendor's own comment:

       # 3. this is preparation for the Pyra but neither tested nor complete
       #    nor working

   They are accurate about themselves. They also try to link `/sys%p/id`, and
   the bq24297 exposes no `id` attribute. The helper script they call,
   `charging.sh`, reads `/dev/usb_id` and switches between 500 mA and 851 mA
   based on the ID-pin resistance of an **Openmoko** wall charger.

2. Because rule 3 never made the symlink, `/dev/usb_max_current` is not a
   symlink:

       -rw-r--r-- 1 root root 7 /dev/usb_max_current      <- regular file 0:0

   It is an ordinary file, created by the first thing that wrote to it as root
   — the thermal daemon. This is the correction to fix 6 above.

3. The driver reads the right numbers out of the device tree at probe and never
   applies them:

       bq2429x_parse_dt: chg_current = 2048000 usb_input_current = 3000000
                         adp_input_current = 2048000 bat_volt_max = 4200000

So the limit stays wherever the chip powers up, which is the 500 mA USB floor,
for the life of the boot.

**What this fix does not do, deliberately.** It does not connect the thermal
daemon's charge ladder to the real knob. That ladder reads `bq27421-0`, the
fuel gauge's own die (fault 1 of fix 7), and it drops to 500 mA above 44°C.
This machine idles with that sensor at 46–47°C. Wiring the daemon to the
working knob without first recalibrating it onto a sensor that means something
would re-impose exactly the cap this fix exists to lift, permanently, and the
battery would drain on the charger again. The pack's thermal protection is the
charger's TS pin, a hardware comparator on the battery thermistor, and it gates
charging whatever the input limit says. It was always the thing doing that job.

**What it assumes, which you should know before raising the number.** It
asserts a current; it detects nothing, because nothing here can. Proper BC1.2
detection means driving `FORCE_DPDM` in the bq24297's REG07, and that belongs
in the driver. The hardware backstop is VINDPM at 4.36 V: when VBUS sags to
there the chip stops taking more, which is why a weak supply browns out rather
than burns. But 4.36 V is below the 4.75 V a USB port is entitled to, so
pointing this at a real 500 mA port pulls that port out of spec. The default is
2 A because that is what this board's own device tree calls
`adp_input_current`. Do not raise it and then plug into a keyboard hub.

**What the supply and cable turned out to be worth.** Raising the limit further
buys nothing here:

| limit | battery current |
| --- | --- |
| 2 A | +476 mA mean over 899 s, 815 samples |
| 3 A | +455 mA mean over 267 s, 243 samples |

The 3 A row read "452 mA over 177 s" until 2026-09-18, when it was recomputed
from the committed TSV and did not reconcile; the derivation is in
`experiments/charging/README.md`. Either way it is below the 2 A arm.

with `DPM_STAT` set the whole time at a total input draw well under 1 A. That
is VINDPM, not the limit — VBUS is sagging, which is the cable. A shorter or
thicker one should be worth real charge rate; a bigger number here is not.

**Where it is applied.** `device/pyra-charge-current.sh` installs three files
and verifies the result:

    /etc/default/pyra-charge-current              the number
    /usr/local/sbin/pyra-charge-current-apply     one idempotent sysfs write
    /etc/udev/rules.d/60-pyra-charge-current.rules

The limit is a register: it resets on every unplug and every boot, which is
what the udev rule is for. `--check` reports the state, `--undo` puts 500 mA
and the stock rules back. `device/pyra-chgwatch.sh` watches the charge path
once a second and changes nothing.

**Unlike fixes 6 and 7, this one does not edit a packaged file**, so an upgrade
will not silently revert it. It adds a rule in `/etc/udev/rules.d`, which takes
precedence over the stock `/lib/udev/rules.d` and leaves it untouched.

**Verified:** the rule re-applies the limit on both `add` and `change` events,
tested by knocking the register down to 500000 and firing each event with
`udevadm trigger`. A physical unplug and replug has **not** been tested — that
needs hands on the device.

## Fix 9 — the machine has never had sound

The speakers and the headphones have been silent since the image was built.
MATE's volume applet works, the wheel turns, `pactl` reports three unmuted
sinks at 100%, and nothing comes out of either output.

**Nothing is broken. The codec is switched off.** The TWL6040 routes its DACs
to the amplifiers through four enumerated ALSA controls, and on a stock
Debian 13 card all four read `Off`:

| control | shipped | what it drives |
| --- | --- | --- |
| `Handsfree Left Playback` | `Off` | speakers |
| `Handsfree Right Playback` | `Off` | speakers |
| `Headset Left Playback` | `Off` | headphones |
| `Headset Right Playback` | `Off` | headphones |
| `Headset Playback Volume` | `0,0` | headphones, -30 dB, the floor |

Everything upstream of those five controls is healthy and always was. ALSA
enumerates the card as `hw:CARD=L15`, PulseAudio opens it, the PCM reaches
`state: RUNNING` with a moving `hw_ptr`, `pactl list sinks` shows
`alsa_output.hw_CARD_L15_DEV_0` plus the `speakers` and `headphones` remap
sinks, all unmuted at 0.00 dB. The samples were arriving at a DAC that was not
connected to anything.

Setting the four routes to `HF DAC` / `HS DAC` and lifting the headset volume
produces sound immediately, on both outputs, with no reboot and no other
change. Confirmed by ear on the hardware, 2026-09-20.

### Why it is off

`/var/lib/alsa/asound.state` shipped that way, and `alsactl` restores it
faithfully on every boot. `alsactl` is doing its job; the saved state is the
bug. The file was captured on a machine whose codec was muted, so every boot
since has replayed the silence.

There is no UCM profile for this card to override it. `alsa-restore` logs

    alsa-lib main.c:1554:(snd_use_case_mgr_open) error: failed to import hw:4
    use case configuration -2

and falls back to the state file, so the state file is the whole story. Note
also that `alsa-state.service` is inactive on this image (`Condition: start
condition unmet`), so nothing re-saves the state at shutdown — which is why a
single bad capture has survived every boot since, and equally why one good
capture sticks.

### Why the volume wheel looked dead

`pyra_volumed` (from `pyra-hacks`, enabled by default) reads the encoder on
`palmas-gpadc` and writes **`Handsfree` only**, through
`snd_mixer_selem_set_playback_volume_all` on `hw:CARD=L15`. It sets a volume;
it never sets a route. Turning the wheel was moving the speaker volume up and
down a path that ended at an amplifier that was switched off.

Two things follow, and both matter before anyone touches these volumes:

* **`Handsfree Playback Volume` belongs to `pyra_volumed`.** Whatever this fix
  or `alsactl` writes there is overwritten the next time the wheel moves. It
  is not ours to set, so the fix does not set it. This also explains a
  confusing hour during diagnosis: the value kept falling back to 2 or 4
  between measurements, because the wheel was being turned.
* **`Headset Playback Volume` has no daemon behind it.** The wheel does not
  reach the headphones at all; only PulseAudio's software volume does. So this
  one does need a sane floor, and it is the one that shipped at zero.

### The fix

`device/pyra-audio-route.sh` installs two files and verifies the result:

    /usr/local/sbin/pyra-audio-route-apply     idempotent, sets the four routes
    /etc/udev/rules.d/95-pyra-audio-route.rules

`95-` so it runs *after* `/lib/udev/rules.d/90-alsa-restore.rules`, which
replays `asound.state`. The rule has the last word regardless of what is in
that file, which is the point: the fix does not depend on a state blob that
anything on the system can overwrite. The helper also runs `alsactl store`
once at apply time, so a boot that somehow misses the rule still comes up with
sound.

The helper sets the four routes unconditionally — nothing else on the system
manages them — but lifts `Headset Playback Volume` **only when it finds it at
zero**, so a value the user chose is left alone.

`--check` reports the state, `--undo` removes both files, `--emit-into ROOT`
writes them to a mounted rootfs offline.

**Like fix 8 and unlike fixes 6 and 7, this one does not edit a packaged
file**, so an upgrade will not silently revert it. It adds a rule in
`/etc/udev/rules.d`, which takes precedence over the stock `/lib/udev/rules.d`
and leaves it untouched.

**Verified:** all four routes and the headset volume were knocked back to
`Off`/`0,0` and an `add` event fired with `udevadm trigger --subsystem-match=
sound`; all five came back. Sound confirmed by ear on both outputs. A full
reboot has **not** been tested — that needs the machine free.

### What this fix is not

This fix makes the machine audible. It does not make audio cheap, and it does
not touch the sample-rate conversion every stream pays for. `audio.md` is the map of the
whole chain and the first thing to open for anything sound-related. **The cost
of playback, what is and is not a hardware limit, and the levers that remain
are in `improvements.md` item 10** — including why a reported 20–30% is the
governor rather than a leak, and why muting saves nothing.

The empty **Hardware** tab in MATE's Sound Preferences is not this fault and is
not a fault at all. That tab lists PulseAudio *cards*, and this machine has
none: `/etc/pulse/pyra.pa` deliberately skips `module-udev-detect` and loads
`module-alsa-sink` directly, in 4 channels, so that two `module-remap-sink`
instances can split front (headphones) from rear (speakers) into the separate
`Speakers` and `Headphones` sinks. Sinks without a card have no card to list.
The **Output** tab, which is the one that does anything here, correctly shows
all three. Loading `module-alsa-card` to populate the Hardware tab would
replace the 4-channel sink and destroy the speaker/headphone split, in
exchange for a profile dropdown with one usable entry. Not worth it.

## Fix 10 — the login greeter takes the sound card, and the session never gets it back

With fix 9 applied the machine has sound — on most boots. On the rest the
desktop comes up silent and stays silent for the whole session, and the only
way back is restarting PulseAudio by hand. It hit **2 of the 6 boots on
record**, which is what kept it hidden: it looked like fix 9 intermittently
failing rather than a second fault sitting behind it.

    15:59:38  card (L15) registers
    15:59:45  user@105 — the lightdm greeter — starts
    15:59:52  greeter pulseaudio STARTED, holding hw:CARD=L15
    15:59:59  user@1000 starts
    16:00:00  session pulseaudio FAILS: device busy
    16:00:14  greeter pulseaudio stops — fourteen seconds too late

The greeter runs a PulseAudio of its own. `/etc/pulse/pyra.pa` opens the codec
as a raw ALSA device with `module-alsa-sink`, which is an **exclusive** open,
so whichever instance arrives first owns the card outright. When the greeter
wins, the session daemon logs

    Failed to load module "module-alsa-sink" (...): initialization failed
    Master sink not found

and both `module-remap-sink` instances fail behind it, taking `speakers` and
`headphones` with them. What is left is `auto_null`, the silent dummy sink
`module-always-sink` provides as a last resort. PulseAudio does not retry, so
the greeter releasing the card fourteen seconds later changes nothing.

This is worth separating from fix 9 clearly, because the symptom is identical
and the cause is not. Fix 9 was the codec shipping switched off, which
silenced **every** boot. This silences a **minority** of boots on top of it.
Neither one hides the other once both are fixed.

Note also that the card's number is not stable across boots — L15 was card 4
on one boot and card 3 on the next. Nothing here depends on it (`pyra.pa`,
fix 9's udev rule and this fix all address the card by name or by attribute),
but it is worth knowing before anyone writes `hw:4` somewhere.

### Why not arbitrate instead

A stock PulseAudio uses `module-udev-detect`, which claims cards through
ALSA's reservation protocol and hands them over politely. `pyra.pa` cannot:
it needs the card opened as one 4-channel device so the two remap sinks can
split front (headphones) from rear (speakers), and that means a raw exclusive
open with no arbitration. Going back to `module-udev-detect` would fix this
race and destroy the separate Speakers and Headphones sinks — the same trade
rejected under fix 9 for the MATE Hardware tab.

So the fix removes the second claimant rather than teaching the two to share.
A login greeter on a handheld has no use for audio; the usual consumer is an
accessibility reader at the login prompt, which this image does not run.

### The fix

`device/pyra-greeter-audio.sh` installs two drop-ins:

    /etc/systemd/user/pulseaudio.service.d/10-no-greeter.conf
    /etc/systemd/user/pulseaudio.socket.d/10-no-greeter.conf

each carrying one line, `ConditionUser=!lightdm`. That condition is evaluated
by **each user's own systemd instance** against the user it is running as, so
a single file in `/etc` skips the unit in the greeter's manager and leaves
every other user untouched. The socket needs it as well as the service, or the
socket would start the service on the first connection.

`--check` reports the state, including whether the session is currently sitting
on `auto_null`; `--undo` removes both files; `--emit-into ROOT` writes them to
a mounted rootfs offline.

**Like fixes 8 and 9, this one does not edit a packaged file.** It shadows
`/usr/lib/systemd/user/pulseaudio.{service,socket}` from `/etc/systemd/user`,
which takes precedence, so an upgrade will not silently revert it.

**Verified, both directions, without waiting for a lucky boot.** The greeter's
user manager was started by hand with `systemctl start user@105.service`:
before the fix it spawned a PulseAudio owned by uid 105; after the fix it does
not, and that manager reports `ConditionResult=no` for both units. The same
drop-in was then checked from the desktop session, where it reports
`ConditionResult=yes`, and `pulseaudio.service` was restarted for real and came
back with all three sinks and `speakers` as the default. A boot that would
otherwise have lost the race has **not** been observed since the fix — that
needs repeated reboots to catch a 1-in-3 event.

---

## Fix 11 — GL cannot reach the GPU on about half the boots

Found on 2026-09-26 while reloading the GPU driver for the idle-power work
(`experiments/gpu-power/`). After a lost race every GL program fails at once:

    PVR:(Error): Couldn't connect to services [0, ]

and the kernel logs, for each attempt,

    PVR_K:(Error): BridgedDispatchKM: Driver initialisation not completed yet.

It stays that way until someone runs `sudo /opt/omap5-sgx-ddk-um-linux/bin/pvrsrvctl
--start --no-module`. On a boot that means no hardware GL for the whole session:
programs that set `SDL_VIDEO_GL_DRIVER` to the DDK fail, and anything that
falls back renders on llvmpipe without saying so.

### Why it races

The SGX driver comes in two halves. The kernel module registers the GPU, and
`pvrsrvctl --start` then loads the microkernel and initialises the services from
user space. The DDK starts the second half from a udev rule,
`/lib/udev/rules.d/omap5-sgx-ddk-um-linux.rules`, on the **module** add event:

    SUBSYSTEM=="module", ACTION=="add", DEVPATH=="/module/pvrsrvkm_omap5_sgx544_116",
        RUN+="/opt/omap5-sgx-ddk-um-linux/bin/pvrsrvctl --start --no-module"

The kernel sends that event while it is setting up the module's sysfs entry,
before the module's init function has run, so before the driver has probed.
`pvrsrvctl` finds the GPU by scanning `/dev/dri`, and `card2` does not exist
until the probe registers it. The journal shows the order when the race is lost:

    (udev-worker): pvrsrvkm_omap5_sgx544_116: Process '.../pvrsrvctl --start --no-module' failed with exit code 1.
    [drm] Initialized pvr 1.14.3699939 20110701 for 56000000.gpu on minor 2

The race was lost with the stock module and with the patched one alike, so it
predates that work. **Measured: 4 of 10 loads came up initialised.**

### The fix

`device/pyra-sgx-init.sh` installs one file, which has the DDK's file name and
so shadows it:

    /etc/udev/rules.d/omap5-sgx-ddk-um-linux.rules

The start moves to the add event of the pvr **DRM card**:

    ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", DRIVERS=="pvrsrvkm",
        RUN+="/opt/omap5-sgx-ddk-um-linux/bin/pvrsrvctl --start --no-module"

That event is sent from `drm_dev_register`, which `pvr_probe` calls only after the
services core has initialised, and udev creates `/dev/dri/cardN` before it runs a
rule's `RUN`. `pvr_probe` still has two things to do after registering: set the DRM
device's `dev_private`, which nothing on the OMAP path reads, and, with the
idle-power patch, drop its runtime-PM reference, which is harmless if an ioctl
arrives first. So nothing is left to race. The stop rule stays on the module
remove event, as the DDK had it.

`--check` says which rule is in force and whether the services have reported
since the driver last registered (the kernel log needs root); `--undo` removes
the file; `--emit-into ROOT` writes it to a mounted rootfs offline, and
`pyra-trixie-prep.sh` uses that.

**Like fixes 8 to 10, it does not edit a packaged file.** Strictly, the DDK's
rule is not dpkg-owned either (it came with the hand-installed DDK in `/opt`),
but shadowing it from `/etc` leaves it intact for `--undo` all the same.

**Verified** with `experiments/gpu-power/initrace.sh`, which reloads the driver and
counts the loads where the services come up with nothing run by hand. It checks for
the kernel's `UM DDK ... match [ OK ]` line within 5 s:

| rule | loads | came up |
| --- | --- | --- |
| DDK's (module add) | 10, stock module | **4** |
| fix 11 (DRM card add) | 20, stock and patched module alternating | **20** |

After a full reboot on `5.6.19-m4`, the coldplug path, udev started the services
2.4 s after the driver registered, and GL ran at 868 Mpix/s.

A manual `udevadm trigger --action=add` on the card would run `pvrsrvctl --start` a
second time. That fails with "already initialized" and changes nothing.

---
