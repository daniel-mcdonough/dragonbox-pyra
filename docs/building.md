# Building the display stack from source

Written 2026-09-10, against the trixie card and a Linux PC. Both builds below
were run end to end and both succeed.

This document exists because of one question: the display driver wedges inside
a modeset, `troubleshooting.md` mitigates it rather than fixing it, and fixing
it means compiling something. What to compile, and where, is answered here.

---

## First: you probably do not need to compile anything yet

The hang has never been located, only observed. Compiling before it is located
means guessing at which of two components to patch, and one of them takes ten
seconds to rebuild while the other takes a reboot to test.

**The X log's last line before a hang is one function call away from the kernel.**
In the driver source, `src/drmmode_display.c:404`:

    INFO_MSG("preparing to set mode: %d %d %d %d %d\n", ...);

    err = drmModeSetCrtc(drmmode->fd, drmmode_crtc->crtc_id, ...);

That is a single ioctl. There is no loop between the message and the call, and
nothing else runs in between. So when the log stops after that line and `Xorg`
spins at 99% in state `R` and will not take `SIGKILL`, **it is spinning inside
`DRM_IOCTL_MODE_SETCRTC` in the kernel**, in `omapdrm` or `omapdss`. The
userspace driver is a bystander. Rebuilding it cannot fix this.

**`/proc/PID/stack` cannot supply it, despite `CONFIG_STACKTRACE=y`.** ARM's
`__save_stack_trace` in `arch/arm/kernel/stacktrace.c` returns immediately for
any task other than the caller when `CONFIG_SMP` is set, with a comment saying
it cannot guarantee the task is not running on the other CPU. This kernel is
SMP, so that file is always empty here. Tested on the running unit, on a
healthy X server, before relying on it.

**sysrq does supply it.** `echo l > /proc/sysrq-trigger` sends an NMI to every
CPU and dumps the symbolised backtrace of whatever is running on each, which is
precisely the spinning thread. Confirmed working on this unit, cross-CPU:

    echo 1 | sudo tee /proc/sys/kernel/sysrq     # debugging-dumps bit is off by default
    echo l | sudo tee /proc/sysrq-trigger
    sudo dmesg | tail -60

The machine stays reachable over SSH during a hang, because only X is stuck, so
this can be run while it is happening. `pyra-modeset-hang-trap.sh` automates
all of it: it provokes the hang, notices within about three seconds, takes five
sysrq samples a second apart, and reboots.

### Reproducing it on purpose

`pyra-modeset-hang-trap.sh` runs on the Pyra and does the whole cycle. It arms
sysrq, starts a watchdog, runs `x11perf` in rounds, and fires when `Xorg` is
burning a whole core with `OMAP DISPC` interrupts stopped — confirmed by asking
the X server a question and getting no answer, so a merely busy server is not
mistaken for a wedged one. Then it captures and reboots, which is both the
recovery and the thermal protection.

    sudo ./device/pyra-modeset-hang-trap.sh --selftest    # prove the capture, hang nothing
    sudo ./device/pyra-modeset-hang-trap.sh               # provoke it for real

Run the self-test first. It is what caught the `/proc/PID/stack` problem above,
on a healthy machine, rather than during the one chance to collect the evidence.

Two measurements from 2026-09-10 worth knowing before running it:

- **The DPMS mitigation does not close this path.** With
  `30-pyra-no-dpms.conf` in place and `xset q` reporting DPMS disabled, one
  seven-test `x11perf` run still provoked **36 modesets**. `x11perf` toggles
  DPMS itself, and the server's zeroed blanking timers do not stop it.
- **The hang is a race, and a rare one now.** About 500 modesets were forced on
  2026-09-10, with compositing both off and on, without a single wedge. The two
  hangs on record happened inside runs of about fourteen. The `DSI VC busy`
  error reproduces constantly, 288 times across those runs, so the race is
  being hit and the wedge is a rare branch of it. Something about the state of
  the machine on the day of the two hangs has not been identified yet.

