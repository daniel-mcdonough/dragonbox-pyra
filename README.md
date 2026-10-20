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
**Fixed by `pyra-idle-dim`, which names the device instead of guessing.** It
now ships in the `pyra-backlight` package, in its own repository, along with a
panel applet for the screen and keyboard backlights.

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
| [docs/card-backup-restore.md](docs/card-backup-restore.md) | Back up the running card on the X220 in ten minutes, and restore it (tested). |
| [docs/fixes.md](docs/fixes.md) | The twelve fixes, what each one is for, and the diagnosis behind it. |
| [docs/power-testing.md](docs/power-testing.md) | How to measure power on the battery gauge, what has been measured, the pitfalls, and the runs still to do. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | It booted wrong, or a service is unhappy. Also the harmless oddities. |
| [docs/grow-rootfs.md](docs/grow-rootfs.md) | The image is 6 GiB. Filling the rest of the card, which must be done on a PC. |
| [docs/gl4es.md](docs/gl4es.md) | Desktop GL after fix 4, on the hardware rather than in software. |
| [docs/qt-gles.md](docs/qt-gles.md) | GLES2 for toolkit programs, which fails silently as shipped. Qt Quick runs on the SGX after one symlink. |
| [docs/audio.md](docs/audio.md) | The audio chain, what the codec will and will not do, and how to diagnose silence. Start here for anything sound-related. |
| [docs/box86.md](docs/box86.md) | Running x86 Linux binaries, x86 Wine, and Windows games. |
| [docs/improvements.md](docs/improvements.md) | Performance: what is already done, what is worth measuring next, what is not. |
| [docs/optimization-playbook.md](docs/optimization-playbook.md) | **The hardware playbook: index, and a triage of every optimisation proposed on this hardware so far.** Start here for porting or optimising software. |
| [docs/hardware-overview.md](docs/hardware-overview.md) | What this machine is, the numbers, and the seven ways it differs from anything modern. The model everything else assumes. |
| [docs/cpu-optimization.md](docs/cpu-optimization.md) | Cortex-A15, NEON, the TLB, the governor, and why the CPU is usually not the problem. |
| [docs/gpu-optimization.md](docs/gpu-optimization.md) | SGX544MP2: tile-based deferred rendering, the measured GLES2 limits, what costs and what is free. |
| [docs/memory-optimization.md](docs/memory-optimization.md) | One memory pool shared by everything, the readback cliff, and why reducing traffic has not paid. |
| [docs/rendering-guidelines.md](docs/rendering-guidelines.md) | The display pipeline, and how to adapt a desktop renderer to this part. |
| [docs/compiler-flags.md](docs/compiler-flags.md) | What to build with, what Debian's baseline silently costs you, and what is not worth adding. |
| [docs/profiling-guide.md](docs/profiling-guide.md) | The four traps that produce confident wrong numbers, and how to build a rig that resolves 0.4%. |
| [docs/porting-checklist.md](docs/porting-checklist.md) | A phased checklist from "is this feasible" to "confirm it in real play". |
| [docs/known-limitations.md](docs/known-limitations.md) | The hard walls, and everything already tried that did not work. |
| [docs/kernel-notes.md](docs/kernel-notes.md) | Kernel tunables worth changing, and the ones to leave alone. |
| [docs/kernel-changes.md](docs/kernel-changes.md) | Every patch made to the kernel, what each one does, and which kernel builds carry it. |
| [docs/pegasus.md](docs/pegasus.md) | Scoping the Pegasus launcher and hardware menus for it: what is proven, what it costs, what to build. |
| [docs/m4-ipu.md](docs/m4-ipu.md) | The OMAP5's two idle Cortex-M4s and its DSP: what they are, the kernel work to reach them, the test firmware that now runs on both cores, the upstream iommu bug that turned up when it did, the letux 7.x alternative, and whether it is worth finishing. |
| [docs/aess-letux-7.3.md](docs/aess-letux-7.3.md) | Our AESS (audio DSP) patches against letux 7.3: what upstream changed, which of our fixes it still lacks, how to port them, and how to test its probe order. |
| [docs/m4-demo.md](docs/m4-demo.md) | Run the two Cortex-M4s on your own Pyra: the demo kit, what it changes, how to undo it, and what the output proves. |
| [docs/building.md](docs/building.md) | Compiling the X display driver and the kernel from source, on a PC, and installing a test build safely. |
| [docs/decisions.md](docs/decisions.md) | Where this deviates from the original forum writeup, and what was rejected. |
| [docs/verification-log.md](docs/verification-log.md) | What was checked against the image and the hardware, dated. |
| [reports/](reports/) | Findings written up for submission upstream, one file each. Drafts, not sent. |

