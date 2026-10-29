# Verification log

> **Type: log.** A dated record of what was done and found: history, not instructions.

What was checked, when, and what it established. The procedure is `procedure.md`.

## Pre-flight results — pyra-trixie-t1.img, checked 2026-09-08

Ran against the loop-mounted image on an x86_64 Arch host. Image is 6 GiB,
`PRETTY_NAME="Debian GNU/Linux 13 (trixie)"`, 862,273,362-byte archive matching
the upstream `content-length`.

| Assumption | Result |
| --- | --- |
| Rootfs is ext4 | **Wrong — it is f2fs.** `modprobe f2fs` to mount it |
| `armsoc_dri.so` missing | Confirmed missing; fix 1 needed |
| `kms_swrast_dri.so` exists | Confirmed, symlink into mesa 25.0.7's `libdril_dri.so` |
| First-run script in `/usr/bin` | **Wrong — `/usr/share/pyra/scripts/pyra-first-run.sh`** |
| Marker is `/var/lib/pyra/first-run.done` | Confirmed, and it is the unit's `ConditionPathExists=!` |
| Wizard is enabled | Confirmed, symlinked into `graphical.target.wants` |
| `pyrainput.service` missing | Confirmed; bookworm's `.deb` has it, trixie's does not |
| `funkeymonkey` + `libpyrainput.so` present | Confirmed |
| `/etc/pyrainput.cfg` present | **Missing** — shipped by no package in either suite |

Other things worth knowing, all confirmed by inspection:

- **U-Boot SPL lives in the raw sectors before partition 1**, not in a
  filesystem. This is why `dd` must target the whole device. Writing to a
  partition produces a card that cannot boot at all.
- The image has **no user accounts** at all (nothing at uid >= 1000, empty
  `/home`), so the wizard is the only thing that would have created one. Skip
  it without creating a user offline and you have no way to log in.
- Every group the script wants — sudo, video, audio, netdev, plugdev,
  bluetooth, dialout, input, render, games, cdrom, floppy — exists in the
  image, so none get skipped.
- The display manager is **lightdm**, not slim, despite the wizard still
  carrying slim-theme code.
- The wizard calls `poweroff` on its *success* path too, not only on cancel.
  So even a wizard that worked would end in a shutdown.

## Prep script checked against the image — 2026-09-09

`pyra-prep-selftest.sh` run as root against a copy of `pyra-trixie-t1.img`.
This is the check that the written procedure and the running machine have not
drifted apart. Six changes to the rootfs, and no others across 148,313 nodes:

| Change | Fix |
| --- | --- |
| removed the `armsoc_dri.so` symlink | 1 |
| wrote `/etc/X11/xorg.conf.d/20-pyra-glx.conf`, 0644 | 4 |
| created `/var/lib/lightdm/data`, 0750, uid 105 gid 108 | 4 |
| installed `/usr/local/sbin/pyra-usb3503-rescue`, 0755 root:root | 5 |
| installed `/etc/systemd/system/pyra-usb3503-rescue.service`, 0644 root:root | 5 |
| enabled the rescue in `multi-user.target.wants` | 5 |

Fixes 2 and 3 reported everything already in place, correctly — this image was
given them on the 8th.

Also confirmed: a second run changes nothing at all, both fix 5 payloads on the
target are byte-identical to the repository copies, `/usr/local/sbin` keeps the
mode it had, the missing-payload abort fires before fix 1 removes anything, and
`fsck.f2fs --dry-run` afterwards reads checkpoint `trimmed crc unmount` with
every node and inode count matched.

## Card as written — 2026-09-08

128 GB SDXC, factory exFAT, confirmed empty before writing. The fixes were
applied to the loop-mounted image first, so the card was written once, already
fixed, and step 4 was not needed.

Verified after writing:

- Readback of the first 6 GiB off the card is md5-identical to the fixed image.
- Partition table reads back as `boot` (ext2) and `rootfs` (f2fs) with
  PARTUUIDs `21a4c285-01` and `-02`, matching what `fstab` and `extlinux.conf`
  reference.
- U-Boot SPL is present in the raw gap on the card.
- All three fixes present on the card's own filesystem, with `armsoc_dri.so`
  resolving to a real file rather than dangling.
- User `pyra` exists at uid 1000 with a `$6$` hash, `/home/pyra` owned 1000:1000
  and populated from skel, and `gshadow` agreeing with `group` on every group.

Two things left open, both only resolvable by booting:

- **113 GB of the card is unused.** The image is 6 GiB and nothing grows the
  rootfs on first boot. Expanding it means growing p2 and running `resize.f2fs`,
  which is worth doing only after the card is known to boot.
- **The rootfs was mounted read-write by a Linux 7.1 host to apply the fixes,
  and the Pyra runs 5.6.19.** The superblock feature set is unchanged (`encrypt`
  only, set at mkfs time) and it unmounted with a clean checkpoint, so this
  should be fine, but it is the one step that was not verifiable offline.

## Boot result — 2026-09-08

The card boots. The long-press quirk in step 5 is real and remains the first
thing to check if it appears not to.

What works:

- Boot through to multi-user, with networking.
- SSH in as the `pyra` account the prep script created, at <pyra-address>.

What does not:

- **lightdm fails and no desktop appears.** Unknown whether this is fix 1
  incompletely covering the Xorg problem, a lightdm configuration issue, or
  something else. The forum writeup only ever claimed a working desktop via
  the bare `xinit` session the first-run wizard used, which is not the same
  code path as lightdm starting a session.

Not yet checked on hardware: whether `pyrainput` actually starts and produces
the three input devices, whether the empty `/etc/pyrainput.cfg` is accepted,
and whether GLES2 through the SGX blob works. Since SSH works, all of that is
now debuggable on the device instead of by pulling the card.

## Desktop fixed, hardware verified — 2026-09-08

Done over SSH on the running unit. lightdm now starts, the GTK greeter renders
on the panel at 1280x720, and the `pyra` user is offered in the user list.

**lightdm itself was never at fault.** `/var/log/lightdm/lightdm.log` shows it
launching `/usr/bin/X :0 ... vt7`, that process dying on signal 6 within 250 ms,
and lightdm giving up after five restarts and hitting systemd's start limit.
The whole failure was the Xorg segfault described under fix 1. Fix 4 resolves
it. A cosmetic warning about a missing `/var/lib/lightdm/data` is unrelated;
create the directory owned by `lightdm` to silence it.

Confirmed working on hardware:

| Thing | Result |
| --- | --- |
| lightdm + greeter | Renders on the panel; MATE is the installed session |
| Display | 1280x720, panel native 720x1280 rotated right |
| X extensions | `DRI3` and `Present` present, `GLX` absent by design |
| `pyrainput` | Active, no restart loop; empty `/etc/pyrainput.cfg` accepted |
| pyraInput devices | All three present: keyboard, Gamepad, Mouse |
| Audio | 5 ALSA cards; the real one is card 4, `Letux Cortex 15` (TWL6040) |
| PulseAudio | Running for the user session (not pipewire) |
| Wifi | `wlan0` up, scans and lists access points |
| Bluetooth | `hci0` UP RUNNING, valid BD address, HCI 4.1 |
| Battery | `bq27421-0` fuel gauge reporting capacity and current |
| Charging | `bq24297` charger present |

Fix 3 is therefore fully validated on hardware: the restored unit starts, and
the empty config file the prep script creates is accepted with no complaint.

