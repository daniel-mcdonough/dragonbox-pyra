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

**USB dies while running: `disabled by hub (EMI?)`, then `port 2 reset error
-110`.** This is not the warm-reboot case and fix 5 does not cover it. Seen on
2026-10-22, about fifteen seconds after a charger was pulled from the USB3
micro port while cables were being swapped:

    usb usb1-port2: disabled by hub (EMI?), re-enabling...
    ehci-omap 4a064c00.ehci: port 2 reset error -110

Port 2 is the HSIC link to the on-board hub, and once it is in this state none
of the following recovers it, all tried in turn: running
`pyra-usb3503-rescue` by hand; rebinding `ehci-omap` as well; pulsing the hub's
reset line (gpio 144, active low) low by hand, which does bring the hub back
onto the port but the link still times out; and holding the hub in reset across
an `ehci-omap` rebind. **Reboot.** The rescue unit handles the warm boot that
follows.

Do **not** rebind `usbhs_omap` (`4a064000.usbhshost`) to try to reinitialise
the link. On this kernel it removes the EHCI and OHCI children and does not
recreate them, which leaves USB host gone for the rest of the boot, and the
reboot that followed panicked on the way down: PID 1 took a fault inside
`openat` and the kernel died with `Attempted to kill init! exitcode=0x0000000b`.
The machine had to be power-cycled. The faulting address scrolled off the
console and `CONFIG_PSTORE` is not set, so the half-removed devices are the
likely cause rather than a proven one.

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

## Root mounts a minute or two late, with nothing on screen

A healthy boot mounts the root filesystem 6-17 s in. Some boots sit in the
initramfs instead and mount it at about 70 s or about 126 s. The SD card is
detected at 2 s either way. In the journal of 27 boots from 2026-09-30 to
2026-10-28 (measured from the kernel timestamps, `_SOURCE_MONOTONIC_TIMESTAMP`;
journald's own receive times put all of early boot at the switch-root moment
and hide the gap), 7 were slow. They happened on `5.6.19-fix` as well as
`m4-kbdled` (and since on `5.6.19-pyradef`, below), so this is not a kernel patch. There are two shapes, and the wait
is the same in both: `init-top/udev` in the initramfs runs `udevadm settle`, which
gives up after 120 s, and root is mounted only after that.

**Shape B, explained: the USB ethernet adapter waits 60 s for firmware that is
not there.** Only cold boots, 2 of 13 (boots on 2026-10-24 and 2026-10-28). When
the RTL8153 adapter behind the on-board hub enumerates while the initramfs's udev
is still running, `r8152` asks for `rtl_nic/rtl8153a-4.fw`. It is not in the
initramfs or on the card. The kernels are built with
`CONFIG_FW_LOADER_USER_HELPER_FALLBACK=y`, so the failed direct load falls back to
the sysfs interface and waits its 60 s timeout for a helper that systemd-udev
does not provide. Meanwhile the probe holds the device lock, the udev worker
loading `r8152` blocks behind it, and the firmware uevent that the initramfs's
`50-firmware.rules` would cancel is queued behind that same device:

    7.048 r8152 1-2.1:1.0: Direct firmware load for rtl_nic/rtl8153a-4.fw failed with error -2
    7.054 r8152 1-2.1:1.0: Falling back to sysfs fallback for: rtl_nic/rtl8153a-4.fw
   60.647 INFO: task kworker/0:1:12 blocked for more than 30 seconds.
   60.809 (rtl8152_set_mac_address [r8152]) from (set_ethernet_addr [r8152]) ... (rtl8152_probe [r8152])
   60.957 INFO: task (udev-worker):1715 blocked for more than 30 seconds.
   61.069 (driver_register) from (usb_register_driver) ... (do_init_module)
   69.607 r8152 1-2.1:1.0: unable to load firmware patch rtl_nic/rtl8153a-4.fw (-11)
   69.728 usbcore: registered new interface driver r8152
   70.650 F2FS-fs (mmcblk1p2): Mounted with checkpoint version = 435fe6e8

On the other cold boot, `r8152` gave up at 69.7 s in the same way, but root still
waited until 126.6 s with nothing logged. That boot also had a second, silent
waiter, which looks like shape A below.

The same 60 s wait happens on **every** boot, but normally the adapter
enumerates only after `pyra-usb3503-rescue` runs in the real root, so the wait
only delays the wired network: on a fast boot the adapter gets carrier around
88 s (`carrier on` at 88.5 s on 2026-10-28, `unable to load firmware patch ... (-11)`
at 85.0 s). Other firmware fallbacks (remoteprocs, wifi config, `regulatory.db`)
are cancelled by udev within a second, because nothing is queued ahead of them.
A live rebind of `r8152` shows the same thing: udev cancels its fallback in 6 ms.
The 60 s wait needs a blocked udev queue, and a boot-time probe supplies one.

The fix is `device/etc/initramfs-tools/scripts/init-top/pyra-fw-nofallback`,
which sets `/proc/sys/kernel/firmware_config/ignore_sysfs_fallback` to 1 before
udev starts. The knob overrides `force_sysfs_fallback`, which is 1 on these
kernels. The setting survives switch_root. Install it as its header says. With it
installed (2026-10-28, warm reboot), the knob reads 1 after boot, the log says
`Ignoring firmware sysfs fallback due to sysctl knob`, `r8152` fails the load
with -2 at once, and the adapter has carrier at 41 s instead of 88 s. Five cold
boots with the adapter plugged in then mounted root at 9.5, 6.5, 7.6, 6.1 and
8.2 s, with carrier at 22-25 s. On two of them `r8152` probed inside the
initramfs, which is the shape B trigger, and gave up on the firmware within
10 ms:

    7.177 r8152 1-2.1:1.0: Direct firmware load for rtl_nic/rtl8153a-4.fw failed with error -2
    7.185 Ignoring firmware sysfs fallback due to sysctl knob
    7.192 r8152 1-2.1:1.0: unable to load firmware patch rtl_nic/rtl8153a-4.fw (-2)
    9.467 F2FS-fs (mmcblk1p2): Mounted with checkpoint version = 435fe8d2

The hook is installed on the trixie card for `5.6.19-m4-kbdled` only; prep does
not install it yet. Without it, the workaround is to unplug the adapter for a
cold boot.

**Shape A, not explained: 120 s of silence after a warm reboot.** 5 of 12 warm
reboots (boots on 2026-10-19, 20, 24 and two on 2026-10-28), root at 126-128 s.
The log stops after the EHCI root hub comes up and resumes with the root mount:

    6.567 hub 1-0:1.0: USB hub found
    6.571 hub 1-0:1.0: 3 ports detected
   35.048 host1_vbus_power: supplied by modem_vbus_hdmi_power      (regulator cleanup, every boot)
   35.131 otg_path: disabling
  127.046 F2FS-fs (mmcblk1p2): recover fsync data on readonly fs

