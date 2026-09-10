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

Two things on the running unit will say where in the kernel, and neither needs
a compiler. Both need the hang to be happening, and the machine stays reachable
over SSH while it is, because only X is stuck:

    # the wedged thread's kernel stack, which is the answer
    sudo cat /proc/$(pidof Xorg)/stack

    # every CPU's backtrace, via sysrq. The bit for debugging dumps is not
    # set by default on this kernel, so enable it first
    echo 1 | sudo tee /proc/sys/kernel/sysrq
    echo l | sudo tee /proc/sysrq-trigger
    sudo dmesg | tail -60

`CONFIG_STACKTRACE` and `CONFIG_KALLSYMS` are both on in `5.6.19-pyradef`, so
the stack comes back symbolised. Capture it into
`~/Xorg-modeset-hang-$(date +%Y%m%d-%H%M).log` beside the other evidence
`troubleshooting.md` asks for.

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