Note on the charger: the `bq24297` reports `status=Not charging` and `online=0`
while the `bq27421-0` fuel gauge simultaneously reports `status=Charging` with a
positive `current_now`. Trust the gauge's capacity trend over either status
string.

## Post-desktop configuration — 2026-09-09

Applied on the running unit, over SSH.

**`pyra-usb3503-rescue.service`.** Installed by hand here, and diagnosed here.
It is now fix 5 and the prep script applies it offline, so a card built from
this document has it before its first boot. See fix 5 above.

**`firmware-realtek`.** The RTL8153 USB ethernet adapter was running without its
firmware: `Direct firmware load for rtl_nic/rtl8153a-4.fw failed with error -2`.
It worked anyway on the driver's fallback path, but installing the package and
rebinding gets `load rtl8153a-4 v2 02/07/20 successfully` and a clean link.

**Wifi.** Worth configuring before you ever reboot remotely — see the USB note in
troubleshooting. `wlan0` associates and gets a lease normally through
NetworkManager.

**Hardware GLES2 confirmed.** See section 6 for the numbers. This is the check
that matters after fix 4, since it proves disabling GLX cost nothing on the path
that was ever fast.


## Performance measurement and the display hang — 2026-09-10

All on the running unit over SSH, against the trixie card.

**Whole-machine CPU attribution works and is cheap.** `pyra-cpu-attribution.sh`
samples every `/proc` entry once a second and tracks first and last counters per
pid, so processes that start and finish inside the window are still counted, and
splits the remaining busy time by kernel accounting class. Checked against
`/proc/stat` totals: 78% to 93% of busy time lands on named processes and the
rest is hard IRQ, which is exactly what cannot belong to a process.

**PulseAudio's cost is conversion, and it is not tunable.** Thirty seconds of the
same audio, three times, via `paplay`: 10.3% of one core at 22050 Hz, 11.1% at
44100 Hz, 3.5% at 88200 Hz. `aplay --dump-hw-params` on the codec gives
`FORMAT: S32_LE` and `RATE: [88200 96000]`, so there is no rate to match without
conversion. Ruled out by direct test, not by reasoning: `resample-method` is
already `trivial`; the daemon logs `sconv_neon`, `mix_neon` and `remap_neon` all
initialising; and playing to the raw ALSA sink instead of through the remap sink
measures 10.6% against 10.5%, so the extra layer is free.

**The i2c interrupt rate is 858 a second at idle**, against 211 for the system
timer. Stopping `pyrainput.service`, the only holder of the nub input devices,
changes nothing: 457/s running, 451/s stopped, 455/s restarted. There is one
cpuidle state, `C1`.

**Every DPMS transition is a full modeset.** Counted in the X log, one action at
a time: three ordinary windows 0, `xset s off` 0, `xset s default` 0,
`xset -dpms` 1, `xset dpms force off` 1, `xset dpms force on` 2, one `x11perf`
run 2. A normal desktop session does three at startup and then none.

**The hang reproduces and both earlier explanations were wrong.** It is not idle
blanking: the second hang happened with `xset s off -dpms` already in effect. It
is not the compositor: `compositing-manager false` gives the same two modesets
per `x11perf` run. When it wedges, `OMAP DISPC` in `/proc/interrupts` goes from
about 10 a second to 0, `Xorg` sits in state `R` at 99% of one core, `SIGKILL`
does not land, and `systemctl restart lightdm` hangs `deactivating`. Logs from
both instances were kept on the device before rebooting.

**The compositor costs what it appears to cost.** Measured against the game,
because `x11perf` cannot be used here. Absolute figures do not compare across
runs — the game's own CPU ranged from 30% to 88% of a core — but ratios to it
do. `Xorg` was 0.243, 0.246 and 0.240 of game CPU across two runs with
compositing on and one with it off. `marco` was 0.064 and 0.068 with it on, and
below 0.010 with it off.

**Autologin verified end to end.** After `systemctl restart lightdm` and again
after a full reboot: no greeter process, a `seat0` session for the account,
`Desktop=lightdm-xsession` matching what a greeter login produces, and marco,
mate-panel and caja all up.

## 2026-09-11, night — the fifth patch, on hardware

**Both nubs now survive a suspend.** The i2c controller they sit on carries
almost nothing else, so its interrupt rate is a direct read-out of whether the
driver's 25 ms poll is running. Nobody has to touch the nub for this, which
matters, because the previous attempt to measure this by hand produced a false
reading.

| | poll rate on `48072000.i2c` |
| --- | --- |
| unpatched, before suspend | 450/s |
| unpatched, after resume | **0/s** |
| unpatched, after `systemctl restart pyrainput` | 450/s |
| patched, at boot | 466/s |
| patched, after suspend to idle | 455/s |
| patched, after deep sleep, first cycle | 475/s |
| patched, after deep sleep, second cycle | 458/s |

The zero is the fault, reproduced on demand on the first attempt after a year
of it being recorded as intermittent. It is not intermittent. Three cycles on
the patched kernel, one `freeze` and two `mem`, and the poll never stopped.

**Resume stayed quiet with the fifth patch on top.** Eight PMIC interrupt
deliveries across one wake, no `Failed to read IRQ status` anywhere in the log,
and `FreezerState=running` afterwards, so the session thaws.

**The three known per-resume warnings are unchanged**, which is what should
happen: `Unbalanced enable for IRQ 144` from the SGX, `unbalanced disables for
otg_path`, and four `DSI error: VC(n) busy` lines. The patch introduced nothing
new to the log.

**The power button wakes the machine.** Closed later the same night, on the
six-patch kernel. A suspend to RAM, woken by pressing the button, with the
button's own delivery count in `/proc/interrupts` moving from 1 to 2 across the
wake and its `wakeup_sources` event count doing the same. The nub poll read
505/s afterwards and the keypad's two registers read `0x00`, so that wake
exercised all three input fixes at once.

How long it stayed down is not knowable from that log. The kernel's monotonic
clock does not advance across a deep suspend on this SoC, so the 2.1 seconds
between the entry and the exit line is the cost of going down and coming back,
not the time spent asleep. Measured against the real-time clock a 30 second
deep suspend also shows about 1.8 seconds of monotonic time, which is what
establishes that reading. The duration does not matter to what was being
tested: the window the fourth patch holds the interrupt across is entered and
left regardless of how long the machine stays down.

## 2026-09-11, late — the keypad controller, caught stuck

**The fault was read off the chip, not inferred.** With the keyboard completely
dead at a login prompt, the TCA8418 at `1-0034` reported:

| register | reading | meaning |
| --- | --- | --- |
| `0x02` | `0x01` | key interrupt pending, so the pin is asserted |
| `0x03` | `0x0a` | ten key events queued |

The interrupt's enable depth in `/sys/kernel/debug/irq/irqs/169` was 0, so
nothing had disabled it, and its count in `/proc/interrupts` was frozen at 5
for the whole boot. `pyrainput` was running with all four raw devices attached,
and restarting it changed nothing. Nothing was logged at any point.

**Unbind and rebind does not recover it.** After both, the same two registers
still read `0x01` and `0x0a`. That is the evidence that the driver's startup
path never clears the chip, which is half of `patches/0006`.

**Reading the queue out by hand fixed it immediately.** Ten reads of register
`0x04` took the count to zero, one write of `0xff` to `0x02` cleared the
status, and both registers then read `0x00`. The interrupt count went 5, 10,
17, 19, 32, 41 as the operator typed, having not moved at all for the previous
twenty minutes.

