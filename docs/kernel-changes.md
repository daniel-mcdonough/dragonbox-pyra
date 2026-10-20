# Kernel changes

Every change made to the Pyra's kernel, in one place: what each patch does, where it
lives, and which kernels carry it. The diagnosis behind each one is in the patch's own
commit message and in the document named against it. Config and runtime tunables are
in `kernel-notes.md`, not here.

The base is the Letux/Pyra **5.6.19** tree (`linux-5.6.19-pyradef`). Patches are
numbered in the order they were written, which is why the directories do not hold
contiguous runs. Two different patches are numbered 0007.

---

## Which kernel carries what

Every variant is built by `pc/pyra-crossbuild.sh <target>` under its own release name,
so each one installs beside the others instead of replacing them.

| Target | Release | Carries |
| --- | --- | --- |
| `kernel-debug` | `5.6.19-softlockup` | Stock source, plus a lockup detector in the config |
| `kernel-fix` | `5.6.19-fix` | `patches/` |
| `kernel-c2` | `5.6.19-c2` | `patches/` + `experiments/c2-idle` |
| `kernel-freq` | `5.6.19-freq` | `patches/` + 0007 (intermediate OPPs) |
| `kernel-oc` | `5.6.19-oc` | `kernel-freq` + 0008 (overclock OPPs) |
| `kernel-m4` | `5.6.19-m4` | `patches/` + 0007 (OPPs) + `experiments/m4-ipu` + `experiments/aess` |
| `kernel-m4demo` | `5.6.19-m4demo` | `patches/` + `experiments/m4-ipu` only. This is what the demo kit ships |
| `kernel-m4-uprobe` | `5.6.19-m4-uprobe` | `kernel-m4` + `UPROBE_EVENTS` |
| `kernel-m4-uprobe-kprobe` | `5.6.19-m4-uprobe-kprobe` | `kernel-m4-uprobe` + `PM_DEBUG`, `PM_ADVANCED_DEBUG` |
| `kernel-m4-kbdled` | `5.6.19-m4-kbdled` | `kernel-m4-uprobe-kprobe` + `experiments/kbd-led` |

**The device runs `5.6.19-m4-kbdled`** (boot entries l5, the default, and l1). l4
(`5.6.19-m4`) is the fallback. The undervolt module and the 0034 GPU module (below) are
installed for m4-kbdled only.

---

## `patches/`: in every kernel except stock and debug

**0001 — omapdrm/dsi: bound the two RX FIFO drain loops.** Two loops in the DSI driver
spin with no limit and no timeout while waiting for the receive FIFO to empty. If the bit
never clears, X pins a core at 100%, cannot be killed, and only a reboot recovers. This
is the candidate fix for the display wedge during modesets. It caps both loops, so the
worst case is a failed modeset. *Candidate: it cannot be confirmed until the wedge stops
happening.* Report: `reports/kernel-omapdrm-dsi-unbounded-rx-drain.md`.

**0002 — omapdrm/dispc: say why the runtime PM put failed.** A bare `WARN_ON` threw
away the error code. It fired twice in 1587 test modesets. This only prints the value,
so the next occurrence says what went wrong. Diagnostic, no behaviour change.

**0003 — mmc: txs02612: do not register hosts the driver cannot serve.** The driver
registers two card hosts even when it has no MMC controller to multiplex, because the
check that should stop it reads `if (1 || ...)`. Their rescan workers hang from boot,
which stops suspend before it gets as far as freezing tasks and leaves the desktop
frozen. This makes the driver refuse to register. Fixes suspend.
Report: `reports/kernel-mmc-txs02612-phantom-hosts.md`.

**0004 — mfd: palmas: hold the interrupt across system suspend.** On resume the PMIC's
interrupt is re-enabled one phase before the i2c bus is usable. The handler can't read
or acknowledge it, so every resume logs hundreds to thousands of `Failed to read IRQ
status: -13`. This keeps the interrupt held until the bus is back. Fixes the interrupt
storm on resume. Report: `reports/kernel-mfd-palmas-resume-irq-storm.md`.

**0005 — input: as5013: restart the poll on resume.** The analogue nubs have no
interrupt line on the Pyra, so the 25 ms poll is the only thing that ever reads them.
Suspend cancels the poll and resume never restarts it, so the nubs die for good after the
first suspend. This restarts it. Report: `reports/kernel-input-as5013-poll-not-restarted.md`.

**0006 — input: tca8418: do not leave the chip asserting an edge-triggered line.** The
keyboard controller's interrupt is a level signal, but it is wired as edge-triggered.
A key pressed between emptying the FIFO and acknowledging the interrupt leaves the line
held low, so no further edge ever arrives and the keyboard goes silent with nothing in
the log. This keeps servicing the chip until it is quiet. Fixes the keyboard going dead.
Report: `reports/kernel-input-tca8418-lost-interrupt.md`.

