# Debian 13 (trixie) on the DragonBox Pyra

Build a bootable trixie SD card for a V5.x Pyra, fix what upstream ships broken,
and get a working desktop with hardware GL and x86 emulation on top of it.

**Status: working.** The card boots to a MATE desktop, GLES2 runs on the SGX
through the DDK blob, desktop GL comes back through gl4es, all the on-board
hardware checks out, the rootfs fills the card, and x86 software runs under
box86 — including a 1999 Windows game under an x86 Wine.

The eMMC is never touched, so the bookworm-7 install stays intact as a recovery
path.

### Six faults you should know about before you rely on it

All six are diagnosed in `docs/troubleshooting.md`, each with the evidence
that identified it. Five are fixed. The remaining one, the display wedge, has a
candidate fix that cannot be confirmed until it next fails to happen. The kernel patches are in
`patches/`, built by `./pc/pyra-crossbuild.sh kernel-fix`.

**The display can wedge inside a modeset.** A core spins at 100% and only a
reboot recovers it. Every DPMS transition is a modeset, so ordinary idle
blanking is enough to hit it. Mitigated rather than fixed, and the mitigation
does not protect you from a program that toggles DPMS itself. Not reproducible
on demand: roughly 2100 deliberate modesets across three configurations have
not triggered it once. The search is now down to two lines: the only two
unbounded busy-wait loops left in the whole modeset path, both draining the
display link's receive queue, both sitting under every display power-on.
**Candidate fix written, not yet confirmed.**

**It would not suspend, and trying froze the desktop.** Two phantom SD hosts,
created by an unfinished mux driver from a stub device tree node, blocked
forever. The kernel's SD suspend hook waited on them and never returned, and
because systemd freezes your session before writing to `/sys/power/state` and
thaws it afterwards, there was no afterwards. You got a background and a
working mouse pointer and nothing else. **Fixed by `patches/0003`, which
deletes two characters, and confirmed on hardware on 2026-09-11.** Both kinds
of sleep complete and resume, the session thaws, and the network comes back.
Resume used to be noisy as well, and most of that is now gone too: see the
fourth patch below.

**The screen never dims.** MATE's backlight helper recognises four device
names, none of which exist here, and falls back to the first entry it finds,
which is the keyboard light. Every dim request has been adjusting the keyboard.
**Fixed by `pyra-idle-dim`, which names the device instead of guessing.**

**Both mouse nubs died on the first suspend and stayed dead.** The device tree
wires no interrupt to the joystick chips, so the driver polls them every 25 ms,
and its suspend callback cancels that poll while its resume callback forgets to
restart it. Only reopening the input device brings it back, which is why a
reboot fixed it and why restarting the input daemon did too. **Fixed by
`patches/0005`.**

**The thermal daemon has never limited a frequency.** It decides a cap every
20 seconds and applies it by calling a program that trixie does not ship and
cannot install, so the call has failed on every cycle since the first boot
while the charging half of the same function worked. That left the kernel's own
governor as the only protection, and on its own it is not enough: two cores
flat out reached 107°C, seven degrees past the passive trip. **Fixed by
`pyra-thermal-fix.sh` and by the prep script, and confirmed on hardware: the
same load now peaks at 84°C.**

**The built-in keyboard can stop dead, silently.** The key controller signals
with a level held asserted while anything is queued, but the device tree
describes the line as edge triggered, so the kernel hears only the moment it
becomes asserted. A key pressed in the window between the driver draining the
queue and acknowledging leaves the line asserted with nothing able to signal
again. Nothing is logged, because the handler is never entered. **Fixed by
`patches/0006`**, with `device/pyra-keypad-rescue` to unstick a machine that is
not running it yet.

---

## Which document

Each one stands alone. Read the one that matches what you are doing.

| Document | What it covers |
| --- | --- |
| [docs/procedure.md](docs/procedure.md) | Buy a card, write the image, apply the fixes offline, boot, verify. Start here. |
| [docs/reproduce.md](docs/reproduce.md) | Get from a blank card to the exact state described here, including the patched kernel. |
| [docs/fixes.md](docs/fixes.md) | The six fixes, what each one is for, and the diagnosis behind it. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | It booted wrong, or a service is unhappy. Also the harmless oddities. |
| [docs/grow-rootfs.md](docs/grow-rootfs.md) | The image is 6 GiB. Filling the rest of the card, which must be done on a PC. |
| [docs/gl4es.md](docs/gl4es.md) | Desktop GL after fix 4, on the hardware rather than in software. |
| [docs/box86.md](docs/box86.md) | Running x86 Linux binaries, x86 Wine, and Windows games. |
| [docs/improvements.md](docs/improvements.md) | Performance: what is already done, what is worth measuring next, what is not. |
| [docs/building.md](docs/building.md) | Compiling the X display driver and the kernel from source, on a PC, and installing a test build safely. |
| [docs/decisions.md](docs/decisions.md) | Where this deviates from the original forum writeup, and what was rejected. |
| [docs/verification-log.md](docs/verification-log.md) | What was checked against the image and the hardware, dated. |
| [docs/progress.md](docs/progress.md) | The running history: what was done when, and why. Newest last. |
| [TODO.md](TODO.md) | The short list of things that need a person: your hands on the device, your account, or your decision. |
| [reports/](reports/) | Findings written up for submission upstream, one file each. Drafts, not sent. |

