# Debian 13 (trixie) on the DragonBox Pyra

This continues the effort to make the trixie image published on the Pyra
forums good enough to use as the Pyra's everyday OS. As published, X crashes,
the first-run wizard powers the unit off, the nubs are dead, and there is no
sound. This repository turns that image into a working SD card for a V5.x Pyra,
with a MATE desktop, hardware GLES2 on the SGX, desktop GL through gl4es,
sound, and charging.

It runs from an SD card. The eMMC is never touched, so the OS on the eMMC
(buster or bookworm, whichever your unit shipped with) stays as it is and takes
over again when you pull the card.

There are two ways to get a card:

- **Write the prebuilt image** (quick start, below). The fixes are already
  applied and the shipped kernel is installed. You only write it to a card.
- **Build the card yourself** from the vendor image with the prep script, on a
  Linux PC. This is what the image is made from, and the way to choose your own
  user name and options.

---

## Quick start: the prebuilt image

You need a V5.x Pyra and a full-size SDXC card, 16 GB or larger, Class 10 / U1
or better (a microSD in an adapter is fine), and any computer with a card
reader.

1. Download the latest `pyra-trixie-release-<commit>.img.xz` and its `.img.xz.sha256`
   from this repository's Releases page, and check it:

        sha256sum -c pyra-trixie-release-<commit>.img.xz.sha256

   The checksum only shows the download arrived intact. To check that this
   repository's CI built the file, run the `gh attestation verify` line from the
   release notes too (`docs/building.md`, "Checking a download").

2. Write it to the card. On Linux:

        lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT      # find the card; get this right
        xzcat pyra-trixie-release-<commit>.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync

   On Windows or macOS, a writer that takes `.xz` files directly works too
   (balenaEtcher, Raspberry Pi Imager).

3. Put the card in the **left** full-size slot and **hold the power button
   until both LEDs go green**. A short tap looks exactly like a dead card. It
   isn't: this image's U-Boot ignores anything but a long press.

4. **Wait.** On its first boot the card grows its root filesystem to fill
   the card before anything else starts. On a 256 GB card that took about
   11 minutes. Don't switch it off in that time.

5. **Choose your password.** A window asks for the password of the user
   `pyra`. Type it twice and press "Set password". The card ships with no
   password, so until you do this nobody can log in, at the login screen, on
   a console or over ssh. Then log in as `pyra` with it.