Some documents cite "the development log §N". That is the dated working log kept
with the private development notes; it is not published.

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
| `pc/pyra-trixie-prep.sh` | Applies all twelve fixes to a mounted rootfs, before the card's first boot. |
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
| `pc/pyra-kernel-tree.sh` | Turns the kernel patch sets into a git tree, one branch per set on the stock source, for review and `git format-patch`. See `docs/kernel-changes.md`. |
| `pc/pyra-push-kernel.sh` | Copies a built kernel and the device scripts to the Pyra, and can install and reboot it in the same step. |
| `pc/pyra-push-helpers.sh` | Copies the device scripts to the Pyra and installs them there, in one command from the workstation. The same thing `pyra-push-kernel.sh` does on its way past, without needing a built kernel to do it. |
| `pc/pyra-m4-verify.sh` | Asserts the M4 patch set and the test firmware still say what `docs/m4-ipu.md` claims they say. Needs no Pyra; `--patches` needs no build either. |
| `pc/pyra-m4-demo-kit.sh` | Packages the M4 demo kit: the `5.6.19-m4demo` kernel, both firmwares, the device scripts, and the patches and `.config` the kernel was built from. Refuses to finish if anything in it names the person who built it. |
| `experiments/pegasus-idle/` | What a QML launcher costs this machine at rest, and how much of that is recoverable: a deliberately inert theme, the measurement scripts, and the controls that rule out Qt and the driver. |
| `experiments/c2-idle/` | One kernel patch, tried and rejected: restoring the processor's retention idle state, which this kernel tree removes, hangs the machine within two minutes. Kept with its result so nobody repeats it. |
| `experiments/m4-ipu/` | The OMAP5's two Cortex-M4s and its DSP, made visible to Linux and then made to run code: four kernel patches, a bare-metal test firmware that runs on both cores, and the unfixed upstream `omap-iommu` bug that starting the IPU turned up. |
| `experiments/thermals-and-frequency/` | Third-party, never booted here: an unlocked device tree with sixteen frequency steps from 250 MHz to 2 GHz, read out and reviewed, and rewritten as two device tree patches so the half that is not overclocking can be built on its own. Also the one change in its example thermal script that can damage a battery. |
| `experiments/undervolt/` | A module that changes one CPU operating point's voltage at runtime, and how the 750 MHz point was stepped from 950 mV to 850 (all clean) and chosen at 870: stress-ng with result checks, Ship of Harkinian's frame dumps, the watts, and a 60-minute soak. Shipped as `device/pyra-undervolt`. |
| `experiments/gpu-tools/` | GPU profiling that works here: PVRTune's server reads the SGX's HWPerf timing on the stock kernel and DDK, and apitrace records a game's GLES2 calls for a desktop frame debugger. Build script, the `eglretrace` patch the DDK needs, and `pvrtune_frames.py` for per-frame GPU time. First result: Ship of Harkinian's GPU is 20% busy at 30 fps. |
| `patches/` | Seven kernel patches: the candidate display fix, the suspend fix, the fix for the interrupt storm on resume, the fix for the nubs dying on resume, the fix for the keyboard going silent, one that prints an error the driver was discarding, and an upstream backport that stops kprobes panicking. Applied by `pc/pyra-crossbuild.sh kernel-fix`. Every kernel change, including the experiments, is listed in `docs/kernel-changes.md`. |

### On the Pyra