Where the reference documents and the history disagree, the reference is right
about *how* and the history is right about *when* and *why*.

---

## What is in here

    pc/          run these on your computer
    device/      run these on the Pyra, or install them onto it
    patches/     kernel source patches, applied by the build script
    experiments/ kernel changes on trial, deliberately kept out of patches/
    reports/     findings written up for upstream, drafted but not sent
    docs/        one document per job, listed above

Everything is idempotent and refuses to run against anything that is not what
it expects. The scripts that take a device argument write to it, so read the
header comment before the first run. The measurement tools change nothing and
need no privileges beyond reading `/proc`.

### On your computer

| Script | What it does |
| --- | --- |
| `pc/pyra-trixie-prep.sh` | Applies all six fixes to a mounted rootfs, before the card's first boot. |
| `pc/pyra-prep-selftest.sh` | Proves the prep script does exactly that, against a copy of the real image. No Pyra, no card. |
| `pc/verify-card-capacity.sh` | Checks the card's real capacity and link stability before anything is grown onto it. |
| `pc/pyra-trixie-grow.sh` | Extends partition 2 and the f2fs onto the rest of the card. |
| `pc/pyra-verify-card-metadata.sh` | Scans the card's f2fs metadata for the signature of a card reader that corrupted what it wrote. Run after every write and every grow. |
| `pc/pyra-card-diagnose.sh` | Asks whether a failing card is the card or the reader. Read-only, about a minute. |
| `pc/pyra-card-read-stability.sh` | Reads the same block twice with the page cache bypassed, to catch a reader that invents data. Read-only. |
| `pc/pyra-card-probe-and-image.sh` | Looks at a suspect card read-only, then images both partitions before anything else is attempted. Writes nothing to the card. |
| `pc/pyra-repair-lib-symlink.sh` | Puts back the `/lib` symlink that a bad tar extraction destroys. Run from the PC with the card mounted, because the device cannot start a single binary once it is gone. |
| `pc/pyra-devsetup.sh` | Development conveniences on a machine you own: your SSH key, sudo without a password, and a desktop with no login prompt. Reversible with `--undo`. |
| `pc/pyra-devsetup-selftest.sh` | Proves that script does exactly that, against a synthetic rootfs in a container. No Pyra, no card, no root. |
| `pc/pyra-crossbuild.sh` | Cross-builds the omap5 X driver or the pyradef kernel for armhf in a container, stock or with any of the patch sets. Touches neither the host nor the Pyra. |
| `pc/pyra-push-kernel.sh` | Copies a built kernel and the device scripts to the Pyra, and can install and reboot it in the same step. |
| `pc/pyra-push-helpers.sh` | Copies the device scripts to the Pyra and installs them there, in one command from the workstation. The same thing `pyra-push-kernel.sh` does on its way past, without needing a built kernel to do it. |
| `experiments/c2-idle/` | One kernel patch, tried and rejected: restoring the processor's retention idle state, which this kernel tree removes, hangs the machine within two minutes. Kept with its result so nobody repeats it. |
| `experiments/thermals-and-frequency/` | Third-party, never booted here: an unlocked device tree with sixteen frequency steps from 250 MHz to 2 GHz, read out and reviewed, and rewritten as two device tree patches so the half that is not overclocking can be built on its own. Also the one change in its example thermal script that can damage a battery. |
| `patches/` | Six kernel patches: the candidate display fix, the suspend fix, the fix for the interrupt storm on resume, the fix for the nubs dying on resume, the fix for the keyboard going silent, and one that prints an error the driver was discarding. Applied by `pc/pyra-crossbuild.sh kernel-fix`. |

### On the Pyra