**Not verified.** That `patches/0006` prevents it. The race needs a keypress
inside a window of a few milliseconds and has not been provoked deliberately.
The patch is reasoned from the registers above and the driver source, and it
compiles, which is a weaker claim than the one made for the nub fix on the same
day. Treat it as untested until the keyboard has survived a long stretch of
ordinary use.

## 2026-09-12, small hours — what the machine will and will not do for sleep

Prompted by the question of whether a standby state exists here. Run on the
six-patch kernel, `5.6.19-fix` build 10. The machine was on external power
throughout: the gauge read `Charging` at 95 mA and gained charge across the
session, even though the charger's own `online` said 0.

**`standby` is not offered and was refused.** `/sys/power/state` reads `freeze
mem`. Writing `standby` to it failed and changed nothing; `/sys/power/state`
read the same two words afterwards and `/sys/power/suspend_stats/fail` stayed
at zero, so it was rejected before any attempt rather than tried and aborted.
The source agrees: `arch/arm/mach-omap2/pm.c` gives `omap_pm_ops` a `.valid` of
`suspend_valid_only_mem`, and its `omap_pm_enter()` has no case but
`PM_SUSPEND_MEM`.

**Both of the states that do exist work.** Three rounds, each woken by the
real-time clock, each returning with `user.slice` thawed:

| Path | Armed for | Wall clock | Kernel entry line |
| --- | --- | --- | --- |
| `freeze` | 30s | 31s | `PM: suspend entry (s2idle)` |
| `mem` | 30s | 31s | `PM: suspend entry (deep)` |
| `mem` | 20s | 21s | `PM: suspend entry (deep)` |

**The deep path still does not reach its target state.** Every `mem` round
logged the same five `didn't enter target state` lines and the same seven
clocks that refused to stop, which is what was already recorded for the stock
kernel. Nothing about the six patches changed it, and nothing was expected to.

**The kernel log's timestamps do not measure how long it slept.** A thirty
second deep suspend shows 1.8 seconds between `PM: suspend entry` and `PM:
suspend exit`, because that clock does not advance while suspended.
`/proc/uptime` does advance, by the full thirty seconds, so the two disagree by
exactly the sleep. Neither is evidence about power: the earlier reading of the
power button's log, which took a 2.1 second gap for a short suspend, was
reading the resume cost.

**Nothing new appeared in the log.** The three per-resume warnings are the ones
already listed: `Unbalanced enable for IRQ 144` from the SGX blob, `unbalanced
disables for otg_path`, and four `DSI error: VC(n) busy` lines. All three
occurred on the s2idle path as well as the deep one, so neither path is worse
than the other.

**Not measured.** What either state saves. The only instrument is the fuel
gauge's coulomb counter and the machine was on external power throughout, so
every reading was of the charger. The procedure for measuring it properly is in
`docs/troubleshooting.md`.

## 2026-09-12, small hours — where standby went, checked against mainline

Follow-up to the entry above, which established that this machine offers no
standby state. The question was whether any OMAP ever did.

**No OMAP generation in this tree offers it.** `arch/arm/mach-omap1/pm.c` and
`arch/arm/mach-omap2/pm.c` both register `.valid = suspend_valid_only_mem` and
both have an enter callback whose only case is `PM_SUSPEND_MEM`. Twelve
platforms under `arch/arm` implement `PM_SUSPEND_STANDBY` at all; TI appears
among them only as `drivers/soc/ti/pm33xx.c`, which is Sitara rather than OMAP.

**The chip does have the state standby would name, and this kernel switches it
off.** The device reports one cpuidle state:

| | |
| --- | --- |
| driver | `omap5_idle` |
| states | 1 |
| `state0` | `C1`, `CPUx WFI, MPUSS ON`, latency 4 us |
| usage at 30 min uptime | 1330364 entries |

Mainline defines a second, `C2`, `CPUx CSWR, MPUSS CSWR`, which puts both cores
and the surrounding subsystem into retention. The Pyra's tree wraps both the
state table entry and the driver entry in `#if 0`.

**That is a local change, confirmed by diff.** Mainline `v5.6`'s
`arch/arm/mach-omap2/cpuidle44xx.c` fetched from the torvalds tree has no `#if
0` anywhere in the file; neither does the current master. The only differences
between mainline `v5.6` and this tree's copy are the two `#if 0`/`#endif` pairs
around the OMAP5 `C2` state and the addition of a separate DRA7 driver, which
keeps its own `C2` enabled. The Debian packaging diff does not touch the file,
so the change arrived in the source tarball.

**What upstream measured when it added the state.** Commit `7abdb0e23e7b`, 2016,
reports idle power on the omap5-uevm falling from about 1.7 W to about 920 mW
with `C2` enabled. A reference board is not a Pyra and the figure does not
transfer, but nothing else on the performance list is of that size.

**Not established.** Why this tree disables it. The `#if 0` carries no comment
and the packaging says nothing. Treat re-enabling it as an experiment that can
hang the machine, not as a fix.

## 2026-09-12, small hours — the retention idle state, tried and rejected

`experiments/c2-idle` restores the OMAP5 cpuidle state this kernel tree removes.
Built as `5.6.19-c2`, the six-patch kernel plus that one change, installed
beside the others and booted.

**The patch takes effect, provably.** In the built object, `omap5_idle_data`
grows from 16 bytes to 32, one `idle_statedata` to two, matching
`dra7_idle_data` which has always had both. Comparing strings does not
distinguish the kernels: the DRA7 driver in the same file carries the same
description text in both.

**The governor uses the state heavily.** One minute after boot, first core:

| state | entries | time in state |
| --- | --- | --- |
| `C1`, `CPUx WFI, MPUSS ON` | 24150 | 15.9 s |
| `C2`, `CPUx CSWR, MPUSS CSWR` | 25367 | 31.7 s |

**The machine hangs.** Two boots on it, from the journal's own boot list:

| boot | kernel | first to last log entry |
| --- | --- | --- |
| -5 | `5.6.19-fix` | 1 h 15 min, ended by a clean shutdown |
| -4 | `5.6.19-c2` | 48 s, ended mid-log |
| -3 | `5.6.19-pyradef` | 2 min 14 s, ended by a clean shutdown |
| -2 | `5.6.19-c2` | 1 min 14 s, ended mid-log |

Both C2 boots stop with no warning, no backtrace, no watchdog line and no
response on either address. The second one stops within seconds of a successful
SSH command, so it was alive and answering immediately before.

**Two candidate causes were checked and eliminated.** The `L3 Custom Error`
warning from the interconnect and a `blocked for more than 30 seconds` hung
task in the USB ethernet adapter's probe both appear on the C2 boots. Counting
them across all eight boots in the journal shows both on every fix and stock
boot as well, including the healthy one running now. Neither is a signature of
this fault.

**Not the display hang.** That one spins a core and leaves the machine
reachable; its backtrace trap depends on that. This takes the network with it.

**Not established.** What actually goes wrong. Nothing reaches the disk, so
the next step would need a serial console rather than another rebuild.

**Machine state afterwards.** Back on `5.6.19-fix`, SHA-256
`f47b212128eb20cf8f1313b41a9392a29aa68f6cd3950a7e9850ba7f84ddda71`, the same
kernel as before the experiment. The experiment kernel was removed afterwards,
leaving the stock, lockup-detector and fix kernels; `/boot` is back to 41%
used, which is where it was before the experiment.

