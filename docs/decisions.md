# Decisions and rejected alternatives

## Where this deviates from the forum post

The original writeup works, but a few steps are fragile enough to be worth
replacing:

- **User creation.** The post appends raw lines to `/etc/passwd`, `/etc/group`
  and `/etc/shadow` and has you hand-edit group membership. That is how you end
  up with `gshadow` disagreeing with `group` and `useradd` refusing to run
  later. The script uses `useradd --root` / `usermod --root`, which write all
  four files consistently and honour the image's own `login.defs`.
- **Password handling.** `openssl passwd -6 'yourpassword'` puts the password
  in shell history and in `ps` output. The script prompts with `read -rs` and
  pipes to `chpasswd -e -R`, so it never reaches the process table.
- **The DRI symlink target.** The post hardcodes `kms_swrast_dri.so`. If mesa
  25.x has dropped that name, a blind `ln -s` creates a dangling symlink and you
  get the same segfault with a more confusing log. The script probes for
  `kms_swrast_dri.so`, then `swrast_dri.so`, then any `*_dri.so`, and hard-fails
  rather than leaving a broken link.
- **The first-run marker.** `/var/lib/pyra/first-run.done` is asserted, not
  verified. The script greps the actual `pyra-first-run.sh` for the path it
  really checks, and warns if it has to fall back to the documented default.
- **Enabling pyrainput.** The post has you run `systemctl enable --now
  pyrainput` after boot. The script symlinks it into `multi-user.target.wants`
  offline, so the nubs work on the very first boot.

---

## Rejected alternatives (for when you're tempted)

**Installing trixie to the eMMC instead of a card.** Technically possible, and
it sidesteps the long-press quirk since the eMMC's older U-Boot has no PMIC
check. But it overwrites bookworm-7 — your only known-good system and your only
recovery path. This image is deliberately a live SD image that leaves the eMMC
alone. Don't burn the fallback to test a build that needed four fixes to reach
a desktop.

**The microSD slot under the battery.** Not the documented boot path, and not
confirmed to be on a boot-capable controller.

**USB boot.** OMAP5 peripheral boot exists, but it is an SPL-over-USB recovery
mechanism, not a way to run a rootfs.

---


## Configuration choices made on the running unit, 2026-09-10

These change the machine's behaviour, so they are recorded with what they cost
and how to undo them. All three are in `improvements.md` or `troubleshooting.md`
with the measurements behind them.

**Marco's compositor is off.** Measured at about 3.5% of all busy CPU during a
real workload, with no effect on the X server's own cost. Taken because it is
free and reversible. The price is window shadows, fades and true transparency on
a five-inch panel.

    gsettings set org.mate.Marco.general compositing-manager true   # to revert

**Display blanking and DPMS are disabled**, both in the X server and in MATE's
own timers. This is a mitigation for a driver bug that wedges the display and
needs a reboot, not a preference. The price is real on a battery handheld: the
screen never turns off by itself. **Undo this when the driver is fixed**, not
before.

**Autologin is on**, in a drop-in that leaves the packaged `90_pyra.conf` alone.
It removes the password prompt at boot, so anyone holding the device is one power
button away from the desktop and the session keyring. Deliberate on a handheld,
and not a substitute for encrypting the card.

## Rejected on measurement, not on principle

Each of these looked reasonable and was killed by a number. They are here so
they do not come back as suggestions.

**Rebuilding the `omap5` display driver for the EXA fallbacks.** Fills and blits
already run on the GC320. The X server's whole share of a real workload is about
0.24 of the game's own CPU, most of it accelerated work rather than fallbacks, so
that is the ceiling on the entire idea.

**Tuning PulseAudio.** The codec accepts only 32-bit samples at 88200 Hz or
above, so every ordinary stream is converted and there is no configuration that
avoids it. The resampler is already the cheapest available, NEON is already in
use, and the extra sink layer measures free.

**Switching the driver's pixmap allocator to cached memory.** Identical software
paths against write-combine and against plain `malloc` measure the same to within
noise, so there was nothing to win.

**Raising `VIV2D_MIN_SIZE`.** It is a per-pixmap allocation gate, not an
operation threshold, so it cannot express the thing it was being asked to
express.

**Chasing the i2c interrupt floor.** Worth 2-3% of one core, needs a kernel
patch, and there is only one cpuidle state so the wakeups block no deeper sleep.

---

---

## Where to fix a kernel fault, 2026-09-11

Four kernel bugs were found in two days and each one had a choice of where to
put the fix. The reasoning is here so the patches are not re-argued.

**The keypad interrupt: driver, not device tree.** The TCA8418 drives INT as a
level and `pyra-mainboard-common.dtsi` declares the line
`IRQ_TYPE_EDGE_FALLING`, which is what makes a missed acknowledgement fatal
rather than merely wasteful. Changing the device tree to level triggering is the
smaller diff and it is tempting. It was rejected: the driver would then storm
whenever its handler returns without acknowledging, which is exactly the failure
already seen on the PMIC, and the resume window where i2c returns `-EACCES` is a
guaranteed opportunity for it. Other boards describe the line the same way, so
the driver has to survive it regardless. `patches/0006` makes the handler leave
only when the chip is quiet, which is correct under either description.

**The nub poll: guarded on `input->users`, not mirrored blindly.** Suspend
cancels the poll unconditionally, so the obvious fix is to schedule it
unconditionally on resume. That would start a poll on a device nobody has opened
yet, which the driver would otherwise never have done, and this chip is polled
at 25 ms forever once started. The guard costs three lines and keeps the
resume path from inventing work.

**The PMIC interrupt: held off across the window, not moved to a different
phase.** The real fault is that `resume_device_irqs()` runs a phase before
runtime power management comes back on the i2c controller. That is core
sequencing and not something to relitigate from a board port, so `patches/0004`
holds the one interrupt off across the window instead. The cost is that the
power button is unavailable for that window, which is why confirming the button
still wakes the machine is an open item rather than a formality.

**Debug options stay once added.** `CONFIG_GENERIC_IRQ_DEBUGFS` went into the
build for a theory that turned out to be about the wrong device. It was kept,
and it is what confirmed the keypad interrupt was not disabled two days later.
It costs nothing at runtime.