| Script | What it does |
| --- | --- |
| `device/pyra-install-helpers.sh` | Puts every script below onto the device in one step, plus the sysrq settings and the idle dimmer's user service. |
| `device/pyra-install-debug-kernel.sh` | Installs a built kernel beside the stock one and gives it a boot entry, without making it the default. |
| `device/pyra-boot-kernel.sh` | Chooses which kernel boots next, with a one-shot mode that reverts to the stock kernel by itself. |
| `device/pyra-sleep-test.sh` | Suspends the machine with the clock armed to wake it, says whether it really came back, and names which sleep state the kernel used. |
| `device/pyra-modeset-hang-trap.sh` | Provokes the display hang on purpose, captures the kernel backtrace of the spinning core, and reboots. Read its header first. |
| `device/pyra-idle-dim` | Dims the screen when the session goes idle, which MATE's own version cannot do here. |
| `device/pyra-usb3503-rescue` | Re-resets the USB hub when a warm reboot leaves it dead. Installed by fix 5. |
| `device/pyra-keypad-rescue` | Unsticks the built-in keyboard when its controller is left holding an edge-triggered interrupt line asserted. |
| `device/pyra-idle-profile.sh` | Which idle states the processor has, how much of a window it spent in each, and what the battery did meanwhile. Read-only. |
| `device/pyra-freq-profile.sh` | Compares two kernels' cpufreq behaviour: idle residency, the latency of short bursts of work, and throughput, with power when the charger is off. Changes nothing, needs no privileges. |
| `device/pyra-governor-sweep.sh` | Measures what each cpufreq governor setting is worth, one knob at a time, against the `performance` governor as the ceiling. Stops the thermal daemon and pins the frequency ceiling for the length of the run, because the daemon caps on battery temperature and will otherwise move the ceiling underneath the measurement; puts both back on every exit path. |
| `device/pyra-governor-tune.sh` | Applies the one governor setting the sweep found worth applying, `sampling_down_factor` 1 → 10: 23% off burst latency and a third off the median, for 5.4% more idle frequency. `--check` and `--undo`. Its systemd unit reapplies it at boot, because a sysfs write does not survive one. |
| `device/pyra-thermal-fix.sh` | Makes the stock thermal daemon able to apply its own decision. It calls `cpufreq-set`, which trixie cannot install, so it has never capped a frequency; this writes `scaling_max_freq` instead. Peak temperature under load falls from 100°C to 84°C. Reversible with `--undo`. |
| `device/pyra-cpu-attribution.sh` | Accounts for every busy CPU cycle by process across a window, and splits the rest by kernel class. Read-only. |
| `device/pyra-x-load-profile.sh` | The X server's share of a workload, plus whether the 2D core moved and whether clients use shared memory. Read-only. |
| `device/pyra-anno1602-test.sh` | Runs a 1999 Windows game under box86 and Wine as a bounded, repeatable load, with a thermal guard. |
| `device/pyra-gles2-smoke.c` | Minimal X11, EGL and GLES2 client, to prove the SGX path works. |
| `device/pyra-exa-fallback-bench.c` | Isolates the cost of the driver's software fallbacks against its hardware paths. |

Two systemd units sit beside the scripts they belong to. The rescue unit is a
payload for fix 5 and the prep script copies it from `device/` rather than
carrying its own copy, so there is only ever one of each in the repository.
`device/etc/` holds files that are installed to the same path under `/` on the
device.

---

## Licence

GPL-2.0-only, in `LICENSE`. The patches in `patches/` are changes to Linux
kernel source and carry its licence; the rest is licensed the same way so that
the whole repository has one answer.

---

## The short version

    # on the PC
    wget https://packages.pyra-handheld.com/images/trixie/pyra-trixie-t1-brokenxorg.7z
    7z x pyra-trixie-t1-brokenxorg.7z
    sudo ./pc/pyra-prep-selftest.sh                    # optional, proves the fixes
    sudo ./pc/verify-card-capacity.sh /dev/sdX         # before trusting the card
    # write the image to the whole device, mount p2, then:
    sudo ./pc/pyra-trixie-prep.sh /mnt
    # after the first boot, with the card back in the reader:
    sudo ./pc/pyra-trixie-grow.sh /dev/sdX

    # the patched kernel, and the helpers, once it is running
    ./pc/pyra-crossbuild.sh kernel-fix
    ./pc/pyra-push-kernel.sh --install --reboot pyra@<address>
    ./pc/pyra-push-helpers.sh pyra@<address>

Every step above has conditions and guards that this summary leaves out.
`docs/procedure.md` is the version to actually follow for the card, and
`docs/reproduce.md` for the whole end state including the kernel.

---

## Not in the repository

The image, the upstream archive and the card dumps are gitignored: they are
large, and they are reproducible from the source above.

## Sources

- Image: https://packages.pyra-handheld.com/images/trixie/
- Original writeup: pyra-handheld.com forums, "Debian 13 (trixie) working on
  the Pyra: three fixes" — reported working on a V5.3 unit.