That is exactly `udevadm settle`'s 120 s, with no hung-task report, no firmware
fallback and no USB error. The on-board hub is absent from the initramfs, but it
is absent on every warm reboot, fast or slow (fix 5 re-resets it later), so that
is not the difference. The waiter is something that sleeps interruptibly, which
the hung-task detector does not report. Four warm reboots on 2026-10-28 with a
diagnostic in place were all fast (6.3-9.5 s). The fifth, with the shape B fix
also in place, showed the same silence at a smaller size: the root hub at
6.75 s, then nothing until the root mount at 23.4 s. The SD card had been there
since 2.2 s, so those 16.6 s were spent in initramfs userspace. The F2FS `recover fsync data on readonly fs` line before each root mount is on
all 32 journaled boots, fast and slow, so it is not a clue. The diagnostic,
which then sampled only at 40 and 90 s, missed it. The diagnostic is
`experiments/initramfs-wait/pyra-settle-diag`. If the initramfs is still running
at 15, 30, 60 or 100 s, it writes every process's state and wchan to
`/run/initramfs/settle-diag.txt` and triggers SysRq-T, so every task's stack is in
the journal after a `pyra-settle-diag` line. The dump goes only to the ring
buffer, not the screen. Check after any slow boot:

    sudo cat /run/initramfs/settle-diag.txt
    sudo journalctl -k -b -g pyra-settle-diag

**2026-10-28, two more shape A boots.** A warm reboot into the stock-config
`5.6.19-pyradef` (l0, no fix and no diagnostic in its initramfs) showed the
whole 120 s: root hub at 6.5 s, silence, root at 127.3 s. So the wait is not in
any of our patches. The next warm reboot, into `m4-kbdled`, was caught by the
diagnostic's 15 s sample and **never finished booting**: the console froze at
20.9 s at the end of the SysRq-T dump. Nothing answered on the network after
7 minutes, and it took a power cycle. Its log was lost with it, because no
journald runs in the initramfs, so the only record is a photo of the panel. That
shows the root mount itself still running and waiting, not finished:

    (rcu_barrier) from (kmem_cache_destroy+0x3c/0x1f8)
    (kmem_cache_destroy) from (f2fs_recover_fsync_data+0x530/0x2794)
    (f2fs_recover_fsync_data) from (f2fs_fill_super+0x1540/0x1c14)
    ... (mount_bdev) (f2fs_mount) (vfs_get_tree) (do_mount) (sys_mount)
    workqueue events: in-flight dbs_work_handler, pending drm_fb_helper_dirty_work

The task's name and state line scrolled off the top. The console redraw
(`drm_fb_helper_dirty_work`) was queued behind the cpufreq governor's work on
CPU0.

**That `rcu_barrier` was the diagnostic's own doing, and F2FS is not the
waiter.** The kernel runs the whole SysRq-T handler inside `rcu_read_lock()`
(`__handle_sysrq` in `drivers/tty/sysrq.c`). Every root mount ends its fsync
recovery with `kmem_cache_destroy()`, which calls `rcu_barrier()` because the
kernels have `CONFIG_MEMCG_KMEM=y` (`flush_memcg_workqueue` in
`mm/slab_common.c`). So a mount that starts while a dump is printing waits
until the dump ends. The dump was printing to every console, because the
cmdline carries `ignore_loglevel`: measured 2026-10-28 on the running system,
with fbcon hidden behind X so only the serial console was printing, one
SysRq-T write took 5.28 s. In the initramfs, fbcon also draws each of the
~3900 lines. The journal (42 boots, 2026-10-02 to 2026-10-28,
kernel timestamps) settles the F2FS question:

- On every boot, slow or fast, `recover fsync data on readonly fs` (printed as
  recovery starts) and `Mounted with checkpoint` are 36-77 ms apart. The 70 s
  and 126-128 s waits all come before recovery starts.
- Every slow boot followed a clean shutdown (`Journal stopped` in the previous
  boot), so there was no fsync data left over from an unclean stop.

Why the frozen boot never recovered is not known. The diagnostic now keeps the
dump off the consoles (it turns `ignore_loglevel` off and sets the console
loglevel to 1 around the SysRq write, then puts both back). On the running
system the same write then took 0.03 s, and the full dump was in the journal.

---

## Crashes, freezes or wrong results since 2026-09-29: suspect the undervolt first

The CPU's 750 MHz point runs at 870 mV, not 950, from every boot on 5.6.19-m4-kbdled
(`device/pyra-undervolt.service`, `experiments/undervolt/README.md`). It passed every 10 mV step to
850 mV and a 60-minute `stress-ng --verify` soak, but too little voltage fails as silent wrong results
first and a crash later, and a crash mid-write can damage the card. So before anything else:

    sudo pyra-undervolt status              # 750000 950000 870000 changed = active
    sudo pyra-undervolt set 750000 900000   # more margin, on the fly
    sudo pyra-undervolt off                 # stock until the next boot
    sudo systemctl disable pyra-undervolt   # stock from now on

The l4 boot entry never loads the module, so it is stock too. If the fault goes away at stock voltage,
raise `POINTS` in `/etc/default/pyra-undervolt` (the default is `750000:870000`) and note it in the
experiment's README.

---

## Solved: the load average that sat at ~2

On the stock kernel two kworkers on the `events_freezable` workqueue sit
permanently in `D` state:

    D   36  kworker/1:1+events_freezable
    D 1309  kworker/1:2+events_freezable

Linux counts uninterruptible tasks in the load average, so two of them pin it
near 2.0 while the CPU is about 80% idle and nothing is actually slow. It is
present from the very first boot of this image, before any of the fixes here
are applied, so it is not something this procedure introduces.

It was written off here as a cosmetic oddity of unknown cause. It was not
cosmetic and the cause turned out to matter: those two workers are the rescans
of the two phantom SD hosts, and the same two workers are what makes this
machine refuse to suspend. Both sections below have the full story.

**Fixed by `patches/0003`.** On `5.6.19-fix`, verified 2026-09-11: no task in
`D` state at all, four MMC hosts instead of six, and the load average settles
where an idle machine's should.


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

**Do not reboot before taking a backtrace.** The machine stays usable over SSH
while the X server is wedged, and this is the only moment the stack can be
read. Three dumps, a second apart, because it catches whatever is running at
that instant:

    for i in 1 2 3; do echo l | sudo tee /proc/sysrq-trigger; sleep 1; done
    sudo dmesg | tail -120

Do not expect the lockup detector to have done this for you. See below.

### What is spinning: the search is down to two loops

It is **the kernel** that spins, not the X driver. The log line the hang stops
on is one `drmModeSetCrtc` call away from the kernel, so `Xorg` is stuck inside
`DRM_IOCTL_MODE_SETCRTC` in `omapdrm`. Three things follow from the symptoms
and together they describe the fault precisely:

- It is a **busy loop, not a wait.** The task is in state `R` and accumulates
  CPU time. A driver waiting on a completion or an interrupt would be in `D`
  and would cost nothing.
- **Interrupts are still on.** CPU time is only credited on timer ticks, so a
  process that reaches 99% is being ticked. This matters: it means the
  kernel's own soft lockup detector can see it.
- **There is no signal check in the loop**, or `SIGKILL` would land.

So: an unbounded busy-wait in the modeset path. Every wait in that path was
then read, in `dss/dsi.c`, `dss/dispc.c`, `dss/dss.c`, `omap_crtc.c`,
`omap_irq.c` and `omap_dmm_tiler.c`. All of them are bounded — by an iteration
count, a `jiffies` deadline, or a `wait_for_completion_timeout` — except two,
which are bounded by nothing at all:

    dsi_vc_flush_receive_data()   dss/dsi.c
    dsi_vc_flush_long_data()      dss/dsi.c

