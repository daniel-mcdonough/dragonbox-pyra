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

    sudo ./pyra-modeset-hang-trap.sh --selftest    # prove the capture, hang nothing
    sudo ./pyra-modeset-hang-trap.sh               # provoke it for real

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

    ./pyra-crossbuild.sh ddx

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

Install and roll back, with the X server stopped:

    sudo systemctl stop lightdm
    sudo dpkg -i xserver-xorg-video-armsoc-omap5_0.6_armhf.deb
    sudo systemctl start lightdm

    # back to stock
    sudo tar xzf /pyra-stock-backup/xorg-drivers.tar.gz -C /

---

## The kernel

    ./pyra-crossbuild.sh kernel               # zImage, modules, dtbs
    ./pyra-crossbuild.sh kernel bindeb-pkg    # the same, as .debs

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

    ./pyra-crossbuild.sh kernel-debug

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
    CONFIG_LOCALVERSION="-softlockup"

Both panic-on-lockup options are off, so it prints and carries on rather than
dying. Two detectors rather than one, because the two plausible shapes of this
fault need different ones: the softlockup detector catches a busy loop, which is
the `R` at 99% that has been observed, and the hung-task detector catches an
uninterruptible sleep, which is what a missing timeout in a `wait_for_*` would
look like instead. One extra option costs nothing and saves a second
build-and-reboot cycle if the fault turns out to be the other shape.

`DEBUG_KERNEL` pulls several other debug options on by default, and the build
turns four of them back off: `DEBUG_PREEMPT`, `RCU_TRACE`, `SCHED_DEBUG` and
`DEBUG_MISC`. `DEBUG_PREEMPT` is the one that matters, since it adds work to
every `preempt_disable`. The build checks all of this and refuses to continue if
any of it fails to stick, rather than quietly producing a kernel that does not
do what it says.

**What it buys.** After 20 seconds of a spinning core the kernel prints
`BUG: soft lockup - CPU#N stuck for Ns!` followed by the symbolised backtrace of
the spinning thread, by itself, into `dmesg`. That is the evidence the whole
exercise needs, and the stock kernel cannot produce it.

### Installing it

Nothing here touches the stock kernel. `/boot` has 195 MB free and this needs
about 27 MB of it.

    scp softlockup-kernel.tar.gz pyra-install-debug-kernel.sh pyra@<address>:
    sudo ./pyra-install-debug-kernel.sh

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

**Do not touch `default l0`.** The stock kernel stays the default and the menu
waits 30 seconds, so the debug kernel is something you choose at each boot and a
bad one is a power cycle away from gone. Do not edit `linux.cfg` either; it is
regenerated and will lose the entry.

To remove it later, delete the `user.cfg` entry, `/boot/*-5.6.19-softlockup`,
`/boot/dtb/linux-image-5.6.19-softlockup/` and
`/lib/modules/5.6.19-softlockup/`.

### Install it beside the stock kernel, not over it

The build produces `KERNELRELEASE=5.6.19-pyradef`, **the same string the
running kernel uses**, so installing it as is overwrites `/boot/vmlinuz` and
`/lib/modules/5.6.19-pyradef` and leaves no fallback on the card.

Give a test kernel its own name instead. Set `CONFIG_LOCALVERSION` in the tree
to match:

    PYRA_KERNELRELEASE=5.6.19-test ./pyra-crossbuild.sh kernel bindeb-pkg

Then add a second `extlinux` entry. `/boot/extlinux/user.cfg` exists and is
empty, and is the file meant for hand-written entries — `linux.cfg` is
regenerated and will lose anything put in it. Copy the `append` line from
`linux.cfg`'s `l0` entry verbatim, changing only the kernel, initrd and dtb
paths.

**Leave `default l0` alone.** The stock kernel stays the default, the menu has
a 30 second timeout, and a test kernel that does not boot is then one power
cycle away from being gone rather than something to recover from. Selecting the
test entry is a deliberate act each boot.

If a test kernel wedges the display before the menu is usable, the serial
console on `ttyO2` at 1500000 is already enabled on every boot entry.

---

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
