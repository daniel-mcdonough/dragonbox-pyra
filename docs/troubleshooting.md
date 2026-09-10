# Troubleshooting

**Quarter-second of LED, then nothing.** You tapped instead of holding. See
step 5. This is by far the most likely "it doesn't boot".

**USB is dead after a warm reboot, and the unit is off the network.** Fix 5 is
not in effect. Check it:

    systemctl status pyra-usb3503-rescue
    journalctl -b -u pyra-usb3503-rescue

A working rescue logs `hub absent from the USB bus, re-resetting` and then `hub
enumerated after 1 s`. If the unit is missing entirely, the prep script never
ran fix 5 — most likely it was run from a copy of the script with its two
payload files left behind, which now aborts rather than half-applying. See fix
5 in `fixes.md` for the diagnosis and the manual rebind. A cold power cycle avoids the
problem entirely and is the way back in if you are locked out.

**Configure wifi anyway before you reboot remotely.** Fix 5 restores the
ethernet adapter a second or two into the boot, but it is a workaround on a
path you cannot watch, and wifi is a second way in that does not depend on it.

**Still no boot after a proper long press.** Re-check that the card is in the
*left* full-size slot, that you `dd`'d to the whole device (`/dev/sdX`) and not
a partition (`/dev/sdX1`), and that `dd` finished with `conv=fsync` plus a
`sync`.

**It boots and then powers off.** Fix 2 didn't take — the marker path was wrong.
Pull the card, mount it, and read `/usr/bin/pyra-first-run.sh` to find the
actual guard condition.

**X still segfaults / lightdm fails and there is no desktop.** Read
`/var/log/Xorg.0.log`. If you see any `AIGLX` line, fix 4 is not in effect:
check that `/etc/X11/xorg.conf.d/20-pyra-glx.conf` exists and disables the GLX
extension. Do not chase the `armsoc_dri.so` symlink — it cannot fix this, for
the reasons under fix 1. `/var/log/lightdm/lightdm.log` and
`/var/log/lightdm/x-0.log` tell you whether lightdm or X is the one failing.

**Nubs still dead.** `systemctl status pyrainput` on the device. If the unit
failed to start, confirm `/usr/sbin/funkeymonkey`,
`/usr/lib/funkeymonkey/libpyrainput.so` and `/etc/pyrainput.cfg` all exist.

**General principle:** the device powers itself off faster than you can debug on
it. Pull the card, mount it on the PC, read the logs there
(`/var/log/Xorg.0.log`, `journalctl --directory=/mnt/pyra/var/log/journal`).
That is the working debug loop for this image.

---

## Known cosmetic oddity: load average sits at ~2

Two kworkers on the `events_freezable` workqueue sit permanently in `D` state:

    D   36  kworker/1:1+events_freezable
    D 1309  kworker/1:2+events_freezable

Linux counts uninterruptible tasks in the load average, so two of them pin it
near 2.0 while the CPU is ~80% idle and nothing is actually slow. Present from
the very first boot of this image, before any of the fixes here were applied, so
it is not something this procedure introduces. Cause not chased down; likely a
driver's delayed work blocking on an i2c transfer. Harmless, but it makes
`uptime` and any monitoring that watches load average misleading on this device.


---

## The X server can hang in a modeset, spinning a core, unkillable

Seen twice on 2026-09-10 on the trixie card, kernel 5.6.19-pyradef, X 21.1.16
with the `omap5` DDX. **Reproducible**, and understood well enough to avoid.

The symptoms, in the order they are noticed:

- Every X client hangs. `xdpyinfo`, `xwininfo` and `x11perf` all block forever
  and have to be killed. New clients hang too, so the display cannot be
  recovered from the desktop.
- `Xorg` sits in state `R` at **99% of one core** and stays there.
- `/var/log/Xorg.0.log` stops mid-modeset. The last line written is
  `(II) OMAP5(0): preparing to set mode: 0 0 8 720 1280` with nothing after it.