Both drain the DSI receive FIFO by spinning on `RX_FIFO_NOT_EMPTY`, bit 20 of
`DSI_VC_CTRL`, reading a word out of the FIFO each time round:

    while (REG_GET(dsi, DSI_VC_CTRL(channel), 20, 20)) {
            val = dsi_read_reg(dsi, DSI_VC_SHORT_PACKET_HEADER(channel));
            ...
    }

No limit, no timeout, no way out if the bit does not clear.

**They sit directly under every display enable.** `dsi_vc_write_common()` ends
every synchronous DCS write with a bus turnaround and then checks that bit; if
it is set it calls the drain. `dsi_vc_send_bta()` checks it before every
turnaround and does the same. The panel driver sends its whole initialisation
sequence through that path each time the display is powered on, which is what
a DPMS transition does.

**And writes on this panel are already known to fail.** The driver tolerates
it explicitly — `panel-boe-w677l.c` logs `failed to configure panel` and
carries on, with the comment *"can fail if the ssd can't forward long
commands"*. A turnaround that timed out leaves a reply arriving with nobody
waiting for it, which is exactly the state the drain loop exists to clean up.
The recovery path for a known-flaky transfer is the one place in the driver
with no way to give up.

This is a hypothesis with a good fit, not a demonstration. What makes it worth
acting on anyway is that bounding the loops is correct regardless of whether it
is the fault: a display controller that stops answering should cost a failed
modeset, not a reboot. `patches/0001` caps both loops at 256 reads and lets the
callers' existing `-EIO` paths unwind, and prints `rx fifo will not drain` on
the way out, so if it ever was the fault the log will say so.

### The lockup detector will not catch this, and why

This was assumed and it is wrong, so it is worth stating plainly. The
`5.6.19-softlockup` kernel has been running for days with the soft lockup
detector armed at a 10 second threshold, and if the hang had happened it would
most likely have reported nothing.

(That kernel was removed from the card on 2026-09-20 to make room in `/boot`;
`kernel/softlockup-kernel.tar.gz` on the PC still installs it without a
recompile. The reasoning below does not depend on it being present.)

The detector does not watch for a busy CPU. It works by having each core's
watchdog timer queue a job on that core's stopper thread, which is real-time
priority and preempts everything; the job updates a timestamp, and the next
timer that finds the timestamp stale declares a soft lockup. This kernel is
built `CONFIG_PREEMPT=y`. A kernel loop that does not hold off preemption gets
preempted by the stopper thread like anything else, the timestamp is updated,
and the detector sees a healthy core.

The two drain loops hold a mutex and nothing else, so they are preemptible. The
detector is blind to exactly this shape of fault. It still earns its place —
it is what found the two SD workers stuck since boot, which the stock kernel
reported not at all — but it is not the instrument for this.

**What does work is sysrq, while the machine is still hung.** `echo l` sends an
inter-processor interrupt to every core and prints a backtrace of whatever that
core is running, which for a spinning loop is the loop. That is the capture
`pyra-modeset-hang-trap.sh` takes, and it is why the sysrq mask on this build
was raised to include the debugging-dump bit. Take it before rebooting; see
Recovery above.

**And the patched kernel answers for itself.** If the drain loops are the
fault, `5.6.19-fix` turns the hang into a line in the log:

    sudo dmesg | grep "rx fifo will not drain"

Present means the diagnosis was right and the machine survived something that
used to need a reboot. A hang with that line absent means the loop was not it,
and the sysrq dump is what says where to look next.

### Two settings that make a live capture worth more

Both are installed on this build in `/etc/sysctl.d/90-pyra-lockup-capture.conf`:

| setting | stock | here | why |
| --- | --- | --- | --- |
| `kernel.sysrq` | 438 | 446 | 438 leaves out `0x8`, the debugging dumps, which is the bit `echo l` and `echo w` need |
| `kernel.softlockup_all_cpu_backtrace` | 0 | 1 | if the detector ever does fire, dump both cores rather than one |

    echo l | sudo tee /proc/sysrq-trigger    # backtrace every CPU
    echo w | sudo tee /proc/sysrq-trigger    # every blocked task

The journal is persistent, so whatever is captured survives the reboot that
recovers the machine: `journalctl -k -b -1`.

### Two measurements that turned out not to be the fault

Both were counted over 1587 deliberate modesets on 2026-09-11, which did not
reproduce the hang but did measure the machinery. An earlier version of this
section put more weight on them than they turned out to deserve.

**The DSI virtual channels reporting busy is harmless.** Over 400 display
power-ons, `dsi_vc_initial_config()` found the `VC_BUSY` bit set on all four
channels every single time — 1600 errors, a clean 400 out of 400 each:

| channel | times busy at configure | out of |
| --- | --- | --- |
| VC(0) | 400 | 400 |
| VC(1) | 400 | 400 |
| VC(2) | 400 | 400 |
| VC(3) | 400 | 400 |

It looks alarming and is not. Later in the same enable, `dsi_vc_config_source()`
waits on that same bit properly, with a 500 ms deadline, and returns `-EIO` if
it is still set. That message never appeared once in 400 enables. So the bit
clears on its own; the earlier check simply runs before the block has settled
and reports a state that is about to go away. It is noise in the log, not a
fault, and making the first check wait would add seconds to every display
power-on for nothing.

**The runtime PM warning is probably unrelated.** `dispc_runtime_put()` failed
twice in 1587 modesets, from the atomic commit worker:

    WARNING: CPU: 0 PID: 4083 at drivers/gpu/drm/omapdrm/dss/dispc.c:667 commit_tail+0x9c/0x194
    Workqueue: events_unbound commit_work

Rare in about the right proportion to a fault seen twice in weeks, which is why
it was worth a second look. But the likely return values, `-EBUSY` and
`-EAGAIN`, both mean only that the device declined to idle and stayed powered,
which is harmless while the display is on. The error was also not latched —
runtime PM remembers a failed callback and would then have failed on every
subsequent put, and it did not. `patches/0002` prints the value so the next
occurrence settles it, but it is no longer the leading candidate.

### One more thing the display does on every boot

The L3 interconnect reports an error during the panel's power-on, once, at
about 2.6 seconds:

    44000000.ocp:L3 Custom Error: MASTER MPU TARGET L4WAKEUP (Idle):
        Data Access in User mode during Functional access
      l3_interrupt_handler
      ...
      w677l_regulator            <- the panel driver toggling its supply GPIO
      w677l_enable
      omapdss_device_enable
      omap_encoder_enable
      drm_atomic_helper_commit_modeset_enables

The CPU touched a register on the wakeup interconnect while that target was
clock-gated. The L3 answers with an error rather than hanging, so it is
survivable and the display comes up anyway, but it means the panel enable path
touches at least one module without holding it awake. Not chased further.

### The mitigation does not cover everything

It does **not** stop a program that toggles DPMS itself. Measured on
2026-09-10, with the config file in place and `xset q` reporting DPMS disabled,
a single seven-test `x11perf` run still provoked 36 modesets. The mitigation
protects an ordinary session, which never toggles DPMS by hand. It does not
make `x11perf` safe to run.

`pyra-modeset-hang-trap.sh` automates provoking the hang and capturing it, and
`building.md` has the patch set and how to build a kernel carrying it.


---

## The WiFi driver can flood the kernel log and starve the machine

