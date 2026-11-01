# Debian 13 (trixie) on the DragonBox Pyra

The Pyra project publishes a trixie image, but it does not work as shipped: X
crashes, the first-run wizard powers the unit off, the nubs are dead, and
there is no sound. This repository turns that image into a working SD card for
a V5.x Pyra, with a MATE desktop, hardware GLES2 on the SGX, desktop GL through
gl4es, sound, charging, and x86 software under box86.

It runs from an SD card. The eMMC is never touched, so your bookworm install
stays as it is and takes over again when you pull the card.

---

## What you need

- A V5.x Pyra.
- A full-size SDXC card, 16 GB or larger, Class 10 / U1 or better. A microSD in
  an adapter is fine. It goes in the **left** full-size slot.
- A Linux PC with a card reader, `7z`, and root. Unless the PC is itself armhf,
  it also needs qemu-user with binfmt (`qemu-user-static` and `binfmt-support`
  on Debian or Ubuntu; `qemu-user-static` and `qemu-user-static-binfmt` on
  Arch), because the prep script rebuilds the card's initrds in a chroot.
- A checkout of this repository on that PC. Run the scripts from inside it;
  some of them use files that sit beside them.

## Get it running

On the PC:

    wget https://packages.pyra-handheld.com/images/trixie/pyra-trixie-t1-brokenxorg.7z
    7z x pyra-trixie-t1-brokenxorg.7z

    lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT          # find the card; get this right
    sudo ./pc/verify-card-capacity.sh /dev/sdX        # is the card what it claims to be
    sudo dd if=pyra-trixie-t1.img of=/dev/sdX bs=4M status=progress conv=fsync

    sudo partprobe /dev/sdX
    sudo mount /dev/sdX2 /mnt
    sudo mount /dev/sdX1 /mnt/boot
    sudo ./pc/pyra-trixie-prep.sh /mnt yourname       # applies the fixes; asks for a password
                                                      # and offers to download the kernel
    sudo umount /mnt/boot /mnt && sync

Put the card in the left slot and **hold the power button until both LEDs go
green**. A short tap looks exactly like a dead card. It isn't: this image's
U-Boot ignores anything but a long press.

After the first boot, shut down, put the card back in the PC, and fill the rest
of it (the image is only 6 GiB):

    sudo ./pc/pyra-trixie-grow.sh /dev/sdX

(Prep's `--grow-on-boot` makes the card do this itself on its first boot
instead; see [docs/grow-rootfs.md](docs/grow-rootfs.md).)

That is the outline. [docs/procedure.md](docs/procedure.md) is the version to
follow: it has the checks between the steps, and a list of what to look at to
confirm each part works.

The prep script installs the shipped kernel, `5.6.19-m4-kbdled`, and the card
boots it (fix 19). It downloads the kernel from the project's release and checks
it against a pinned hash, or takes a tarball you name with `--kernel FILE`. No
release is pinned yet, so for now build the tarball yourself (see below) and
pass it in. `--no-kernel` keeps the stock `5.6.19-pyradef`.

## Do these after the first boot

**Turn off suspend.** On the stock kernel it never completes, and a failed
attempt leaves you a frozen desktop with a working mouse pointer. Unless
`uname -r` says `5.6.19-m4-kbdled`, mask it so an idle timeout fails harmlessly
instead:

    sudo systemctl mask sleep.target suspend.target hybrid-sleep.target \
                        suspend-then-hibernate.target hibernate.target

The shipped kernel fixes this properly (see below).

**The display can wedge when the screen blanks.** Rarely, but when it does a
core spins at 100% and only a reboot recovers it. The workaround is to stop the
screen blanking; [docs/troubleshooting.md](docs/troubleshooting.md) has the
three settings. A fix has been written but is not yet confirmed.

For a screen that dims when idle (MATE's own dimming adjusts the keyboard light
instead), install the separate `pyra-backlight` package. Section 8 of
`docs/procedure.md` has both of these in full.

## If something goes wrong

- It boots wrong, a service fails, or something freezes:
  [docs/troubleshooting.md](docs/troubleshooting.md).
- The card itself misbehaves, or you suspect the reader: run
  `pc/pyra-card-diagnose.sh`, which is read-only.