## 2026-09-12 — the prep selftest, with the sixth fix in it

`sudo ./pc/pyra-prep-selftest.sh` against a copy of the real image,
loop-mounted, on the workstation.

**31 passed, 0 failed.**

This is the run that matters for fix 6, because everything before it had been
exercised against a synthetic rootfs in a container. The selftest uses the
genuine vendor `pyra-thermal.sh` on the genuine card layout, which is the only
place the transformation meets the file it was written for.

What it established for the new fix, beyond the two obvious assertions that no
`cpufreq-set` call survives and that something writes `scaling_max_freq`:

| Checked | Result |
| --- | --- |
| The vendor original is kept on the card | Present as `pyra-thermal.sh.before-pyra-thermal-fix`, so the card carries its own undo |
| The vendor's thermal ladder is untouched | Same number of ladder decisions before and after |
| The patched daemon parses | `bash -n` clean, so the card cannot boot with a dead daemon |
| Prep's output matches the device script | Byte for byte against `pyra-thermal-fix.sh --emit-patched`, so there is demonstrably one implementation |
| A second run changes nothing | Whole-rootfs snapshot identical, and the log says "already applies" |

The existing guarantees held with the new fix in place: the before-and-after
rootfs snapshots show no write outside what the six fixes claim, the second run
leaves the filesystem byte-identical, the missing-payload abort still happens
before fix 1 removes anything, and `fsck.f2fs` is clean afterwards.

## 2026-09-13, evening — the thermal ladder on hardware, and the regression it caused

`device/pyra-thermal-probe.sh` on the live machine. Every thermal zone, the
frequency ceiling, the current frequency and the battery current, logged every
five seconds through an idle → one-core-load → idle cycle. **Stock V5.3, stock
heatsink and factory thermal interface, no coating, no aftermarket compound,
case closed, on battery** except where a run says otherwise. Two arms: *vendor*,
the daemon running and deciding, and *pinned*, the daemon stopped and the
ceiling held at the top of the table, which is the only way to see where the
sensors sit with nothing intervening.

This is the run that matters for fix 7, because every fault in it is a decision
the daemon makes at a temperature, and nothing before fix 6 could make those
decisions visible — until `cpufreq-set` was replaced the daemon had never
applied a cap at all.

**Fault 1, the sensor.** One core of load, machine discharging gently throughout:

| t | `core_thermal` | `bq27421-0` | ceiling |
| --- | --- | --- | --- |
| 182 s, load starts | 55.4°C | 42.2°C | 1500000 |
| 213 s | 70.6°C | 44.6°C | **1250000** |

The gauge rose 2.0°C inside ten seconds with nothing putting current through the
cell, which settles what it is measuring: its own die, on the mainboard. Across
that whole run the core peaked at **71.0°C** and its own ladder — first rung
77°C — was never consulted once. The cap also outlived its cause, still at
1250 MHz **350 s** after the load stopped with the core back to 57.4°C, because
the board cools slowly back through 44°C.

**Fault 2, no hysteresis.** Twelve ceiling changes in that single run, seven of
them inside a 116-second window with the gauge between 44.8 and 45.5°C, and four
more during the *idle* phase with the machine doing nothing. That is the
1.5/1.25 GHz oscillation this hardware is known for, measured.

**Where the new rungs came from.** Pinned arm, nothing capping, so the board
sensor could be read against the core ladder it is supposed to back up:

| `core_thermal` | `bq27421-0` |
| --- | --- |
| 59.0°C (idle) | 44.5°C — *already past the vendor's first rung* |
| 77°C — the core ladder's first rung | **48.4°C** |
| 86.2°C (peak) | 50.5°C |

The two ladders are inverted: the board has already demanded 750 MHz, three
rungs deeper, by the moment the core first reaches its own first rung.

**Verification, one core, daemon active, the machine as a person would use it:**

| ladder | ceiling changes | core peak | `cpu_thermal` peak |
| --- | --- | --- | --- |
| vendor, capping on the gauge at 44°C | 12 | 71.0°C (throttled) | — |
| fixed, 2°C band | 7 | 85.0°C | 91.3°C |
| **fixed, 5°C band** | **2** | **81.8°C** | **88.7°C** |

The 2°C band was tried first and is below this controller's noise floor — the
core moves up to 6°C between five-second samples on one core, and 10°C on two,
so across one poll it travels further than any small band. It released correctly
and still crossed the same rung six times in four minutes. A full rung caps once,
holds for the load and releases on idle, and because holding regulates better
than oscillating it is also **cooler**: peak down from 91.3°C to 88.7°C.

Applying and reverting the fix on the live machine inside the same minute, at
the same board temperature, moves the ceiling 1250000 ↔ 1500000. That is the
cleanest single demonstration that the ladder and nothing else was responsible.

**Every figure in this entry was recomputed from the committed TSVs while writing
it**, rather than copied from the prose, and one moved: the 5°C band's
`cpu_thermal` peak is 88.7°C, not the 88.0°C published on the day. Everything
else reconciles exactly — both other rows of the table, the twelve vendor ceiling
changes (a thirteenth counts only if the file's `done` terminator is mistaken for
a sample), the seven inside the 116-second window, the four in the idle phase,
the 71.0°C core peak, the two-core ramp sample for sample, and all three A/B
peaks at 74.4, 102.0 and 87.0°C. The three figures the upstream report quotes
— 74, 102 and 87°C — are the ones that check out exactly.

**Then two cores failed, and it was this fix that broke them.** Recorded here
because it is a regression this change introduced, not a pre-existing hazard it
merely exposed — the first write-up claimed the latter, before the A/B had been
run, and was wrong:

| ladder | starting ceiling | two cores flat out | `cpu_thermal` peak |
| --- | --- | --- | --- |
| vendor | **750000** | ceiling never moved | **74°C** |
| corrected, poll untouched | **1500000** | aborted | **102°C** |

The vendor was sitting at 750 MHz because the board was at 47°C, and two cores
at 750 MHz is harmless here. That accidental pre-cap was doing real safety work.
The ramp says why 20 seconds cannot: `cpu_thermal` went 63.2 → 98.1°C in
**sixteen seconds** from a 63°C idle, and led `core_thermal` by up to 12°C while
doing it, so the daemon's next look landed after the trip and on the cooler of
the two sensors.

Hence faults 4 and 5 in the same change, and the end state:

| configuration | two cores flat out | outcome |
| --- | --- | --- |
| as shipped, pre-capped at 750 MHz | 74°C | safe, but throttled at idle too |
| ladder corrected only | 102°C | aborted |
| **ladder corrected, 2 s poll, both sensors** | **87°C** | **ran to completion** |

It caps within two seconds of the ramp, hunts briefly, holds 1000 MHz for 205 s
and releases once idle.

**What the 2-second poll costs**, since this is a fanless handheld and idle power
is a live concern. Three 300-second windows, bracketed 2 s / 20 s / 2 s so drift
shows up as disagreement between the first and third:

| interval | daemon CPU over 300 s | share of one core | idle mean frequency |
| --- | --- | --- | --- |
| 2 s | 349 jiffies | 1.163% | 392 MHz |
| 20 s | 32 jiffies | 0.107% | 392 MHz |
| 2 s (repeat) | 355 jiffies | 1.183% | 397 MHz |