**The stock kernel has no lockup detector.** `CONFIG_SOFTLOCKUP_DETECTOR` and
`CONFIG_DETECT_HUNG_TASK` are both unset, which is why a core spinning for
minutes produces no kernel message at all. Turning them on is a config change,
not a patch, and it makes the kernel print the offending stack by itself after
20 seconds. That is the cheapest first build to make.

---

## Which container, and why not an armhf one

An emulated armhf container works and is the obvious answer, but it is the
wrong one for the kernel. `qemu-user` costs roughly an order of magnitude, and
a 5.6 kernel with this config is around 5,000 objects.

**Cross-compile instead.** A Debian **amd64** container with
`crossbuild-essential-armhf` runs the compiler natively on the PC and emits
armhf, with no emulation anywhere. The full kernel takes about five minutes on
sixteen cores. The same tree built natively on the Pyra's two Cortex-A15s would
take hours, and building it in an emulated container would take longer still.

Which suite matters, and the two builds do not want the same one:

| Build | Container | Why |
| --- | --- | --- |
| the X driver | `debian:trixie` | must match the X server ABI on the card |
| the kernel | `debian:bookworm` | 5.6 does not build with gcc 14. Bookworm's gcc 12 is what upstream used |

The kernel source package agrees: its `Maintainer:` field reads
`pyra <pyra@nspawn-bookworm-armhf>`, so upstream builds it in a bookworm
container too.

`pyra-crossbuild.sh` does all of this. It needs `docker` on the PC and nothing
else — no toolchain installed on the host, no `binfmt` registration, no qemu,
and nothing whatsoever installed on the Pyra.

---

## Where the source is

Both source packages are in the Pyra repository, and both were verified against
its `Sources` index over HTTPS:

| Package | Version | Upstream |
| --- | --- | --- |
| `xserver-xorg-video-armsoc-omap5` | 0.6 | `github.com/julbouln/xf86-video-armsoc-omap5` |
| `linux-5.6.19-pyradef` | 5.6.19-pyradef-10 | letux/Pyra tree, 195 MB orig tarball |

`pyra-crossbuild.sh` pins the SHA-256 of each `.dsc` and lets `dpkg-source`
verify the tarballs against it when it unpacks, so the whole chain is checked
from one pinned hash.

There is no `deb-src` line for the Pyra repository in the image, so
`apt-get source` does not work as shipped. The script fetches the `.dsc` and
its tarballs directly instead.

---

## The X display driver

    ./pc/pyra-crossbuild.sh ddx

About two minutes, most of it `apt`. Output is
`xserver-xorg-video-armsoc-omap5_0.6_armhf.deb` plus a `-dbgsym` package, in
`~/git/dragonbox-pyra-build/ddx/`.

It is a genuine compile from the nine `.c` files under `src/`, not a repack of
a prebuilt object. The resulting `omap5_drv.so` is the same size as the
installed one and differs only in bytes, which is what a newer compiler on the
same source should produce.

This is the driver to rebuild for anything **above** the ioctl: the EXA
fallback counting in `improvements.md` item 4, extra instrumentation around the
modeset, or a timeout wrapper. It is not the driver to rebuild for the hang
itself.

**Nothing here patches it, and the machine does not run this build.** The
installed driver is the distribution package from the Pyra repository, and it
is meant to stay that way; this target exists so that future work has a way in.
The fix this project made for the display driver is a configuration change,
fix 4, which disables the GLX extension. If you are trying to reproduce the
machine rather than experiment on it, skip this section entirely.
Checked on 2026-09-11: `omap5_drv.so` on the device is the 2023 file from
`xserver-xorg-video-armsoc-omap5 0.6`, not the one built here.

Install and roll back, with the X server stopped:

    sudo systemctl stop lightdm
    sudo dpkg -i xserver-xorg-video-armsoc-omap5_0.6_armhf.deb
    sudo systemctl start lightdm

    # back to stock
    sudo tar xzf /pyra-stock-backup/xorg-drivers.tar.gz -C /

---

## The kernel

    ./pc/pyra-crossbuild.sh kernel               # zImage, modules, dtbs
    ./pc/pyra-crossbuild.sh kernel bindeb-pkg    # the same, as .debs

