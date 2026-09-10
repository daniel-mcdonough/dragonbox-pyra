# Debian 13 (trixie) on the DragonBox Pyra

Build a bootable trixie SD card for a V5.x Pyra, fix what upstream ships broken,
and get a working desktop with hardware GL and x86 emulation on top of it.

**Status: working.** The card boots to a MATE desktop, GLES2 runs on the SGX
through the DDK blob, desktop GL comes back through gl4es, all the on-board
hardware checks out, the rootfs fills the card, and x86 software runs under
box86 — including a 1999 Windows game under an x86 Wine.

The eMMC is never touched, so the bookworm-7 install stays intact as a recovery
path.

**One known hazard.** The display driver can wedge inside a modeset, spinning a
core at 100% until the machine is rebooted, and every DPMS transition is a
modeset. It is mitigated rather than fixed, and `docs/troubleshooting.md` has
the mechanism, the mitigation and the one tool you must not run on this
machine.

---

## Which document

Each one stands alone. Read the one that matches what you are doing.

| Document | What it covers |
| --- | --- |
| [docs/procedure.md](docs/procedure.md) | Buy a card, write the image, apply the fixes offline, boot, verify. Start here. |
| [docs/fixes.md](docs/fixes.md) | The five fixes, what each one is for, and the diagnosis behind it. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | It booted wrong, or a service is unhappy. Also the harmless oddities. |
| [docs/grow-rootfs.md](docs/grow-rootfs.md) | The image is 6 GiB. Filling the rest of the card, which must be done on a PC. |
| [docs/gl4es.md](docs/gl4es.md) | Desktop GL after fix 4, on the hardware rather than in software. |
| [docs/box86.md](docs/box86.md) | Running x86 Linux binaries, x86 Wine, and Windows games. |
| [docs/improvements.md](docs/improvements.md) | Performance: what is already done, what is worth measuring next, what is not. |
| [docs/building.md](docs/building.md) | Compiling the X display driver and the kernel from source, on a PC, and installing a test build safely. |
| [docs/decisions.md](docs/decisions.md) | Where this deviates from the original forum writeup, and what was rejected. |
| [docs/verification-log.md](docs/verification-log.md) | What was checked against the image and the hardware, dated. |
| [docs/progress.md](docs/progress.md) | The running history: what was done when, and why. Newest last. |

Where the reference documents and the history disagree, the reference is right
about *how* and the history is right about *when* and *why*.

---

## Scripts

All are idempotent and refuse to run against anything that is not what they
expect. The three that take a device argument write to it, so read the header
comment before the first run. The measurement tools at the bottom of the table
change nothing and need no privileges beyond reading `/proc`.

| Script | Runs on | What it does |
| --- | --- | --- |
| `pyra-trixie-prep.sh` | PC | Applies all five fixes to a mounted rootfs, before the card's first boot. |
| `pyra-prep-selftest.sh` | PC | Proves the prep script does exactly that, against a copy of the real image. No Pyra, no card. |
| `verify-card-capacity.sh` | PC | Checks the card's real capacity and link stability before anything is grown onto it. |
| `pyra-trixie-grow.sh` | PC | Extends partition 2 and the f2fs onto the rest of the card. |
| `pyra-usb3503-rescue` | Pyra | Re-resets the USB hub when a warm reboot leaves it dead. Installed by fix 5. |
| `pyra-gles2-smoke.c` | Pyra | Minimal X11 + EGL + GLES2 client, to prove the SGX path works. |
| `pyra-cpu-attribution.sh` | Pyra | Accounts for every busy CPU cycle by process across a window, and splits the rest by kernel class. Read-only. |
| `pyra-x-load-profile.sh` | Pyra | The X server's share of a workload, plus whether the 2D core moved and whether clients use shared memory. Read-only. |
| `pyra-anno1602-test.sh` | Pyra | Runs a 1999 Windows game under box86 and Wine as a bounded, repeatable load, with a thermal guard. |
| `pyra-modeset-hang-trap.sh` | Pyra | Provokes the display hang on purpose, captures the kernel backtrace of the spinning core, and reboots. Read its header first. |
| `pyra-install-debug-kernel.sh` | Pyra | Installs a test kernel beside the stock one and adds a boot menu entry, without making it the default. |
| `pyra-boot-kernel.sh` | Pyra | Chooses which kernel boots next, with a one-shot mode that reverts to the stock kernel by itself. |
| `pyra-verify-card-metadata.sh` | PC | Scans the card's f2fs metadata for the signature of a card reader that corrupted what it wrote. Run after every write and every grow. |
| `pyra-crossbuild.sh` | PC | Cross-builds the omap5 X driver or the pyradef kernel for armhf in a container. Touches neither the host nor the Pyra. |
| `pyra-exa-fallback-bench.c` | Pyra | Isolates the cost of the driver's software fallbacks against its hardware paths. |

`pyra-usb3503-rescue.service` is the unit for the rescue script. Both are
payloads for fix 5, and the prep script copies them from here rather than
embedding them, so there is only ever one copy of each.

---

## The short version

    # on the PC
    wget https://packages.pyra-handheld.com/images/trixie/pyra-trixie-t1-brokenxorg.7z
    7z x pyra-trixie-t1-brokenxorg.7z
    sudo ./pyra-prep-selftest.sh                    # optional, proves the fixes
    sudo ./verify-card-capacity.sh /dev/sdX         # before trusting the card
    # write the image to the whole device, mount p2, then:
    sudo ./pyra-trixie-prep.sh /mnt
    # after the first boot, with the card back in the reader:
    sudo ./pyra-trixie-grow.sh /dev/sdX

Every step above has conditions and guards that this summary leaves out.
`docs/procedure.md` is the version to actually follow.

---

## Not in the repository

The image, the upstream archive and the card dumps are gitignored: they are
large, and they are reproducible from the source above.

## Sources

- Image: https://packages.pyra-handheld.com/images/trixie/
- Original writeup: pyra-handheld.com forums, "Debian 13 (trixie) working on
  the Pyra: three fixes" — reported working on a V5.3 unit.