About **1.07% of one core**, half a percent of the machine, and it does not
appear in frequency residency at all — idle mean frequency is the same to within
a percent, and the proportion of idle spent at the top step was *highest* in the
20-second window (2.10% against 1.35% and 1.89%), which is noise in the
direction opposite to the one a cost would predict.

**The honest cost, stated because it is a cost.** The machine now runs hotter
than fix 6 alone left it: 88.7°C on one core and 87.0°C on two, against 84°C with
fix 6 alone. Fix 6 got that margin by throttling at 70°C for no thermal reason.
Nothing here approaches the 107°C that fix 6 was written to stop.

**Not established by this run.** The board rungs (54–62°C) are calibrated on this
one stock unit and are overridable for exactly that reason — cooling work moves
that sensor 20–23°C and they would never fire. And this is the live machine
only: prep's offline application of fix 7 has not been checked, because the prep
selftest has not been re-run since fixes 7 and 8 were added to it.

**Artifacts:** `experiments/thermal-ladder/` — seven TSVs across the vendor,
pinned, 2°C, 5°C and two-core arms, the three `ab*` A/B directories, and
`pollcost-20260913.log` with the `pollcost.sh` that produced it.

## 2026-09-13, night — the charger's input limit, and a Pyra that discharges on a charger

Found while trying to answer whether the thermal daemon's charge ladder does
anything useful. A charger was attached so the ladder would have something to
act on, and the battery went **down**. It had been written off once as a weak USB
port; the second time, on a different supply, the numbers got read properly.

**The starting state.** Idle, charger attached, nothing running but the desktop:

| | |
| --- | --- |
| `bq24297/online` | 1 |
| `bq24297/status` | `Not charging` |
| `max_current` | **500000** |
| `bq27421-0/current_now` | **−617000** |
| `bq27421-0/status` | `Discharging` |
| `bq27421-0/capacity` | 21 |

`REG08` read `0x0c`: power-good set, charge state `00`, and **`DPM_STAT` set** —
the chip regulating against its input limit. The machine draws about 620 mA at
idle and was being admitted 500 mA, so the pack covered the difference. Nothing
is faulty; the limit is simply below the machine's own appetite, and no supply or
cable on the other end can change that.

**One write, and the A/B is unambiguous.** `echo 2000000 > …/max_current`:
`REG00` `0x32` → `0x36` (IINLIM `010` → `110`) immediately, battery current
−617 mA → 0 → positive, voltage 3.709 → 3.731 V inside five seconds. Then a
sustained window, same supply and same cable:

| | 899 s at a 2 A limit |
| --- | --- |
| battery current | mean **+476 mA**, min 202, max 531 |
| capacity | 21% → 23% |
| voltage | 3.766 → 3.782 V |
| `REG08` | `0x2c` — fast charging, PG good — on **all 815 samples** |
| `REG09` | `00` on all 815 samples, no faults |

**2 A is the right number, and the cable is now the constraint.** The same run at
the chip's 3 A ceiling gave **+455 mA** over its 267 s at that limit, 243
samples — no gain, and lower with a pack that was fuller by then (23% against
21%). Both arms recomputed from the TSVs on 2026-09-18; the 3 A figure published
before that did not reconcile with its own artifact, and the derivation is in
`experiments/charging/README.md`.

`DPM_STAT` stayed set through both arms while total input draw was well under
1 A, which has one meaning: the chip is regulating against **VINDPM** at 4.36 V,
so VBUS is sagging. That is cable resistance. 2 A is also what this
board's own device tree calls `adp_input_current`, so the default follows the
hardware description rather than an opinion.

**Why nothing ever set it — three mechanisms, all broken.** Every rule in
`/lib/udev/rules.d/charging.rules` that works names `twl4030`, which is OMAP3
GTA04 hardware; the Pyra rules below it carry the vendor's own accurate comment,
*"neither tested nor complete nor working"*, and try to symlink an `id`
attribute the bq24297 does not have. Because rule 3 never ran,
`/dev/usb_max_current` is a **regular file**, `-rw-r--r-- root root 7 bytes`,
created by the first root process to write it — the thermal daemon, which has
written its charge decision there on every poll, into nothing, on every Pyra
running this image. And the driver parses all four device tree values at probe
(`usb_input_current = 3000000`, `adp_input_current = 2048000`) and applies none
of them.

**This corrects an earlier entry in this log by implication.** The 2026-09-12
sleep session recorded the gauge gaining charge at +95 mA on external power,
which is not contradicted and is worth reading alongside this: a mostly
suspended machine draws less than 500 mA and does charge. It is the awake idle
draw of ~620 mA that loses, which is why this went unnoticed for so long.

**Two sysfs readings that mislead, both now documented in the scripts.** `REG09`
came back `0x01`, which the driver logs as `HOT`, and this was briefly taken for
an NTC fault blocking charging; the register is read-to-clear and it was a stale
latch, reading `00` across 815 samples of an actively fast-charging pack minutes
later. `pyra-chgwatch.sh`'s header now says not to conclude anything from one
read of it. Separately, the charger's own `status` reads `Not charging` while it
fast-charges and the gauge reads `Charging` — cosmetic, but any indicator
reading the charger rather than the gauge will lie, which is the same trap as
the 2026-09-08 note above.

**What was checked about the fix itself.** `device/pyra-charge-current.sh` writes
a config, an idempotent one-line helper and a udev rule under
`/etc/udev/rules.d`, because the limit is a register and does not survive an
unplug or a boot. The live path and the offline `--emit-into ROOT` tree were
checked byte-for-byte against each other, the same one-implementation pattern
fixes 6 and 7 use. Unlike those two it edits no packaged file, so an `apt
upgrade` cannot silently revert it — the first fix in this project with that
property, and the reason it is not on the post-upgrade re-check list.

**Not established.** The udev rule was exercised by knocking the register down to
500000 and firing `add` and `change` with `udevadm trigger`; it returned to
2000000 both times. **A physical unplug and replug has not been tested**, and
that is the one part of fix 8 needing hands on the device. Prep's offline
application is unchecked for the same reason as fix 7: the selftest has not been
re-run since these two fixes were added.

**Deliberately not done.** The daemon's charge ladder is *not* connected to the
working knob. It reads the fuel gauge's die — fault 1 of fix 7 — and drops to
500 mA above 44°C, and this machine idles with that sensor at 46–47°C. Wiring
the two together before recalibrating the ladder would re-impose exactly the cap
this fix removes, permanently, with no way out from userspace. The pack's real
thermal protection is the charger's TS pin, in hardware, and always was.

**Artifacts:** `experiments/charging/` — `chgwatch-2A-20260913.tsv`,
`chgwatch-3A-20260913.tsv`, and `charge-probe-20260913-190806.tsv`, the earlier
run whose evidence was collected and misread.

## 2026-09-26, small hours — fix 11, the SGX services race, on hardware