About five minutes for a full build on sixteen cores, and seconds for an
incremental one after an edit. The tree is unpacked once into
`~/git/dragonbox-pyra-build/kernel/src/` and built in place afterwards.

Three things about this tree are worth knowing before editing it:

- **`omapdrm`, `omapdss` and the panel driver are built in, not modules.**
  `CONFIG_DRM_OMAP=y`, and `modules.builtin` lists `omapdrm.ko`, `omapdss.ko`
  and `panel-boe-w677l.ko`. So a fix in the modeset path means a whole kernel
  and a reboot to test it. There is no module to swap.
- **The SGX kernel module is in tree.** `pvrsrvkm_omap5_sgx544_116` lives at
  `drivers/gpu/drm/pvrsgx/1.14.3699939/` in this source and rebuilds with
  everything else, so a kernel rebuild does not break the GLES2 path.
- **The shipped `.config` is the one that built the running kernel**, and
  `arch/arm/configs/pyra_defconfig` is beside it. `CONFIG_OMAP2_DSS_DEBUG` and
  `CONFIG_OMAP2_DSS_DEBUGFS` are both off, and turning them on is the other
  obvious instrumentation build.

The build needs `libyaml-dev` and the `openssl` binary in the container beyond
what the source package's `Build-Depends` lists. The script installs both.
Without them the build stops at `scripts/dtc/yamltree.c` and at
`certs/signing_key.pem` respectively.

### A kernel that reports lockups

    ./pc/pyra-crossbuild.sh kernel-debug

Built and staged 2026-09-10. This is the stock source and the stock config with
the lockup detectors turned on and **nothing else changed**, which is the whole
point: the fault it exists to catch is a timing race, so anything that perturbs
timing works against it.

| | |
| --- | --- |
| version | `5.6.19-softlockup` |
| kernel | `kernel/src/arch/arm/boot/zImage` |
| ready to install | `kernel/softlockup-kernel.tar.gz`, 23 MB |
| symbols | `kernel/src/vmlinux`, for resolving addresses out of a report |

The config delta against stock is exactly this and no more:

    CONFIG_DEBUG_KERNEL=y
    CONFIG_LOCKUP_DETECTOR=y
    CONFIG_SOFTLOCKUP_DETECTOR=y
    CONFIG_DETECT_HUNG_TASK=y
    CONFIG_DEFAULT_HUNG_TASK_TIMEOUT=30
    CONFIG_GENERIC_IRQ_DEBUGFS=y
    CONFIG_LOCALVERSION="-softlockup"

Both panic-on-lockup options are off, so it prints and carries on rather than
dying. Two detectors rather than one, because the two plausible shapes of this
fault need different ones: the softlockup detector catches a busy loop, and the
hung-task detector catches an uninterruptible sleep, which is what a missing
timeout in a `wait_for_*` would look like instead.

`GENERIC_IRQ_DEBUGFS` is the odd one out: it has nothing to do with lockups and
costs nothing at runtime. It fills in `/sys/kernel/debug/irq/irqs/<n>`, which
carries an interrupt's enable depth. Without it, an interrupt somebody disabled
and never re-enabled is indistinguishable from one that is armed and idle,
because `handle_edge_irq()` increments the counter in `/proc/interrupts` only
after it has checked whether the interrupt is disabled. The case that made this
worth turning on, a nub that stopped reporting, turned out not to need it: the
interrupt being watched belonged to a different device. The option stays
because it is free and the next question of this shape will be a real one.

One thing to know before editing that block: the whole config sequence is
inside a single-quoted string handed to the container, so a comment there
cannot contain an apostrophe.

`DEBUG_KERNEL` pulls several other debug options on by default, and the build
turns four of them back off: `DEBUG_PREEMPT`, `RCU_TRACE`, `SCHED_DEBUG` and
`DEBUG_MISC`. `DEBUG_PREEMPT` is the one that matters, since it adds work to
every `preempt_disable`. The build checks all of this and refuses to continue if
any of it fails to stick, rather than quietly producing a kernel that does not
do what it says.