- Before experimenting on a card that works:
  [docs/card-backup-restore.md](docs/card-backup-restore.md). It takes about ten
  minutes.

## The shipped kernel

The kernel this project ships is `5.6.19-m4-kbdled`, and a prepared card boots
it (fix 19); the image's stock `5.6.19-pyradef` stays on the card as `l0`. It carries everything in `patches/`: the
suspend fix, the nubs dying after a resume, the built-in keyboard going silent,
the noise on every resume, the root filesystem mounting a minute late, and the
candidate display fix. On top of that it carries the AESS audio path with
headphone-jack switching, the SGX powering off at idle, five extra CPU
frequency steps below the rated 1.5 GHz (no overclock), and the keyboard light
as an LED. [docs/kernel-changes.md](docs/kernel-changes.md) lists every patch.
Building it needs Docker on the PC and takes about ten minutes. Hand the
result to prep, or put it on a card that is already running:

    ./pc/pyra-crossbuild.sh kernel-m4-kbdled          # ../dragonbox-pyra-build/kernel/m4-kbdled-kernel.tar.gz
    sudo ./pc/pyra-trixie-prep.sh --kernel ../dragonbox-pyra-build/kernel/m4-kbdled-kernel.tar.gz /mnt yourname
    ./pc/pyra-push-kernel.sh --install --reboot pyra@<address>   # or this, on a running card

[docs/reproduce.md](docs/reproduce.md) is the full path, including turning
suspend back on and checking each fix took.

On this kernel the keyboard light is an LED, which the stock Fn-key script
cannot find. Prep's fix 15 (and `pyra-push-helpers.sh`) point the Fn keys at
`pyra-kbdlight.sh`, which drives it; the `pyra-backlight` 0.2 panel applet
controls it too.

---

## Documentation

Each document stands alone. Read the one that matches what you are doing.

The line under each document's title says what kind it is: **instructions** (steps to
follow), **reference** (how things are and why), or **log** (a dated record: history,
not instructions). The logs are listed separately at the end.

### Setting up and using it

| Document | What it covers |
| --- | --- |
| [docs/procedure.md](docs/procedure.md) | Write the card, apply the fixes, boot, verify. **Start here.** |
| [docs/troubleshooting.md](docs/troubleshooting.md) | It booted wrong, or a service is unhappy. Also the harmless oddities. |
| [docs/grow-rootfs.md](docs/grow-rootfs.md) | Filling the rest of the card, which must be done on a PC. |
| [docs/card-backup-restore.md](docs/card-backup-restore.md) | Back up the running card in ten minutes, and restore it. |
| [docs/reproduce.md](docs/reproduce.md) | Everything here, including the patched kernel and the helper scripts. |
| [docs/fixes.md](docs/fixes.md) | The twenty-one fixes the prep script applies, what each is for, and the diagnosis behind it. |
| [docs/audio.md](docs/audio.md) | The audio chain, what the codec will and will not do, and how to diagnose silence. |
| [docs/gl4es.md](docs/gl4es.md) | Desktop GL programs, on the GPU rather than in software. |
| [docs/qt-gles.md](docs/qt-gles.md) | GLES2 for Qt and other toolkit programs, which fails silently as shipped. |
| [docs/box86.md](docs/box86.md) | Running x86 Linux binaries, x86 Wine, and Windows games. |
| [docs/known-limitations.md](docs/known-limitations.md) | The hard walls, and everything already tried that did not work. |

### Porting and optimising software

