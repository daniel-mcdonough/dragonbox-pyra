# The thirty-five fixes, and what they actually do

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
| 6 | package fix | `pyra-hacks`: set the ceiling through sysfs, not `cpufreq-set` | `pyra-hacks` takes the patch, or the `0.38+pyraN` deb is installed | `pyra-hacks-thermal-daemon.md` |
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
| 24 | setting | — (MATE's default critical-battery action is hibernate, which these kernels can't do) | the kernel gains hibernation (not planned) | — |
| 25 | workaround | `pyra-meta`: `pyra-meta-mate` depends on `mate-polkit` ahead of `network-manager-gnome`, so apt never installs ukui-polkit; the patch is in `patches/userspace/pyra-meta-polkit/`. The GL-check half is a setting | the image no longer ships ukui-polkit (the GL-check snippet stays) | `pyra-meta-polkit-ukui-timeout.md` |
| 26 | project choice | — (the Pyra's own settings app, and the pyra-hacks fork it depends on) | — | — |
| 27 | project choice | — (a sound icon for the AESS sink's two outputs, in place of MATE's) | — | — |
| 29 | package fix | `funkeymonkey-pyrainput`: four key names that look up nothing, nub axes left off-centre inside the deadzone, brightness defaults after the config; `systemd-dev` in Build-Depends for the unit (fix 3). Patches in `patches/userspace/funkeymonkey-pyrainput/` | the vendor ships a build with the patches and the unit | `pyra-funkeymonkey-pyrainput-brightness-order.md` (0001; 0002/0003 not drafted yet) |
| 28 | package fix | `pyra-config-xorg`: Fn+D and Fn+' are Alt as well as `_` and `:`, and Fn+R/Fn+T swap é and è; the patch is in `patches/userspace/pyra-config-xorg/`. The console half restores what Debian's keymap leaves out | `pyra-config-xorg` takes the patch (the console fragment stays) | — (none drafted yet) |
| 30 | workaround | the image's menu offers `xinput_calibrator`, which knows only the evdev driver; libinput drops the DT's kernel fuzz on a touchscreen and does not filter in its place | the image ships a libinput calibrator, and libinput keeps or applies a touchscreen's fuzz | — (none drafted yet) |
| 31 | project choice | — (a bug-report tool, and a record of how the card was prepared) | — | — |
| 32 | restores | the image lacks `python3-apt`, which the DBP Installer needs on trixie (its bundled `apt_pkg` is built for Python 3.7); `~/dragonbox` → `/dragonbox` because `dbpd` searches only filesystem roots | the image ships `python3-apt`, and the Installer's RootFs target is a place `dbpd` searches | — |
| 33 | workaround | `pam_gnome_keyring`'s password step finds no keyring daemon before `pam_systemd` has made `XDG_RUNTIME_DIR`, so a password changed at the greeter never reaches the login keyring (gnome-keyring 48.0) | never, for release images: a password chosen before the first login is the better design anyway | — |
| 34 | workaround | GTK 4's default GL renderer corrupts the heap on this card's EGL stack (GTK 4.18.6; cause not found) | a GTK 4 program draws with the variable unset | — |
| 35 | workaround | `pyra-hacks`: `pyra_volumed.service` is wanted only by `sound.target`, which only udev starts; the unit should be wanted by `multi-user.target` too | the fork's unit is wanted by `multi-user.target` | — |


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

**Root is locked.** The vendor image's root password is `root`, the same on
every card (yescrypt hash, last changed 2026-02-01; checked 2026-11-23 against
the pristine image with libxcrypt's `crypt()`, trying only `pyra`, `root`,
`toor` and empty). The wizard's `passwd -l root` hid it, so turning the wizard
off left root open on every prepared card until this change. sshd keeps
Debian's `prohibit-password` for root, so the password never worked over ssh.
It did work at a console login, and `su` with it gave any program running as
the user root without the user's password. Prep now locks root in every mode
(`usermod -L`, which puts `!` before the hash); the user gets root through
`sudo`. A locked root makes `sulogin` refuse the emergency and rescue shells
("the root account is locked"), so prep also installs
`emergency.service.d/` and `rescue.service.d/pyra-sulogin-force.conf`, which
set `SYSTEMD_SULOGIN_FORCE=1`. A boot that fails into one of them gets a root
shell on the console with no password. That gives nothing that holding the
card doesn't already give. Recovery: `troubleshooting.md`, "Root is locked".
The selftest (476 passed, 2026-11-23) asserts root locked after a plain run and after `--release`, the
two drop-ins installed, and that a second run reports root already locked.

Caveat from the original report: the wizard was never retested *after* X was
properly fixed, so it may well behave now. Skipping it is the path known to
work.

### Fix 3 — dead nubs

A genuine packaging bug. `funkeymonkey-pyrainput` 0.1.19 in the **trixie** repo
ships without `/lib/systemd/system/pyrainput.service`. The identical version in
the **bookworm** repo has it. The script writes the unit and enables it offline.

Why (found 2026-11-21, R87): the package's CMake file asks pkg-config for
`systemd`'s `systemdsystemunitdir` and installs the unit only if it finds
`systemd.pc`. Trixie moved that file from `systemd` to `systemd-dev`, and the
package's `Build-Depends: systemd` was not updated, so the build silently
skipped the unit (`pkg_check_modules` without `REQUIRED`). Debian split
`systemd-dev` out in systemd 253-2; bookworm (252) has no such package, so one
`debian/control` for both suites needs `systemd-dev | systemd (<< 253-2~)`
(untested; `reports/pyra-funkeymonkey-missing-unit.md`). Fix 29's rebuild adds `systemd-dev` and ships the unit
again, byte-identical to the one this fix writes; fix 3 stays for
`--no-pyrainput`.

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
that insists on desktop GL will not work. GTK4 applications don't fall back
to cairo on their own: zenity 4.1.90 (GTK 4.18.6) aborts with a heap error in
GTK's default GL renderer every time, and runs with `GSK_RENDERER=cairo`
(measured 2026-11-26, `dbp.md` "zenity crashes"). Fix 34 sets that for every
login.

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

On a cold boot that reads `0`. A quick off/on may not count as cold. Forum
users on the vendor OS logged `reset gpio state 1` after a power-off and
power-on, at a time when its `reboot` was broken anyway (Kazuki, 2021,
https://pyra-handheld.com/boards/posts/1693629/). fritata found that an
immediate off/on fails and that waiting several minutes before powering on
avoids it (https://pyra-handheld.com/boards/posts/1694105/). Bosbeetle's 30
boots, each after a shutdown, lost USB on 2 of 10 on the black port (both
logging `port 2 reset error -110`, which troubleshooting.md otherwise lists
as the separate charger-pull case), 4 of 10 on the blue, and none on the
USB3 port, which is the OTG controller's and not behind the hub
(https://pyra-handheld.com/boards/posts/1693656/). `SP_ILOCK failed (-121)`
appeared in those logs too, but it is also on the bookworm baseline's cold
boot, so it tells the two apart from nothing. Rebinding the driver re-runs
the reset from a known state, and everything behind the hub returns within
seconds:

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
likely how you are talking to the machine. The 4G modem sits behind the same
hub, and forum users saw it vanish with the ports (Kazuki,
https://pyra-handheld.com/boards/posts/1693465/; EvilDragon,
https://pyra-handheld.com/boards/posts/1693461/), so on a 4G unit the rescue
should bring the modem back too (not tested; this unit has no modem). Without this fix, one `reboot` over
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

A ceiling of your own below 1500 MHz needs the packaged form, pyra-hacks
`0.38+pyra5` (*A CPU ceiling of your own*, under "Fixes 6, 7 and 12 as a
package"); this transformation of the vendor's script has none.

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
(`bat_volt_max` is applied, capped 150 mV under the `vsys` regulator's 4.2 V,
so the charge voltage is 4.048 V; see "The charge voltage is 4.048 V" in
`experiments/charging/README.md`.)

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
release. It would read a real cell temperature and act on the charge current
(REG02), not the input limit. The pack thermistor is readable: Palmas GPADC
channel 0, only while a charger is in, because the bq24297's REGN biases the
divider (measured 2026-11-19; the °C conversion is not calibrated yet;
`experiments/charging/README.md`, "What protects the cell"). Where the TS pin
trips on this board has not been measured; the ~38°C figure is from another
board.

A guard exists now (`device/pyra-charge-guard.sh`, 2026-11-24,
`experiments/charging/README.md` "The guard"): it reads the margin to the
charger's own hot cut-off and lowers REG02 before that cut-off trips, with
hysteresis. It is not a prep fix — the release decision above stands. A real
charge on 2026-11-25 drove it through five reduce/restore cycles on hardware
(`verification-log.md`; a replug it missed then is fixed in the script); whether it makes the TS pin's hard stop rarer has not
been measured.

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
whatever gets plugged in, and fix 8 holds it on a detected adapter too, where
the chip alone would pick 3 A (owner decision, 2026-11-21). One more reason not
to raise it: a forum post (ouzle, 2021-04-20,
https://pyra-handheld.com/boards/posts/1691490/) says the charger's coil "can only take 2.7A".
The inductor's rating has not been checked on the schematic. Estimated, not
measured (90 % efficiency, 3.8 V): at 3 A in from 5 V the buck can deliver about 3.5 A at the cell
voltage under full load, about 2.4 A at 2 A in.

**Where it is applied.** `device/pyra-charge-current.sh` installs four files
and verifies the result:

    /etc/default/pyra-charge-current              the number
    /usr/local/sbin/pyra-charge-current-apply     an idempotent sysfs write, and a re-check
    /etc/udev/rules.d/60-pyra-charge-current.rules
    /etc/udev/rules.d/charging.rules              masks the stock rules

The limit is a register: it resets on every unplug and every boot, which is
what the udev rule is for. A physical replug needs more than the rule. The
bq24297 runs its own D+/D− detection after the plug event that runs the
helper: it holds 100 mA while it detects, discards writes made meanwhile, and
then sets the limit it detected. That is 3 A for the brick on the USB3 port
(0.12 s after VBUS) and 500 mA on the normal micro port, where detection
finds no type (0.55 s). Traced 2026-11-21; the timeline is in
`experiments/charging/README.md`, "What a replug does to the limit". So the
helper, besides its immediate write, starts a transient `systemd-run` job
(udev `RUN` must return quickly) that re-checks every 0.5 s for 10 s, puts the
configured limit back, and logs `limit was N, set 2000000 again` under the
`pyra-charge-current` tag. A supply whose detection takes longer than 10 s
would keep the chip's value; none seen. `--check` reports the state, `--undo` puts 500 mA
and the stock rules back. `device/pyra-chgwatch.sh` watches the charge path
once a second and changes nothing.

**Unlike fixes 6 and 7, this one does not edit a packaged file**, so an upgrade
will not silently revert it. Its rule and its mask both live in
`/etc/udev/rules.d`, which takes precedence over the stock
`/lib/udev/rules.d` and leaves it untouched.

**Verified:** the rule re-applies the limit on both `add` and `change` events,
tested by knocking the register down to 500000 and firing each event with
`udevadm trigger`. Physical replugs on the r5 card with the re-check
installed (2026-11-21, `verification-log.md`): the USB3 port went 100000 →
3000000 (the chip) → **2000000** 0.21 s after detection, the normal micro port
100000 → 500000 (the chip) → **2000000** 0.10 s after. Without the re-check
(2026-11-20 and 2026-11-21) the USB3 port stayed at 3000000. A laptop port
after a replug (2026-11-25, R99 test card, kernel r4, `verification-log.md`):
the chip detects `HOST` (SDP, no charger type) each time, never `ADAP`, and
`pyra-chgwatch.sh` at 1 s resolution read `reg00` `0x36` (**2000000**) on
every sample across the one unplug and replug its log holds — too coarse to catch the chip's
floor the way the kprobe trace did on the other two ports, but consistent
with the same sub-0.5 s re-check applying here too. So this fix holds 2 A on
a port whose own SDP class is rated 500 mA: out of spec for that port, by the
same "2 A on any supply" policy already applied to the normal micro port's
floor case, not a bug to fix.

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
change. Confirmed by ear on the hardware, 2026-09-20. The vendor knew the
cause in 2021: for a silent speaker, check both HF DACs in alsamixer
(EvilDragon, 2021-06-04, https://pyra-handheld.com/boards/posts/1693405/).

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
* **`Headset Playback Volume` has no daemon behind it in the packaged
  image.** The packaged `pyra_volumed` does not reach the headphones at all, so
  this one does need a sane floor, and it is the one that shipped at zero. Fix
  12's daemon drives it from the wheel as well, and overrides the floor on the
  wheel's next turn.

### The fix

`device/pyra-audio-route.sh` installs three files and verifies the result:

    /usr/local/sbin/pyra-audio-route-apply                     idempotent, sets the four routes
    /etc/udev/rules.d/95-pyra-audio-route.rules
    /etc/systemd/user/pulseaudio.service.d/20-pyra-audio-route.conf

`95-` so the rule runs *after* `/lib/udev/rules.d/90-alsa-restore.rules`, which
replays `asound.state`. The rule has the last word regardless of what is in
that file, which is the point: the fix does not depend on a state blob that
anything on the system can overwrite. The helper also runs `alsactl store`
once at apply time, so a boot that somehow misses the rule still comes up with
sound. The third file is R109's fix, below.

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
sound`; all five came back. Sound confirmed by ear on both outputs.

**A real reboot exposed a second race, distinct from this one: the headset
routes lose it (R109, fixed 2026-11-25).** Checked on three real boots
(`verification-log.md`, 2026-11-24), the speaker routes (`Handsfree
Left/Right Playback`) come up `HF DAC` every time, but the headset routes
(`Headset Left/Right Playback`) came up `Off` all three times — headphones
silent, speakers fine, on the same boot, from the same rule. `udevadm
trigger --subsystem-match=sound` immediately fixed it once the system was
up, which is what every prior check of this fix used, so the rule and the
script were never themselves broken.

It is not the two guesses that looked most likely going in — not a race
inside the codec's own probe sequence, and not the headset controls being
absent when `RUN+=` fired (the udev rule's own run of the helper always sets
both headset controls correctly; nothing there ever failed or needed a
retry). The actual cause: **the session's own PulseAudio resets the headset
pair back to `Off` when it opens the card**, roughly a second after the udev
rule has already set them correctly. Confirmed directly: with the routes
sitting at `HS DAC` on an already-booted card, `systemctl --user restart
pulseaudio.service` alone put them back to `Off` every time, with nothing
else touched — `module-alsa-sink`'s own open of `hw:CARD=L15` is what does
it, not a kernel-side DAPM race and not a timing gap in the rule. The
handsfree pair is never touched by this.

Because the bug is PulseAudio's own startup, not a short window inside the
udev rule, a `udevadm settle` or a retry loop around the two headset `cset`
calls — the fix this looked like it wanted — cannot catch it: PulseAudio
starts and reopens the card *after* the rule's `RUN+=` has already finished
and exited. The fix instead reasserts the two routes from a second point,
ordered after PulseAudio's own open rather than racing it:
`/etc/systemd/user/pulseaudio.service.d/20-pyra-audio-route.conf` adds
`ExecStartPost=/usr/local/sbin/pyra-audio-route-apply` to
`pulseaudio.service`. That unit is `Type=notify`, so systemd only runs
`ExecStartPost` once PulseAudio itself has signalled ready — which is after
it has already opened the card and done whatever it does to the mixer. Re-
running the same idempotent helper at that point is ordered correctly by
construction, not by guessing how long the window is. It runs again on every
other PulseAudio start too (manual restarts, socket activation, a
`Restart=on-failure` respawn), each of which resets the pair the same way, so
the same idempotent assertion puts it back each time. The greeter's PulseAudio (fix 10) never runs this helper
either, because `pulseaudio.service` doesn't start at all under lightdm's
user manager.

Verified on the R99 test card: two real boots after installing the drop-in,
`Headset Left/Right Playback` read `HS DAC` once PulseAudio had finished
starting, with nobody touching anything (`verification-log.md`, 2026-11-25). After
startup nothing resets it (R117, 2026-11-26). It stayed `HS DAC` through an idle
sink resuming for playback and a system suspend/resume. Over two headphone
unplug/replug cycles it followed the port: `Off` on `pyra-speaker` (by design, that
path selects `Off`) and `HS DAC` on `pyra-headphones`. The drop-in covers startup,
which is the only place the pair is lost. The four-route loop in the
helper also gained `logger` calls on failure, previously missing — it is why
this shipped unnoticed for two months: every earlier check of fix 9 used a
manual `udevadm trigger` retrigger, which always worked, so a cold boot was
never actually watched end to end until R15's reboot pass found it.

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

Since 2026-11-14 it also sets `Headset Playback Volume` (0 to 15, -30 to
0 dB) from the same travel, so the wheel works on headphones too; the packaged
daemon never touched them. *The volume wheel* in `audio.md` has why it can
write both at once. The package carries it as patch 0002, released as
`0.38+pyra2` (*Fixes 6, 7 and 12 as a package*); `0.38+pyra1` drives only the
speakers.

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

When fix 26 installs the pyra-hacks fork, fix 12 stands aside: it writes
nothing and removes the four files an earlier run wrote (the drop-in, the
runner, the source and the built binary), so the packaged unit runs the fork's
`pyra_volumed`. pyra-settings' wheel page writes `/etc/pyra_volumed.conf`, which
only the fork's daemon reads. The calibration then lasts only as long as the
fork does; fix 26's *Kept in step with apt* has the guard that says when a
package run replaces it.

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

Fix 29's rebuilt package carries that patch (0001), so on a prepped card the
file applies at start without the reload: checked 2026-11-21 with the drop-in
moved aside (`verification-log.md`, R87). The drop-in stays anyway. It costs one
reload at start, and it keeps the keys working if a package run puts the
vendor's 0.1.19 back (fix 29's guard warns when that happens).

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
kernel (fix 19), and the stock one is its fallback in `l0`.

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
rescue is for a card booted on `l0`. It is also
for the shipped kernel after a resume: a key let go of while the machine sleeps
leaves the same stuck line. `patches/0050` fixes that, from
`kernel-5.6.19-r2` on (the pinned release is r4); `kernel-5.6.19-r1` predates it (`troubleshooting.md`, "Dead after a resume").

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
download that asset ([Y/n]; a run with no terminal takes yes; `n` stops prep
with "pass --kernel FILE") and installs it
only if its SHA-256 matches the hash pinned in the script. The script comes from
the repository, so the hash travels with the source that names it.
`--kernel FILE` installs a tarball you already have, whether a download or
`./pc/pyra-crossbuild.sh kernel-m4-kbdled`. Prep says whether it matches the
pinned release, and installs it either way. It refuses any tarball that doesn't
carry `./boot/vmlinuz-5.6.19-m4-kbdled`, or that has a `./lib/` entry.
There is no option to skip the kernel: the stock one stays in `l0` as the
fallback whatever prep does. All of this happens before
fix 1 writes anything, so a failed download or a wrong tarball leaves the card
untouched.

The pinned release is `kernel-5.6.19-r5` (built by the Kernel release
workflow from that tag, run 45958723755, 2026-11-27; it adds `patches/0055`, the
rumble fix, `kernel-notes.md` §9, to r4, which added `patches/0054` and the
`M4_KBDLED_ASKED` options, §8, to r3; r3 added `patches/0053` to r2; r1 lacked
`patches/0050`). r4 was the first kernel release with an
attestation (`building.md`, "Checking a download"). A new release changes the tag, URL and
hash in prep together.

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

Prep also installs both scripts in `/usr/local/sbin` on every run, because they are how a user changes kernels afterwards
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
tarball it downloads the release prep pins and checks it against prep's hash.
Its abort tests pass the same tarball, since prep has no kernel-less run.
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
interval, so it happens early, just after a program opens its own files. A
window resize rebuilds them too: a test program that opened eight files and
then resized its window lost one of them in 3 of 3 runs with the stock build,
and none with the fixed one (2026-11-21, `gl4es.md`, "Fullscreen crashes").
Setting the interval to 0 and back to 1 within one frame rebuilt nothing. An
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

The script knows three builds, each disassembled against its `-dbgsym` package
(the `blx` after `PVRSRVUnmapDmaBuf` in `destroy_buffer`, its stub resolving to
`close@GLIBC_2.4`, `r0` reloaded right after): trixie's 0.4 at `0x1548`, and
0.5 for bookworm (`0x165e`, stock `1b3fa326…`) and bullseye (`0x1662`, stock
`8e37577c…`). The two 0.5 builds come from the same source but differ. So the
same commands fix a stock bookworm card, and a trixie card whose 0.4 is
replaced by a 0.5 gets the 0.5 patched by the guard. `.stock` always holds the
stock copy of the build that is installed: `install` refreshes it when a
package brought another known build, and `rollback` refuses a `.stock` of a
different build rather than put a 0.4 library under a 0.5 package.

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
  and one for the keyboard light. Prep puts it on the default panel, below.
- `pyra-idle-dim`, a user service that dims the screen after
  `org.mate.session idle-delay` and brings it back on wake. The package's
  postinst enables it for every user (`/etc/systemd/user/default.target.wants`).
- `pyra-greeter-kbd-light` (from 0.5), which turns the keyboard light on at
  lightdm's login screen, at boot and after every logout. A drop-in in
  `/usr/share/lightdm/lightdm.conf.d/` makes it lightdm's
  `greeter-setup-script`. The vendor's `90_pyra.conf` sets no such script
  (checked against `pyra-config-desktop` 0.39, 2026-11-17). An empty
  `greeter-setup-script=` in a file under `/etc/lightdm/lightdm.conf.d/` turns
  it off.

The package (from 0.6) also sets MATE's `kbd-brightness-on-ac` default to 20 (upstream
100), the login screen's level. Without that, the keyboard light jumps to full
for about a second at a login on AC. Nothing in the vendor image or this repo
sets that key.

MATE's `backlight-enable` stays false, or the two would dim the panel at once
(`procedure.md` §8). So MATE's own brightness controls do nothing: the slider in
*Power Management Preferences* and mate-power-manager's *Brightness Applet*.
The Pyra Brightness applet replaces both (owner, 2026-11-03).

**The default panel.** MATE builds a user's panel from `org.mate.panel
default-layout` at the first login, when the panel has no settings yet; the
vendor image has none for `pyra`. The vendor's `99_pyra.gschema.override` (in
`pyra-config-desktop`) names its `pyra.layout`. Prep installs
`pyra-backlight.layout`, which is that file with the applet appended
(`panel-right-stick=true`, `position=4`, so it sits left of the notification
area, whose first icon is Bluetooth), and `99_pyra_panel.gschema.override`,
which sorts after the vendor's and names it, then recompiles the schemas.
Only with `pyra-backlight` installed: a layout naming a missing applet makes
the panel complain at the first login, so with `--no-backlight` prep removes
them. A user who has logged in keeps their own panel; *Add to Panel…* adds it
there, or `mate-panel --reset` rebuilds the panel from the layout (losing
changes made to it). The selftest checks that the vendor's `pyra.layout` is
still the start of ours. Tried on the release card on 2026-11-11: a panel
rebuilt from the layout has the applet, right-stuck at position 4, beside the
Bluetooth icon.

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
release, checked against `BACKLIGHT_SHA256` in the script: v0.8's
`pyra-backlight_0.8_all.deb`, SHA-256 `2c25bbf3…f87a` as published (built by
that repository's release workflow). A `.deb` given with
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
  `ssh.service` makes no keys; its `sshd -t` fails without one. openssh-server's
  own `sshd-keygen.service` is enabled in the image but runs only on a systemd
  first boot, which a prepared card's first boot is not (skipped there,
  2026-11-19);
- `/etc/machine-id` is emptied, so systemd writes a new one on the first boot;
  `/var/lib/dbus/machine-id`, a file in the vendor image, becomes a link to it;
- `systemd-firstboot.service` is masked. An empty machine-id is not a systemd
  first boot (`machine-id(5)`), so it would not start on a prepared card; the
  mask covers a card whose machine-id is missing or `uninitialized`, which is a
  first boot. It prompts on tty1
  for whatever of locale, keymap, timezone and root password it finds unset.

Prep knows the vendor's by pins in the script: the SHA-256 of each public
key's blob and the machine-id itself. It removes only those, so a re-run on a
card that has booted since keeps the card's own. One vendor key among them is
enough to remove them all. `--release` removes whatever is there, and also
systemd's random seed and credential secret and the vendor's stale apt package
lists (`procedure.md` section 4).

**What you see.** If your PC has talked to another Pyra at the same address,
ssh warns once that the host key changed. Remove the old entry with
`ssh-keygen -R <address>` after checking you are talking to your own card.

**Checked.** The selftest asserts the vendor's are removed, a card's own are
kept, and a mixed set is removed (`pc/pyra-prep-selftest.sh`). The same steps
as `--release` booted on a Pyra on 2026-11-01 (`verification-log.md`, 2026-11-01): new
host keys in about 13 s, sshd up after them, a new machine-id, no console
prompt.

## Fix 24 — at critical battery MATE tries to hibernate

**Symptom.** MATE's power manager defaults `action-critical-battery` to
`hibernate`. The Pyra's kernels have no hibernation: there is no
`/sys/power/disk`, `/sys/power/state` is `freeze mem`, and logind's
`CanHibernate` is `na`. At critical battery MATE warned that the machine was
about to hibernate, then asked logind to hibernate and was refused.

**What actually happened at critical battery.** UPower and MATE act on the
same event. MATE 1.26.1 doesn't use its own `percentage-action` or
`time-action` keys. It acts on UPower's `warning-level` reaching `action`,
which UPower 1.90.9 sets at 2 % (`PercentageAction` in
`/etc/UPower/UPower.conf`, with `UsePercentageForPolicy=true`) while the
battery reads discharging. Both then wait 20 s:

- UPower's `CriticalPowerAction=HybridSleep` falls back through `Hibernate`,
  which logind refuses, to `PowerOff` (`up_backend_get_critical_action`).
  `GetCriticalAction` on the running daemon returns `PowerOff`. So the machine
  did power off. MATE's warning was simply wrong.
- MATE ran its own action, `hibernate`, which failed.

**The fix.** Prep installs `/usr/share/glib-2.0/schemas/99_pyra_power.gschema.override`,
which sets `action-critical-battery='shutdown'`, and recompiles the schemas in
the chroot. Then it reads the value back on the memory backend, the same way
as fix 20. MATE's warning now says "about to shutdown", and MATE asks logind to
power off at the same moment UPower does. It is a default, so a user's own
gsettings value still wins. `pyra-install-helpers.sh` installs the same file
and recompiles. mate-power-manager reads the new default when it starts, so the
change takes effect at the next login.

`UPower.conf` is left alone. It is a dpkg conffile, UPower 1.90.9 reads no
drop-in directory, and its fallback already ends at `PowerOff`.

Suspend is no choice for critical battery: a suspended Pyra keeps drawing from
the cell.

**Idle sleep.** The same file sets `action-sleep-type-battery` and
`action-sleep-type-ac` to `suspend`. MATE's idle sleep runs that action once
`sleep-computer-battery` / `-ac` runs out, after `org.mate.session idle-delay`.
Upstream defaults them to `hibernate` (battery) and `suspend` (AC); with
`hibernate`, idle sleep on battery would ask logind to hibernate and be
refused. Idle sleep itself stays off by default (`sleep-computer-*` is `0`), and
`idle-delay` stays at Debian's 30 min (owner, 2026-11-15).
Prep and the selftest read both keys back on the memory backend. Checked
against the release card's schemas on 2026-11-15: compiled with `--strict`,
the three keys read `shutdown`, `suspend`, `suspend`.

**With a charger in.** The `bq24297` reports `online=0` even with a charger in
(`verification-log.md`, 2026-09), so UPower's `OnBattery` is always true here.
MATE's check for being on mains never stops it. What decides is the fuel gauge:
UPower computes a warning level only while the battery reads discharging. A
charger that keeps up keeps the gauge at charging, so nothing happens. One that
can't keep up with the load (a weak brick, a sagging cable) still gets the
shutdown at 2 %, which is right, because the cell is still draining.

**MATE's countdown can't be cancelled.** mate-power-manager 1.26.1 starts its
20 s timer without keeping the source ID (`gpm-manager.c`, "battery
critical-action"). Plugging the charger in during those 20 s doesn't stop it,
although UPower's own timer is cancelled. With `hibernate` that was harmless,
because the call failed. With `shutdown` the machine powers off anyway. At 2 %
that is the safe outcome; plug in before the warning, not during it. The
first, accidental test showed this (`verification-log.md`, 2026-11-12): UPower
dropped back to no warning 12 s into the countdown, and MATE still powered the
machine off.

**Checked** on the release card on 2026-11-12 (`verification-log.md`), with the
action level raised to 95 % for one boot: MATE showed "about to shutdown" and
logind powered off 20.2 s after UPower reached the action level.

## Fix 25 — a login takes about 35 s, most of it waiting

**Symptom.** On the trixie image the desktop came up about 35 s after the
password was entered, against noticeably less on the stock bookworm card.
Profiled on the release card on 2026-11-14 (how: `profiling-guide.md` §3.3),
the wait is two things, both inside mate-session before it starts the
window manager.

**1. A second polkit agent that never registers (about 30 s).** The image has
two polkit agents, `mate-polkit` and `ukui-polkit`. `network-manager-gnome`
depends on `policykit-1-gnome | polkit-1-auth-agent`. Trixie has no
`policykit-1-gnome`, so apt satisfies the virtual package while resolving
nm-applet. That happens before it reaches `mate-polkit` through
`mate-desktop-environment`, and it takes `ukui-polkit`, the first provider in
its list. Both were installed by the vendor's own image build
(`apt install pyra-meta-mate`, 2026-02-01).

`ukui-polkit`'s autostart entry is `OnlyShowIn=UKUI;MATE` with
`X-MATE-Autostart-Phase=Initialization`. mate-session waits for every
Initialization-phase app to register before it moves on. The UKUI agent
starts, takes the polkit agent role, and never registers, so mate-session
waits out its phase timeout:

    x-session-manager: WARNING: Application 'polkit-ukui-authentication-agent-1.desktop' failed to register before timeout

marco started 29.8 s after the agent. Because the UKUI agent took the role,
`mate-polkit` then failed with "An authentication agent already exists".

**2. mate-session's GL check (about 6 s).** Before anything else mate-session
runs `mate-session-check-accelerated`. It fails ("No hardware 3D support"),
so mate-session runs it again with `LIBGL_ALWAYS_SOFTWARE=1`, which fails too
(`gl_failed!`). At login the first run took about 0.7 s and the second about
5.4 s. The second asks for the AT-SPI registry at once and then goes quiet
until it exits. Run by hand later, from cold (with the `_GNOME_SESSION_ACCELERATED`
root-window property removed), either run takes 0.26 s. What the second run
waits for at login is not pinned down. The result is used by nothing here:
mate-session only logs it, and neither marco, mate-panel, caja nor
mate-settings-daemon reads the `_GNOME_SESSION_ACCELERATED` or
`_GNOME_SESSION_RENDERER` properties it sets.

**The fix.** Prep installs two files, and `pyra-install-helpers.sh` installs
the same two:

- `/etc/xdg/pyra/autostart/polkit-ukui-authentication-agent-1.desktop`, with
  `Hidden=true`. `/etc/xdg/pyra` comes first in `XDG_CONFIG_DIRS`
  (`pyra-config-desktop`'s `65pyra_xdg-config`), so it hides the entry in
  `/etc/xdg/autostart`. It must keep an `Exec=` line: mate-session rejects an
  entry without one ("Key file does not have key 'Exec'") and then uses the
  copy in `/etc/xdg/autostart`, which is the one being hidden. The first try
  on the card made exactly that mistake and changed nothing. The package
  stays installed, so a package upgrade doesn't undo the fix. Prep refuses an
  image that has no `mate-polkit` autostart entry, since hiding the UKUI one
  would then leave no agent at all.
- `/etc/X11/Xsession.d/56pyra_mate-no-accel-check`, which appends
  `--disable-acceleration-check` to `STARTUP` when it is a plain
  `x-session-manager` or `mate-session` and `x-session-manager` resolves to
  mate-session. A user's own `~/.xsession` is left alone. Prep refuses a
  `mate-session` without the option, and warns if the image's
  `x-session-manager` is not mate-session.

Both take effect at the next login.

**The proper fix for the polkit half** is in the image build. The patch in
`patches/userspace/pyra-meta-polkit/` names `mate-polkit` in `pyra-meta-mate`'s
Depends, ahead of `network-manager-gnome`. Order matters. Simulated with
`apt-get install -s` in a trixie armhf container, with
`pyra-meta-desktop-base`'s and `pyra-meta-extra`'s Debian dependencies in place:

| `pyra-meta-mate` Depends | apt installs |
| --- | --- |
| as shipped (0.41) | `mate-polkit` and `ukui-polkit` (with `libpolkit-qt5-1-1`) |
| `mate-polkit` before `network-manager-gnome` | `mate-polkit` only |
| `mate-polkit` at the end | `mate-polkit` and `ukui-polkit` |

The patch helps only new images. A card that already has `ukui-polkit` keeps
it, so the override is still needed there. `apt purge ukui-polkit` would also
work; its dry run orphans a long list of libraries, not all checked to be
ukui's.

**Checked** on the release card on 2026-11-14 (`verification-log.md`): with
the override, marco started 6.5 s after the session opened instead of 36.3 s,
`polkit-mate-authentication-agent-1` was the running agent, and the timeout
warning was gone. With the GL-check snippet as well, marco started about 0.8 s
after the session opened.

## Fix 26 — no place to set what only the Pyra has

**Symptom.** Which buttons wake the Pyra from suspend, whether the lid does,
what the lid and idle do, and the volume wheel's calibration have no settings
page: MATE knows none of them.

**Fix.** Prep installs `pyra-settings`, a GTK 3 app from its own repository
(pyra-settings). Its root helper runs through pkexec (polkit action
`org.pyra.settings.wake`), and `pyra-settings-apply.service`, which the
package's postinst enables, applies the saved choices at boot from
`/etc/pyra-settings/pyra-settings.conf`. The wake-button page needs
`patches/0053` in the kernel (`wakeup_keys`); the helper looks for the file,
not the kernel version, and on a kernel without it the page says so.
It is in `kernel-5.6.19-r3` and later (fix 19 pins r4); r2 and earlier lack it.

It recommends `pyra-hacks (>= 0.38+pyra3)`, the fork (*Fixes 6, 7 and 12 as a
package*, below), which its volume wheel page needs, and `pyra-backlight (>= 0.4)`
(fix 22), which its display and keyboard light page needs. (0.13 and earlier
had both in Depends; 0.14 moved them to Recommends.) Prep installs both anyway,
so fix 26 also
installs the fork's `pyra-hacks_0.38+pyra5_armhf.deb`, pinned by SHA-256
(`28e6242f…2c5d73`, the release asset as published), from a copy beside the pyra-settings `.deb` or else from that release. It
replaces the vendor's 0.38; an image that already has 0.38+pyra5 or later
keeps it. 0.38+pyra5 also keeps a CPU ceiling you set (*A CPU ceiling of your
own*, below). The fork's thermal
script is byte-identical to what fixes 6 and 7 make, so their dpkg guard finds
nothing to do, and prep checks that after the install. Fix 12 stands aside
(above). Fix 8 stays: the fork does not set the charger's limit.

**How prep installs it.** As fix 22: the image's `dpkg -i` in the chroot, both
`.deb`s in one run, after checking before fix 1 that the file is
`pyra-settings` and that the image has every package either depends on (the
vendor image has all seven of pyra-settings 0.18's: python3, python3-gi,
gir1.2-gtk-3.0, pkexec, polkitd, alsa-utils, pulseaudio-utils).
`--settings` with `--no-backlight` is refused, since a page of pyra-settings
needs pyra-backlight. A second run sees the version installed and does nothing.

The `.deb` comes from `--settings FILE`, or by default from pyra-settings'
[release v0.18](https://github.com/daniel-mcdonough/pyra-settings/releases/tag/v0.18)
(`pyra-settings_0.18_all.deb`), checked against `SETTINGS_SHA256` in the script
(`3cbadf16…131dda702`, the asset as published). 0.15 added the Performance page
(*A CPU ceiling of your own*); 0.16 fits it on the Pyra's screen (0.15's window
was wider than 1280 px and would not maximize); 0.17 adds the About page, which
shows and copies fix 31's `pyra-info`; 0.18 adds the Rumble page (on/off, four
strengths, a test rumble), which needs kernel patch 0055 and otherwise shows a
note (`kernel-changes.md`, 0055). `--no-settings` leaves both packages
out and fix 12 in place.

**Kept in step with apt.** The fork is in no apt repository, and the vendor
repository's 0.38 sorts below `0.38+pyra5`, so apt keeps the fork. A vendor
0.39 would replace it and satisfy pyra-settings' Recommends without reading
`/etc/pyra_volumed.conf`; the wheel page would then do nothing until the fork
is rebased.

Nothing in apt says when that happens, so fix 26 also installs a dpkg
`post-invoke` hook, `/etc/dpkg/dpkg.cfg.d/pyra-wheel-guard`, which runs
`/usr/local/sbin/pyra-wheel-guard` after every package run. The guard is
silent while `pyra-hacks` is a `+pyra` version, or while fix 12's drop-in
(`calibrated.conf`) is there. Otherwise, after a downgrade to the vendor's
0.38 (`apt install pyra-hacks=0.38` or a `dpkg -i`) or a vendor 0.39, it
prints a `THE VOLUME WHEEL IS NOT CALIBRATED` banner on every package run
and logs a journal warning (`journalctl -t pyra-wheel-guard`). It changes
nothing, since a newer vendor package may have fixed the wheel itself. Only
fix 26 installs it, because only there did fix 12 stand aside; on a
`--no-settings` card fix 12's drop-in survives package runs by itself. The
selftest fires it with the image's dpkg: a downgrade to the archive's 0.38
deb warns (and fixes 6 and 7's guard re-applies both fixes in the same run),
and the return to the fork is silent.

## Fix 27 — MATE's sound icon knows nothing of the speakers and headphones

**Symptom.** The panel shows MATE's own sound icon
(`mate-volume-control-status-icon`). On the AESS kernels the sound card is one
PulseAudio sink, `aess`, with two outputs, and the icon has no way to switch
between them; choosing one means `pactl` or `pavucontrol`.

**Fix.** Prep installs `pyra-sound`, a tray icon from its own repository
([pyra-sound](https://github.com/daniel-mcdonough/pyra-sound)): left click mutes
and unmutes, right click opens a small window to switch between the speakers and
the headphones. It runs as the logged-in user and goes through PulseAudio only;
no root, no unit. It starts from `/etc/xdg/autostart/pyra-sound.desktop`.

The package hides MATE's icon without touching MATE's files: it links a copy of
`mate-volume-control-status-icon.desktop` with `Hidden=true` into
`/etc/xdg/pyra/autostart/`. pyra-config-desktop's
`/etc/X11/Xsession.d/65pyra_xdg-config` puts `/etc/xdg/pyra` ahead of
`/etc/xdg` in `XDG_CONFIG_DIRS`, so the hidden copy wins at login. Removing
pyra-sound removes the link and MATE's icon comes back at the next login. Prep
checks, through the image's own root, that the link resolves to a
`Hidden=true` entry, and warns if the image lacks the Xsession snippet (the
vendor image has it).

It needs an AESS kernel (`5.6.19-m4*`, fix 19); on the stock kernel there is no
`aess` sink. The volume wheel stays with `pyra_volumed`: with fix 26's fork it
drives the headphones too, and from 0.4 the icon shows one volume, the wheel's
position, on both outputs. Without the fork the window offers a headphone
slider instead.

**How prep installs it.** As fix 22: the image's `dpkg -i` in the chroot, after
checking before fix 1 that the file is `pyra-sound` and that the image has
every package it depends on (the vendor image has all six of 0.4's: python3,
python3-gi, gir1.2-glib-2.0, gir1.2-gtk-3.0, pulseaudio-utils, alsa-utils). So
no apt run and no network is needed in the chroot, and `--release` deleting the
package lists afterwards changes nothing. It depends on neither fix 22 nor fix
26. A second run sees the version installed and does nothing. Nothing in it is
per machine, so `--release` keeps it.

The `.deb` comes from `--sound FILE`, or by default from pyra-sound's
[release v0.4](https://github.com/daniel-mcdonough/pyra-sound/releases/tag/v0.4)
(`pyra-sound_0.4_all.deb`), checked against `SOUND_SHA256` in the script
(`67f9aa94…19eb62`, the asset as published, checked 2026-11-17). `--no-sound`
leaves it out, and MATE's icon stays.

## Fix 28 — Fn symbols that are Alt, swapped, or missing on the console

**Symptom.** The Fn layer is made by the input daemon, not the keyboard: for
Fn plus a letter, Fn+' or Fn+M it sends a spare keycode (Fn+D is 197, Fn+' is
196), and the X layout and the console keymap each decide what it types.
Under X (pyra-config-xorg 0.39, as 0.38) every symbol types, but Fn+D (`_`)
and Fn+' (`:`) are also Alt while held: a key pressed before they are let go
arrives as Alt+key (mate-terminal sends ESC b for `_b` typed fast, which moves
bash back a word), and Shift+Fn+D or Shift+Fn+' types nothing. Fn+R types è
and Fn+T é, the other way round from the keycaps. On a tty, Fn plus a key in
the top two letter rows, Fn+' and Fn+M type nothing, and Fn+Q and Fn+W send
`ESC [ M` and Delete.

**Cause.** Under X, the pc symbols give keycodes 196 and 197 (`<ALT>`,
`<META>`) Mod1 with Alt_L/Meta_L on level 2, and pyra-config-xorg's
`symbols/pyra` adds `modifier_map Mod1 { <META> }`; XKB's catch-all
interpretation then makes each key an Alt modifier. On the console, Debian's
keymap (ckbcomp's output) has nothing on most of those keycodes. On bullseye and
bookworm forum users found `_` and `:` dead outright, blamed the boot rule's
`evdev(inet)` part for overriding the pyra symbols, and found that
`setxkbmap -symbols pyra` brings them back but breaks the Pyra key (mapped to
MenuKB) and that `~/.Xmodmap` has no effect (Askarus,
https://pyra-handheld.com/boards/posts/1717515/,
https://pyra-handheld.com/boards/posts/1717722/; the chain as aTc describes
it, https://pyra-handheld.com/boards/posts/1716997/). On trixie both symbols
type and the fault is the Alt modifier above.

**Fix.** Two parts, both found and checked on the r5 card by injecting the
daemon's keycodes through uinput (`troubleshooting.md`, development log R78):

- **X.** `patches/userspace/pyra-config-xorg/0001-fn-d-and-fn-apostrophe-not-alt-r-t-accents.patch`
  puts the symbol on both levels of `<META>` and `<ALT>` with an explicit
  `NoAction()`, which wins over the interpretation, and swaps the accents on
  R and T. Prep diverts `/usr/share/X11/xkb/symbols/pyra` with the image's
  `dpkg-divert` (local, to `pyra.dist`), so a pyra-config-xorg upgrade writes
  its new file to `pyra.dist` and leaves the fixed one alone; it then applies
  the patch to `pyra.dist` with the PC's `patch` and installs the result.
  X compiles the keymap at every start, so there is no cache to refresh. Prep
  then compiles the keymap X builds (`pc+pyra(pyra)+inet(evdev)`) with the
  image's `xkbcomp` and stops unless `<META>` is `_` and `<ALT>` `:` on both
  levels with no action, and Fn+R/Fn+T are é and è.
- **Console.** `device/etc/console-setup/pyra-fn.kmap` gives every Fn key its
  keycap symbol. Prep appends it to `/etc/console-setup/remap.inc`, which
  ckbcomp adds to every keymap it builds, as a block between two marker lines
  (`# >>> pyra-fn` … `# <<< pyra-fn`); a re-run replaces the block rather than
  adding a second one. `remap.inc` is a conffile of console-setup-linux, so a
  package run keeps the edit. The console loads
  `/etc/console-setup/cached_UTF-8_del.kmap.gz` at boot, and the image's
  `setupcon` rebuilds it only when it is missing or older than
  `/etc/default/keyboard`, so prep removes it and runs `setupcon --save-only`
  in the chroot, then checks that every `keycode` line of the fragment is in
  the new cache.

**What prep checks first.** Before fix 1 writes anything: that the patch and
the fragment are in the checkout, that the PC has `patch`, that the image's
keymap is pyra-config-xorg's stock file (SHA-256 `1125b26a…`, 0.38 and 0.39)
or, on a re-run, diverted with the stock file in `pyra.dist` and the fixed one
(`19030823…`) in place, that the image has `remap.inc`, and that
`/etc/default/console-setup` sets `CHARMAP="UTF-8"` (the cache's name depends
on it). A keymap prep doesn't know stops it. A re-run finds the diversion, the
fixed file, the block and the cache in place and writes nothing. Nothing in it
is per machine, so `--release` keeps it.

**Undo.** `sudo rm /usr/share/X11/xkb/symbols/pyra && sudo dpkg-divert --remove
--rename /usr/share/X11/xkb/symbols/pyra` puts the package's file back; delete
the marked block from `remap.inc`, then `sudo touch /etc/default/keyboard &&
sudo setupcon --save-only`.

**Checked** 2026-11-25 on the R99 test card, with physical key presses rather
than R78's uinput injection, after a real boot (`verification-log.md`): under
X, Fn+D/Shift+Fn+D typed `_`, Fn+'/Shift+Fn+' typed `:`, neither acted as Alt
(a fast plain letter struck right after either chord never jumped the cursor
back a word), and Fn+R/Fn+T typed é/è, keycap-correct; on tty1 (a fresh
`login:` prompt, read back from `/dev/vcsu1`) Fn+E..P, A..L, ', M typed all
eighteen keycap symbols in order.

## Fix 29 — Usr1, Fn+Esc and d-pad right send nothing, the nubs stick off-centre, and rumble stutters

**Symptom.** In `funkeymonkey-pyrainput` 0.1.19, Usr1 and Fn+Usr1 send nothing,
Fn+Esc sends no SysRq, and d-pad right moves only the keyboard's `KEY_RIGHT`,
never the gamepad's hat (left, up and down do both). A nub pushed hard and let
go fast can leave the gamepad axis at its last value outside the deadzone (seen
at -38,-232 and -14,-248 with the raw nub back at 0,0), so a game keeps walking.
The brightness-key lines in `/etc/pyrainput.cfg` wait for a reload (fix 15).
Each rumble strength change from a game (SDL re-uploads the effect under the
same id) makes pyrainput erase the vibrator's copy and upload a new one; the
erase stops the motor, so it switches off for about 16 ms at every change, and
without a fresh play event it stays off.
Diagnosis: development log, R77 and R134; workarounds for a card without this fix in
`troubleshooting.md`.

**Fix.** Prep installs `funkeymonkey-pyrainput` 0.1.19+pyra2: the vendor's 0.1.19
source package with the four patches in `patches/userspace/funkeymonkey-pyrainput/`
(0001 brightness defaults before the config, 0002 the axes back to 0 inside the
deadzone, 0003 the four key names, 0004 a known rumble effect updated in place
under the vibrator's id instead of erased and uploaded again) and `systemd-dev` added to Build-Depends, so
it ships `pyrainput.service` again (fix 3 has why the vendor's trixie build
lacks it). The unit is byte-identical to fix 3's; dpkg takes over the file fix 3
wrote, and the package's postinst keeps it enabled. Depends are the vendor
build's (`funkeymonkey (>= 0.1.1)`, libc6, libgcc-s1, libstdc++6), all in the
image.

**Where the .deb comes from.** `./pc/pyra-crossbuild.sh pyrainput` builds it in
a trixie container from the vendor's `.dsc` (pinned by SHA-256) and the Pyra
repository's `funkeymonkey-dev` 0.1.2 headers (pinned too). The changelog entry
has a fixed date, so the build is reproducible: four builds on 2026-11-26 gave
the same file, SHA-256 `f2e166bf…62783dbb`. Prep pins that hash and downloads
the release asset `pyrainput-0.1.19+pyra2` from this repository's releases;
`--pyrainput FILE` uses a `.deb` you have (a local build has the same hash),
`--no-pyrainput` keeps the vendor's 0.1.19. Before fix 1 writes anything prep
checks that the file is `funkeymonkey-pyrainput`, a `+pyra` version, ships the
unit, and that the image has its dependencies. A second run sees the version
installed and does nothing.

**Kept in step with apt.** As fix 26: no apt hold (it would also hold back a
vendor release that fixes these bugs). The vendor's 0.1.19 sorts below
`0.1.19+pyra2`, so apt keeps it, but a downgrade or a vendor 0.1.20 replaces it.
A dpkg `post-invoke` hook, `/etc/dpkg/dpkg.cfg.d/pyra-input-guard`, runs
`/usr/local/sbin/pyra-input-guard` after every package run. It is silent while
the package is a `+pyra` version. Otherwise it prints a `THE INPUT DAEMON IS
NOT THE FIXED BUILD` banner and logs a warning (`journalctl -t
pyra-input-guard`). One thing it does change: a replacement built like the
vendor's 0.1.19 has no unit, so dpkg deletes ours as the old package's file and
the daemon would not start at the next boot (no nubs, no gamepad, no Fn layer).
Then the guard writes fix 3's unit back and enables it. The selftest fires it
with the image's dpkg: a downgrade to the archive's vendor 0.1.19 warns and
leaves fix 3's unit enabled, and the return to the fixed build is silent and owns
the unit again.

**Checked** 2026-11-21 on the r5 release card with the package installed by
`dpkg -i` (`verification-log.md`, R87): d-pad right sets `ABS_HAT0X`, Usr1 sends
`KEY_PAUSE`, Fn+Usr1 `KEY_SCALE`, the nubs' gamepad axes follow the raw nub back
to rest, and Fn+brightness steps the keyboard light from the config with fix
15's drop-in moved aside.

**Checked again** 2026-11-25 on the R99 test card, this time through the
packaged install prep itself puts down (not a manual `dpkg -i`) and after a
real boot, not a reload (`verification-log.md`): version, the service running
from the package's own unit file (`dpkg -S` confirms it, `dpkg -V` flags
nothing but the expected conffile), and Fn+Esc — three presses each opened
MATE's screenshot tool, the desktop-session face of the same `KEY_SYSRQ` this
section calls "SysRq (PrtScrn)".

**Rumble checked** 2026-11-26 on the R99 test card with 0.1.19+pyra2 (kernel r4
with 0055; `verification-log.md`, R134): one effect re-uploaded twice under its
id while playing keeps VIBCTLR at `01` from play to stop, with VIBDATR following
each strength (`0x24`, `0x32`, `0x22`); 0.1.19+pyra1 wrote VIBCTLR `00` at the
first update. 0001-0003 are unchanged from +pyra1, whose checks above stand.

## Fix 30 — touchscreen calibration does nothing, and the pointer jitters

**Symptom.** The menu's "Calibrate Touchscreen" runs `xinput_calibrator` 0.8.0.
It prints a result, and nothing changes. With the stylus held still, the
pointer jumps around by a few pixels. Diagnosis: `troubleshooting.md`,
"Touchscreen calibration does nothing", and development log, R81.

**Calibration.** X drives the TSC2007 with libinput, which takes a calibration
only as its `libinput Calibration Matrix` property. `xinput_calibrator` knows
only the evdev driver. Prep installs `/usr/local/bin/pyra-touch-calibrate`
(from `device/`), which fits that matrix to five held targets, applies it
live and saves it with sudo in `/etc/X11/xorg.conf.d/99-zz-pyra-touch-calibration.conf`.
That file overrides the vendor's matrix and leaves the vendor's file alone. The
tool sets and reads the property through libXi with Python's ctypes, the two
calls `xinput` would make. The image has no `xinput` package, and prep runs no apt.
libxi6 and python3-gi are on the image, and prep checks for both before fix 1
writes anything. The menu entry `/usr/local/share/applications/xinput_calibrator.desktop`
has the same name as `xinput-calibrator`'s. The session's `XDG_DATA_DIRS` is
`/usr/share/mate:/usr/local/share/:/usr/share/`, so the menu shows this one,
which opens the tool in a terminal (it asks for the sudo password there).
`xinput-calibrator` itself stays installed.

**Jitter.** The DT asks for `touchscreen-fuzz-x/-y = <5>`. libinput's
`90-libinput-fuzz-override.rules` copies that into `LIBINPUT_FUZZ_00/01`, and
its RUN (`libinput-fuzz-to-zero`) sets the kernel fuzz to 0. libinput 1.28 does
not use those values for a touchscreen, so the raw noise reaches the pointer.
`/etc/udev/rules.d/91-pyra-touch-fuzz.rules`, for the TSC2007 only, sets
`EVDEV_ABS_00/01` to `:::<LIBINPUT_FUZZ>` and adds `RUN{builtin}+="keyboard"`.
RUN entries run in the order they were added, so udev's keyboard builtin puts
the fuzz back after libinput's program has zeroed it. A hwdb entry can't do it,
because `60-evdev.rules` applies hwdb values before libinput's rule runs. Two
side effects:

- libinput logs `libinput bug: kernel fuzz of 5 even with LIBINPUT_FUZZ_00
  present` (and `_01`) in the Xorg log, twice each time X opens the
  touchscreen. It logs this whether the property is there or not
  (`evdev_read_fuzz_prop` in 1.28.1), and then uses a fuzz of 0 for its own
  view, so the kernel filters once and libinput adds nothing. The lines are
  expected.
- The kernel's filter (`input_defuzz_abs_event`) works in axis steps. With
  fuzz 5, a change of 1 step from the last reported value is dropped, 2 to 4
  steps move a quarter of the way, and 5 to 9 move halfway; 10 or more pass
  as they are. One step is 1.78 px across (`ABS_X`, 720 steps over 1280 px)
  and 0.56 px down, so a slow stroke lags by a few pixels and a still stylus
  holds still.

The rule also removes the drawback libinput's own rule notes: a second trigger
no longer loses the fuzz, because the kernel value is 5 again when
`libinput-fuzz-extract` reads it.

Nothing in fix 30 is per machine, so `--release` keeps all three files. A
second run finds them up to date.

**Checked** 2026-11-21 on the r5 release card, with the three files copied in
by hand (`verification-log.md`, R89). After `udevadm trigger`, `evtest` showed
Fuzz 5 on `ABS_X` and `ABS_Y`. X re-added the touchscreen with the two expected
lines and nothing else. The owner opened the tool from the menu, calibrated and
saved, and found dragging and writing fine. The selftest asserts the files, that
the image's python3 and ctypes have everything the tool calls, that the menu
resolves to the new entry, and that the image's `udevadm verify` passes the rule.

**Checked again** 2026-11-25 on the R99 test card, through prep's own install
(not files copied by hand) after a real boot (`verification-log.md`). `evtest`
again showed Fuzz 5 on both axes, and the menu's "Calibrate Touchscreen" was
confirmed by its running processes to launch `pyra-touch-calibrate`, not
`xinput_calibrator`. The Xorg log carried four `kernel fuzz of 5` lines (two
pairs), not R89's two: on a real cold boot, X hotplug-adds the touchscreen like
every other input device, immediately removes it, then re-adds it a second
time once `99-pyra-touchscreen.conf`'s static `CalibrationMatrix` option is
applied — every device in the log shows the same add/remove pair at this stage,
not just the touchscreen. R89's check reused an already-running X server and
only triggered one add via `udevadm trigger`, so it never saw this. Each pair is
still exactly the expected one-per-axis line, with nothing else logged for the
device. Two lines per add, not per boot, is the more precise statement.

## Fix 31 — a bug report can't say which Pyra, card or packages it is about

**Symptom.** Nothing on the card says how it was made. The r5 release image has
no marker in `/etc`, the boot entry U-Boot chose is not passed to the kernel,
and `MemTotal` looks like the fitted RAM but isn't (`board-revision.md`). A
report then needs several rounds of questions.

**Fix.** Prep installs `/usr/local/bin/pyra-info` (from `device/`), a
read-only script that needs no root. It prints:

- the mainboard (device-tree `model`) and CPU board (first `compatible`);
- RAM as "not readable from Linux": U-Boot 0.1.5 is a 4 GB build and hands the
  kernel two fixed banks whatever is fitted, so no size is printed;
- the kernel (`uname -r` and `uname -v`, so two builds of one name differ);
- the boot entry: the `extlinux` label whose `linux` line is the running
  kernel and whose `append` line is `/proc/cmdline`, and the default. It is
  matched, not read: the stock kernel's `l0`, `l0r` and `l0h` differ only in
  their command lines;
- the OS (`PRETTY_NAME`);
- how the card was prepared, from `/etc/dragonbox-pyra-prep`;
- the versions of `u-boot-pyra`, `pyra-hacks`, `pyra-settings`,
  `pyra-backlight`, `pyra-sound`, `funkeymonkey-pyrainput` and
  `dri3wsegl-pyra` (`dpkg-query`), or "not installed".

`/etc/dragonbox-pyra-prep` is written on every prep run, `key=value` lines that
`pyra-info` reads as text and never sources: `prep` (the checkout's commit,
`-dirty` with uncommitted changes to tracked files, `unknown` outside git),
`date` (UTC), `kernel` (the release tag when fix 19's tarball matched the pin,
else `local build, sha256 …`) and `release` (`yes` for `--release`). A second
run on the same day with the same checkout finds it up to date. Prep runs as
root in a checkout the user owns, so it calls git with `safe.directory` set to
that checkout. A card prepared before fix 31 says "no record".

Pyra Settings' About page (0.17 and later) runs `pyra-info` and shows its text with a
button that copies it.

**Checked** 2026-11-22 on the r5 release card with `pyra-info` copied in by
hand (`verification-log.md`, R93): every line matched the card (V5.3/V5.3,
`l5`, the seven packages), in 0.11 s as user `pyra`. The selftest asserts the
file and mode, the marker's commit, kernel, date and release lines (and
`release=yes` after `--release`), that the image's own bash and dpkg-query run
the script and list the image's `u-boot-pyra` and fix 26's `pyra-settings`, and
that a second run reports both files up to date.

## Fix 32 — the DBP Installer won't start, and its downloads never register

**Symptom.** `dbpInstaller_sebt3` 1.2.1 stops with `ModuleNotFoundError: No
module named 'apt_pkg'`. It bundles a Python 3.7 copy of the `apt` module whose
compiled `apt_pkg` can't load on trixie's Python 3.13, and falls back to the
system's, which `python3-apt` provides and the vendor image lacks. With
`python3-apt` installed by hand it runs, but its default target, "RootFs",
downloads into `~/dragonbox/packages`, and `dbpd` looks for
`dragonbox/packages` only at the root of each mounted filesystem: the download
completes and nothing registers. Diagnosis: `dbp.md`, "The DBP Installer", and
development log, R86.

**Fix.** Prep installs `python3-apt` 3.0.0 with the image's dpkg, together
with the two packages it depends on that the image lacks, `python-apt-common`
3.0.0 and `distro-info-data` 0.66+deb13u2 (the set `apt install python3-apt`
pulls in on the card). The three are Debian trixie's builds, downloaded from
`deb.debian.org` and checked against the SHA-256s in trixie's signed Packages
index; when a point release drops one from the pool, prep fetches it from
`snapshot.debian.org` by its SHA-1. Before fix 1 writes anything prep checks
that the image has everything they depend on. A package the image already has
is not downloaded. As with fix 22, prep runs no apt: a release image has no
package lists, and apt would fetch whatever is current.

Then it makes `/dragonbox`, `/dragonbox/packages` and `/dragonbox/appdata`,
mode 755 and owned by the card's user (fix 2's, `pyra` by default), and links
`~/dragonbox` to `/dragonbox`. The Installer's RootFs downloads then land where
`dbpd` searches the system card. A `~/dragonbox` that is an empty directory is
replaced by the link; one that holds files, or a link pointing elsewhere, is
left alone with a warning. Only the user prep sets up gets the link: another
user's Installer downloads still go to their own `~/dragonbox`. Nothing here
is per machine, so `--release` keeps it. A second run finds it all in place.

**Checked** 2026-11-23 by hand on the r5 release card (`verification-log.md`,
R86): with `python3-apt` installed by apt (the same three packages and
versions) the Installer lists the repository and downloads, and with the link
a RootFs download registered in 4 s. The selftest asserts the three packages
installed, that the image's python3 imports `apt` and `apt_pkg`, no staged
`.deb` left behind, the three directories' owner and mode, the link, and that
a second run finds them in place.

## Fix 33 — a release card's login keyring opens with `pyra`

**Symptom.** On the r5 release card, Chromium's first start asked to unlock
`~/.local/share/keyrings/login.keyring`, and `pyra`, the published default,
opened it. The password set at the first login did not (`browsers.md`;
development log, R98).

**Cause.** `--release` used to ship `pyra` expired (`chage -d 0`), so the
greeter changed it inside the first login. The card's journal of that login
(2026-11-21 04:46) shows each step, and gnome-keyring 48.0's
`pam/gkr-pam-module.c` explains it:

1. auth: `gkr-pam: unable to locate daemon control file`, then `stashed
   password to try later in open session`. The module keeps `pyra` for the
   session.
2. account: `expired password for user pyra`; chauthtok: `password changed`.
3. The module's password step: `unable to locate daemon control file` again.
   `get_control_file` needs `XDG_RUNTIME_DIR`, which `pam_systemd` sets only
   when the session opens, later. `change_keyring_password` then returns an
   error without setting `need_daemon`, so the step starts no daemon and
   stashes nothing. Had it reached the daemon, `change_or_create_login` would
   have created the keyring with the new password.
4. session: `unlocked login keyring`. The daemon has no login keyring, so the
   unlock creates one, with the stashed `pyra`.

So any password changed at the greeter misses the keyring, not only on a
release card. Only a release card does it on its first login.

**Fix.** The password is chosen before the greeter, so the first login uses
it. `--release` locks the user's password (shadow `!`, which no password
matches) instead of setting `pyra`, and writes
`/var/lib/dragonbox-pyra/first-boot-password` (0600, root), which names the
user. On the first boot `pyra-first-boot.service` (ordered before
`display-manager.service`, conditioned on that file) runs
`/usr/local/sbin/pyra-first-boot` under `xinit`. It is a GTK 3 window: the
password twice, "Show the password", "Set password" and "Shut down". It
refuses an empty password, two that differ, a line break, and `pyra`. The
password goes to `chpasswd` on stdin. Once that succeeds the file is removed,
the window closes, and lightdm starts. "Shut down" sets nothing, and the window
comes back on the next boot. If X cannot start, the unit's second command runs
`passwd` on tty1 until it succeeds. Without the file, as on any card prepared
with a password, the unit is skipped. A non-release run with `--set-password`
on a release image removes the file.

GTK 3 and not zenity: trixie's zenity 4.1.90 is GTK 4 and libadwaita, and
this X server has no GLX (fix 4). `pyra-touch-calibrate` (fix 30) already
runs GTK 3 on it. No window manager runs, so the window sizes itself to the
screen and takes the keyboard focus when it is mapped.

The vendor's own wizard, `pyra-first-run` 0.24 (the same on the bookworm 7
image and the trixie image), stays off (fix 2). It creates a second user
with four groups, so it would miss everything prep sets up for `pyra`. It
powers off when a dialog fails, and its password checks break on spaces.
Its hostname, timezone and locale questions are not carried over.

A release card no longer has a password anyone knows before its first boot,
so ssh, a console and the greeter all refuse logins until then.

**Checked** 2026-11-23. Source and journal as above. The window was driven
under Xvfb with no window manager (`--dry-run`): it takes the keyboard focus,
refuses unequal entries and `pyra`, and accepts `a:b c|d`. The selftest (468 passed, 2026-11-23) asserts the
tool and unit installed and enabled, that a card with a password has nothing
pending, the window's checks under the image's python3 and GTK 3, the release
state (shadow `!`, the pending file 600 root, no expiry), and the first-boot
step itself: the image's `chpasswd` writes a hash that the image's `crypt()`
opens with `a:b c|d`, and the pending file goes. On a Pyra, on a fresh release
card built from `8c3a35d` (`verification-log.md`, R99): the window came up
before the greeter and took the password, there was no keyring before the
first login, and the first login created one that the new password opens and
`pyra` does not.

## Fix 34 — GTK 4 programs abort before they draw: zenity, Volume Control

**Symptom.** zenity 4.1.90 (GTK 4.18.6) aborts before it draws, with a
different heap error each run (`malloc(): invalid size (unsorted)` and
others): 6/6 runs by hand, and 3/3 with `GSK_RENDERER=ngl`. DBP launchers
report missing data through zenity, so their messages never show (`dbp.md`,
"zenity crashes"; development log, R127). pavucontrol 6.1, the menu's Sound &
Video → Volume Control, is GTK 4 too and dies the same way: a segfault, then
`malloc(): invalid size (unsorted)` (2026-11-26, R99 card). With
`GSK_RENDERER=cairo` both draw.

The card's other GTK 4 users, from `apt-cache rdepends --installed
libgtk-4-1`: libadwaita, gtkmm 4, GTK 4's GStreamer media backend, and gcr4,
whose only program is `gcr4-ssh-askpass`. The keyring's unlock prompt,
`gcr-prompter`, is gcr's GTK 3 build. Everything else on the desktop (MATE,
the panel, caja, `pyra-settings`, fix 33's window) is GTK 3, which ignores
the variable.

**Cause** (2026-11-27, `verification-log.md` R131; the tools are in
`experiments/gtk4-renderer/`). Two things together:

1. **GTK 4.18 gets no GL here.** libepoxy opens `libEGL.so.1`, which resolves
   to the SGX blob, not glvnd. The blob offers OpenGL ES 2.0 only, and GTK
   needs GLES 3.0 or GL 3.3: `eglCreateContext` fails all of GTK's requests
   with `EGL_BAD_MATCH`.
2. **GTK then falls back to Vulkan, and lavapipe corrupts the heap.** mesa's
   software Vulkan driver is the only Vulkan device. In mesa 25.0.7 on armhf,
   every recorded command is allocated 4 bytes short (`vk_cmd_queue.c` adds
   `sizeof(vk_cmd_queue_entry_base)`, 20, but the command starts at offset
   24). `vkcube` crashes the same way. Mesa 26.2 has the fix; trixie, and
   trixie-backports' 26.1, do not. With the sizes corrected in memory, lavapipe
   still crashes, in its JIT code.

`GSK_RENDERER=ngl` or `gl` doesn't help, because a failed GL
renderer still falls through to the Vulkan fallback. `GDK_DISABLE=vulkan` also
avoids the crash, by ending at cairo too. With `GDK_DEBUG=opengl` zenity dies
earlier, in libepoxy: GTK's debug output calls `eglQueryDisplayAttribEXT`
without checking that the EGL has it. That is a separate, debug-only fault.

**Fix.** Prep adds `GSK_RENDERER=cairo` to `/etc/environment`, under a comment
naming the fix. pam_env reads that file for lightdm's session, ssh, su and
the console (`session required pam_env.so readenv=1`), and systemd's user
manager reads it through `/usr/lib/environment.d/99-environment.conf`, a link
to it, so D-Bus activated programs get it too. A file under
`/etc/environment.d` would reach only the user manager, and an Xsession.d
snippet only X sessions. The vendor's file is empty; prep keeps any other
line in it, and replaces another `GSK_RENDERER` line with a warning. It
warns if lightdm's PAM stack or the link no longer reads the file. Nothing
here is per machine, so `--release` keeps it. A program run with its own
`GSK_RENDERER` still gets that one. On a card prepared before fix 34, add
the line `GSK_RENDERER=cairo` to `/etc/environment` as root and log in again.

Epiphany is not fixed by this: with cairo its WebKit web process crashes
instead (`browsers.md`).

**Checked** 2026-11-26 on the R99 card (`verification-log.md`, R129), with the
line added to its `/etc/environment` and a fresh login: mate-panel, zenity and
pavucontrol carried `GSK_RENDERER=cairo` in `/proc/<pid>/environ`; CorsixTH,
started from the menu with `HOSPITAL.EXE` moved aside, showed its zenity
error dialog; Volume Control opened from the menu and drew. GTK 3 programs
started as before. The selftest (503 passed, 2026-11-26) asserts the file (644 root:root, the one
setting), lightdm's pam_env line, that the image's environment.d generator
passes the variable on, and that a second run finds it in place.

## Fix 35 — the volume wheel stays dead after rescue mode

**Symptom.** After `sudo systemctl rescue` and then `systemctl default`, the
volume wheel does nothing until the next reboot. pyra-sound's wheel bar does
not move, though the icon, the headphone slider and the sound itself all work
(the r6 release card, 2026-11-27).

**Cause.** `pyra_volumed.service` is `WantedBy=sound.target`, and
`sound.target` has no other way in: udev's sound-card devices pull it in at
boot. Rescue mode stops `sound.target` and the daemon with it. `systemctl
default` isolates `graphical.target`, whose tree holds neither, so neither comes
back. The unit's `Restart=on-failure` does not fire either, because systemd
counts a stop by SIGTERM as clean. `bluetooth.service` is wanted by
`multi-user.target` directly and comes back; `bluetooth.target` stays down,
with nothing hanging off it but the service.

**Fix.** Prep writes `/etc/systemd/system/multi-user.target.d/pyra-volumed.conf`,
which adds `Wants=pyra_volumed.service` to `multi-user.target`, under a comment
naming the fix. It doesn't pull in `sound.target`, which would join the boot
transaction ahead of the card, and `alsa-restore` would then skip the mixer
state because no card was there yet. The daemon itself can start early only
because the fork's (fix 26, from `0.38+pyra4`) exits until the card and the
wheel's ADC are there, and systemd restarts it every 2 s. The vendor's daemon
waits for neither, so with `--no-settings` prep writes nothing and removes
the file if an earlier run wrote it. Nothing here is per machine, so
`--release` keeps it. On a card prepared before fix 35, write the same two
lines to that path as root and run `sudo systemctl daemon-reload`. Until
then, `sudo systemctl start sound.target` or a reboot brings the wheel back.

**Checked** 2026-11-27 on the r6 card (`verification-log.md`, R140): with the
daemon stopped, `sudo systemctl default` left it inactive without the
drop-in and started it with the drop-in, and no unit failed.

## Fixes 6, 7 and 12 as a package

All three change files that `pyra-hacks` owns, so the prep script and the
device scripts patch or override that package in place. The same three changes
as patches against pyra-hacks 0.38, in the form sent upstream, are in
`patches/userspace/pyra-hacks-thermal/` (fixes 6 and 7, a two-patch series)
and `patches/userspace/pyra-hacks-volumed/` (fix 12, also a two-patch series:
the taper, then the headphones). Each applies with `git am`.

The packaged form is a separate repository,
[pyra-hacks](https://github.com/daniel-mcdonough/pyra-hacks): `main` is the
package's release history rebuilt from the source packages (upstream's
repository is not public), each fix is a branch off it (`feature/thermal-cap`,
`feature/thermal-ladder`, `feature/volumed-taper`), and `pyra` merges them with
a `+pyraN` version. The patches above are `git format-patch` output from
those branches. Its CI builds the deb, and each `+pyraN` tag is a
[release](https://github.com/daniel-mcdonough/pyra-hacks/releases) with the
debs attached:

| version | changelog date | adds |
| --- | --- | --- |
| `0.38+pyra1` | 2026-10-20 | fixes 6, 7 and 12 (the wheel's taper, speakers only) |
| `0.38+pyra2` | 2026-11-14 | the wheel drives the headphones too (fix 12, patch 0002) |
| `0.38+pyra3` | 2026-11-14 | the wheel's off position has its own band, so it doesn't flutter at the bottom |
| `0.38+pyra4` | 2026-11-19 | `pyra_volumed` exits when the sound card or the wheel's ADC is not there yet and systemd restarts it every 2 s, up to 30 times, so a daemon started before the card registered no longer leaves the wheel dead for the boot |
| `0.38+pyra5` | 2026-11-22 | the thermal daemon keeps a CPU ceiling set in `/etc/default/pyra-thermal` (*A CPU ceiling of your own*, below); prep's fix 26 installs this one |

To install 0.38+pyra2 on the Pyra:

    wget https://github.com/daniel-mcdonough/pyra-hacks/releases/download/v0.38%2Bpyra2/pyra-hacks_0.38+pyra2_armhf.deb
    sha256sum pyra-hacks_0.38+pyra2_armhf.deb
    # 72f708e1776759190eddcfb210819795fab5f730e4414081ecf3bc3aca2a0daa
    sudo apt install ./pyra-hacks_0.38+pyra2_armhf.deb

To build it here instead, clone that repository beside this one as
`../pyra-hacks`, on its `pyra` branch (the GitHub default, `master`, is empty,
and the build looks for a local `pyra` branch):

    git clone -b pyra https://github.com/daniel-mcdonough/pyra-hacks.git ../pyra-hacks
    ./pc/pyra-crossbuild.sh pyra-hacks     # -> pyra-hacks_0.38+pyra2_armhf.deb

Its `pyra-thermal.sh` is byte-identical to what fixes 6 and 7 produce from the
0.38 script, and its `pyra_volumed` is fix 12's mapping on upstream's own
libiio and alsa-lib code, driving the headphones as well from `0.38+pyra2`,
with the calibration and both ranges readable from `/etc/pyra_volumed.conf`. With it installed, `dpkg --verify pyra-hacks` is
clean and the three fixes have nothing left to do. Undo fix 12's override
(`device/pyra-volumed/install.sh --undo`), because its runner would otherwise
take over the packaged daemon.

The running unit has had `0.38+pyra1` since 2026-10-20, replacing 0.38. The previous
thermal script is kept beside it as `pyra-thermal.sh.before-pyra1-deb`. To
go back, install the archive's `pyra-hacks_0.38_armhf.deb`, then run fixes 6,
7 and 12 again. The fixes stay in the prep script for cards with the stock
package; fix 26 installs `0.38+pyra5` along with pyra-settings.

### A CPU ceiling of your own

The thermal daemon writes `scaling_max_freq` every 2 seconds, so a lower
limit written there by hand, or by `cpupower frequency-set -u`, is gone
within one pass. From `0.38+pyra5` (`dpkg-query -W pyra-hacks`) it reads a
ceiling from `/etc/default/pyra-thermal` instead:

    echo CPU_MAX_MHZ=1000 | sudo tee /etc/default/pyra-thermal

The daemon reads the file on every pass, so the ceiling applies within 2 s
with no restart. It never raises the clock past it, and when hot the ladder
still caps below it, as before. To lift it, delete the file
(`sudo rm /etc/default/pyra-thermal`); the top goes back to 1500 MHz within
2 s. The package does not ship the file, so no file means no ceiling.

- The value is in MHz. The kernel rounds it down to a step: `0007`'s are 250,
  375, 500, 625, 750, 875, 1000, 1125, 1250, 1400 and 1500 MHz, so 1300
  gives 1250.
- `CPU_MAX_MHZ = "875"  # comment` works too. A value that is not a plain
  number from 1 to 9999 (empty, a leading zero, letters) is ignored, as is
  anything above 1500. With several valid lines the lowest wins.
- The daemon reads the file with the shell's own `read`, and does not source
  it, so nothing in it is executed. It is root's to write, like the rest of
  `/etc/default`.
- A card prepared with `--no-settings` keeps the vendor's 0.38 with fixes 6
  and 7, which has no ceiling. Install the fork (above) to get one.
- pyra-settings 0.15 and later set it from their Performance page (No limit,
  or a step from 1400 down to 250 MHz), through their root helper. The page
  shows "Custom" for a value between steps written by hand; saving a choice
  rewrites the file whole, so comments in it go.

Checked on the card on 2026-11-22 (measured, ondemand, two busy-loop shells,
`scaling_max_freq` sampled about once a second); details in `verification-log.md`:

| ceiling | load | `scaling_max_freq` seen | peak `cpu_thermal` |
| --- | --- | --- | --- |
| 1000 MHz | 150 s | 1000 MHz in all 170 samples | 63.6°C |
| 1400 MHz | 180 s | 1400 MHz, and 1250 MHz twice when `cpu_thermal` passed 77°C (106 of 200 samples) | 79.4°C |

A 1500 MHz written by hand under a 875 MHz ceiling was back to 875 MHz
2.5 s later.

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

With a `0.38+pyraN` package the file already carries both markers, so the
guard is silent; it only acts if an archive version replaces that package.
Fix 12 is not watched. Its drop-in survives package runs by itself, but on a
card where it was removed for a `0.38+pyraN` package, an archive upgrade
brings back the stock wheel mapping without a word.

Fix 21 has a guard of the same shape, `pyra-wsegl-guard`, for the library
`dri3wsegl-pyra` owns. It is described under fix 21: it keys on the `.stock`
copy and a rollback marker rather than on backups.