**0033 — ARM: kprobes: avoid fortify_panic() when copying the optprobe template.** A
backport of upstream ARM 9019/1. With `KPROBES` and `FORTIFY_SOURCE` both on, placing a
kprobe panics, because `memcpy` thinks the 96-byte assembly template is a 4-byte `u32`.
This makes kprobes usable for profiling. Not our bug, and the fix is upstream's. See
`building.md`, patch 7.

---

## `experiments/m4-ipu/`: in all m4 kernels, and the demo kit

The OMAP5's two Cortex-M4s and its DSP, made visible to Linux. Booted 2026-09-20; both M4s
run code. Full story in `m4-ipu.md`. The same four files are in
`dragonbox-pyra-build/kernel/patches/` and are identical to these.

**0009 — remoteproc/omap: backport the device tree driver from v5.9.** 5.6.19's
`omap_remoteproc.c` is the 2011 platform-data driver, which can't probe on a device-tree
SoC, so `CONFIG_OMAP_REMOTEPROC` built dead code. This replaces it wholesale with the v5.9
driver.

**0010 — ARM: dts: omap5: add the ipu and dsp nodes.** The SoC-level description of the two
remote processors, taken verbatim from v5.9. Left disabled.

**0011 — ARM: dts: pyra: enable the ipu and dsp.** Enables both on the Pyra V5.3 board with
upstream's reusable memory carveouts (8 MB DSP, 56 MB IPU), modelled on `omap5-uevm.dts`.
The pages go back to the allocator whenever the processor is stopped.

**0012 — iommu/omap: do not sleep while holding the iommu spinlocks.** Starting the IPU
produced two "scheduling while atomic" BUGs every time, because the attach path resumes a
device that sleeps in its reset while two spinlocks are held. Mainline has the same
code. This turns both locks into mutexes, since every path that takes them can already
sleep. A real upstream bug. Report: `reports/kernel-iommu-omap-sleep-under-spinlock.md`.

---

## `experiments/aess/`: in all m4 kernels except m4demo

Brings up the OMAP5's audio DSP (the AESS/ABE) between the CPU and the McPDM link to the
codec. Upstream left it dead. **Status 2026-09-24: it plays, and it is the audio path of
the m4 kernels.** Most of the code was recovered from the unbuilt `sound/soc/omap/`
rather than written new. Details in `experiments/aess/README.md` and `audio.md`. Reports
are indexed in `reports/letux-aess-INDEX.md`.