**What it buys, and what it does not.** After 20 seconds of a spinning core
the kernel prints `BUG: soft lockup - CPU#N stuck for Ns!` with the symbolised
backtrace of the spinning thread, into `dmesg`, by itself. The stock kernel
cannot produce that at all, and the hung-task half of it earned its keep
immediately: it found the two SD workers that have been stuck since boot on
every boot this machine has ever done.

But it will not catch the display hang, and it is better to know that than to
wait for a report that is not coming. The soft lockup detector does not watch
for a busy CPU. Each core's watchdog timer queues a job on that core's stopper
thread, which is real-time priority; the job updates a timestamp, and a stale
timestamp is what declares the lockup. This kernel is `CONFIG_PREEMPT=y`, so a
kernel loop that does not hold off preemption is preempted by that stopper
thread like anything else and the timestamp never goes stale. The loops the
display hang is now pinned to hold a mutex and nothing more, so they are
preemptible and invisible to it.

For that fault the capture is `echo l` to sysrq while the machine is still
hung, which is what `pyra-modeset-hang-trap.sh` does and what
`troubleshooting.md` describes.

### Installing it

Nothing here touches the stock kernel. `/boot` has 195 MB free and this needs
about 27 MB of it.

    scp softlockup-kernel.tar.gz device/pyra-install-debug-kernel.sh pyra@<address>:
    sudo ./device/pyra-install-debug-kernel.sh

`pyra-install-debug-kernel.sh` does everything in this section: it refuses a
tarball that would destroy `/lib`, checks `/boot` has room, extracts, runs
`depmod` and `update-initramfs`, and writes the `user.cfg` entry below by
copying the stock `append` line verbatim rather than retyping it. It re-checks
that `/lib` is still a symlink immediately after extraction and stops before
the entry is written if it is not. Running it twice replaces the entry instead
of stacking a second one.

By hand, it is:

    sudo tar xzf softlockup-kernel.tar.gz -C / --keep-directory-symlink
    sudo depmod -a 5.6.19-softlockup
    sudo update-initramfs -c -k 5.6.19-softlockup

The initrd is not in the tarball and cannot be: it has to be built on the device
against the device's own userspace.

**`--keep-directory-symlink` is not optional.** trixie is usr-merged, so `/lib`
is a symlink to `usr/lib`, and GNU tar extracting an archive that contains a
`./lib/` directory entry deletes that symlink and puts a real directory there.
Every binary then loses its interpreter and nothing on the system can start,
including the shell needed to repair it. An earlier version of the tarball had
exactly that layout and did exactly that to the card on 2026-09-10; see
`progress.md`. The build now stages under `usr/lib` and refuses to produce a
tarball containing a `./lib/` entry, so the flag is belt as well as braces.

Then add this to `/boot/extlinux/user.cfg`, which exists and is empty. The
`append` line is copied verbatim from the stock `l0` entry in `linux.cfg`, with
only the three paths changed:

    label l1
        menu label trixie, kernel 5.6.19-softlockup (lockup detector)
        linux /vmlinuz-5.6.19-softlockup
        append root=PARTUUID=21a4c285-02 console=ttyO2,1500000n8 console=tty0 vram=12M omapfb.vram=0:8M,1:4M omapfb.rotate_type=0 omapdss.def_disp=lcd rootwait twl4030_charger.allow_usb=1 musb_hdrc.preserve_vbus=1 log_buf_len=8M ignore_loglevel earlyprintk drm_kms_helper.fbdev_rotation=8 drm.force_hw_rotation fastboot
        fdtdir /dtb/linux-image-5.6.19-softlockup
        initrd /initrd.img-5.6.19-softlockup

Do not edit `linux.cfg`; it is meant to be regenerated and would lose the entry.

### There is no boot menu on this machine

The entry above is correct and necessary, but you cannot pick it from a menu,
because the Pyra never shows one.

**U-Boot has no display driver.** The Pyra runs U-Boot 2016.11 out of the raw
area at the front of the eMMC, before partition 1. Search its image for
`vidconsole`, `panel`, `lcd` or `dss` and nothing comes back, while `sysboot`,
`pxelinux.cfg` and `Enter choice:` are all there. So the extlinux menu is
written to the serial console on `ttyO2` at 1500000 baud and never reaches the
LCD. There is no `usb_kbd` in it either, so even a visible menu could not be
answered from the built-in keyboard.

