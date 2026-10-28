# The scripts, and what each one does

Every script in `pc/`, `device/` and `experiments/`, one line each. The README has
the few you need to get a card running; this is the rest.

    pc/          run these on your computer
    device/      run these on the Pyra, or install them onto it
    patches/     kernel source patches, applied by the build script
    experiments/ kernel changes on trial, deliberately kept out of patches/
    reports/     findings written up for upstream, drafted but not sent
    docs/        one document per job, listed in the README

Everything is idempotent and refuses to run against anything that is not what
it expects. The scripts that take a device argument write to it, so read the
header comment before the first run. The measurement tools change nothing and
need no privileges beyond reading `/proc`.

## On your computer

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
| `experiments/bookworm-baseline/` | Stock bookworm-7 on the same kernel, captured as the thing to compare against: its X log and `glxinfo` (software GLX through llvmpipe, where trixie crashes), its sound card (no AESS), its full boot log and package list. |
| `experiments/jack-detect/` | Why the headphone jack always read "inserted", on stock as well, and the fix: three kernel patches (the detector's interrupt pin, the sound card using the detector, and the detector driver losing events across suspend and reboot), then PulseAudio switching to the headphones on plug-in. Unplugging is not seen while the headset amplifier is on, a board-level limit still being looked into. In `5.6.19-m4-kbdled`. |
| `patches/` | Seven kernel patches: the candidate display fix, the suspend fix, the fix for the interrupt storm on resume, the fix for the nubs dying on resume, the fix for the keyboard going silent, one that prints an error the driver was discarding, and an upstream backport that stops kprobes panicking. Applied by `pc/pyra-crossbuild.sh kernel-fix`. Every kernel change, including the experiments, is listed in `docs/kernel-changes.md`. |

## On the Pyra

| Script | What it does |
| --- | --- |
| `device/pyra-install-helpers.sh` | Puts every script below onto the device in one step, plus the sysrq settings. Also removes the idle dimmer copies that earlier versions installed, which now come from the `pyra-backlight` package. |
| `device/pyra-install-debug-kernel.sh` | Installs a built kernel beside the stock one and gives it a boot entry, without making it the default. |
| `device/pyra-boot-kernel.sh` | Chooses which kernel boots next, since U-Boot's menu only exists on the serial console. `debug --once` gives a test kernel exactly one boot. `base <label>` sets which kernel the machine returns to, which is no longer always the distro one — its thermal behaviour stops the battery charging. |
| `device/pyra-sleep-test.sh` | Suspends the machine with the clock armed to wake it, says whether it really came back, and names which sleep state the kernel used. |
| `device/pyra-modeset-hang-trap.sh` | Provokes the display hang on purpose, captures the kernel backtrace of the spinning core, and reboots. Read its header first. |
| `device/pyra-gles` | Runs a GLES2 program against the SGX driver instead of glvnd, which is otherwise what it gets and why it draws nothing. Needs no root and installs nothing. |
| `device/pyra-usb3503-rescue` | Re-resets the USB hub when a warm reboot leaves it dead. Installed by fix 5. |
| `device/etc/initramfs-tools/scripts/init-top/pyra-fw-nofallback` | Turns off the kernel's 60 s sysfs firmware fallback before the initramfs's udev starts. Without it a USB ethernet adapter that enumerates early can hold root back by a minute or two. See "Root mounts a minute or two late" in `troubleshooting.md`. Copy it in and run `update-initramfs`; not installed by any script yet. Measured 2026-10-28: 5 cold boots with the adapter plugged in mounted root at 6-10 s. |
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