| # | What it does |
| --- | --- |
| 0013 | **Build the AESS DAI links.** The function that should create them was an empty stub, so the AESS component was never bound, its probe never ran, and every register access was silently dropped. One root cause behind several apparent bugs. |
| 0014 | **Load the firmware's own container format.** `omap_aess-adfw.bin` from linux-firmware was rejected as an invalid topology file. This parses the container it actually is. |
| 0015 | **Add the mixer controls.** The firmware boots with all 36 gains muted, and nothing in userspace could raise them. This adds the gains as ordinary ALSA controls. |
| 0016 | **McPDM: one DAI per path.** McPDM had one DAI that could express "headset" or "headset + speakers" but never "speakers" alone. This splits it so the ABE can drive DL1 and DL2 independently. |
| 0017 | **Run the AESS init sequence.** The memory and scheduler setup sat inside an `#if 0`, so closing any PCM hit a NULL map, oopsed and left the card wedged. Written from the first boot's failure. |
| 0018 | **The memory banks are 8 KiB, not 4.** Probe died in `memcpy` loading firmware parameters past a wrongly sized bank. |
| 0019 | **Add the DAPM graph.** The card came up but opening a PCM returned -EINVAL, because there was no routing path from a front end to a back end. This adds the playback graph. |
| 0020 | **dts: restore the AESS audio routes.** Routes the codec's downlink streams to the AESS back ends in the board device tree. |
| 0021 | **Convert the PCM ops to component callbacks.** They were commented out, so the platform supplied no period or buffer limits and every open failed hw_refine. |
| 0022 | **Open the McPDM back-end ports.** The stream ran and the DSP processed it, but nothing fed McPDM's FIFO, so it was silent. |
| 0023 | **Enable the McPDM back-end ports.** Port enable skipped McPDM with "handled by the McPDM driver", and no driver handled it. Without this the DSP's downlink tasks were never scheduled. |
| 0024 | **Keep a known-good reference path.** `legacy_link=1` adds the direct, DSP-bypassing McPDM link as a second PCM, so "the DSP is silent" can be told apart from "the codec or speakers are silent". |
| 0025 | **Start McPDM after the AESS port.** Follows TI's documented start order: AESS port, wait 250 µs, then the serial port. |
| 0026 | **Size the ping-pong buffer from the firmware.** The firmware cycles four buffers, not two, so real audio came out as pulsing noise. A steady sine hid it. |
| 0027 | **Stop McPDM from the trigger.** Playback ended in a burst of static, because McPDM kept sending stale FIFO contents until close. |
| 0028 | **Don't write uninitialised equaliser coefficients.** With the legacy firmware container, every equaliser was loaded from uninitialised stack memory. Now the firmware's own coefficients are left in place. |
| 0029 | **Don't advertise 44.1 kHz.** 44.1 kHz streams were clocked at 48 kHz and played 8.8% fast, about a semitone and a half sharp. Real 44.1 kHz needs the whole ABE timebase changed, so this offers 48 kHz only and leaves resampling to userspace. |
| 0030 | **Pop every downlink slot for the ABE.** The DSP writes six samples per frame and McPDM popped four, which aliased everything around a 2.67 kHz carrier. |
| 0031 | **Never report the pointer going backwards.** For one read per buffer switch the position was a period behind. ALSA took that as a wrap, PulseAudio thought it underran and rewrote the ring, and resampled audio skipped back 128 to 384 ms like a scratched record. |
| 0032 | **Don't map DMEM into userspace.** DMEM keeps only 32-bit stores, so mmap'd writes of any other width lost samples (crackle, or silence through alsa-lib's rate plugin). This drops mmap and copies with 32-bit stores. |

---

## Smaller device-tree and driver changes

**0007 (`thermals-and-frequency/`) — ARM: dts: omap5: add the intermediate OPPs below
1.5 GHz.** Fills the 250 MHz gaps between the six stock CPU steps with five more, on the
same voltage curve, so ramps are finer and the thermal cap has more places to land. The
stock steps keep their voltages. *In `kernel-freq` and all m4 kernels, so it is on the
running kernel.* The directory's README still says nothing in it was ever booted; that
predates m4 picking up 0007.

**0008 (`thermals-and-frequency/`) — ARM: dts: omap5: add the OPPs above the part's
rating.** Raises the ceiling from 1.5 to 2 GHz on a 1.5 GHz-rated part, using voltages
from a third-party unit with a modified heatsink. *Only in `kernel-oc`. Never booted
here, deliberately.* The risk is to hardware, not just stability.

**0035 (`kbd-led/`) — ARM: dts: pyra v5.3: make the keyboard light an LED.** The keyboard
light was a second `pwm-backlight`, so desktop tools that pick "the" backlight drove the
keyboard instead of the panel. This declares it as `pyra::kbd_backlight`, which UPower and
systemd look for. *In `kernel-m4-kbdled`, the running kernel.* It moves the sysfs path,
so anything hard-coding `/sys/class/backlight/keyboard-backlight` breaks.
Report: `reports/pyra-kernel-kbd-backlight.md`.

**0034 (`gpu-power/`) — pvrsgx: let the SGX power domain go off at idle.** The GPU driver
takes a runtime-PM reference at probe and only gives it back at remove, so the GPU never
powers down while the driver is loaded. That costs about 0.22 W at desktop idle. This
balances the reference and lets the power domain autosuspend after 100 ms. *Not built into
any kernel.* It is installed as a rebuilt module at
`/lib/modules/5.6.19-m4-kbdled/updates/` since 2026-09-26. If m4-kbdled is rebuilt, that
module still loads unless it is rebuilt too or deleted. The README says the durable form
is "0034 in `patches/`", but it is not there. It is still only in `experiments/gpu-power/`.
Report: `reports/kernel-pvrsrvkm-runtime-pm-reference.md`.

**`undervolt/pyra_undervolt.ko` — out-of-tree module, not a patch.** Changes one CPU
operating point's voltage at runtime. The 750 MHz point runs at 870 mV (stock 950),
saving 0.16 W with no change in frame output. Applied at boot by `device/pyra-undervolt`
since 2026-09-29. It refuses to act on any kernel but `5.6.19-m4-kbdled`, so booting l4
undoes it.

---

## Tried and rejected

**0007 (`c2-idle/`) — ARM: OMAP5: enable the C2 retention idle state.** The Letux tree
`#if 0`s out OMAP5's deeper CPU idle state, which mainline keeps, and upstream measured
it saving about 0.8 W on the uEVM. Restoring it **hung the machine** 48 and 74 seconds
after boot, with no log output. Built only as `kernel-c2`. Kept with its result in
`experiments/c2-idle/RESULT.md` so nobody repeats it.

---

## Not kernel changes, but kept beside them

These live in the same experiment directories and are easy to mistake for kernel
patches:

- `kms-plane/armsoc-0001-leavevt-drop-drm-master.patch` and `dragonbox-pyra-build/ddx/patches/0001-leavevt-drop-drm-master.patch`: the X armsoc display driver, not the kernel.
- `gpu-tools/apitrace-pyra-waitnative.patch`: apitrace's `eglretrace`.
