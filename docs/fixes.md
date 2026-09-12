# The six fixes, and what they actually do

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
plain redirection with no `set -e` to stop in between, so it has worked all
along. The daemon has been managing the charger correctly and the CPU not at
all, while reporting itself active and healthy.

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

---