**And `timeout 30` is three seconds, not thirty.** extlinux timeouts are in
tenths of a second, and U-Boot's `pxe` code follows that convention.

The practical effect is that the machine appears to boot straight into the
stock kernel with no prompt of any kind, which is exactly what it does. To
check any of this yourself:

    sudo dd if=/dev/mmcblk0 bs=512 count=2048 2>/dev/null | strings -n 6 \
        | grep -iE "^U-Boot 20|vidconsole|panel|sysboot|Enter choice"

**So a test kernel has to be made the default**, and `pyra-boot-kernel.sh` is
what does it:

    sudo pyra-boot-kernel.sh status
    sudo pyra-boot-kernel.sh debug --once    # next boot only
    sudo pyra-boot-kernel.sh debug           # every boot
    sudo pyra-boot-kernel.sh stock           # back to the stock kernel

`--once` replaces the safety the menu was supposed to provide. It arms
`pyra-boot-revert.service`, a one-shot ordered before `sysinit.target` that
puts `default` back to `l0` early in the next boot. A test kernel that boots
gets exactly one boot; forgetting to change it back is not a way to end up
stranded on a debug kernel.

What `--once` cannot cover is a kernel that never reaches userspace, because
nothing running on the device can. Recover that by putting the card in a PC,
mounting partition 1, and changing one word in `extlinux.conf`. Editing that
file by hand is safe here: `extlinux-update` is not installed and there is no
`/etc/default/extlinux`, so nothing regenerates it.

To remove it later, delete the `user.cfg` entry, `/boot/*-5.6.19-softlockup`,
`/boot/dtb/linux-image-5.6.19-softlockup/` and
`/lib/modules/5.6.19-softlockup/`.

### Install it beside the stock kernel, not over it

The build produces `KERNELRELEASE=5.6.19-pyradef`, **the same string the
running kernel uses**, so installing it as is overwrites `/boot/vmlinuz` and
`/lib/modules/5.6.19-pyradef` and leaves no fallback on the card.

Give a test kernel its own name instead. Set `CONFIG_LOCALVERSION` in the tree
to match:

    PYRA_KERNELRELEASE=5.6.19-test ./pc/pyra-crossbuild.sh kernel bindeb-pkg

Then add a second `extlinux` entry. `/boot/extlinux/user.cfg` exists and is
empty, and is the file meant for hand-written entries — `linux.cfg` is
regenerated and will lose anything put in it. Copy the `append` line from
`linux.cfg`'s `l0` entry verbatim, changing only the kernel, initrd and dtb
paths.

**Then select it with `pyra-boot-kernel.sh`, not from the menu.** There is no
menu on this hardware; see above. Use `debug --once` so the machine returns
itself to the stock kernel on the following boot.

If a test kernel wedges the display before the menu is usable, the serial
console on `ttyO2` at 1500000 is already enabled on every boot entry.

---

## The patch set, and the kernel that carries it

Six changes live in `patches/` as ordinary unified diffs. They are applied
in order by `./pc/pyra-crossbuild.sh kernel-fix`, which builds exactly what
`kernel-debug` builds — same source, same compiler, same lockup detector —
and then puts the patches on top. It lands as `5.6.19-fix`, in its own source
tree, so the unpatched `5.6.19-softlockup` build stays reproducible.

    ./pc/pyra-crossbuild.sh kernel-fix

Built, staged, installed and confirmed on hardware 2026-09-11.

| | |
| --- | --- |
| version | `5.6.19-fix` |
| kernel | `kernel/src-fix/arch/arm/boot/zImage` |
| ready to install | `kernel/fix-kernel.tar.gz`, 23 MB |
| symbols | `kernel/src-fix/vmlinux`, for resolving addresses out of a report |