- The display controller has stopped. `OMAP DISPC` in `/proc/interrupts` goes
  from about 10 a second to **zero**, so there are no more vblanks and whatever
  the driver is waiting for will never arrive.

**`SIGKILL` does not work.** The process spins inside the kernel without
reaching a signal check, so `kill -9` leaves it running and
`systemctl restart lightdm` gets stuck with the unit `deactivating` forever
while it waits for a server that will never exit.

On a fanless handheld this is a thermal problem and not only an annoyance. One
core pinned at 100% held `cpu_thermal` between 85 and 97°C on an otherwise idle
desktop, and it touched 101.5°C, past the 100°C passive trip.

### What triggers it

Every modeset is a chance to hit this, and **every DPMS transition is a
modeset.** Counting `preparing to set mode` in the X log while poking one thing
at a time:

| action | modesets |
| --- | --- |
| three ordinary windows opened and closed | 0 |
| `xset s off`, `xset s default` | 0 |
| `xset -dpms` | 1 |
| `xset dpms force off` | 1 |
| `xset dpms force on` | 2 |
| one `x11perf` run | 2 |

Each one reprograms the mode and re-applies the rotation property to all four
display planes, which is what `TilerRotation 270` costs. An ordinary desktop
session does three at startup and then none, so this is not something normal use
runs into quickly.

`x11perf` is the reliable way to reproduce it, because it disables and restores
DPMS around every single test. A seven-test suite is fourteen modesets and both
hangs happened inside one. **Do not run `x11perf` on this machine** until the
driver is fixed; use a benchmark that leaves DPMS alone.

Two hypotheses that were tested and are wrong. It is not idle blanking as such:
the second hang happened with `xset s off -dpms` already in effect, because
`x11perf` toggles DPMS itself regardless. And it is not the compositor:
`compositing-manager false` gives exactly the same two modesets per run.

### Mitigation

Stop the transitions from happening. Both halves are needed, because MATE has
its own display timers independent of the X server's:

    # X server, permanent, applies at next X start
    /etc/X11/xorg.conf.d/30-pyra-no-dpms.conf   with BlankTime/StandbyTime/
                                                SuspendTime/OffTime all "0"

    # MATE, per-user
    gsettings set org.mate.power-manager sleep-display-ac 0
    gsettings set org.mate.power-manager sleep-display-battery 0

    # this session only
    xset s off -dpms

The cost is that the screen never blanks on its own, which on a battery handheld
is a real cost. It buys not having to reboot, and not having a core pinned at
100% inside a closed case. Reverse it by deleting the config file and setting
the two timers back to 1800 and 600.

This is a mitigation and not a fix. Any program that toggles DPMS still triggers
the modeset, and a modeset can still wedge.

### Recovery

**A reboot is the only recovery found.** `sudo systemctl reboot` works normally;
it is only the X server that is stuck, not the kernel.

Keep the evidence first, because it is gone afterwards:

    sudo cp /var/log/Xorg.0.log ~/Xorg-modeset-hang-$(date +%Y%m%d-%H%M).log
    sudo dmesg > ~/dmesg-modeset-hang-$(date +%Y%m%d-%H%M).log

### Still unknown

Why the modeset wedges rather than failing. `dmesg` from the first hang carried
`DSI: omapdss DSI error: VC(0..3) busy when trying to configure it!` from earlier
in the same boot, but the second hang produced no kernel message at all, so those
errors are a separate symptom rather than the cause. The driver has no timeout on
whatever it waits for, which is the part that turns a display glitch into a
machine that needs rebooting, and that is where a fix should start.

It is now known to be **the kernel** that spins, not the X driver: the log line
the hang stops on is one `drmModeSetCrtc` call away from the kernel, so `Xorg`
is stuck inside `DRM_IOCTL_MODE_SETCRTC` in `omapdrm`. `building.md` has the
reasoning, the two diagnostics that will name the function during the next hang
without any rebuild, and how to compile a kernel with a fix in it.
