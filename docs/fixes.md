# The twenty-three fixes, and what they actually do

> **Type: reference.** How things are and why; not a procedure.

The procedure that applies them is `procedure.md`. The dated record of each one
being checked against the image and the hardware is `verification-log.md`.

## Which fixes are temporary

Most of these stand in for a change that belongs in someone else's package,
image or kernel. The table says which, what the proper fix is, and what lets the
fix be dropped. The kinds:

- **workaround**: avoids or undoes a fault that should be fixed where it lives;
- **package fix**: the proper fix, applied in place to a package this project
  doesn't own, with the patch in `patches/userspace/`;
- **restores**: puts back something the image or a package leaves out;
- **stock-kernel rescue**: needed only on the stock `5.6.19-pyradef`, whose fault
  the shipped kernel fixes with a patch;
- **setting** and **project choice**: meant to stay.

The reports named are drafts in `reports/`, not sent yet; the public copy leaves
them out.

| Fix | Kind | The proper fix | Drop it when | Draft report |
| --- | --- | --- | --- | --- |
| 1 | superseded by 4 | — | prep already removes it | — |
| 2 | workaround | `pyra-first-run.sh` treats any dialog failure as "Shutdown" | the image's wizard handles a failed dialog | `pyra-image-first-run-wizard-shutdown.md` |
| 3 | restores | the trixie `funkeymonkey-pyrainput` 0.1.19 package lacks `pyrainput.service` | the trixie package ships the unit | `pyra-funkeymonkey-missing-unit.md` |
| 4 | workaround | Xorg crashes after the AIGLX probe fails; GLX is turned off to avoid it | Xorg or Mesa's software-GLX fallback is fixed | `xorg-aiglx-dri2-null-deref.md`, `mesa-dril-omapdrm-no-fallback.md` |
| 5 | workaround | the usb3503 driver or device tree should reset the hub on every boot | the kernel resets the hub itself (no patch yet) | `kernel-usb3503-warm-reboot-no-reset.md` (on hold) |
| 6 | package fix | `pyra-hacks`: set the ceiling through sysfs, not `cpufreq-set` | `pyra-hacks` takes the patch, or the `0.38+pyra1` deb is installed | `pyra-hacks-thermal-daemon.md` |
| 7 | package fix | `pyra-hacks`: the ladder's five decision faults | as fix 6 | `pyra-hacks-thermal-ladder.md` |
| 8 | restores | nothing in the image sets the charger's input limit | `pyra-hacks` (or another package) sets it | `pyra-hacks-charge-current.md` |
| 9 | restores | the image ships no `asound.state`, so the codec routes are off | the image ships one | `pyra-image-asound-state-all-off.md` |
| 10 | workaround | the greeter shouldn't run PulseAudio | the image keeps PulseAudio out of the greeter | `pyra-image-greeter-pulseaudio.md` |
| 11 | workaround | the DDK starts `pvrsrvctl` before the GPU's DRM card exists | the DDK's udev rule waits for the card | `pyra-ddk-services-udev-race.md` |
| 12 | package fix | `pyra-hacks`: read the wheel through its measured taper | as fix 6 | `pyra-hacks-volumed-taper.md` |
| 13 | workaround | the DDK has no glvnd vendor; `pyra-gles` puts the blob in front per program | the DDK ships a glvnd vendor | `pyra-ddk-no-glvnd-vendor.md` |
| 14 | stock-kernel rescue | `patches/0048`-`0049`, and firmware fallback off in the shipped kernel's config | the card no longer keeps the stock kernel, or it takes the backport | `kernel-fsnotify-delete-before-d-delete.md` |
| 15 | workaround | `funkeymonkey-pyrainput` reads its config before setting defaults; the patch is in `patches/userspace/` | funkeymonkey takes the patch | `pyra-funkeymonkey-pyrainput-brightness-order.md`, `pyra-funkeymonkey-early-signals.md` |
| 16 | setting | — (a measured governor setting) | — | — |
| 17 | project choice | — (each kernel needs its own audio script) | the card stops carrying two kernels | — |
| 18 | stock-kernel rescue | `patches/0006` in the shipped kernel | as fix 14 | `kernel-input-tca8418-lost-interrupt.md` |
| 19 | project choice | — (the card boots the kernel built here) | the vendor's kernel carries these patches | the kernel reports |
| 20 | setting | — (MATE's battery dimming fights the Fn keys) | — | — |
| 21 | workaround | `dri3wsegl-pyra` closes a descriptor twice; a four-byte binary patch removes the second close | the package drops the `close()` at `dri3_ws.c:324` | `pyra-ddk-dri3-wsegl-double-close.md` |
| 22 | restores | MATE's backlight helper takes the first device it finds, the keyboard light on the stock kernel, so the image ships MATE's screen dimming off and no brightness slider | MATE picks the panel by itself and the image turns its dimming back on | — |
| 23 | workaround | the vendor image ships its ssh host keys and machine-id, the same on every card; an image should make them on the first boot | the vendor image ships without them | — (none drafted yet) |


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

The image already has a `pyra` user, locked or with a password that isn't
documented (its hash matched none of the obvious defaults, checked 2026-10-29).
Prep leaves an existing user's password alone unless `--set-password` is given.
`--ssh-key FILE.pub` authorises one public key for the user: type and key only,
written to `~/.ssh/authorized_keys` with 0600 and `.ssh` 0700, both owned by the
user. A private key, or a file without exactly one key, is refused before
anything is written. The selftest sets a test password on the image's `pyra`
with `--set-password` and checks the shadow hash. It also checks a test key's
file, modes and owner, and that its comment didn't land.

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
package, in a location that is not a conffile, so a reinstall, upgrade or
downgrade of `pyra-hacks` puts the broken version back. Prep therefore also
installs a dpkg hook that puts it back again; see "Fixes 6, 7 and 12 as a
package" below. `pyra-thermal-fix.sh --check` says what state the file is in.
The proper home for this is upstream, and it is on the report list.

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
conffile, so a package run reverts it, and the same dpkg hook re-applies it.
`pyra-thermal-ladder.sh --check` says what state the file is in.

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

   **Not always, as it turned out.** It is a race between that rule and the
   daemon's first poll. On 2026-10-22 the rule won on two boots in a row, the
   symlink was made, and the ladder drove the real limit: it flapped between
   1, 2 and 3 A every few seconds while charging. Fix 8 now masks the stock
   rules, so the race no longer exists. The logs are in
   `experiments/charging/README.md`.

3. The driver reads the right numbers out of the device tree at probe and never
   applies them:

       bq2429x_parse_dt: chg_current = 2048000 usb_input_current = 3000000
                         adp_input_current = 2048000 bat_volt_max = 4200000

So the limit stays wherever the chip powers up, which is the 500 mA USB floor,
for the life of the boot.

**What this fix does not do, deliberately.** It does not let the thermal
daemon's charge ladder reach the real knob, and since 2026-10-22 it enforces
that rather than relying on boot order. That ladder reads `bq27421-0`, the
fuel gauge's own die (fault 1 of fix 7), and it drops to 500 mA above 44°C.
This machine idles with that sensor at 46–47°C. Wiring the daemon to the
working knob without first recalibrating it onto a sensor that means something
would re-impose exactly the cap this fix exists to lift, permanently, and the
battery would drain on the charger again. The pack's thermal protection is the
charger's TS pin, a hardware comparator on the battery thermistor, and it gates
charging whatever the input limit says. It was always the thing doing that job.

The release keeps it that way (owner decision, 2026-10-29): no software charge
control, the TS pin alone. A proper guard is open work and not part of this
release. It would read a real cell temperature, perhaps the thermistor through
the Palmas GPADC (not confirmed), and act on the charge current (REG02), not
the input limit (`experiments/charging/README.md`, "What protects the cell").
Where the TS pin trips on this board has not been measured; the ~38°C figure
is from another board.

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

That held for that cable. On 2026-10-22, with a 15 W brick on the USB3 micro
port, 2 A gave +1342 mA and 3 A gave +1518 mA. A short cable on the normal
micro port gave +999 mA at 2 A. The default stays at 2 A, because it applies to
whatever gets plugged in.

**Where it is applied.** `device/pyra-charge-current.sh` installs four files
and verifies the result:

    /etc/default/pyra-charge-current              the number
    /usr/local/sbin/pyra-charge-current-apply     one idempotent sysfs write
    /etc/udev/rules.d/60-pyra-charge-current.rules
    /etc/udev/rules.d/charging.rules              masks the stock rules

The limit is a register: it resets on every unplug and every boot, which is
what the udev rule is for. `--check` reports the state, `--undo` puts 500 mA
and the stock rules back. `device/pyra-chgwatch.sh` watches the charge path
once a second and changes nothing.

**Unlike fixes 6 and 7, this one does not edit a packaged file**, so an upgrade
will not silently revert it. Its rule and its mask both live in
`/etc/udev/rules.d`, which takes precedence over the stock
`/lib/udev/rules.d` and leaves it untouched.

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

## Fix 12 — the volume wheel is silent for half its travel

Found 2026-10-20, once the speakers played through the DSP. You had to turn
the wheel nearly to the top to hear anything, and then it rose too fast.

`pyra_volumed` (pyra-hacks 0.38) reads the wheel on `palmas-gpadc` channel 2
and sets `Handsfree Playback Volume` to `raw * 29 / 2052`. That control is
already in dB: 0 to 29 is -52 to +6 dB in 2 dB steps. The wheel is not linear
either. Held at quarter turns, one unit read

| wheel | min | 1/4 | 1/2 | 3/4 | max |
| --- | --- | --- | --- | --- | --- |
| raw | 16 | 144 | 394 | 1071 | 2068 |

so the lower half of the travel gave steps 0 to 5, -52 to -42 dB, which is
inaudible on the speakers, and the upper half had to cover the other 48 dB.

`device/pyra-volumed/pyra_volumed.c` converts the reading back into travel
through those five points (interpolating in log(raw)) and spreads -40 to
+6 dB evenly over it, with the very bottom at -52 dB. It needs only libc and
libm: the ADC comes from sysfs and the volume goes in with the ALSA control
ioctl, so it does not need `libasound2-dev` or `libiio-dev`, which the image
does not ship.

The prep script cannot build C, so the card gets the source, a runner
(`/usr/local/sbin/pyra-volumed-run`) and a drop-in that points the packaged
`pyra_volumed.service` at the runner. On the first start the runner builds
`/usr/local/bin/pyra_volumed` with the image's gcc, and it rebuilds whenever
the source is newer than the binary. If the build fails it logs why (`journalctl
-t pyra_volumed`) and runs the packaged daemon. On a running Pyra, `sudo
device/pyra-volumed/install.sh` does the same and `--undo` reverts it.

Checked on hardware: a bottom-to-top sweep gave steps 0, 8, 10, 13, 15, 16, 18,
19, 22, 24, 27, 29, and it sounds even by ear. The calibration comes from one
unit, and another unit's pot may differ. The table is at the top of the source.

## Fix 13 — no Qt5 program draws anything

Found 2026-09-18 with Pegasus; the diagnosis is `qt-gles.md`. Every program
that links the distribution's GLES2, which is every Qt5 toolkit program, gets
a real EGL context from the SGX blob and then sends its GL calls to glvnd's
`libGLESv2.so.2`. The blob ships its library as `libGLESv2.so.1`, and glvnd
has no vendor for the blob's context, so every GL call is a stub: empty
`GL_VENDOR`, a maximum texture size of zero, no shader that compiles, and no
error anywhere.

`device/pyra-gles` runs a program with one symlink in front of glvnd,
`libGLESv2.so.2` pointing at the blob's `libGLESv2.so.1`, through
`LD_LIBRARY_PATH`. Prep installs it as `/usr/local/bin/pyra-gles`:

    pyra-gles qmlscene scene.qml
    pyra-gles --check

It is per program on purpose. Putting the link in `ld.so.conf` would hand the
blob every GLES2 program, including ones that need glvnd's software fallback.
Nothing in the image's menus links Qt (checked 2026-10-29 by running `ldd` on
every `Exec=` in `/usr/share/applications`, on the running unit), so prep
wraps no launcher. A Qt program you add gets `pyra-gles` in front of its
command, in its `.desktop` file or its own launcher.