The build reports each patch as it goes, and the result carries all six:

      applied  0001-omapdrm-dsi-bound-the-rx-fifo-drain-loops.patch
      applied  0002-omapdrm-dispc-report-the-runtime-pm-errno.patch
      applied  0003-mmc-txs02612-refuse-phantom-hosts.patch
      applied  0004-mfd-palmas-hold-the-irq-across-suspend.patch
      applied  0005-input-as5013-restart-the-poll-on-resume.patch
      applied  0006-input-tca8418-service-until-the-chip-is-quiet.patch

Install it the same way as the lockup-detector kernel, with
`pyra-install-debug-kernel.sh`. It reads the release name out of the tarball,
so name the tarball you mean — with both of them sitting in `/home/pyra` it
refuses to guess:

    scp ~/git/dragonbox-pyra-build/kernel/fix-kernel.tar.gz pyra@<address>:
    sudo ./device/pyra-install-debug-kernel.sh fix-kernel.tar.gz
    sudo pyra-boot-kernel.sh debug --once

A rebuilt kernel keeps the same release name, so reinstalling one while
running it collides with the module tree you are using. That is refused by
default. While iterating on patches, which is the case where you want it
anyway, pass `--replace-running` and reboot straight afterwards.

There is one test slot in the boot configuration, `l1`, and installing points
it at the kernel you just installed. The older test kernel's files stay in
`/boot` but drop out of the configuration, so going back to it means running
the installer again with its tarball. The stock kernel is never touched and
stays the default.

The patch step is idempotent. A patch already present in the tree is reported
as `already` and skipped, one that will not apply stops the build rather than
producing a kernel that is missing a fix it claims to have.

### 1. Bound the two DSI receive-FIFO drain loops

`0001-omapdrm-dsi-bound-the-rx-fifo-drain-loops.patch`. This is the candidate
fix for the modeset hang, and the reasoning is in `troubleshooting.md`.

`dsi_vc_flush_receive_data()` and `dsi_vc_flush_long_data()` spin on a status
bit with no iteration limit and no timeout. They are the only unbounded
busy-waits left anywhere in the modeset path, they are reached from every DCS
write the panel driver makes while the display is being enabled, and a loop
there never reaches a signal check. The patch caps both at 256 reads and lets
the callers' existing `-EIO` paths unwind.

**How to know it worked.** You cannot prove a negative here, but you can watch
for the give-up message, which is new and appears only in the case that used
to hang:

    sudo dmesg | grep "rx fifo will not drain"

If that line ever appears, the diagnosis was right and the machine survived
something that previously needed a reboot.

### 2. Print the error the display controller is failing with

`0002-omapdrm-dispc-report-the-runtime-pm-errno.patch`. Evidence, not a fix.

`dispc_runtime_put()` fired twice in 1587 modesets, from the atomic commit
worker, and the assertion was bare, so the return value that would identify
the failure was thrown away. `-EBUSY` or `-EAGAIN` would mean the device
simply declined to idle, which is unremarkable; anything else would mean the
suspend callback itself failed.

Worth pairing with a look at what runtime PM thinks, across a modeset:

    watch -n0.5 cat /sys/devices/platform/44000000.ocp/*/*/58000000.dss/power/runtime_status

### 3. Stop the mux driver registering hosts it cannot reach

`0003-mmc-txs02612-refuse-phantom-hosts.patch`. This is the fix for suspend.

`drivers/mmc/host/txs02612.c` fails to find its controller, says so, and then
registers two card hosts regardless because of a forced condition someone left
in. Deleting `1 || ` is the whole change. The sysfs `switch` control that
selects between the eMMC and the second card slot is created earlier in the
same function, so it survives. `CONFIG_MMC_TXS02612=y`, so there is no module
to blacklist and this genuinely needs a rebuild.

**How to know it worked.** Boot it and look for the two hosts:

    ls /sys/class/mmc_host/          # expect mmc1 and mmc2 to be gone
    ps -eo stat,comm | grep '^D'     # expect no kworker stuck in D state

then unmask the sleep targets and try to suspend.

### 4. Stop the PMIC's interrupt storming on every resume

`0004-mfd-palmas-hold-the-irq-across-suspend.patch`. This is the fix for the
noise on resume.