Each card makes its own ssh host keys and machine-id on that first boot, so
two cards written from the same image don't share them. Then carry on with
[Do these after the first boot](#do-these-after-the-first-boot).
[docs/procedure.md](docs/procedure.md) has the checks that confirm each part
works.

## Build the card yourself

### What you need

- A V5.x Pyra, and an SD card as above.
- A Linux PC with a card reader, `7z`, `patch`, and root. Unless the PC is itself armhf,
  it also needs qemu-user with binfmt (`qemu-user-static` and `binfmt-support`
  on Debian or Ubuntu; `qemu-user-static` and `qemu-user-static-binfmt` on
  Arch), because the prep script rebuilds the card's initrds in a chroot.
- A checkout of this repository on that PC. Run the scripts from inside it;
  some of them use files that sit beside them.

### Steps

On the PC:

    wget https://packages.pyra-handheld.com/images/trixie/pyra-trixie-t1-brokenxorg.7z
    echo "b2220b3f5ab9974d397d9fbac6c6190c8ff6690fdf977d0b52c4a6ade3fd28c7  pyra-trixie-t1-brokenxorg.7z" \
        | sha256sum -c                                # the archive the fixes were made for
    7z x pyra-trixie-t1-brokenxorg.7z

    lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT          # find the card; get this right
    sudo dd if=pyra-trixie-t1.img of=/dev/sdX bs=4M status=progress conv=fsync

    sudo partprobe /dev/sdX
    sudo ./pc/verify-card-capacity.sh /dev/sdX        # is the card what it claims to be
    sudo mount /dev/sdX2 /mnt
    sudo mount /dev/sdX1 /mnt/boot
    sudo ./pc/pyra-trixie-prep.sh /mnt yourname       # your user (not 'pyra'); asks for a password
                                                      # and needs a kernel: see below
    sudo umount /mnt/boot /mnt && sync

The vendor's server is the only source of that archive. It was reported down
in April 2026 and served it again, unchanged, when checked on 2026-11-21. If
it is down, any copy whose SHA-256 matches the line above will do; there is no
mirror we know of. Otherwise write the prebuilt image instead, which is made
from the same archive.

Boot it as in step 3 of the quick start (hold the power button until both
LEDs go green).

After the first boot, shut down, put the card back in the PC, and fill the rest
of it (the image is only 6 GiB):

    sudo ./pc/pyra-trixie-grow.sh /dev/sdX

(Prep's `--grow-on-boot` makes the card do this itself on its first boot
instead; see [docs/grow-rootfs.md](docs/grow-rootfs.md).)

That is the outline. [docs/procedure.md](docs/procedure.md) is the version to
follow: it has the checks between the steps, and a list of what to look at to
confirm each part works. The prebuilt image is this same procedure with
`--release` ([docs/building.md](docs/building.md), "The release image in CI").

The prep script installs the shipped kernel, `5.6.19-m4-kbdled`, and the card
boots it (fix 19). It downloads the kernel from the project's release and checks
it against a pinned hash (release `kernel-5.6.19-r4`), or takes a tarball you
name with `--kernel FILE`. It always installs one of the two: there is no
stock-only card. The stock `5.6.19-pyradef` stays in boot slot `l0` as the
fallback.

It also installs `pyra-backlight` (fix 22): a panel applet with sliders for the
screen and the keyboard light, and `pyra-idle-dim`, which dims the screen when
the session goes idle. The same way, it downloads the package from its
[release](https://github.com/daniel-mcdonough/pyra-backlight/releases/tag/v0.8) and checks it against a pinned hash;
`--backlight FILE` takes a `.deb` you have, and `--no-backlight` leaves it out.

It also installs `pyra-settings` (fix 26), the Pyra's own settings app (wake
buttons, lid, volume wheel, CPU ceiling), with the pyra-hacks fork its volume
wheel and Performance pages need. It downloads the package from its
[release](https://github.com/daniel-mcdonough/pyra-settings/releases/tag/v0.17) and checks it against a pinned hash;
`--settings FILE` takes a `.deb` you have, and `--no-settings` leaves it out.

It also installs `pyra-sound` (fix 27), a sound icon for the panel (mute,
speakers or headphones) that takes the place of MATE's own. It downloads the package from its
[release](https://github.com/daniel-mcdonough/pyra-sound/releases/tag/v0.4) and checks it against a pinned hash;
`--sound FILE` takes a `.deb` you have, and `--no-sound` leaves it out.

The vendor image ships its ssh host keys and machine-id, the same on every card.
Prep removes them (fix 23), and the card makes its own on its first boot. If
your PC has reached another Pyra at the same address, ssh warns once that the
host key changed.

## Do these after the first boot

**External HDMI doesn't work.** A monitor gets a picture only at 640x480;
higher modes show black. Plugging a monitor in while the desktop runs can also
hang the 2D GPU and lock up X until a reboot (`sync; sudo systemctl reboot -f`).
Leave HDMI unplugged for now. [docs/troubleshooting.md](docs/troubleshooting.md),
"An HDMI monitor shows nothing above 640x480", has what is known.

**Don't run `x11perf`.** It forces dozens of display mode changes, and on the
stock kernel that hung X twice. [docs/troubleshooting.md](docs/troubleshooting.md),
"The X server can hang in a modeset".

**Brightness.** A prepared card has `pyra-backlight` (fix 22). Its slider is
on the panel. Its `pyra-idle-dim` dims the screen after MATE's idle delay
(`gsettings set org.mate.session idle-delay 5`, in minutes). Section 8 of
`docs/procedure.md` has both of these in full. On a card booted back on
`l0`, read the same section's note on
suspend first: the stock kernel can't complete one.

## If something goes wrong

- Reporting a bug: paste the output of `pyra-info` (or press Copy on the About
  page of Pyra Settings). It names the boards, kernel, boot entry, how the card
  was prepared and the versions of the packages prep pins (fix 31).
- It boots wrong, a service fails, or something freezes:
  [docs/troubleshooting.md](docs/troubleshooting.md).
- The card itself misbehaves, or you suspect the reader: run
  `pc/pyra-card-diagnose.sh`, which is read-only.
- Before experimenting on a card that works:
  [docs/card-backup-restore.md](docs/card-backup-restore.md). It takes about ten
  minutes.

## The shipped kernel

The kernel this project ships is `5.6.19-m4-kbdled`, and a prepared card boots
it (fix 19); the image's stock `5.6.19-pyradef` stays on the card as `l0`. It carries every kernel patch in `patches/`: the suspend fix, the nubs dying after a resume, the built-in keyboard going silent,
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
`pyra-kbdlight.sh`, which drives it; the `pyra-backlight` panel applet
controls it too.

---

## Documentation

The line under each document's title says what kind it is: **instructions** (steps to
follow), **reference** (how things are and why), or **log** (a dated record: history,
not instructions). The logs are listed separately at the end.

### Setting up and using it

| Document | What it covers |
| --- | --- |
| [docs/procedure.md](docs/procedure.md) | Write the card, apply the fixes, boot, verify. **Start here.** |
| [docs/troubleshooting.md](docs/troubleshooting.md) | It booted wrong, or a service is unhappy. |
| [docs/board-revision.md](docs/board-revision.md) | Which mainboard, CPU board and RAM size your Pyra has, from a running card or U-Boot's serial lines. |
| [docs/grow-rootfs.md](docs/grow-rootfs.md) | Filling the rest of the card. |
| [docs/card-backup-restore.md](docs/card-backup-restore.md) | Back up the running card, and restore it. |
| [docs/reproduce.md](docs/reproduce.md) | Everything here, including the patched kernel and the helper scripts. |
| [docs/fixes.md](docs/fixes.md) | The thirty-three fixes the prep script applies, what each is for, and the diagnosis behind it. Opens with a table of which ones are temporary and what retires them. |
| [docs/audio.md](docs/audio.md) | The audio chain, what the codec will and will not do, and how to diagnose silence. |
| [docs/gl4es.md](docs/gl4es.md) | Desktop GL programs, on the GPU rather than in software; DBPs that need GLX; fullscreen crashes under gl4es. |
| [docs/dbp.md](docs/dbp.md) | DBP packages from the forum: installing one, the false "missing dependencies" dialog, and which old libraries trixie renamed. |
| [docs/browsers.md](docs/browsers.md) | Which web browser to install (Firefox ESR, or the Pyrafox DBP), and which ones fail on this card, measured. |
| [docs/qt-gles.md](docs/qt-gles.md) | GLES2 for Qt and other toolkit programs, which fails silently as shipped. |
| [docs/known-limitations.md](docs/known-limitations.md) | The hard walls, and everything already tried that did not work. |

### Porting and optimising software

| Document | What it covers |
| --- | --- |
| [docs/optimization-playbook.md](docs/optimization-playbook.md) | **Start here.** Index, and a triage of every optimisation proposed on this hardware so far. |
| [docs/hardware-overview.md](docs/hardware-overview.md) | What this machine is, the numbers, and the ways it differs from anything modern. |
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
| `reports/` | Findings written up for submission upstream. |

### Logs:

| Document | What it covers |
| --- | --- |
| [docs/improvements.md](docs/improvements.md) | System performance: what is done, what is worth measuring next, what is not. |
| [docs/pegasus.md](docs/pegasus.md) | Scoping the Pegasus launcher and hardware menus for it. |
| [docs/m4-ipu.md](docs/m4-ipu.md) | The OMAP5's two idle Cortex-M4s and its DSP, and the kernel work to reach them. |
| [docs/aess-letux-7.3.md](docs/aess-letux-7.3.md) | Porting the AESS (audio DSP) patches to letux 7.3. |
| [docs/verification-log.md](docs/verification-log.md) | What was checked against the image and the hardware, dated. |

Some documents cite "the development log §N". That is the dated working log kept
with the private development notes; it is not published. The notes can be provided if requested.
They were kept out of the repo due to them containing local configuration information and
adding noise to the repo.

## What is in the repository

    pc/          run these on your computer
    device/      run these on the Pyra, or install them onto it
    patches/     kernel source patches, applied by the build script
      userspace/ patches to Pyra packages (pyra-hacks, pyra-meta, funkeymonkey-pyrainput), in the form sent upstream
    experiments/ kernel changes and measurements on trial, kept out of patches/
    reports/     findings written up for upstream, drafted but not sent (not in the public copy)
    docs/        one document per job, listed above

The scripts are idempotent and refuse to run against anything that is not what
they expect. [docs/scripts.md](docs/scripts.md) lists
them all.

## Licence

GPL-2.0-only, in `LICENSE`, with the exceptions below. The kernel patches in `patches/` and
`experiments/` are changes to Linux kernel source and carry its licence, including
the BSD-3-Clause header that `experiments/m4-ipu/0009-*.patch` adds, since the
kernel file it touches is BSD-3-Clause upstream. Likewise, the patches in
`patches/userspace/` carry the licence of the package they change: MIT for
pyra-hacks, pyra-meta and pyra-config, BSD-2-Clause for funkeymonkey-pyrainput. So does
`experiments/kms-plane/armsoc-0001-*.patch`: MIT, for xf86-video-armsoc.

The exception is the Cortex-M4 test firmware in `experiments/m4-ipu/firmware/`
(`Makefile`, `m4.ld`, `main.c`, `resource_table.c`, `start.S`): BSD-3-Clause,
with the text in that directory's `LICENSE`. Its resource table follows the
layout of the kernel's BSD-licensed `include/linux/remoteproc.h`, and firmware
for a remote processor is normally BSD-licensed so it can be built into
anything.

Not ours, and kept under their own terms:

- `experiments/kms-plane/viv2d/*.xml.h`: generated etnaviv register headers,
  MIT, with their copyright and licence text in each file.

Every other file is GPL-2.0-only.

## Sources

- Image: https://packages.pyra-handheld.com/images/trixie/
- Original writeup: pyra-handheld.com forums, "Debian 13 (trixie) working on
  the Pyra: three fixes", reported working on a V5.3 unit.