Seen once, on the night of 2026-09-27/28, kernel `5.6.19-m4-kbdled`, WiFi firmware Rev 8.9.0.0.83
(PHY Rev 8.2.0.0.243), associated to the home access point with power save **on**. The machine was idle:
the game had exited and the only traffic, ssh, went over USB ethernet. **Not reproduced**; the trigger is
unknown.

**Seen again on 2026-10-01/02**, same kernel and firmware, same shape: idle on the desktop from ~21:40
(idle-dim's last entries are 21:40 dim and 23:55 wake), ssh timing out in the banner exchange on both
interfaces while USB ethernet answered ping in 0.7 ms, the desktop dead. The power button's shutdown stopped
on a black console with a cursor, and the machine was held off. The journal again kept only the storm (2,318
traces from 00:18 to 00:20, the last three boots in `--list-boots`), plus one thing the first time did not
show: `watchdog: BUG: soft lockup - CPU#1 stuck for 22s! [kworker/1:1]` and an RCU self-detected stall, with
CPU 0 in `console_unlock`, i.e. printing the traces. The trigger is lost again; mitigation 1 below is what
would have kept it. The hard power-off cost nothing: F2FS replayed one journal file's fsync data (`err = 0`)
and the root fsck passed.

The symptoms, in the order they were noticed:

- ssh on both interfaces (USB ethernet and WiFi) times out **during the banner exchange**, yet both
  addresses answer ping in under 2 ms. The kernel is alive; userspace is not being scheduled.
- The desktop is mostly unresponsive: the mouse does nothing. The power button still brings up MATE's
  shutdown dialog, and the keyboard backlight still reacts to keys (the idle-dim service is alive).

What the journal showed afterwards (`sudo journalctl -b -1`; the journal is readable only with sudo):
`mac80211` in a hardware-restart loop. `ieee80211_restart_work` → `ieee80211_reconfig` →
`cfg80211_shutdown_all_interfaces` → the station teardown on disassociation, and every step failing
mac80211's own check:

    WARNING: CPU: 1 PID: 4122 at net/mac80211/driver-ops.h:17 drv_sta_state+0x290/0x62c
    wlan0:  Failed check-sdata-in-driver check, flags: 0x4
    Workqueue: events_freezable ieee80211_restart_work

**2,048 full stack traces in the last two minutes of the boot**, ~17 a second. That load is the likely
reason userspace starved; not proven.

**Why it happened is not known.** A hardware restart is what `wlcore` asks mac80211 for after a firmware
failure. The first error (the firmware fault or watchdog that started it) is not in the journal, because
the storm wrote over it (next paragraph). What is known of this chip in general, and *not* evidenced here:
`wl18xx` firmware faults are usually a firmware watchdog, an SDIO bus error, or a power-save transition,
and the restart path on 5.x kernels mishandles an interface that is still associated, which is this
warning. Also noted, relevance unknown: every boot logs `Direct firmware load for
ti-connectivity/wl18xx-conf.bin failed with error -2`, so the driver runs on its built-in default
configuration.

**The storm erased the evidence, and every earlier boot with it.** The Pyra image ships
`/usr/lib/systemd/journald.conf.d/Pyra-maxuse.conf` with `SystemMaxUse=50M`. At ~17 traces a second
journald rotated a fresh 6.5 MB file every ~10 s and vacuumed the oldest to stay under 50 MB, so the
journal kept only the storm's last two minutes and `--list-boots` lost all history. There is no text
log to fall back on either: the image forwards to syslog (`syslog.conf`, `ForwardToSyslog=yes`) but no
syslog daemon is installed.

### Recovery

- **The power button's shutdown dialog works.** Its countdown ends in a normal, clean shutdown, even
  though the dialog cannot be clicked (the mouse is dead) and could not be brought into focus from the
  Pyra's keyboard. Let it run out. This is how the machine was recovered; it booted normally afterwards (the card was not fsck'd).
- If ssh answers (it did not here), take the radio down, which ends the restart loop:
  `sudo nmcli radio wifi off`, or `sudo modprobe -r wl18xx wlcore_sdio wlcore`.
- If the dialog's shutdown stalls on a black console (2026-10-02), holding the power button is what is left.
- Do not hold the power button while the card might be writing (the journal was writing 6.5 MB files
  every ~10 s). The tested card backup is the fallback (`card-backup-restore.md`).

### Mitigation

Each changes the system image, so each is the owner's call. Only 1 is applied (2026-10-02).

1. **Keep the evidence: give the journal room. Installed 2026-10-02** as
   `device/etc/systemd/journald.conf.d/Pyra-maxuse.conf` (`SystemMaxUse=1G`, `SystemMaxFileSize=64M`);
   journald reports `max 1G`. It must have **the image's file name**: a file in `/etc` replaces the one of
   the same name in `/usr/lib`, while drop-ins of different names apply in name order across both
   directories, so a `90-...conf` sorts before `Pyra-maxuse.conf` (`9` < `P`) and loses to its 50M (tried).
   The root filesystem has ~109 GB free. With 1 GB the same storm would have left ~2 hours of it and the
   boots before it, not 2 minutes. Journald does not rate-limit kernel messages (its `RateLimit*`
   settings apply per service), so size is the lever.
2. **Take WiFi out of long sessions.** When USB ethernet is connected, `sudo nmcli radio wifi off` for the
   session and `on` afterwards. It removes the driver from the picture entirely. It also removes the
   second way in that the start of this document recommends for remote reboots, so turn it back on before
   rebooting remotely.
3. **Turn WiFi power save off** (hypothesis: power-save transitions are one of this chip's known firmware
   fault triggers; nothing here shows it was the trigger). Per connection:
   `sudo nmcli connection modify <name> 802-11-wireless.powersave 2`, then reconnect. Costs some idle
   power, not measured.
4. **If it recurs with the journal kept:** the first `wlcore` error before the first `cut here` is the
   trigger. Look for `wlcore: ERROR`, `firmware watchdog`, `Hardware recovery in progress`, or SDIO
   (`mmc`) errors.

## Fixed: the machine would not sleep, and trying froze the desktop

**Fixed by `patches/0003` and confirmed on hardware on 2026-09-11.** Everything
below describes the stock kernel, and is kept because it is what you will see
if you are still on one. The confirmation is at the end of the section.

**Symptom.** Idle suspend never happens. Some time later the screen comes back
to a bare background with a working mouse pointer and no desktop and no login
prompt. The pointer moves, nothing else responds. SSH still works.

**What is actually happening.** The suspend started and never finished, and the
desktop is frozen because of it. `systemd-sleep` freezes `user.slice` before it
writes to `/sys/power/state`, and thaws it afterwards. There is no afterwards.
The X server lives in `system.slice` so it keeps running and keeps drawing the
hardware cursor, which is why the pointer still moves over a dead desktop.

**Where it stops.** In the kernel's MMC suspend hook, waiting forever. Taken
with `echo w > /proc/sysrq-trigger` on a live machine stuck this way:

    systemd-sleep   D
      state_store            <- writing "mem" to /sys/power/state
      pm_suspend
      __pm_notifier_call_chain
      mmc_pm_notify          <- the MMC subsystem's suspend hook
      __cancel_work_timer
      __flush_work
      wait_for_completion    <- never returns