| Document | What it covers |
| --- | --- |
| [docs/optimization-playbook.md](docs/optimization-playbook.md) | **Start here.** Index, and a triage of every optimisation proposed on this hardware so far. |
| [docs/hardware-overview.md](docs/hardware-overview.md) | What this machine is, the numbers, and the seven ways it differs from anything modern. |
| [docs/porting-checklist.md](docs/porting-checklist.md) | A phased checklist from "is this feasible" to "confirm it in real play". |
| [docs/cpu-optimization.md](docs/cpu-optimization.md) | Cortex-A15, NEON, the TLB, the governor, and why the CPU is usually not the problem. |
| [docs/gpu-optimization.md](docs/gpu-optimization.md) | SGX544MP2: tile-based deferred rendering, the measured GLES2 limits, what costs and what is free. |
| [docs/memory-optimization.md](docs/memory-optimization.md) | One memory pool shared by everything, and the readback cliff. |
| [docs/rendering-guidelines.md](docs/rendering-guidelines.md) | The display pipeline, and how to adapt a desktop renderer to this part. |
| [docs/compiler-flags.md](docs/compiler-flags.md) | What to build with, and what Debian's baseline silently costs you. |
| [docs/profiling-guide.md](docs/profiling-guide.md) | The four traps that produce confident wrong numbers, and how to avoid them. |
| [docs/power-testing.md](docs/power-testing.md) | Measuring power on the battery gauge, what has been measured, and the pitfalls. |

### Kernel and development work

| Document | What it covers |
| --- | --- |
| [docs/scripts.md](docs/scripts.md) | Every script in the repository, one line each. |
| [docs/building.md](docs/building.md) | Compiling the X driver and the kernel on a PC, and installing a test build safely. |
| [docs/kernel-changes.md](docs/kernel-changes.md) | Every kernel patch, what it does, and which builds carry it. |
| [docs/kernel-notes.md](docs/kernel-notes.md) | Kernel tunables worth changing, and the ones to leave alone. |
| [docs/m4-demo.md](docs/m4-demo.md) | Run the two Cortex-M4s on your own Pyra, on the shipped kernel or a one-boot M4 kernel, and how to undo it. |
| [docs/decisions.md](docs/decisions.md) | Where this deviates from the original forum writeup, and what was rejected. |
| [reports/](reports/) | Findings written up for submission upstream. Drafts, not sent. |

### Logs: history, not instructions

| Document | What it covers |
| --- | --- |
| [docs/improvements.md](docs/improvements.md) | System performance: what is done, what is worth measuring next, what is not. |
| [docs/pegasus.md](docs/pegasus.md) | Scoping the Pegasus launcher and hardware menus for it. |
| [docs/m4-ipu.md](docs/m4-ipu.md) | The OMAP5's two idle Cortex-M4s and its DSP, and the kernel work to reach them. |
| [docs/aess-letux-7.3.md](docs/aess-letux-7.3.md) | Porting the AESS (audio DSP) patches to letux 7.3. |
| [docs/verification-log.md](docs/verification-log.md) | What was checked against the image and the hardware, dated. |

Some documents cite "the development log §N". That is the dated working log kept
with the private development notes; it is not published.

## What is in the repository

    pc/          run these on your computer
    device/      run these on the Pyra, or install them onto it
    patches/     kernel source patches, applied by the build script
    experiments/ kernel changes and measurements on trial, kept out of patches/
    reports/     findings written up for upstream, drafted but not sent
    docs/        one document per job, listed above

The scripts are idempotent and refuse to run against anything that is not what
they expect. The ones that take a device argument write to it, so read the
header comment before the first run. [docs/scripts.md](docs/scripts.md) lists
them all.

The image, the upstream archive and card dumps are gitignored: they are large,
and reproducible from the sources below.

## Licence

GPL-2.0-only, in `LICENSE`, with one exception. The patches in `patches/` and
`experiments/` are changes to Linux kernel source and carry its licence, including
the BSD-3-Clause header that `experiments/m4-ipu/0009-*.patch` adds, since the
kernel file it touches is BSD-3-Clause upstream.

The exception is the Cortex-M4 test firmware in `experiments/m4-ipu/firmware/`
(`Makefile`, `m4.ld`, `main.c`, `resource_table.c`, `start.S`): BSD-3-Clause,
with the text in that directory's `LICENSE`. Its resource table follows the
layout of the kernel's BSD-licensed `include/linux/remoteproc.h`, and firmware
for a remote processor is normally BSD-licensed so it can be built into
anything. Every other file is GPL-2.0-only.

## Sources

- Image: https://packages.pyra-handheld.com/images/trixie/
- Original writeup: pyra-handheld.com forums, "Debian 13 (trixie) working on
  the Pyra: three fixes", reported working on a V5.3 unit.