The Palmas interrupt is left enabled across suspend because it is a wakeup
source, and `resume_device_irqs()` hands it back one phase before runtime power
management is restored on the i2c controller it has to talk to. Every register
read in that window returns `-EACCES`, so the handler cannot acknowledge a
level interrupt it cannot read, and the line re-fires until the bus comes back.
The patch gives the driver suspend and resume callbacks that hold the interrupt
off over exactly that window. `troubleshooting.md` has the full chain.

**How to know it worked.** Count deliveries rather than log lines, across one
suspend:

    awk '/ palmas$/{print $2+$3}' /proc/interrupts
    sudo pyra-sleep-test.sh --mode mem --seconds 20
    awk '/ palmas$/{print $2+$3}' /proc/interrupts

Expect a difference of about two, and no `Failed to read IRQ status` in
`dmesg`. Before the patch, the same wake gave 233 deliveries and 231 messages.

**What to check by hand.** The patch touches the interrupt that serves the
power button, so confirm once that pressing it still wakes the machine. The
real-time clock alarm, which is on the same chip and the same interrupt, does.

### 5. Bring the mouse nubs back after a suspend

`0005-input-as5013-restart-the-poll-on-resume.patch`. Without it the first
suspend of the session kills both nubs until something reopens the input
device.

The device tree wires no interrupt to the joystick chips, so the driver falls
back to a 25 ms poll, which is then the only thing that ever reads them. The
suspend callback cancels that poll because i2c is unusable while suspended. The
resume callback re-enables an interrupt that does not exist and never restarts
the poll. The patch schedules it again, guarded so that a suspend before
anything has opened the device does not start a poll the driver would never
have started.

**How to know it worked.** The nubs' i2c controller carries almost nothing
else, so its interrupt rate says whether the poll is running, and you do not
need to touch the nub to read it:

    a=$(awk '/48072000.i2c/{print $2}' /proc/interrupts); sleep 2
    b=$(awk '/48072000.i2c/{print $2}' /proc/interrupts); echo $(( (b-a)/2 ))

About 450 a second means the poll is alive. Read it before a suspend and after
the resume: both should say about 450. Before the patch the second reading is
exactly zero, and stays zero until `sudo systemctl restart pyrainput`.

### 6. Stop the built-in keyboard going silent

`0006-input-tca8418-service-until-the-chip-is-quiet.patch`. Without it the key
matrix controller can be left holding its interrupt line asserted with
keystrokes queued, after which no further interrupt is possible and the
keyboard is dead with nothing in the log.

The line is edge triggered in the device tree but the chip drives it as a
level, so the driver gets one chance per edge to empty it. A key pressed
between the last queue read and the acknowledgement wastes that chance. The
patch keeps servicing until the chip reports nothing pending, and does the same
once at the end of probe, because the chip keeps its queue across an unbind and
the old startup path never cleared it.

**How to know it worked.** Press keys and watch the count move:

    grep tca8418 /proc/interrupts

A count frozen while you type is the fault. `device/pyra-keypad-rescue` clears
it on a machine not yet running this kernel.

## Backups

Taken 2026-09-10, before anything was installed. Two copies, because a card
that will not boot cannot be fixed over SSH:

| Where | What |
| --- | --- |
| `/pyra-stock-backup/` on the card | `boot-5.6.19-pyradef.tar.gz`, `modules-5.6.19-pyradef.tar.gz`, `xorg-drivers.tar.gz`, the full `dpkg -l`, and SHA-256 of the stock kernel and driver |
| `~/git/dragonbox-pyra-build/stock-backup/` on the PC | the same files |

Each tarball restores from `/` with paths intact:

    sudo tar xzf /pyra-stock-backup/boot-5.6.19-pyradef.tar.gz -C /
    sudo tar xzf /pyra-stock-backup/modules-5.6.19-pyradef.tar.gz -C /
    sudo tar xzf /pyra-stock-backup/xorg-drivers.tar.gz -C /

From the PC, with the card mounted, the same tarballs extract to the mounted
rootfs — but note that `/boot` is a separate ext4 partition, so mount both.

The stock packages are also still downloadable from the Pyra repository, and
the eMMC bookworm install is untouched and remains the last resort.