| Script | What it does |
| --- | --- |
| `device/pyra-install-helpers.sh` | Puts every script below onto the device in one step, plus the sysrq settings. Also removes the idle dimmer copies that earlier versions installed, which now come from the `pyra-backlight` package. |
| `device/pyra-install-debug-kernel.sh` | Installs a built kernel beside the stock one and gives it a boot entry, without making it the default. |
| `device/pyra-boot-kernel.sh` | Chooses which kernel boots next, since U-Boot's menu only exists on the serial console. `debug --once` gives a test kernel exactly one boot. `base <label>` sets which kernel the machine returns to, which is no longer always the distro one — its thermal behaviour stops the battery charging. |
| `device/pyra-sleep-test.sh` | Suspends the machine with the clock armed to wake it, says whether it really came back, and names which sleep state the kernel used. |
| `device/pyra-modeset-hang-trap.sh` | Provokes the display hang on purpose, captures the kernel backtrace of the spinning core, and reboots. Read its header first. |
| `device/pyra-gles` | Runs a GLES2 program against the SGX driver instead of glvnd, which is otherwise what it gets and why it draws nothing. Needs no root and installs nothing. |
| `device/pyra-usb3503-rescue` | Re-resets the USB hub when a warm reboot leaves it dead. Installed by fix 5. |
| `device/pyra-keypad-rescue` | Unsticks the built-in keyboard when its controller is left holding an edge-triggered interrupt line asserted. |
| `device/pyra-idle-profile.sh` | Which idle states the processor has, how much of a window it spent in each, and what the battery did meanwhile. Read-only. |
| `device/pyra-modem-power.sh` | Reads the board's one INA231, on the modem rail, or explains why it cannot be read. On a unit with no modem fitted it cannot: the rail is down and the sensor is powered from it. Read-only. |
| `device/pyra-aess-probe.sh` | Answers whether the OMAP5 AESS -- the SoC's audio DSP, which could take PulseAudio's resampling off the CPU -- is live silicon on this machine. It is. Forces the module active through ti-sysc, round-trips a word through each of its three memories and puts every value back. Note `devmem2` on this image reads 0x0 for every address; the script uses busybox and checks its tool first. |
| `device/pyra-aess-run.py` | Loads the AESS firmware, builds the scheduler table the kernel driver never builds, and runs the audio DSP. Measures its loop rate against the event-generator divisor: 3999 loops/s at 48 kHz, 3676 at 44.1, ratio 0.9193 vs 0.9192 expected. Restores everything; plays no audio. Read `pyra-aess-probe.sh` first. |
| `device/pyra-aess-dl-probe.py` | Asks whether anything comes out of the AESS downlink. It does not, and the header explains why: port tasks only enter the scheduler when a port is enabled, which needs the port-enable path this does not implement. Also records the rule that all ABE access must be 32-bit. |
| `device/pyra-aess-port-enable.py` | Decodes the AESS port table and enables a port's scheduler tasks. Still moves no samples, because a port must first be connected (IO descriptor + ATC). Documents why the remaining work belongs in the driver, not in `/dev/mem`. |
| `experiments/aess/` | Patches 0013–0016 toward using the OMAP5 audio DSP: the AESS DAI links, the firmware's own container format, the mixer controls recovered from it, and one McPDM DAI per path so DL1 and DL2 can be driven separately. `container-check.c` validates the firmware parser with no kernel. All build clean; none has been booted. |
| `device/pyra-freq-profile.sh` | Compares two kernels' cpufreq behaviour: idle residency, the latency of short bursts of work, and throughput, with power when the charger is off. Changes nothing, needs no privileges. |
| `device/pyra-governor-sweep.sh` | Measures what each cpufreq governor setting is worth, one knob at a time, against the `performance` governor as the ceiling. Stops the thermal daemon and pins the frequency ceiling for the length of the run, because the daemon caps on battery temperature and will otherwise move the ceiling underneath the measurement; puts both back on every exit path. |
| `device/pyra-undervolt` | Runs the CPU's 750 MHz point, the clock `pyra-soh` pins, at 870 mV instead of the device tree's 950: −0.16 W and −1.5 °C while Ship of Harkinian runs, frames unchanged. Its systemd unit applies it at boot (on 5.6.19-m4-kbdled only, so the l4 entry stays stock); `set KHZ UV` changes a point on the fly, `off` puts every point back. The module is built by `experiments/undervolt/build-module.sh`. |
| `device/pyra-governor-tune.sh` | Applies the one governor setting the sweep found worth applying, `sampling_down_factor` 1 → 10: 23% off burst latency and a third off the median, for 5.4% more idle frequency. `--check` and `--undo`. Its systemd unit reapplies it at boot, because a sysfs write does not survive one. |
| `device/pyra-thermal-fix.sh` | Makes the stock thermal daemon able to apply its own decision. It calls `cpufreq-set`, which trixie cannot install, so it has never capped a frequency; this writes `scaling_max_freq` instead. Peak temperature under load falls from 100°C to 84°C. Reversible with `--undo`. |
| `device/pyra-thermal-ladder.sh` | Fixes five faults in the same daemon, all invisible until `pyra-thermal-fix.sh` made it able to act: it throttles on the fuel gauge's die temperature rather than the cell, it has no hysteresis, its second ladder can overwrite the first one's deeper cap, it polls every 20 s on a machine that crosses its passive trip in 16, and it watches `core_thermal` while the trip is on `cpu_thermal`. The last two only bite once the first is fixed — the broken ladder kept the machine permanently pre-capped, which was protection by accident. Anchored replacements, refuses a file it does not recognise, `--undo` puts it back. |
| `device/pyra-thermal-probe.sh` | Logs every thermal zone and the CPU ceiling through a load cycle, twice: once with the daemon deciding, and once with it stopped and the ceiling pinned. The first arm shows what the daemon does; the second is the only way to see where the sensors actually sit at full speed, because the daemon's own capping otherwise limits the heat it is being measured against. |
| `device/pyra-ceiling-cost.sh` | Measures what each rung of the thermal ladder costs, in burst latency, in sustained throughput and in watts. A cap that buys no battery life is costing speed for nothing, and that is not answerable from the clock ratio alone. |
| `device/pyra-charge-probe.sh` | Finds out what is actually limiting charging, with the daemon deciding and then with it stopped and the limit lifted to the vendor's own 3 A default. Needs the charger plugged in. |
| `device/pyra-charge-current.sh` | Fix 8. A Pyra on a charger loses charge: the bq24297's input current limit is never set by anything, so it sits at the 500 mA USB floor while the machine draws ~620 mA at idle. Installs a config, a one-line helper and a udev rule that re-applies the limit on plug — it is a register and resets every time. `--check`, `--undo`, and `--emit-into ROOT` for the card prep. |
| `device/pyra-chgwatch.sh` | Watches the charge path once a second and changes nothing: input limit, battery current and voltage, and the charger's own status and fault registers. Needs no root. |
| `device/pyra-cpu-attribution.sh` | Accounts for every busy CPU cycle by process across a window, and splits the rest by kernel class. Read-only. |
| `device/pyra-x-load-profile.sh` | The X server's share of a workload, plus whether the 2D core moved and whether clients use shared memory. Read-only. |
| `device/pyra-anno1602-test.sh` | Runs a 1999 Windows game under box86 and Wine as a bounded, repeatable load, with a thermal guard. |
| `device/pyra-m4-check.sh` | Reports the state of the two Cortex-M4s and the DSP. Read-only, and safe on the stock kernel, so the before and after of installing `5.6.19-m4` can be compared. |
| `device/pyra-m4-run.sh` | Loads the test firmware onto the IPU and proves both M4s are executing it, then removes the firmware again — `auto_boot` means a file left in `/lib/firmware` starts the cores at every boot. Needs `5.6.19-m4`. |
| `device/pyra-m4-demo.sh` | The M4 demo for an audience: both cores' heartbeats live, their clock measured from each core's own cycle counter, a stop and restart that shows the count begin again from zero, and the firmware removed on exit. Needs `5.6.19-m4demo` or `5.6.19-m4`. |
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