`mmc_pm_notify()` cancels each host's card-detect work and waits for it to
finish. On this machine two of those never finish, so suspend cannot even get
as far as freezing tasks. `dmesg` shows it stopping exactly there, with no
`Freezing user space processes` line after it:

    PM: suspend entry (deep)
    Filesystems sync: 0.104 seconds

**Why those two never finish.** They are not real card slots. See the SD mux
section below. Two phantom MMC hosts get registered with no controller behind
them, their rescans block forever in `sdio_reset`, and every suspend attempt
then waits on those rescans.

**Recovering a session that is already frozen**, without rebooting:

    sudo systemctl thaw user.slice

The desktop comes straight back. The stuck `systemd-sleep` cannot be killed —
it is blocked in an uninterruptible kernel wait — so suspend stays broken until
the next boot, and NetworkManager stays in its ASLEEP state with WiFi
unmanaged. Put WiFi back with:

    sudo nmcli device set wlan0 managed yes

**Stopping it happening again, on a kernel without the fix.** Refuse the
operation outright rather than relying on desktop settings:

    sudo systemctl mask sleep.target suspend.target hybrid-sleep.target \
                        suspend-then-hibernate.target hibernate.target

With those masked, an idle timeout fails immediately instead of freezing the
session, because `systemd-suspend.service` never starts and so nothing ever
freezes `user.slice`. Undo with `systemctl unmask`.

### Confirmed working on `5.6.19-fix`

The five sleep targets are unmasked on this build. Both kinds of sleep were
tested with the real-time clock armed to wake the machine by itself, so nothing
depended on a wake key working:

    echo +30 | sudo tee /sys/class/rtc/rtc0/wakealarm
    echo mem | sudo tee /sys/power/state

Suspend-to-idle first, then suspend to RAM. Both returned 0 and both came back.
The kernel now gets past the point it used to stop at, and finishes:

    PM: suspend entry (deep)
    Freezing user space processes ... (elapsed 0.010 seconds) done.
    printk: Suspending console(s)
    Restarting tasks ... done.
    PM: suspend exit

The `Freezing user space processes` line is the one that never used to appear.
Afterwards the session is running rather than frozen, which is the failure this
whole section is about:

    $ systemctl show user.slice -p FreezerState
    FreezerState=running

The desktop, the display manager and both network interfaces all survived, and
nothing was left in `D` state. NetworkManager came back connected on WiFi and
ethernet rather than stuck in its ASLEEP state, so the `nmcli device set wlan0
managed yes` recovery above is no longer needed either.

### Two suspends in a row: `Wakeup pending. Abort CPU freeze`

If you test suspend twice back to back, the second attempt fails immediately
and the write to `/sys/power/state` returns an error:

    PM: suspend entry (deep)
    Freezing user space processes ... done.
    Wakeup pending. Abort CPU freeze

This is correct kernel behaviour and not a fault. The wake that ended the
first round is still outstanding, and the kernel will not suspend into an
unhandled wakeup event, because doing so is how a machine sleeps through the
very key press that was meant to wake it.

The way out is the `wakeup_count` protocol. Reading the count and writing it
back is how userspace says it has seen every wakeup so far, and the write
fails while one is outstanding, so looping on it is the wait:

    count=$(cat /sys/power/wakeup_count)
    echo "$count" | sudo tee /sys/power/wakeup_count    # fails if one is pending
    echo mem | sudo tee /sys/power/state

`pyra-sleep-test.sh` does this between rounds. If it ever gives up there, a
wakeup source really is stuck on, and this says which:

    grep -v '	0	' /sys/kernel/debug/wakeup_sources

### Fixed: the interrupt storm that made every resume noisy

Waking up used to produce a burst of kernel messages. It was survivable and
everything worked afterwards, and it was never caused by the suspend fix; it
was simply not visible before, because suspend never got far enough to resume
from. Most of it is now gone.

| message | before | after | what it is |
| --- | --- | --- | --- |
| `dummy 0-0049: Failed to read IRQ status: -13` | 231 to 6500 | 0 | the PMIC's interrupt handler retrying over an i2c bus that has not resumed yet |
| `Unbalanced enable for IRQ 144` | 1 | 1 | IRQ 144 is `SGX ISR`, so this is the PowerVR graphics driver |
| `unbalanced disables for otg_path` | 1 | 1 (0 with `0044`) | a regulator reference count in the USB OTG path |
| `DSI error: VC(n) busy when trying to configure it!` | 4 | 4 | the display link is re-initialised with all four channels still marked busy |

**The first one is fixed by `patches/0004`.** The device at i2c address `0x49`
is a second address block of the Palmas PMIC at `0x48`. The chain is worth
writing down because none of the four links is obvious on its own.

The Palmas node is a wakeup source, so the i2c core registers its interrupt as
the device's wake interrupt. `suspend_device_irq()` deliberately leaves an
armed wakeup interrupt enabled and unmasked, which is how the PMIC gets to wake
the machine at all.

On the way back, `resume_device_irqs()` re-enables the line at the end of
`dpm_resume_noirq()`. Runtime power management for the i2c controller is not
restored until `pm_runtime_enable()` in `device_resume_early()`, one phase
later. In between, every transfer on that bus fails: `omap_i2c_xfer_common()`
calls `pm_runtime_get_sync()`, which returns `-EACCES` while runtime power
management is disabled. That is where the `-13` comes from, and it is not an
i2c error at all.

The interrupt is level triggered and its handler is threaded with
`IRQF_ONESHOT`. `regmap_irq_thread()` cannot read the status registers, so it
cannot acknowledge the interrupt, so it returns `IRQ_NONE`, so the oneshot
unmask hands back a line that is still asserted. Round it goes until the i2c
controller is resumed.

The measurement that settled it counts hardware deliveries rather than log
lines:

    awk '/ palmas$/{print $2+$3}' /proc/interrupts

One RTC alarm, a single nested interrupt, produced 233 deliveries of the parent
interrupt and 231 messages. With `patches/0004` the same wake delivers it
twice. The patch holds the interrupt off for the duration of the suspend and
re-enables it in the driver's resume callback, which runs after
`device_resume_early()` has put the bus back. Nothing is masked at the
wakeup generator in the meantime, so the chip can still wake the machine, and
the delivery that does the waking is latched pending and replayed.

How long the storm ran varied a great deal, because it lasts exactly as long as
the noirq resume phase does. A quiet machine gave 231 messages in 23
milliseconds; one with the USB ethernet adapter and more modules loaded gave
6500 over seven seconds.

**The SGX and DSI warnings are not fixed.** `Unbalanced enable for IRQ 144` comes from
`resume_irqs()` finding the SGX interrupt already enabled. The PowerVR driver
in `drivers/staging/pvr` requests that interrupt and never disables it, so
where the extra enable comes from was not determined. It is one line per
resume and has no visible effect.

**The `otg_path` warning is fixed by `patches/0044`**, a backport of mainline
`ac01df343e5a`. On every resume `dwc3_omap_complete()` sets the OTG port's ID to
floating, and the driver disabled the VBUS regulator, `otg_path`, without
having enabled it. 0044 skips the disable when the regulator is off. It is in
every kernel built from `patches/` after 2026-10-28; see `kernel-changes.md`.