## Fix 14 — root mounts a minute or two late, with nothing on screen

Some boots sit in the initramfs for 70-126 s before mounting root
(`troubleshooting.md`, "Root mounts a minute or two late", which has the
measurements). There are two causes, and an `init-top` hook for each:

- `pyra-fw-nofallback` sets `/proc/sys/kernel/firmware_config/ignore_sysfs_fallback`
  before udev starts. Without it, a USB ethernet adapter that probes inside the
  initramfs waits 60 s for firmware that is not on the card, and
  `udevadm settle` waits behind it. The stock `5.6.19-pyradef` and every
  developer build have `CONFIG_FW_LOADER_USER_HELPER_FALLBACK=y`. The shipped
  `5.6.19-m4-kbdled` is built with it off (`building.md`), and there the hook
  changes nothing; it stays for the stock kernel.
- `pyra-settle-nudge` wakes a `udevadm settle` that slept through the end of
  the event queue. `patches/0048` fixes that cause in our kernels, but a card
  also boots the stock `5.6.19-pyradef`, which does not have it. On a kernel
  with 0048 the hook never has to act.

A hook only runs once it is inside the initrd. Prep copies both into
`/etc/initramfs-tools/scripts/init-top/` and then rebuilds each kernel's initrd
by running the image's own `update-initramfs -u -k <release>` in a chroot.
That is the same command `pyra-install-helpers.sh` runs on the device, so the
card gets the initrd it would have built itself. Two things follow:

- The card's boot partition (p1) has to be mounted at the rootfs's `/boot`
  when prep runs. Prep stops before writing anything if it is not.
- A PC that is not armhf needs qemu-user with binfmt registered, so that
  `chroot` can run the image's binaries: `qemu-user-static` and
  `binfmt-support` on Debian or Ubuntu, `qemu-user-static` and
  `qemu-user-static-binfmt` on Arch. Prep checks with `chroot <root> /bin/true`
  before writing anything. Under qemu the stock image's one rebuild took
  under 43 s on an x86 PC (measured 2026-10-29: that was all of prep's first
  run, by the selftest's timestamps); on the Pyra a rebuild takes about 20 s.

An initrd that already lists both hooks and is newer than both is left alone,
so a second run rebuilds nothing. Once a hook is in `/etc/initramfs-tools`, a
later kernel install or `update-initramfs` on the device keeps it in.

## Fix 15 — the Fn keyboard-brightness keys do nothing on the shipped kernel

`5.6.19-m4-kbdled` declares the keyboard light as an LED,
`/sys/class/leds/pyra::kbd_backlight` (0-100, linear), instead of a second
backlight (`building.md`, "The keyboard-LED kernel"). funkeymonkey's
`libpyrainput` runs a shell command, as root, for each brightness-key
combination. Its built-in commands for Fn+brightness and Fn+Shift+brightness
are `pyra-scripts`' `/usr/share/pyra/scripts/pyra-brightkey.sh key up|down`,
and that script only knows `/sys/class/backlight/keyboard-backlight`, which
this kernel does not have. Nothing else calls it (checked in the 0.31 package
and funkeymonkey-pyrainput 0.1.19's source).

`device/pyra-kbdlight.sh up|down` drives the LED in the stock kernel's nine
steps (0 1 2 5 10 20 40 60 100 percent, its `brightness-levels` table), from the
step nearest the current value, so a value the applet or UPower set between two
steps is no trap. Without the LED it hands the key to the vendor script
unchanged, so it is right on the stock kernel too, and prep installs it without
checking which kernel the card boots.

The keys reach it through two lines in `/etc/pyrainput.cfg`:

    scripts.brightness.fn = /usr/local/sbin/pyra-kbdlight.sh up
    scripts.brightness.fnshift = /usr/local/sbin/pyra-kbdlight.sh down

That file is libpyrainput's documented settings file, no package ships it (fix 3
creates it empty), and funkeymonkey reads it at start and on
`systemctl reload pyrainput`. So a `pyra-scripts` upgrade cannot undo this, and
the vendor file is never touched. `pyra-kbdlight.sh --configure FILE` writes the
two lines; prep and `pyra-install-helpers.sh` both call it. It leaves alone a
line the file already has for either key, and prep prints that as a warning.

**At start the two lines don't take effect on their own**: in
funkeymonkey-pyrainput 0.1.19, `init()` loads the file and then, at its end,
sets the four brightness commands back to the built-in ones
(`pyrainput.cpp:158-161`). Only a reload (SIGUSR1, `user1()`) applies them,
because `resetSettings()` leaves the brightness commands alone. Found
2026-10-31 on the fix 19 card (`verification-log.md`): after every boot the
keys ran the vendor script until someone ran `sudo systemctl reload pyrainput`.

So fix 15 also installs a drop-in,
`/etc/systemd/system/pyrainput.service.d/pyra-kbdlight.conf`, whose
`ExecStartPost=-/usr/local/sbin/pyra-kbdlight.sh --reload $MAINPID` reloads
the daemon once at each start (a restart after a crash included). The reload
can't be sent right away. funkeymonkey 0.1.2 installs its SIGUSR1 handler only
after it has opened and grabbed the input devices and loaded the plugin
(`main.cpp`, `process()`). A USR1 before that kills the daemon, and
`Restart=on-failure` would then loop. So `--reload` polls
`/proc/PID/status` until `SigCgt` has bit 9 (SIGUSR1) set, for at most 10 s,
and only then sends it. A USR1 that lands during the plugin's `init()` is not
lost: the flag is served after `init()` returns. A second USR1 follows one
second later. It covers a signal that lands between the main loop's flag check
and its `select()`, which has no timeout and would otherwise sleep until the
next input event and handle that event with the built-in commands. Both the
`-` prefix and the script's exit status 0 keep a miss from failing the unit.
The journal shows the result at each start:
`pyra-kbdlight: pyrainput reloaded, Fn keys from the config (handler up after
N ms)`, or a line saying why it didn't. `pyra-install-helpers.sh` installs the
same drop-in, and still reloads the running daemon itself. The real fix
belongs upstream: set the four defaults before `loadConfig()` in `init()`
(the patch is `patches/userspace/funkeymonkey-pyrainput/`, drafted for upstream in
`reports/pyra-funkeymonkey-pyrainput-brightness-order.md`; the start-up signal windows
are in `reports/pyra-funkeymonkey-early-signals.md`).

Checked 2026-10-31 on the fix 19 card (`verification-log.md`): two cold boots
each logged the reload at about 23 s, the handler up 300 and 100 ms after
the process started. After the second, with nothing run by hand, both key
combinations stepped the light through all nine steps.

Rejected: `dpkg-divert` of `pyra-brightkey.sh`, for the reason fix 6/7's guard
gives (it would keep our copy over any newer vendor one, silently). A copy
earlier in `PATH` does nothing: libpyrainput calls the script by its absolute
path.

Checked 2026-10-29 on the trixie card (m4-kbdled): Fn+brightness stepped the
light 40, 60, 100, and Fn+Shift+brightness down through 60 40 20 10 5 2 1 0 and
back, at the desktop greeter, with pyra-scripts 0.31 in place
(`verification-log.md`). It passed only because `pyra-install-helpers.sh` had
just reloaded pyrainput; before the drop-in, a reboot undid it (above).

In a MATE session the keys work the same. MATE's power manager would keep its
own level for the light on battery and undo theirs; fix 20 turns that off. The
script writes sysfs rather than UPower's `KbdBacklight.SetBrightness`: sysfs
also works at the greeter and without UPower, and a UPower write updates the
level MATE keeps for itself, which a later power change would put back (fix 20).

## Fix 16 — the governor drops the clock between every unit of a burst

The ondemand governor's `sampling_down_factor` is 1 on every kernel here, so it
steps the clock down at the first idle sample, and work that arrives in bursts
(a frame, a key press, a page of output) pays the ramp back up for each unit.
At 10 it waits ten sampling periods before stepping down, so a burst pays the
ramp once. Measured 2026-09-13, two interleaved passes per setting, thermal
daemon stopped and the ceiling pinned (`experiments/governor/README.md`): mean
burst latency 53.8 → 41.2 ms (-23.4 %), median 53.5 → 36.0 ms (-32.7 %), for
421 → 444 MHz idle mean frequency (+5.4 %). The other ondemand knobs were worth
about 1 % each and are left at stock; `device/pyra-governor-tune.sh`'s header
says why.

A sysfs write does not survive a reboot, so prep installs the script to
`/usr/local/sbin` and `pyra-governor-tune.service` to `/etc/systemd/system`,
and enables the unit offline with a `multi-user.target.wants` link, as fix 5
does. `pyra-install-helpers.sh` installs the same two files to the same paths
and enables the unit online.

The unit is a oneshot with `RemainAfterExit=yes`. Leaving ondemand discards its
tunables, and the kernel recreates them at stock values when the governor comes
back (seen 2026-09-28 after a benchmark pin; `pyra-cpu-pin`'s header), so the
way to put 10 back is `systemctl restart pyra-governor-tune`, not `start`.

**On another governor it does nothing and does not fail.** Every kernel config
on the trixie card, the stock `5.6.19-pyradef` included, has `CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y` with `cpufreq-dt` built
in (checked 2026-10-29 in `/boot/config-*`). On a machine running something
else, the unit's `ConditionPathExists` on the ondemand directory skips it, and
the script by itself reports the governor and exits 0.

Check after boot: `pyra-governor-tune.sh --check` reads `sampling_down_factor :
10` and `applied.`. Checked 2026-10-29 on the trixie card (m4-kbdled), whose
script, unit, modes and enable link are byte-for-byte what prep writes: the
boot-time run, 16 s after boot, left 10 (`verification-log.md`).

## Fix 17 — the AESS kernel needs its own PulseAudio script, and the stock one must keep the packaged one

On `5.6.19-m4-kbdled` audio goes through the OMAP5's audio DSP (AESS) on
`hw:L15,5`; on the stock `5.6.19-pyradef` it goes over the direct McPDM link on
`hw:L15,0`, which the packaged `/etc/pulse/pyra.pa` opens. Each kernel needs its
own script, and loading the wrong one leaves the session on `auto_null`, the
"dummy output" (`audio.md`, "Two paths, chosen by the kernel"). A file in `/etc`
can name only one of them, and a prepared card has both: it boots the shipped
kernel (fix 19), and the stock one is its fallback (`--no-kernel`, or `l0`).

So the choice is made per boot. Prep installs, to the same paths
`pyra-install-helpers.sh` uses:

    /usr/local/sbin/pyra-audio-select.sh                          0755
    /etc/systemd/system/pyra-audio-select.service                  0644
    /usr/local/share/pyra-audio/zz-pyra-aess.conf                  0644  the daemon.conf that picks pyra-aess.pa
    /etc/pulse/pyra-aess.pa                                        0644
    /etc/pulse/pyra-alsa-mixer/profile-sets/pyra-aess.conf         0644
    /usr/share/pulseaudio/alsa-mixer/paths/pyra-speaker.conf       0644
    /usr/share/pulseaudio/alsa-mixer/paths/pyra-headphones.conf    0644

and makes `/etc/pulse/daemon.conf.d/zz-pyra-aess.conf` a link to
`/run/pyra-audio/zz-pyra-aess.conf`, then enables the unit offline with a
`multi-user.target.wants` link. `/run` starts empty, so the link dangles until
the unit runs. Before the display manager, the unit waits for the card and, on a
kernel whose PCM list has `MultiMedia1 LP`, copies the daemon.conf into `/run`.
On any other kernel it leaves the link dangling. PulseAudio 17 skips a dangling
file in `daemon.conf.d`, so on `pyradef` the packaged `pyra.conf` and `pyra.pa`
apply untouched. Both prep and `pyra-install-helpers.sh` make the link with
`pyra-audio-select.sh --link`, so it has one implementation. A regular file in
its place, from an install by hand, is moved aside as `.before-select` if its
settings differ from the payload's.

**No package guard.** Two of the files have to be in
`/usr/share/pulseaudio/alsa-mixer/paths`, the only place PulseAudio 17 reads a
profile set's paths from. The `pulseaudio` package owns that directory but none
of the seven files: on the trixie card, `dpkg -S` finds only the directories
(checked 2026-10-29). dpkg replaces and removes only the files it owns, so an
upgrade leaves these alone. Fixes 6 and 7 need `pyra-thermal-guard` because they
edit a file that `pyra-hacks` owns and rewrites; this fix edits no packaged file.
The packaged `pyra.conf` and `pyra.pa` (`pyra-config-pulseaudio`) are left
untouched, and `zz-` sorts after `pyra.conf`, so its assignments win when it is
there.

**Next to fixes 9, 10 and 12.** Fix 9's helper sets the four codec routes and
the DSP's DL1 and DL2 mixers. The AESS path needs those mixers, and its two
ports switch the routes per output. Fix 10 keeps the greeter's PulseAudio off
the card, which the session's `module-alsa-card` open needs as much as the
packaged `module-alsa-sink` does. The two mixer paths have no volume element, so
`Handsfree Playback Volume` is still the wheel's alone (fix 12).

Check after boot: `pyra-audio-select.sh --check` ends `ok`. On m4-kbdled it
reads `path aess` and names `/etc/pulse/pyra-aess.pa`, and `pactl list short
sinks` shows `aess`. On pyradef it reads `path direct` and names the packaged
`/etc/pulse/pyra.pa`. On 2026-10-29 the trixie card, whose files match what
prep writes, chose `aess` on m4-kbdled and `direct` on pyradef, and a stream
ran through the `aess` sink and through the packaged `speakers` sink
respectively. On 2026-11-01 the release card, freshly prepared with this fix,
chose `aess` on m4-kbdled, and the speakers and the headphones were both
audible. Nobody has listened on pyradef yet (`verification-log.md`).

## Fix 18 — the built-in keyboard goes dead, with nothing logged, on the stock kernel

The TCA8418 key controller holds its interrupt line asserted for as long as it
has events queued, and the device tree describes that line as edge triggered.
A key that arrives between the driver's last FIFO read and the write that
acknowledges leaves the line asserted, no further edge ever comes, and the
keyboard stays dead. The handler is never entered, so nothing is logged.
`patches/0006` fixes it in the kernel (`kernel-changes.md`), and the shipped
kernel fix 19 installs carries it; the stock `5.6.19-pyradef` does not, so the
rescue is for a card prepared with `--no-kernel` or booted on `l0`.

Prep installs `device/pyra-keypad-rescue` as `/usr/local/sbin/pyra-keypad-rescue`.
It reads the queued events out over i2c and clears the interrupt status, which
releases the line; the queued keystrokes are discarded, and it changes nothing
if the chip is not stuck. It is run by hand, from ssh or the touchscreen with an
on-screen keyboard, so there is no unit and nothing is enabled. How to use it:
`troubleshooting.md`, "Getting the keyboard back without that kernel".

It needs `i2cget` and `i2cset`. Prep installs no packages; the vendor image
`pyra-trixie-t1` ships `i2c-tools` 4.4-2 (checked 2026-10-29 in the image's dpkg
status, and the selftest checks both binaries in the mounted image). Prep warns
if an image lacks them, and the script says `apt install i2c-tools`.

Unrelated to fix 5, which is the USB hub after a warm reboot.

## Fix 19 — the card boots the stock kernel, which has none of the kernel fixes

The image boots `5.6.19-pyradef`. Suspend never completes on it, the nubs die
after a resume, the keyboard can go silent (fix 18 is the manual workaround),
and it has no AESS audio path, no jack switching and no keyboard light as an
LED. The shipped kernel, `5.6.19-m4-kbdled` (`building.md`, "Which kernel
ships"), carries all of that. Before this fix, a prepared card reached it only
through a cross-build and `pyra-push-kernel.sh`.

Prep installs it into `user.cfg` slot `l5` and makes `l5` the base and the
default, so the card's first boot is on the shipped kernel. The distro kernel
stays in `linux.cfg` as `l0`, untouched. The vendor's `extlinux.conf` is kept as
`extlinux.conf.orig`.

**Where the kernel comes from.** The release workflow publishes
`m4-kbdled-kernel.tar.gz` on each `kernel-*` tag. With no option, prep offers to
download that asset ([Y/n]; a run with no terminal takes yes) and installs it
only if its SHA-256 matches the hash pinned in the script. The script comes from
the repository, so the hash travels with the source that names it.
`--kernel FILE` installs a tarball you already have, whether a download or
`./pc/pyra-crossbuild.sh kernel-m4-kbdled`. Prep says whether it matches the
pinned release, and installs it either way. It refuses any tarball that doesn't
carry `./boot/vmlinuz-5.6.19-m4-kbdled`, or that has a `./lib/` entry.
`--no-kernel` leaves the card on the stock kernel. All of this happens before
fix 1 writes anything, so a failed download or a wrong tarball leaves the card
untouched.

No release is pinned yet: the public repository has no remote, so no
`kernel-*` release exists. Until one does, a run with no option stops before
writing and asks for `--kernel FILE` or `--no-kernel`.

**How it installs.** The two device scripts do the work, run in the chroot the
way fix 14 runs the image's tools, so each job has one implementation:

- `pyra-install-debug-kernel.sh --slot l5` refuses a tarball that would replace
  the `/lib` symlink, checks the room in `/boot` and the root filesystem,
  extracts, and runs `depmod`. It then writes
  `/etc/modprobe.d/pyra-m4-noautoboot.conf` (the shipped kernel has
  `omap_remoteproc` as a module, and without the blacklist both M4s start at
  boot once their firmware exists). It builds the initrd (fix 14's hooks are
  in place by then, so it has them) and writes the `l5` entry with the stock
  `append` line copied verbatim.
- `pyra-boot-kernel.sh base l5`, then `stock`, makes `l5` the kernel the
  one-shot revert and `stock` return to, and the default.

Prep also installs both scripts in `/usr/local/sbin` on every run, with or
without a kernel, because they are how a user changes kernels afterwards
(`building.md`, "Boot slots").

A second run compares the slot's entry, the installed `vmlinuz` with the
tarball's, the initrd, the modules and the blacklist. When all of them match it
changes nothing. A different tarball (a newer release) is installed over the
old one in the same slot.

**Fallback.** A kernel that never reaches userspace cannot be undone from the
device, and U-Boot shows no menu. Put the card in a PC, mount p1, and change
`default l5` to `default l0` in `extlinux/extlinux.conf`
(`troubleshooting.md`, "The card does not boot after prep installed the
kernel"). From a running system, `sudo pyra-boot-kernel.sh debug l0 --once`
tries the stock kernel for one boot, and `sudo pyra-boot-kernel.sh base l0 &&
sudo pyra-boot-kernel.sh stock` goes back to it for good.

The selftest installs the cross-build's tarball when it finds one and asserts
the entry, the files, the blacklist, the base and the default. Without a
tarball it runs prep with `--no-kernel` and reports the skip in its verdict.
No prepared card has booted this fix yet (`verification-log.md`).

## Fix 20 — on battery, MATE takes the keyboard light back from the Fn keys

On the shipped kernel the keyboard light is an LED UPower knows
(`pyra::kbd_backlight`), so mate-power-manager drives it. On battery, with
MATE's defaults, it does three things to it (measured 2026-10-31 on the image
card, `verification-log.md`):

- at every power change, unplugging included, it sets the light to half of its
  own 100 % (`kbd-brightness-dim-by-on-battery 50`), whatever the keys had set;
- after the idle time it dims that by 75 % (`kbd-brightness-dim-by-on-idle`),
  raising a level the keys had set below it;
- at the next touch it puts its 50 % back.

So a level set with the Fn keys (fix 15) or an applet lasted until the next
idle period. All three hang on one key. In mate-power-manager 1.26.1
(`src/gpm-kbd-backlight.c`), the idle dim and restore run on battery only when
`idle-dim-battery` and `kbd-backlight-battery-reduce` are both true, and the
power-change step does nothing on battery when `kbd-backlight-battery-reduce`
is false. On AC the idle dim and restore hang on `idle-dim-ac`, false by
default and in the image, so MATE never dims the light on AC.

Fix 20 installs
`/usr/share/glib-2.0/schemas/99_pyra_kbdlight.gschema.override`, which sets
`kbd-backlight-battery-reduce=false`, and recompiles the schemas with the
image's own `glib-compile-schemas --strict`, in the chroot. It then reads the
value back with `gsettings` on the memory backend, so the compiled default is
what it checks. It is a default, so a user who wants MATE's battery dimming
back sets the key with `gsettings` and that wins. dpkg's glib trigger
recompiles every override after any schema package changes, so no upgrade
drops it. MATE's Power Management preferences show the key as "Reduce keyboard
backlight brightness" on the battery tab, so the user can turn MATE's
behaviour back on from there. Ticking it, or "Dim display when idle" on the AC
tab (`idle-dim-ac`, which also covers the keyboard), brings back the dim and
the restore to MATE's own level, never the one the keys set: MATE's restore
sets `master_percentage` to 100 and ignores the current level (checked
2026-10-31 with both ticked). The name sorts after pyra-config-desktop's `99_pyra.gschema.override`,
so if that package ever sets the same key, this file's value still wins.
`pyra-install-helpers.sh` installs the same file and recompiles; a running
session picks the value up at the next power change.

One reset is left, on AC. When MATE goes to its AC level (100 %, at a plug-in or
a resume), it steps from the level it last set itself, not the real one. The
keys and the applet write the LED without telling MATE (sysfs, or logind), so
MATE still thinks the light is at its 100 % and sends nothing. Only at
mate-power-manager's start, at login on AC, does it read the real level and set
100 %. A write through UPower's `SetBrightness` is different: MATE follows
UPower's `BrightnessChanged` signal and takes that level as its own (source,
not measured), so a later plug-in or resume would put 100 % back.

Checked 2026-10-31 on the image card: with the key false, the light stayed at
the level the keys set across unplugging, an on-battery flap, 60 s idle, a nub
touch, a key press and plugging back in (`verification-log.md`).

Not done: an idle dim that restores the user's level. MATE can't, so it would
be `pyra-idle-dim`'s job (the `pyra-backlight` package), not a setting.
Not done: `kbd-brightness-dim-by-on-idle 0`. It stops only the dim. The touch
would still put MATE's 50 % back, and so would every power change. The upstream
side is in `reports/pyra-kernel-kbd-backlight.md`.

## Fix 21 — the SGX window system closes a descriptor it no longer owns

Every program that draws with GLES on the desktop goes through
`/usr/lib/libpvrDRI3WSEGL.so` (`dri3wsegl-pyra` 0.4), the SGX driver's X11
window system. It can lose any file it has open: a log, a config file, a save.
In Ship of Harkinian the log went dead (`Failed flush to file ...: Bad file
descriptor`) in 54 of 63 benchmark runs, mostly within seconds of launch, and
once a log record was written into a save file.

The cause is a double close. When it creates a buffer, the library exports it
as a dma-buf, keeps the descriptor number and passes the descriptor to
`xcb_dri3_pixmap_from_buffer_checked`; libxcb owns a descriptor passed that
way, sends it to X and closes it. When the buffer is destroyed, the library
calls `close()` on the stored number again (`destroy_buffer`, `dri3_ws.c:324`
in the 0.4 source; the `blx close@plt` at file offset `0x1548`). By then the
number has usually gone to the next file the program opened, and that file
loses its descriptor. Buffers are rebuilt when a client sets its swap
interval, so it happens early, just after a program opens its own files. An
`LD_PRELOAD` shim caught the library closing the game's log from
`+0x154d`, the return address of that call.

Fix 21 runs `device/pyra-wsegl-fdfix.sh --root` on the image. It turns the
second `close()` into two Thumb NOPs (`ff f7 0c ef` to `00 bf 00 bf`; the
result was unused). It touches only a file whose SHA-256 is the known stock
build and checks the four bytes before it writes. The patched file must match
the known fixed SHA-256. The stock file is kept as
`/usr/lib/libpvrDRI3WSEGL.so.stock`. The library is replaced by rename, never
written in place, and a symlink at any of its paths is refused, so nothing is
written off the image. Prep checks the library before fix 1 writes anything
and stops on any other build. A second run reports it already patched. The
script also goes onto the card as `/usr/local/sbin/pyra-wsegl-fdfix.sh`:
`status` says which build is in place, and `sudo pyra-wsegl-fdfix.sh rollback`
puts the stock one back. On a card that was not prepared, `sudo
./pyra-wsegl-fdfix.sh install` from `device/` applies the same patch.

`dri3wsegl-pyra` owns the file, so `apt install --reinstall dri3wsegl-pyra`
(or any `dpkg -i` of the deb) writes the stock build back without a word.
Prep and `pyra-install-helpers.sh` therefore also install a dpkg hook, shaped
like the one for fixes 6 and 7 ("Surviving a package run" below):

    /usr/local/sbin/pyra-wsegl-guard          the guard
    /etc/dpkg/dpkg.cfg.d/pyra-wsegl-guard     post-invoke=... runs the guard

After every dpkg run the guard looks at the library, but only on a card where
the fix was applied (`libpvrDRI3WSEGL.so.stock` exists) and not rolled back.
The fixed build: nothing, silently. The stock build: it runs
`pyra-wsegl-fdfix.sh install` and prints one line; programs already running
keep the stock build until they restart. Any other build (a newer package):
it changes nothing, and prints a banner and logs a journal warning on every
package run until someone looks. It always exits 0, and the config line skips
it if the guard has been deleted.

A rollback must stay a rollback, and the `.stock` file is still there after
one, so `rollback` also writes `/var/lib/pyra-wsegl-fdfix/rolled-back`, which
the guard respects; `install` removes it, and `status` mentions it. The marker
is not kept beside the library: ldconfig warns about an empty file in
`/usr/lib` on every libc trigger. `pyra-install-helpers.sh` installs the
script and the guard but does not patch: on such a card the guard has no
`.stock` file and does nothing until `sudo pyra-wsegl-fdfix.sh install`.
Checked on a Pyra on 2026-11-01 with real dpkg runs: `dpkg -i` of the 0.4
deb re-patched the library, a rolled-back card stayed stock through the same
reinstall, and an unknown build warned and was left alone (`dpkg --configure
-a`), with dpkg exiting 0 each time. The prep selftest fires the same hook in
its chroot.

The vendor image carries the stock build (checked 2026-11-01 on the image at
the vendor pin, and the trixie 0.4 deb has the same file). With the patch, the
same game run had no `Bad file descriptor`, kept its log open until its own
`fclose` at quit, and held a flat descriptor count with no dma-buf descriptors
left open (Shipwright report 10 §10.7).

What it does not cover:

- `dri3wsegl-pyra` owns the file, so `dpkg --verify dri3wsegl-pyra` reports it
  changed. A newer package version is a build the script does not know: it
  refuses to patch it, prep stops on it, and on a card the guard warns on
  every package run but leaves it alone, so until someone adds its hashes the
  card runs that build unpatched. Rejected for the guard: `dpkg-divert`, which
  would keep the patched 0.4 file over a newer vendor build, silently.
- After a reinstall, `rollback` still restores the `.stock` copy made at the
  first `install`. For 0.4 that is the same file; for a newer package the guard
  has already said the library is unknown.
- The fix belongs in the source: drop the `close()` at `dri3_ws.c:324`. 0.5
  (bullseye, bookworm) and TI's upstream have the same code
  (`reports/pyra-ddk-dri3-wsegl-double-close.md`).
- A prepared image therefore ships a modified binary of an MIT package. The
  package's licence stays in `/usr/share/doc/dri3wsegl-pyra/copyright`.

## Fix 22 — no brightness slider, and the screen never dims

**Symptom.** The image has no way to set the screen's brightness from the
desktop, and the screen does not dim when the session goes idle.

**Cause.** MATE's backlight helper does not recognise either of the Pyra's
backlight names and takes the first device in `/sys/class/backlight`. On the
stock `5.6.19-pyradef` that is the keyboard light, so MATE's brightness applet
and its idle dimming both adjust the keyboard. The image works around that by
switching MATE's backlight control off (`org.mate.power-manager
backlight-enable false`), which leaves no brightness control at all.

**Fix.** Prep installs `pyra-backlight`, a separate package from its own
repository (https://github.com/daniel-mcdonough/pyra-backlight). It names each device itself and sets it through logind, so no
root is needed, and it also drives a keyboard light that the kernel declares as
an LED (`*::kbd_backlight`, as on `5.6.19-m4-kbdled`). It carries:

- `pyra-brightness-applet`, a MATE panel applet with a slider for the screen
  and one for the keyboard light. It is not on the panel by default: add it
  with right-click, *Add to Panel…*, *Pyra Brightness*.
- `pyra-idle-dim`, a user service that dims the screen after
  `org.mate.session idle-delay` and brings it back on wake. The package's
  postinst enables it for every user (`/etc/systemd/user/default.target.wants`).

MATE's `backlight-enable` stays false, or the two would dim the panel at once
(`procedure.md` §8). So MATE's own brightness controls do nothing: the slider in
*Power Management Preferences* and mate-power-manager's *Brightness Applet*.
The Pyra Brightness applet replaces both (owner, 2026-11-03).

**How prep installs it.** With the image's own `dpkg -i`, in the chroot, not
apt, so nothing comes from a mirror unpinned. Before writing anything it reads
the `.deb` with the image's `dpkg-deb`, refuses any package that is not
`pyra-backlight`, and checks every `Depends` entry against the image's dpkg
database, versions and virtual packages included. The vendor image has all of
them but one: `gir1.2-matepanelapplet-4.0`, the MATE panel applet's GObject
bindings, which the applet imports. Prep adds Debian trixie's
`gir1.2-matepanelapplet-4.0_1.27.1-4.1_armhf.deb` (22 KB), pinned by SHA-256 in
the script. It uses a copy beside the pyra-backlight `.deb` if there is one,
and otherwise downloads it from `deb.debian.org`, then from
`snapshot.debian.org` by hash, which keeps it after the pool has moved on. Its
own dependencies are checked the same way, and both go in with one `dpkg -i`.
The `dpkg` run fires the post-invoke hooks of fixes 6, 7 and 21, which find
nothing to do. A second run sees that version installed and configured and
does nothing. (Found by the selftest, 2026-11-02: a card where the package had
been installed by hand had the bindings, and the vendor image does not.)

The `.deb` comes from `--backlight FILE`, or by default from pyra-backlight's
release, checked against `BACKLIGHT_SHA256` in the script: v0.2's
`pyra-backlight_0.2_all.deb`, SHA-256 `d6e1ae62…9d10` as published (built by
that repository's release workflow, so it differs from a local `./build-deb.sh`
build in the gzipped man page's timestamp and nothing else). A `.deb` given with
`--backlight` that matches the pin is reported as the release; any other is
installed as given. `--no-backlight` leaves it out.

## Fix 23 — every card has the same ssh host keys and machine-id

**Symptom.** Every card written from the vendor image has the same six ssh host
key files and the same `/etc/machine-id` (`79a963ec…`). Found on 2026-10-31,
when a freshly written card matched another card's entry in the PC's
`known_hosts`.

**Why it matters.** The private host keys are on every card, so anyone with a
Pyra card can pose as yours to an ssh client that trusts it, and sit in the
middle of its sessions. The machine-id is meant to be unique too: programs use
it as a per-machine identifier, and network stacks can derive a DHCP client
identifier from it.

**The fix.** Prep removes them and the card makes its own on its first boot:

- the ssh host keys are removed, and `pyra-ssh-hostkeys.service`
  (`device/`) runs `ssh-keygen -A` before sshd on a card with none. Debian's
  `ssh.service` makes no keys; its `sshd -t` fails without one;
- `/etc/machine-id` is emptied, so systemd writes a new one on the first boot;
  `/var/lib/dbus/machine-id`, a file in the vendor image, becomes a link to it;
- `systemd-firstboot.service` is masked. The empty machine-id makes systemd
  treat the boot as a first boot, which would start it, and it prompts on tty1
  for whatever of locale, keymap, timezone and root password it finds unset.

Prep knows the vendor's by pins in the script: the SHA-256 of each public
key's blob and the machine-id itself. It removes only those, so a re-run on a
card that has booted since keeps the card's own. One vendor key among them is
enough to remove them all. `--release` removes whatever is there, and also
systemd's random seed and credential secret (`procedure.md` section 4).

**What you see.** If your PC has talked to another Pyra at the same address,
ssh warns once that the host key changed. Remove the old entry with
`ssh-keygen -R <address>` after checking you are talking to your own card.

**Checked.** The selftest asserts the vendor's are removed, a card's own are
kept, and a mixed set is removed (`pc/pyra-prep-selftest.sh`). The same steps
as `--release` booted on a Pyra on 2026-11-01 (`verification-log.md`, R42): new
host keys in about 13 s, sshd up after them, a new machine-id, no console
prompt.

## Fixes 6, 7 and 12 as a package

All three change files that `pyra-hacks` owns, so the prep script and the
device scripts patch or override that package in place. The same three changes
as patches against pyra-hacks 0.38, in the form sent upstream, are in
`patches/userspace/pyra-hacks-thermal/` (fixes 6 and 7, a two-patch series)
and `patches/userspace/pyra-hacks-volumed/` (fix 12). Each applies with `git am`.

The packaged form is a separate repository,
[pyra-hacks](https://github.com/daniel-mcdonough/pyra-hacks): `main` is the
package's release history rebuilt from the source packages (upstream's
repository is not public), each fix is a branch off it (`feature/thermal-cap`,
`feature/thermal-ladder`, `feature/volumed-taper`), and `pyra` merges them with
a `0.38+pyra1` version. The patches above are `git format-patch` output from
those branches. Its CI builds the deb, and each `+pyraN` tag is a
[release](https://github.com/daniel-mcdonough/pyra-hacks/releases) with the
debs attached. To install 0.38+pyra1 on the Pyra:

    wget https://github.com/daniel-mcdonough/pyra-hacks/releases/download/v0.38%2Bpyra1/pyra-hacks_0.38+pyra1_armhf.deb
    sha256sum pyra-hacks_0.38+pyra1_armhf.deb
    # d46efe8cbef3c3e9ad334a724f70fded76ecebba9d3188676ef7338af3a93269
    sudo apt install ./pyra-hacks_0.38+pyra1_armhf.deb

To build it here instead, check that repository out beside this one as
`../pyra-hacks`:

    ./pc/pyra-crossbuild.sh pyra-hacks     # -> pyra-hacks_0.38+pyra1_armhf.deb

Its `pyra-thermal.sh` is byte-identical to what fixes 6 and 7 produce from the
0.38 script, and its `pyra_volumed` is fix 12's mapping on upstream's own
libiio and alsa-lib code, with the calibration readable from
`/etc/pyra_volumed.conf`. With it installed, `dpkg --verify pyra-hacks` is
clean and the three fixes have nothing left to do. Undo fix 12's override
(`device/pyra-volumed/install.sh --undo`), because its runner would otherwise
take over the packaged daemon.

The running unit has had it since 2026-10-20, replacing 0.38. The previous
thermal script is kept beside it as `pyra-thermal.sh.before-pyra1-deb`. To
go back, install the archive's `pyra-hacks_0.38_armhf.deb`, then run fixes 6,
7 and 12 again. The fixes stay in the prep script for cards with the stock
package.

### Surviving a package run: `pyra-thermal-guard`

Fixes 6 and 7 edit `pyra-thermal.sh`, which is not a conffile, so
`apt install --reinstall pyra-hacks`, an upgrade or a downgrade writes the
vendor's file back, and nothing said so. Prep (as part of fixes 6 and 7) and
`pyra-install-helpers.sh` install:

    /usr/local/sbin/pyra-thermal-fix.sh       the fix 6 transformation
    /usr/local/sbin/pyra-thermal-ladder.sh    the fix 7 transformation
    /usr/local/sbin/pyra-thermal-guard        the guard
    /etc/dpkg/dpkg.cfg.d/pyra-thermal-guard   post-invoke=... runs the guard

dpkg runs a `post-invoke` hook after every unpack, configure, install or
remove, so it fires under apt and under a plain `dpkg -i` alike. The guard:

- does nothing, silently, when both markers are in the file;
- when a marker is missing but that fix's `.before-*` backup is there,
  derives the fixed file from the vendor file just installed through the two
  `--emit-patched` doors, checks it parses, installs it, refreshes the
  backups to the new vendor file (so `--undo` still gets back to what the
  package shipped), restarts `pyra-thermal.service` and prints one line;
- when the transforms refuse the new file (upstream fixed it, or moved the
  lines), changes nothing and prints a banner and logs a journal warning on
  every package run until someone looks;
- always exits 0, because a failing `post-invoke` hook fails every dpkg
  operation; the config line also skips it if the guard has been deleted.

`--undo` deletes the backup, so the guard leaves an undone fix alone.

Rejected: an apt pin holds back every upstream change to the package and does
nothing about `--reinstall` or the stock package. `dpkg-divert` would keep
the old fixed file over any newer vendor one, silently, which is the same
fault the other way round.

With the `0.38+pyra1` package the file already carries both markers, so the
guard is silent; it only acts if an archive version replaces that package.
Fix 12 is not watched. Its drop-in survives package runs by itself, but on a
card where it was removed for the `0.38+pyra1` package, an archive upgrade
brings back the stock wheel mapping without a word.

Fix 21 has a guard of the same shape, `pyra-wsegl-guard`, for the library
`dri3wsegl-pyra` owns. It is described under fix 21: it keys on the `.stock`
copy and a rollback marker rather than on backups.

