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

Seen 2026-09-10 on the trixie card, kernel 5.6.19-pyradef, X 21.1.16 with the
`omap5` DDX. The desktop had been left idle for several minutes between
benchmark runs, long enough for the screen to blank, and the next client to
connect never got a reply.

The symptoms, in the order they are noticed:

- Every X client hangs. `xdpyinfo`, `xwininfo` and `x11perf` all block forever
  and have to be killed. New clients hang too, so the display is unrecoverable
  from the desktop.
- `Xorg` sits in state `R` at **99% of one core**, and stays there.
- `/var/log/Xorg.0.log` stops mid-modeset. The last line written is
  `(II) OMAP5(0): preparing to set mode: 0 0 8 720 1280` with nothing after it.
- `dmesg` carries, from earlier in the same boot:

      DSI: omapdss DSI error: VC(0) busy when trying to configure it!
      DSI: omapdss DSI error: VC(1) busy when trying to configure it!
      DSI: omapdss DSI error: VC(2) busy when trying to configure it!
      DSI: omapdss DSI error: VC(3) busy when trying to configure it!

**`SIGKILL` does not work.** The process is spinning inside the kernel without
reaching a signal check, so `kill -9` leaves it running and
`systemctl restart lightdm` gets stuck with the unit `deactivating` forever
while it waits for a server that will never exit.

On a fanless handheld this is a thermal problem and not only an annoyance. One
core pinned at 100% held `cpu_thermal` between 85 and 90°C on an otherwise idle
desktop, and it briefly touched 101.5°C, past the 100°C passive trip.

**The only recovery found is a reboot.** `sudo systemctl reboot` works normally;
it is only the X server that is stuck, not the kernel.

Before rebooting, keep the evidence, because it is gone afterwards:

    sudo cp /var/log/Xorg.0.log ~/Xorg-dsi-hang-$(date +%Y%m%d-%H%M).log
    sudo dmesg > ~/dmesg-dsi-hang-$(date +%Y%m%d-%H%M).log

Note that the machine comes back to the lightdm greeter and there is no
autologin configured, so the desktop session has to be started at the device.

Not yet established: whether DPMS blanking is the trigger, or only a correlate.
The one observed instance followed a long idle gap, and the DSI virtual-channel
errors appeared well before the hang rather than with it. Anyone reproducing
this should record `xset q` and the exact idle time first. Disabling blanking
with `xset s off -dpms` is the obvious workaround to try, and is untested.