The DSI one is worth a second look for a different reason. It comes from
`dsi_vc_initial_config()`, which reads `DSI_VC_CTRL`, finds `VC_BUSY` set, says
so, and configures the channel anyway. All four channels report busy on every
resume, so suspend leaves the display link in exactly the confused state that
the two unbounded drain loops behind `patches/0001` are there to survive. That
makes suspend and resume the most promising way found so far to provoke the
display hang deliberately, which roughly 2100 ordinary modesets never managed.
It has not provoked it yet: across the seven suspend cycles run on
`5.6.19-fix` so far, the `rx fifo will not drain` message that `patches/0001`
would print has not appeared once.

### Suspend to RAM is not as deep as its name suggests

Every suspend logs this, in both the stock and the patched kernel:

    Powerdomain (core_pwrdm) didn't enter target state 1
    Powerdomain (abe_pwrdm) didn't enter target state 1
    Powerdomain (dss_pwrdm) didn't enter target state 1
    Powerdomain (emu_pwrdm) didn't enter target state 0
    Powerdomain (l3init_pwrdm) didn't enter target state 1
    Could not enter target state in pm_suspend
    A possible cause could be an old bootloader - try u-boot >= v2012.07

preceded by seven clocks that refused to stop, five in `l4per_cm` and two in
`l3init_cm`. The machine does sleep and does resume, but the system-on-chip
never reaches the state it was asked for, so `mem` saves much less power than
it should. The bootloader hint is stale: this card runs U-Boot 2016.11, far
newer than the version it suggests. Identified, not chased, and it is a
battery-life question rather than a correctness one.

### There is no standby state on this machine, and there cannot be

Linux names three sleep states. `standby`, the shallow one that keeps the
system-on-chip powered and only stops the clocks, is not one of the two this
machine offers:

    $ cat /sys/power/state
    freeze mem

Writing `standby` there is refused, and nothing happens. That is not a missing
kernel option. Every OMAP board declares a single valid suspend state, in
`arch/arm/mach-omap2/pm.c`:

    static const struct platform_suspend_ops omap_pm_ops = {
            ...
            .valid  = suspend_valid_only_mem,
    };

`suspend_valid_only_mem()` returns true for `PM_SUSPEND_MEM` and nothing else,
and the platform's own `omap_pm_enter()` returns `-EINVAL` for any other state,
so the two refusals agree.

This is not new and it is not particular to this chip. `arch/arm/mach-omap1`
does the same thing, with the same helper and the same single case, so no OMAP
generation in this tree has ever offered standby. Nor is it an OMAP oddity:
twelve platforms in the whole of `arch/arm` implement the state, and TI is
among them only through `drivers/soc/ti/pm33xx.c`, which is the Sitara parts
rather than the OMAPs. The state is mostly a relic of the ACPI S1 that the
kernel's own documentation maps it to.

Offering `standby` would mean writing a second low-power sequence for the power
and reset controller, and there is little reason to want one: the sequence that
already exists does not reach the state it asks for, as the messages above say,
so a deliberately shallower one would be starting from behind.

### The shallow state the chip does have, and does not use here

Standby names a machine with its clocks stopped and its logic still powered.
The processor can do that, and mainline uses it, just not through
`/sys/power/state`. It is a cpuidle state, entered and left thousands of times
a second without anything being suspended. On this kernel there is only one,
and it is the shallowest possible:

    $ cat /sys/devices/system/cpu/cpuidle/current_driver
    omap5_idle
    $ cat /sys/devices/system/cpu/cpu0/cpuidle/state0/desc
    CPUx WFI, MPUSS ON

Mainline has a second one, `C2`, which puts both cores and the subsystem around
them into retention. This kernel comments it out in
`arch/arm/mach-omap2/cpuidle44xx.c`, and that is a change carried by the Pyra's
kernel tree, not by upstream: mainline 5.6 has it enabled, and so does mainline
today. Whether to turn it back on is `docs/improvements.md` item 12, along with
the reasons to be careful about it.

What you have instead are the two ends:

| State | What it is | What it costs |
| --- | --- | --- |
| `freeze` | Suspend to idle. Tasks are frozen, devices suspended, the cores park in their deepest idle state. Nothing in the power controller is touched. | Resumes instantly and from anything. Saves the least. |
| `mem` | Suspend to RAM, which on this board means the `deep` path. Non-boot CPUs go down, the power controller is asked for its low-power state and declines part of it. | About two seconds each way. Needs a wake source that survives it. |

`mem` has a second switch behind it. `/sys/power/mem_sleep` decides what `mem`
means, and if it is set to `s2idle` then writing `mem` quietly does the same
thing as writing `freeze`:

    $ cat /sys/power/mem_sleep
    s2idle [deep]

The bracketed one is what you will get. Nothing in the result of the write says
which happened, which is why `device/pyra-sleep-test.sh` reads the path back
out of the kernel log afterwards rather than assuming.

### Testing either of them

`device/pyra-sleep-test.sh` is the whole test. It arms the real-time clock
first, so nothing depends on a wake key working; it detaches, so running it
over SSH survives the connection dropping; and it checks that `user.slice`
thawed afterwards, which is the thing the old fault broke.

    sudo ./pyra-sleep-test.sh                    # freeze, then mem
    sudo ./pyra-sleep-test.sh --mode mem         # only suspend to RAM
    sudo ./pyra-sleep-test.sh --seconds 60       # stay down longer

A good run says which path the kernel took and that the session came back:

    returned 0 after 21s of wall clock
    user.slice FreezerState: running
    the kernel took the 'deep' path
    RESULT mem: ok, slept and resumed with the session intact

Do not use `/proc/uptime` to work out how long it was really asleep. That clock
counts the time spent suspended, so it advances by the full sleep either way.
The kernel log timestamps do not count it, which is why a thirty second deep
suspend shows about two seconds between `PM: suspend entry` and `PM: suspend
exit`. Those two seconds are the cost of going down and coming back, not the
time spent down.

### What it saves, which is not measured

Nobody has measured the difference between the two, or between either of them
and an idle machine. The messages above give good reason to expect `mem` to be
disappointing, since the parts of the chip that hold the most power refuse to
enter their target state.

The only instrument on board is the fuel gauge's coulomb counter, and it is
only usable on battery:

    cat /sys/class/power_supply/bq27421-0/charge_now    # in uAh
    cat /sys/class/power_supply/bq27421-0/current_now   # signed, uA

With the charger connected the battery reads `Charging` with a positive
current, and any before-and-after comparison measures the charger. Unplug it,
read `charge_now`, sleep for an hour with `--seconds 3600`, read it again, and
the difference over the elapsed hours is the average draw. An hour is the right
order: over thirty seconds the counter's own resolution swamps the answer.

## Fixed: the nubs stopped on the first suspend and stayed stopped

The pointer stopped responding to the nub and stayed dead until the machine was
rebooted. Seen on 2026-09-10 and 2026-09-11, both on days of repeated suspend
testing, which turned out to be the whole of it. This is not intermittent. Every
suspend kills both nubs, and they never come back by themselves.

**The chips are fine throughout.** Both nubs are AS5013 magnetic joysticks on
i2c bus 1, at `0x40` for the left and `0x41` for the right. Read them directly
while the nub is dead and they answer normally: the control register at `0x0f`
reads `0xf1`, which is the driver's expected mode with data waiting, and the
axis registers at `0x10` and `0x11` still track the stick. Nothing is reading
them.