**Established.** The DDK's udev rule starts the SGX services on the pvrsrvkm
module add event, which comes before the driver probes. `initrace.sh` reloaded
the driver 10 times under that rule: the services came up by themselves **4
times**. With fix 11 in place (start on the pvr DRM card's add event) they came
up **20 of 20**, alternating the stock module with the idle-power one. The
journal shows no `pvrsrvctl ... failed` after the rule changed. After a full reboot
into `5.6.19-m4`, udev started them 2.4 s after the driver registered, and a GL
fill ran at 868 Mpix/s (drawn over the lightdm greeter with its X authority,
because nobody was logged in).

The installed rule is byte-identical to `--emit-into` output. `udevadm verify`
passes it.

**Not established.** `pyra-trixie-prep.sh` applying it offline: the section
follows fix 10's line for line, but the selftest has not been run with it in.
Repeated reboots: one was done, and the old rule lost 6 of 10.

**Artifacts:** `experiments/gpu-power/initrace.sh`; the rule is generated by
`device/pyra-sgx-init.sh`.

## 2026-10-18 — the window system and DDX sources read against the shipped binaries

**Established, off the device.**

- The source of `libpvrDRI3WSEGL.so` exists. The package server's
  `dri3wsegl-pyra_0.4.tar.xz`, now archived in `pyra-packages-archive/`, sits
  beside a .deb whose library has the stock sha256 `d852ce4d…`. Its upstream is
  TI's `dri3wsegl` (MIT).
- The DDX's Present flip is compiled out (`//#define ARMSOC_PRESENT_FLIP 1`).
  The stock `omap5_drv.so` contains "ARMSOC DRI3 init" and lacks "present flip
  failed".
- `SwapbuffersWait` is in neither the DDX source nor its binary.
- From the source: the swap waits for the SGX (`WaitForOpsComplete`) and makes
  a blocking X round trip. The X copy is committed asynchronously. The
  window system's vsync wait needs `DRI3_VSYNC`, which nothing sets.

**Not established.** Every performance consequence. None of this has been
timed on the device: not the swap's split between GPU wait and round trip, the
copy's cost, nor what the vsync toggle actually does.

**Corrected in place:** `rendering-guidelines.md` §§1.1, 1.2, 1.5 (and new
§1.6), `improvements.md` §6 and the `SwapbuffersWait` entry,
`known-limitations.md` §5, `profiling-guide.md` §§1.3 and 2.2, and the playbook.

## 2026-10-23 — stock bookworm-7 as a baseline, and the headphone jack traced

A second SD card with stock `pyra-bookworm-7` booted on the V5.3 unit, same
`5.6.19-pyradef #10` kernel as the trixie card. Captures and detail in
`experiments/bookworm-baseline/` and `experiments/jack-detect/`.

**Established, on the device.**

- Bookworm's X falls back to software GLX: `AIGLX error: unable to load
  driver armsoc`, then `GLX: Initialized DRISWRAST GL provider`. `glxinfo -B`
  says `llvmpipe (LLVM 15.0.6)`, Mesa 22.3.6, not accelerated. The X and Mesa
  reports now quote this instead of the development log.
- Stock audio does not use the AESS. `CONFIG_SND_SOC_OMAP_AESS=y` and the
  component registers, but the only PCM is `twl6040-legacy-0` and no AESS
  firmware is requested.
- The jack reads "inserted" with nothing plugged in on stock too.
- The TS3A227E jack detector fails its probe on every boot (`Cannot request
  irq 197 (-5)`) because PCAL6524 pin 14 is an output. Bank 1's config
  register reads `0x08` straight after boot; P16 needs bit 6 set.
- With the pin set to input from sysfs and the driver rebound, the TS3A227E
  is right: accessory status `0x00` empty, `0x09` with 3-pole headphones,
  one interrupt per transition over three unplug/replug cycles. The card's
  jack, fed by the TWL6040, stayed "inserted" through all of them.
- Bookworm ships `cpufreq-set`, so its thermal daemon can apply caps.

**Not established.** What leaves P16 as an output: the packaged U-Boot 0.1.5
source would write it as an input, and its compiled table could not be found
in the binary. A stock thermal load run. Suspend and resume with the
TS3A227E bound.

**Corrected in place:** `audio.md` (the jack entry under *Open*, and the
stock path), `reports/xorg-aiglx-dri2-null-deref.md`,
`reports/mesa-dril-omapdrm-no-fallback.md`.

**Later the same night: 0037 on hardware.** `kernel-jack` (stock source + 0037)
booted five times warm on the bookworm card. Each boot: the line hogged as an
input, no `gpiochip_lock_as_irq` error, `ts3a227e` bound with IRQ 197, bank 1
config `0x48`, banks 0 and 2 unchanged. Cold boots not yet done. The
`auto_null`-only PulseAudio seen on some of those boots also happens on stock;
it is the greeter's PulseAudio holding the card, not the kernel.

**Then 0038.** `kernel-jack` rebuilt with 0038. With the jack empty the card's
`Headset Stereophone Jack` reads `off` for the first time; three plug/unplug
cycles each moved the control and `SW_HEADPHONE_INSERT` once, matching the
TS3A227E. Only 3-pole plugs were tried, so the mic detection and the buttons are
unverified. Suspend was not tried: `kernel-jack` has no `patches/0003`.

## 2026-10-24 — the jack on the trixie card, through suspend

`kernel-m4-kbdled` rebuilt in the real tree with 0037 and 0038 and installed
over the running one (old build kept on the card). AESS path unchanged; five
plug changes reported once each; `twl6040_irq_plug` 0.

Suspend found a fault in the TS3A227E driver: a plug change while asleep left
INTB asserted and the jack dead until reboot, and, because the chip is not
reset, through a warm reboot too. Both were reproduced (the second as
`experiments/jack-detect/dead-after-reboot-0038-20261024.log`). 0039 clears
pending events at probe and resume. With it: INTB released after a warm
reboot; unplug while asleep reads `off` at resume, plug-in while asleep reads
`on`; six awake changes around the two suspends each reported once; both
suspends `RESULT mem: ok`.

**Not established.** 4-pole headsets and buttons; cold boot with 0039.

**Step 3, PulseAudio, same day.** Jack sections in the two path files. Plug-in
switches the `aess` sink to the headphones; manual port choice still works.
Unplug does not switch back: with the headset amplifier on, the TS3A227E
registered no removal through an unplug during playback and a plug/unplug at
idle, then registered it 190 ms after the amplifier was turned off by hand
(`experiments/jack-detect/amp-blinds-removal-20261024.log`). Shipped with the
unplug half manual; documented in `audio.md` and `known-limitations.md` 2.9.


## 2026-10-28 — the late root mount, read from the journal

Method: the kernel timestamp of every message (`_SOURCE_MONOTONIC_TIMESTAMP`)
from the trixie card's journal, 27 boots from 2026-09-30 to 2026-10-28, plus
how each previous boot ended (`systemd-reboot` or `systemd-poweroff`).

- Root (F2FS on `mmcblk1p2`) mounted at 6-17 s on 20 boots, and at 70-128 s on 7.
- The 5 slow boots that followed a warm reboot (out of 12) all mounted at
  126-128 s with nothing logged between the EHCI root hub (6.6 s) and the root
  mount. Not explained.
- The 2 slow boots that followed a power-off (out of 13) had `r8152` waiting on
  the sysfs firmware fallback for `rtl_nic/rtl8153a-4.fw` inside the initramfs,
  with hung-task reports for the probe and for the udev worker. Root mounted
  about 1 s after `r8152` gave up (70.6 s), and on the other boot at 126.6 s.
- One slow warm reboot was on `5.6.19-fix`, so 0043-0047 are not the cause.
- With `pyra-settle-diag` installed, 4 warm reboots mounted root at 7.6, 9.5,
  6.5 and 6.3 s. The on-board hub was absent in the initramfs on all four, just
  as on the slow ones.

### Same day: the firmware-fallback fix, measured

Method: `pyra-fw-nofallback` and `pyra-settle-diag` installed in the
`5.6.19-m4-kbdled` initramfs; kernel log read over wifi after each boot.

- Live, before any reboot: `r8152` unbound and rebound through sysfs. With
  `ignore_sysfs_fallback` at 0, udev cancelled the fallback in 6 ms (`-11`). At
  1, the kernel logged `Ignoring firmware sysfs fallback due to sysctl knob` and
  the load failed with `-2`. The 60 s wait needs the udev queue to be blocked
  behind the device, which happens at boot and not on a rebind.
  `force_sysfs_fallback` reads 1 on this kernel; the ignore knob overrides it.
- Before the fix, on the boot just before: the fallback started at 21.2 s and
  timed out at 85.0 s, and the adapter had carrier at 88.5 s.
- 1 warm reboot with the fix: knob 1 after boot, carrier at 41 s. Root mounted
  at 23.4 s, after 16.6 s of silence in the initramfs (root hub at 6.75 s, SD
  card present since 2.2 s). This is shape A at a smaller size. The diagnostic
  then sampled only from 40 s, so it now samples at 15, 30, 60 and 100 s.
- 5 cold boots with the adapter plugged in: root at 9.5, 6.5, 7.6, 6.1 and 8.2 s,
  carrier at 25, 23, 24, 22 and 23 s, knob 1 on all. On boots 1 and 5 `r8152`
  probed inside the initramfs (7.2 s and 8.1 s) and failed the load within 10 ms.
- `F2FS-fs ... recover fsync data on readonly fs` precedes the root mount on all
  32 journaled boots, so it does not distinguish slow boots.

## 2026-10-28 — the PulseAudio script chosen per boot

Method: `device/pyra-install-helpers.sh` run through `pc/pyra-push-helpers.sh`
on the trixie card, then `pyra-audio-select.sh --check` and `pactl list sinks
short` over ssh after each boot. The two reboots were owner-approved.

- Live on `5.6.19-m4-kbdled`, before any reboot: `--check` gave `path aess` and
  `ok`, and the sink was `aess`. With the `/run` file moved away and PulseAudio
  restarted, PulseAudio skipped the dangling link with no error and loaded the
  packaged `pyra.pa`, which fails on this kernel (`hw:CARD=L15,DEV=0`) and
  leaves `auto_null`. With the file back, the sink was `aess` again.
- Warm reboot into l0, `5.6.19-pyradef`: `path direct`, packaged script, `ok`.
  Sinks were `alsa_output.hw_CARD_L15_DEV_0`, `speakers` and `headphones`. The
  service finished at 139.8 s and the display manager started at 142.9 s. That
  boot was a shape A late root mount (127.3 s), see
  `troubleshooting.md`.
- Warm reboot into l5, `m4-kbdled`: hung in the initramfs (`troubleshooting.md`,
  shape A) and was power-cycled. The boot after that mounted root at 7.6 s and
  gave `path aess`, the AESS script and `ok`, with sink `aess` on port
  `pyra-speaker`. The service finished at 22.8 s and the display manager
  started at 24.0 s.

## 2026-10-28 — `pyra-settle-diag` kept off the consoles; the F2FS lead tested

Method: the hook's two console functions sourced in a root shell on the trixie
card, running `5.6.19-m4-kbdled` with X up (fbcon hidden), around
`echo t > /proc/sysrq-trigger`. Times are from `/proc/uptime` before and after
the write.

- Without the change (`ignore_loglevel` Y, console loglevel 7): the write took
  5.28 s (408.15 to 413.43).
- With it: `ignore_loglevel` N and `kernel.printk` `1 4 1 7` during the write,
  which took 0.03 s (413.44 to 413.47). Afterwards they read Y and `7 4 1 7`
  again. The ring buffer held both dumps in full (3906 and 3909 lines after
  `sysrq: Show State`), and `journalctl -k` had both headers.
- The card's m4-kbdled initrd was rebuilt with the new hook. `unmkinitramfs`
  shows both `pyra-settle-diag` and `pyra-fw-nofallback` in it.
- The F2FS lead, from the journal of 42 boots (2026-10-02 to 2026-10-28,
  `_SOURCE_MONOTONIC_TIMESTAMP`): `recover fsync data on readonly fs` to
  `Mounted with checkpoint` took 36-77 ms on every boot,
  the nine slow ones included (70.6 s, 23.4 s and seven at 126.1-127.7 s). Every slow boot's previous boot
  ended with `Journal stopped`. So F2FS recovery is not the waiter, and slow
  boots don't follow unclean shutdowns.
- Six owner-approved warm reboots into l5 with the new hook. Reboots 1-5 came
  after about 1 min up each, and root mounted at 10.6, 6.5, 10.6, 7.6 and 7.6 s.
  Reboot 6, after 10 min up, was shape A: root at 126.2 s. The `sysrq: Show
  State` headers were at 16.2, 30.8, 60.7 and 100.8 s, the boot finished, and
  the four dumps were in `dmesg`. After boot, `ignore_loglevel` read Y and
  `kernel.printk` read `7 4 1 7`. `/run/initramfs/settle-diag.txt`: no
  `/run/udev/queue` at any sample. `udevadm settle` and `systemd-udevd` were in
  `do_epoll_wait`, with no D-state task (`troubleshooting.md`, shape A).

## 2026-10-29 — the M4 `auto_boot` guard ships with the kernel install

`pyra-install-debug-kernel.sh` now writes `/etc/modprobe.d/pyra-m4-noautoboot.conf`
(`blacklist omap_remoteproc`) for any kernel whose module tree has
`omap_remoteproc.ko`, before it builds the initrd. `pyra-m4-run.sh` and
`pyra-m4-demo.sh` load the module themselves. Checked on the trixie card,
running `5.6.19-m4-kbdled`:

- `omap_remoteproc` is a module there: before the change `lsmod` listed it,
  loaded by udev at boot from the `ipu` modalias.
- The tarball on the card matched the installed kernel (same sha256 for
  `vmlinuz` and `omap_remoteproc.ko`), so `sudo ./pyra-install-debug-kernel.sh
  --replace-running ~/m4-kbdled-kernel.tar.gz` rewrote no kernel files and
  kept `default l5`. It wrote the conf file, and `lsinitramfs` shows
  `etc/modprobe.d/pyra-m4-noautoboot.conf` in the new initrd.
- After a reboot, `lsmod | grep omap_remoteproc` printed nothing,
  `/sys/class/remoteproc` was empty, and the kernel log had nothing from
  remoteproc. `systemd-analyze` gave 7.0 s (kernel) + 23.4 s (userspace).
- `sudo ./pyra-m4-demo.sh ~/pyra-m4-demo-20261018/pyra-m4-demo.xem4` (the
  2026-10-18 kit's firmware) printed `loading omap_remoteproc (blacklisted at
  boot, loaded on request)`, found `remoteproc1 55020000.ipu`, and passed: 13 ok,
  0 failed. Both cores measured at 212.8 and 212.9 MHz (SysTick, ten 1 s samples).
  Afterwards the firmware was gone and the module was still loaded.

## 2026-10-29 — the thermal fixes survive a `pyra-hacks` package run

`pyra-thermal-guard` and its dpkg hook (`fixes.md`, "Surviving a package run")
installed on the trixie card, running `5.6.19-m4-kbdled` with
`pyra-hacks 0.38+pyra1`. Run by hand first, the guard printed nothing. Then:

- `apt-get install --allow-downgrades pyra-hacks=0.38` (the archive's deb,
  the stock-package path): between `Unpacking pyra-hacks (0.38) over
  (0.38+pyra1)` and `Setting up`, dpkg printed `pyra-thermal-guard: a package
  run replaced /usr/share/pyra/scripts/pyra-thermal.sh; re-applied fixes 6
  and 7 and restarted pyra-thermal.service.` `dpkg --verify` then flagged the
  file (`??5??????`), as expected for the stock package with the fixes
  applied. Both `--check`s reported `Nothing to do`. The file was
  byte-identical to the one in the `0.38+pyra1` deb.
- `apt-get install --reinstall pyra-hacks` on that 0.38: the same line again,
  both `--check`s clean, the file byte-identical again. The journal had one
  `pyra-thermal-guard` notice per run.
- `apt-get install ./pyra-hacks_0.38+pyra1_armhf.deb`: the guard said
  nothing, because the packaged file already has both fixes. `dpkg --verify
  pyra-hacks` was clean, both `--check`s reported `Nothing to do`, and
  `pyra-thermal` and `pyra_volumed` were active.

Between the first and last step the wheel ran the stock `pyra_volumed`. This
card has no fix 12 drop-in; it gets fix 12 from the `+pyra1` deb.

Offline, against the card's 0.38 vendor file: an undone fix (backup deleted)
is left alone, and a vendor file the transforms refuse is left unchanged with
the warning banner. The guard exits 0 in every case.

## 2026-10-29 — shape A: settle misses the queue file's deletion; `pyra-settle-nudge`

Method: the trixie card on l5 (`5.6.19-m4-kbdled`), warm reboots with
`systemctl reboot`, each after at least 660 s up. Root-mount times are the
kernel's `Mounted with checkpoint` stamp unless marked "column" (the journal's
monotonic column, which runs slightly later). `pyra-settle-diag` was extended
first: epoll and inotify `fdinfo` of `systemd-udevd` and `udevadm`, a 0.2 s
timeline of `/run/udev/queue` and settle, and a one-time poke after the 15 s
sample (`experiments/initramfs-wait/README.md`).

- Before the nudge, 7 reboots: root at 9.3, 10.9, 9.6, 9.7 and 9.4 s (column),
  then 26.6 s, then 16.7 s.
- 26.6 s boot, 15 s sample: settle's fds were epoll, inotify and timerfd, with no
  socket, so it was past the PING. `/run/udev/queue` was absent. udevd's epoll
  still held its control listener (`tfd: 3 events: 19`, `/run/udev/control`,
  inode 1526).
- 16.7 s boot, timeline: `6.23 queue=1 settle=running`, `6.86 queue=0
  settle=running`, `15.79 poke`, `15.84 queue=0 settle=gone`. settle's inotify
  watch: `wd:1 ino:4dd mask:200`, and `ls -id /run/udev` gave 1245 (0x4dd).
- `pyra-settle-nudge` was then installed in the m4-kbdled initrd beside the
  diagnostic, after a live test with a stand-in `udevadm settle` (nudged at
  +1.0 s and +3.1 s, then logged `settle exited`).
- After the nudge, 4 reboots:
  - 8.7 s, nudged. The timeline had `7.13 queue=0 settle=running` and
    `7.97 settle=gone`. The nudge log had `7.83 ... nudged` and
    `8.35 settle exited`.
  - 6.7, 6.5 and 7.8 s, no nudge: settle left with the queue (5.93, 5.70
    and 7.09 s).
- Not shown: a full 126 s boot rescued by the nudge. The nudged boot was
  stuck the same way (settle still there 0.7 s after the queue went) but
  was cut short at once, so how long it would have waited is unknown.

## 2026-10-29 — shape A cause: `IN_DELETE` before `d_delete()` in 5.6.19

Method: the trixie card on l5 (`5.6.19-m4-kbdled`), `pyra-settle-nudge` moved
out of the initrd and `experiments/initramfs-wait/pyra-settle-trace` put in
(kprobes, no ptrace). Warm reboots with `systemctl reboot`, the second after
662 s up. The serial console was logged on the PC for both.

- Reboot 1 (after 42 min up, path probes unfiltered): root at 11.8 s. settle
  watched at 7.256 s, queue deleted at 7.482 s on CPU 1, settle woken on CPU
  0, lookup at 7.482256, exited.
- Reboot 2: root at 17.8 s. Timeline `7.41 queue=0 settle=running`,
  `13.73 settle=gone`. Each of the three queue deletions (7.379, 10.333,
  13.565 s) reached settle's inotify group (`inotify_handle_event`,
  `fsnotify_add_event` returned 0) and woke settle, which read 32 bytes and
  looked up `/run/udev/queue`. After the first two, both on CPU 1 with settle
  running before udevd returned from `fsnotify_add_event`, it slept on. After
  the third (udevd on CPU 0, settle on CPU 1) it exited. No settle warning on
  the serial console.
- `inotify-delete-race.c`, 2000 cycles each, tmpfs. Pyra 5.6.19: same CPU
  1964 and 1970 stale, CPU 0/1 4, CPU 1/0 83, unpinned 1090. PC 7.2 kernel:
  0 in all three runs.
- Restored: trace hook out, nudge back. Next boot: settle exited at 6.18 s
  (nudge log), `kprobe_events` empty.

## 2026-10-29 — shape A fixed: `patches/0048`-`0049` in m4-kbdled

Method: `patches/0048`-`0049` (the 5.4.y stable backports of a37d9a17f099 and
29044dae2e74) cross-built into `5.6.19-m4-kbdled` and installed over it with
`pc/pyra-push-kernel.sh`. `/boot` had 18 MB free, so the `.before-r16` and
`.before-r21` initrds were first moved to `/var/backups/pyra-boot/`. Then
`pyra-settle-nudge` was moved out and `pyra-settle-trace` put in, five warm reboots
were run (`systemctl reboot`, 6 min apart), and `5.6.19-m4` (l4, no 0048) was
booted once for the comparison.

- `inotify-delete-race.c`, changed first so the deleter re-creates the file only
  after the waiter's check. 2000 cycles each, tmpfs, waiter/deleter CPU 0/0, 1/1,
  0/1, 1/0, unpinned. Patched: 0, 0, 0, 0, 0. Unpatched l4: 1956, 1986, 3, 12,
  1137. Patched with the old test version: 0, 0, 2, 4, 0, the cross-CPU hits
  being that version's artifact.
- Reboots 1-5: settle dropped its watch (exiting) 1.2, 1.2, 1.3, 1.3 and 1.5 ms
  after the queue file's one deletion during its wait. `gap.py`: on reboot 3 settle was
  switched in for udevd on CPU 0 inside `fsnotify_add_event` and looked the name
  up at 8.421122, before udevd returned at 8.422417. It exited (`IN_IGNORED` at
  8.422326). On R21's stuck boot, the same sequence left settle asleep twice. On
  the other four, the lookup came after udevd returned. Root at 8.26 s on
  reboot 5. Boot warnings: only the usual `omap_l3_noc` and wlcore ones, also
  after a pty was opened and closed.
- Restored: base back to l5, trace hook out, nudge back (comment updated), initrd
  file list equal to `.before-r22`. Next boot: settle exited at 6.03 s, no nudge,
  root at 6.58 s, no kprobes.