**The driver polls, and suspend cancels the poll.** The device tree gives the
as5013 nodes no interrupt gpio, so probe takes its else branch, sets the
client's interrupt number to zero and sets up a delayed work item instead. From
then on a 25 ms poll is the only thing that ever reads the joystick. The suspend
callback cancels that work, correctly, because i2c is unusable while suspended.
The resume callback re-enables the interrupt and stops. It never schedules the
work again. Since the interrupt number is zero, re-enabling it does nothing at
all, which is why the resume path looks like it is doing something.

Only opening the input device reschedules the poll. That is why restarting the
input daemon appears to repair the hardware, and why rebooting does. Both end in
a fresh open.

**Fixed by `patches/0005`**, which schedules the work again on resume, guarded so
that a suspend before anything has opened the device does not start a poll the
driver would never have started. Confirmed on hardware on 2026-09-11 across
three suspend cycles, one to idle and two to RAM.

### How to see it

The i2c controller the nubs sit on carries almost nothing else, so its interrupt
count is a direct read-out of whether the poll is alive. Two nubs at 25 ms gives
about 450 interrupts a second.

    a=$(awk '/48072000.i2c/{print $2}' /proc/interrupts); sleep 2
    b=$(awk '/48072000.i2c/{print $2}' /proc/interrupts); echo $(( (b-a)/2 ))

On the unpatched kernel that reads about 450 before a suspend, exactly 0 after
the resume, and about 450 again after `sudo systemctl restart pyrainput`. On the
patched kernel it stays at about 450 throughout. Nobody has to touch the nub for
this measurement, which is its main virtue.

### The wrong turn, recorded because it was convincing

The first day of this was spent on the wrong interrupt. `/proc/interrupts` has
two promising lines:

    184:  29  0  4805d000.gpio  27  Edge  Left-Nub
    185:   0  0  4805d000.gpio  21  Edge  Right-Nub

Those are the nub *click* buttons, on gpio-keys, and they have nothing to do
with the analog axes. The joystick driver would have named its own line
`as5013`, and there is no such line, which is the fact that unravelled it. The
zero on the right nub means nobody clicks the right nub. A counter that moves
only when a human is touching the hardware invites exactly this kind of
mistake, and the earlier version of this section built a plausible theory about
unbalanced `disable_irq()` calls on top of it.

`CONFIG_GENERIC_IRQ_DEBUGFS` was turned on in the build to read that line's
enable depth. It is still on and still worth having, but it is not what settled
this.

## Fixed: the built-in keyboard stops dead, and nothing is logged

The keyboard stops responding completely, at the login prompt or in a session.
No error appears anywhere. The input daemon is running and healthy, the key
controller's interrupt is not disabled, and the chip answers on the bus.

**The chip is holding its interrupt line asserted with your keystrokes queued
behind it.** Read three registers on the TCA8418 at i2c `1-0034`:

    sudo i2cget -y -f 1 0x34 0x02      # interrupt status
    sudo i2cget -y -f 1 0x34 0x03      # queued key events

Stuck, those read `0x01` and a non-zero count. Ten events were queued in the
case that produced this section.

**Why it cannot recover by itself.** That pin is a level. The chip holds it
asserted for as long as anything is queued, and asserting it again when it is
already asserted produces no transition. The device tree describes it as
`IRQ_TYPE_EDGE_FALLING` and the driver takes its trigger type from there, so
the kernel only ever hears the moment the pin becomes asserted. Once the driver
finishes a pass with the chip still asserting, the pin never returns high and
no further interrupt can be delivered, ever. The count in `/proc/interrupts`
freezes:

    grep tca8418 /proc/interrupts

Nothing is logged because the handler is never entered. That silence is what
makes this hard to recognise; a level-triggered line in the same state would
storm instead, which is what the PMIC did.

**The race.** The handler drains the FIFO until it reads an empty slot, and
only then writes the register that acknowledges. A key pressed between those
two i2c transfers leaves a fresh event queued and the status set again. On this
machine the window is wide, because both nubs are polled on the same bus every
25 ms and keypad transfers queue behind them.

**Rebinding the driver does not help.** The chip keeps its FIFO and its status
across an unbind, and nothing in the driver's startup path clears them, so it
reattaches to a chip that is already asserting and is dead from that moment.
Confirmed: after an unbind and rebind the two registers still read `0x01` and
ten events.

**Fixed by `patches/0006`**, which services the chip in a loop until it reports
nothing pending, so an event arriving mid-drain is handled in the same
invocation instead of waiting for an edge that cannot come, and which does the
same once at the end of probe so the driver always starts from a released pin.

### Getting the keyboard back without that kernel

You need another way in, because the keyboard is the broken thing: ssh, or the
touchscreen with an on-screen keyboard.

    sudo pyra-keypad-rescue

It reads the queued events out and clears the status, which releases the pin.
The queued keystrokes are discarded. It changes nothing if the chip is not
stuck. To confirm, press keys while watching the count:

    grep tca8418 /proc/interrupts

By hand, if the script is not installed, it is a read of register `0x04` per
queued event followed by `sudo i2cset -y -f 1 0x34 0x02 0xff`.

## Fixed: two of the six SD hosts were phantoms, and they were what broke suspend

`mmc1` and `mmc2` have no hardware behind them. Everything real works: the
full-size card slot, the eMMC and the WiFi radio each have their own host, and
a second card slot shares the eMMC's controller through a hardware mux switched
by hand:

    cat /sys/devices/platform/txs02612/switch     # eMMC or uSD

The phantoms come from a stub node kept deliberately at the root of the device
tree, with the comment *"keep this as long as the txs02612 driver does not
exist/work as mmc slave driver"*. The driver finds no controller for it and
says so plainly at boot:

    txs02612 txs02612: failed to get mmc phandle in /txs02612 node
    txs02612 txs02612: could not get access to host port, using manual mode

and then registers two card hosts anyway, because of a forced condition left in
`drivers/mmc/host/txs02612.c`:

    if (1 || !IS_ERR_OR_NULL(data->host)) {

The `1 ||` makes the test meaningless. Two hosts appear, the MMC core tries to
reset a card on each, and those requests never complete. The workers sit in
uninterruptible sleep from early boot onwards. On the stock kernel nothing says
so; the lockup-detector kernel reports them within 30 seconds of boot.

This costs no CPU. Blocked is not spinning. What it costs is suspend, above.

**The fix is one deletion**: drop the `1 || ` so the driver refuses to register
hosts it cannot serve. It is `patches/0003`, and `CONFIG_MMC_TXS02612=y` in
every kernel here, so there is no module to blacklist and it needs a rebuild.

**Confirmed on `5.6.19-fix`, 2026-09-11.** The driver still probes, still fails
to find its controller, and still says so, but now it stops there instead of
registering hosts anyway:

    txs02612 txs02612: probe
    txs02612 txs02612: failed to get mmc phandle in /txs02612 node
    txs02612 txs02612: could not get access to host port, using manual mode
    txs02612 txs02612: probed

Six MMC hosts became four, and all four are real controllers at distinct
addresses. Nothing was lost with the phantoms: the eMMC and the card the system
booted from are both present, WiFi is up, and the manual mux control still
reads and writes:

    $ cat /sys/devices/platform/txs02612/switch
    eMMC

No task is left in `D` state, which also settles the load average above.

## No sound: the desktop offers only a "Dummy Output"

PulseAudio could not open the card, fell back to `auto_null`, and will not
retry for the rest of the session. The usual cause is a script that does not
match the booted kernel: AESS kernels (`-m4`, `-m4-kbdled`) need
`pyra-aess.pa`, and every other kernel needs the packaged `pyra.pa`. Since
2026-10-28, `pyra-audio-select.service` chooses at each boot. Check:

    pyra-audio-select.sh --check                  # "ok", or which MISMATCH
    systemctl status pyra-audio-select.service    # what the boot step chose

Recovery, once `--check` says `ok`: `systemctl --user restart pulseaudio.service`.
If the service is not installed, run `device/pyra-install-helpers.sh`. Every
other cause (routes off, the greeter holding the card) is in `audio.md`,
*Diagnosing silence*.

## The screen never dims, and MATE's setting for it does nothing

**It dims the keyboard instead.** `mate-power-backlight-helper` searches
`/sys/class/backlight` for a device whose name it recognises — it knows about
`intel_backlight`, `nv_backlight`, `nvidia_backlight` and `gmux_backlight` —
finds none of them here, and falls back to whatever the directory hands it
first. This machine has two entries, `backlight` and `keyboard-backlight`, and
the helper picks the keyboard. Every request to dim the screen adjusts the
keyboard lamp and the panel never changes.

You can watch it happen. Ask the helper what it is looking at:

    $ sudo mate-power-backlight-helper --get-brightness
    2
    $ sudo mate-power-backlight-helper --get-max-brightness
    8
    $ cat /sys/class/backlight/backlight/actual_brightness        # the screen
    13
    $ cat /sys/class/backlight/keyboard-backlight/actual_brightness
    2

That is almost certainly why the image ships `backlight-enable=false` in
`/usr/share/glib-2.0/schemas/99_pyra.gschema.override`. The feature was aimed
at the wrong device, so it was turned off. Turning it back on does not help,
and does make the keyboard light flicker at you.

**Nothing is wrong with the hardware or the permissions.** The panel backlight
takes fifteen steps and responds instantly, and a session can drive it without
root through logind:

    busctl call org.freedesktop.login1 /org/freedesktop/login1/session/auto \
        org.freedesktop.login1.Session SetBrightness ssu backlight backlight 6

**The fix is `pyra-idle-dim`**, which names the device instead of guessing and
goes through logind, so it needs no privileges. It ships in the
`pyra-backlight` package, in its own repository, which enables it as a user
service for everyone:

    ./build-deb.sh                                   # on the PC, in ~/git/pyra-backlight
    sudo apt install ./pyra-backlight_0.1_all.deb    # on the Pyra
    systemctl --user start pyra-idle-dim.service     # or log out and in

It listens for the session manager's idle signal, so **the delay is whatever
`org.mate.session idle-delay` says** and nothing in the service duplicates that
setting. The stock value is 30 minutes:

    gsettings set org.mate.session idle-delay 5

`PYRA_DIM_PERCENT` in the unit file sets how far down it goes, 20 percent of
maximum by default. Leave `backlight-enable` false; this replaces it rather
than working alongside it.

To check it without waiting for a real idle timeout, drive the session state by
hand and watch the brightness follow:

    gdbus call --session --dest org.gnome.SessionManager \
        --object-path /org/gnome/SessionManager/Presence \
        --method org.gnome.SessionManager.Presence.SetStatus 3   # idle
    gdbus call --session --dest org.gnome.SessionManager \
        --object-path /org/gnome/SessionManager/Presence \
        --method org.gnome.SessionManager.Presence.SetStatus 0   # awake

## The card will not mount: `Failed to get valid F2FS checkpoint`

Seen 2026-09-10. The symptom, from the Pyra's own boot:

    F2FS-fs (mmcblk3p2): invalid crc_offset: 295978
    F2FS-fs (mmcblk3p2): invalid crc_offset: 0
    F2FS-fs (mmcblk3p2): Failed to get valid F2FS checkpoint
    mount: mounting /dev/mmcblk3p2 on /root failed: Structure needs cleaning
    Failed to mount /dev/mmcblk3p2 as root file system.

The initramfs then drops to a BusyBox shell, which is statically linked and
works fine, so the machine is not dead and the card can be examined in place.

### It is the card reader, and it happened weeks ago

`295978` is not a plausible offset inside a 4 KB block. Reading the raw block
tells you why: it starts `55534243`, which is ASCII `USBC`, the USB Bulk-Only
Transport command wrapper signature, followed by a transfer tag. That is a USB
bridge chip's own protocol structure sitting where filesystem metadata belongs.

`pyra-verify-card-metadata.sh` counts them. On this card there were 85, spread
across the checkpoint packs, the segment table and the node address table, with
tags running in one unbroken sequence. One sustained write, through a bad USB
reader, into the metadata area of the grown filesystem. `grow-rootfs.md` has the
prevention, which is to do that write through a real SD host controller and to
run the check afterwards.

**The corruption is on the card, not in the reading.** Confirmed by reading the
same four blocks through three independent paths, which agreed byte for byte:
the Pyra's own MMC controller, the USB reader on two different ports, and a
laptop's built-in SDHCI slot.

### What can be recovered, and what cannot

**The checkpoint can be.** f2fs writes each checkpoint block twice, once at the
start of its pack and an identical copy at the last block of the pack. Where the
leading block is corrupt the trailing copy is usually intact, and copying it
back over the leading one restores a valid checkpoint:

    # blocks 519 and 1031 are the trailing copies of the packs at 512 and 1024
    sudo dd if=/dev/sdX2 of=/tmp/cp.bin bs=4096 skip=1031 count=1 iflag=direct
    sudo dd if=/tmp/cp.bin of=/dev/sdX2 bs=4096 seek=1024 count=1 \
            conv=fsync,notrunc oflag=direct

Verify a candidate before writing it: a real checkpoint block has the value 4092
at byte offset 164, and a CRC32 at that offset, seeded with `0xF2F52010` and
computed over the preceding 4092 bytes, that matches what is stored there.

**The node address table mostly cannot.** It has two copies too, selected by the
checkpoint's `nat_bitmap`, with a block at address A pairing with A plus or
minus half the NAT span. But a block whose partner was never written holds
zeros, which is no use. Of 59 corrupt NAT blocks here, 25 had an intact partner
and 34 had an empty one. Each block maps about 455 inodes, so even a perfect
reconstruction left roughly 15,000 of 148,754 inodes unmapped, and those files
come back without names or not at all.

**`fsck.f2fs -f -y` is not the answer on its own.** With the checkpoint restored
it runs to completion, 31 minutes on this card, and fixes the segment table. It
cannot invent the missing node table entries, so the root inode stays
unreachable and the mount then fails with `Failed to read root inode` instead.

### What to do

Reflash. The image, the twelve fixes, the grow and the verification are all
scripted in this repository, so a rebuild is bounded work with a known outcome,
while this recovery is not. Image the card first if anything on it matters, and
do the rewrite through an SD host controller rather than the reader that caused
it.

### A trap worth knowing

If the card was in a USB reader that cannot write reliably, writes will appear
to succeed and silently not land. Always read the block back and compare after
writing. On this card, a checkpoint block written through the USB reader read
back unchanged three times running, and the identical write through a laptop's
SD slot landed first time.
