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

## 2026-10-29 — installer boot slots (`--slot`)

Method: the new `device/pyra-install-debug-kernel.sh` copied to the trixie card
and run with sudo, booted on `5.6.19-m4-kbdled` (base and default `l5`). Kernel:
`fix-kernel.tar.gz`, whose `vmlinuz` md5 equals the installed `5.6.19-fix`, so no
kernel changed. `user.cfg` was saved first and put back afterwards (md5 equal to
before).

- `--slot l0`: refused, "l0 is an entry in /boot/extlinux/linux.cfg". `--slot L5`:
  refused by the label check (exit 2). `--slot l1` with the running release:
  refused as before.
- `--slot l6`: added `l6` at the end, `l1`-`l5` unchanged, default `l5`. /boot
  needed 29 MB of 44 MB free (the release's own 18 MB credited). The printed
  removal commands said to keep the files, because `l2` boots `5.6.19-fix` too.
- `--slot l6` again: `user.cfg` md5 unchanged.
- No `--slot`: repointed only `l1` ("l1 booted /vmlinuz-5.6.19-m4-kbdled; l5 still
  boots it"); `l5` (base) and `l6` kept. `pyra-boot-kernel.sh status`: next boot
  and base `l5`, revert disarmed.
- Not rebooted: the entry text is the same as the `l1` entry the installer has
  always written, which boots.

## 2026-10-29 — a one-boot try of any slot (`debug LABEL --once`)

`pyra-boot-kernel.sh debug LABEL [--once]`, checked on the trixie card running
`5.6.19-m4-kbdled`, base `l5`, without a reboot (arming and disarming is the
state change; the revert unit's command is unchanged):

- `debug l4 --once`: `default l4`, `pyra-boot-revert.service` enabled, and
  `status` printed "next boot: l4 — trixie, kernel 5.6.19-m4", "base kernel:
  l5", "one-shot revert: enabled", and that the boot after next is back on l5.
  `stock` then put `default l5` back and the unit read `disabled`.
- `debug l3 --once --quiet`, then the unit's own command,
  `/usr/local/sbin/pyra-boot-kernel.sh stock --quiet`: `default` went from `l3`
  to `l5`.
- Plain `debug --once` still selects `l1`; plain `debug` sets `l1` for every
  boot with the revert disarmed. `debug l0 --once` is accepted (the distro
  kernel).
- Refused, exit 1, nothing changed: `debug l5` (the base), `debug l0h` and
  `debug l0r` (`linux.cfg` boot modes; `l0h` is `init=` a hardware-test script,
  so the revert would never run), `debug nope`. `debug l4 l3` and
  `debug --bogus` exit 2. `base l1` is still refused.
- `pc/pyra-push-kernel.sh --install --slot l4`, against stub `ssh`/`scp`/`rsync`
  on the PC, ran `pyra-install-debug-kernel.sh --slot l4 k.tar.gz` remotely;
  without `--install` it printed the same command; without `--slot` the command
  had none. `--slot 'l5;rm'` is refused before anything is copied.

Left as found: `default l5`, revert disarmed, and the new script installed in
`/usr/local/sbin` (sha256 matches the repository copy).

## 2026-10-29 — `pyra-install-helpers.sh` installs the `init-top` hooks

`pyra-fw-nofallback` and `pyra-settle-nudge` are now in the helper's map, and the
helper rebuilds every `/boot/initrd.img-*` that lacks either hook or is older than
one. Checked on the trixie card running `5.6.19-m4-kbdled`, through
`pc/pyra-push-helpers.sh`, with no reboot:

- Before: both hooks already in `/etc/initramfs-tools/scripts/init-top/` from the
  manual install, byte-identical to the repository. The `fix` and `m4-kbdled`
  initrds listed them. `freq`, `m4`, `m4demo` and the stock `pyradef` did not.
  `/boot` had 44 MB free, against initrds of about 13 MB each.
- `--dry-run`: `same` for both hooks and for the `fix` and `m4-kbdled` initrds,
  `would rebuild` for the other four.
- First run: exit 0, the four rebuilt, `/boot` at 43 MB free. The whole run took
  84 s, so about 20 s per rebuild. Verify printed `ok ... has both init-top hooks`
  for all six. The two `m4-uprobe` module trees have no initrd and were not
  touched.
- Second run: exit 0, `same` for every file and all six initrds, and no initrd
  mtime changed.
- After: the hooks' sha256 (`fb2a2068...` and `e32f61e3...`) match the repository
  and their mtimes are those of the manual install. `lsinitramfs` of each of the
  six initrds lists `scripts/init-top/pyra-fw-nofallback` and
  `scripts/init-top/pyra-settle-nudge`.

A rebuilt initrd takes every hook in that directory, so the four rebuilt initrds
also gained the diagnostic `pyra-settle-diag`, which only the trixie card had
(the `fix` and `m4-kbdled` initrds already carried it). It triggers SysRq-T on a
boot still in the initramfs at 15 s, and one such dump froze a boot on
2026-10-28, so it was then removed from `init-top/` and all six initrds were
rebuilt with `update-initramfs -u -k`. Removing a hook does not make the helper
rebuild, because it only looks for missing or newer hooks. Afterwards
`lsinitramfs` of each of the six lists `pyra-fw-nofallback` and
`pyra-settle-nudge` and nothing else of ours in `init-top/` but the vendor's
`pyra-emmc-switch`. The diagnostic and the original stock initrd are kept on the
card's root filesystem. Not boot-tested: `lsinitramfs` shows what is in each
initrd.

## 2026-10-29 — prep fixes 13 and 14, on the stock image

`sudo pc/pyra-prep-selftest.sh` against a copy of `pyra-trixie-t1.img`, on an
x86 Arch PC with `qemu-user-static` and `qemu-user-static-binfmt` (the `qemu-arm`
binfmt entry has flags `PF`). The selftest now mounts p1 at the rootfs's `/boot`.

- First attempt failed in fix 14 before any initrd changed:
  `chroot: failed to run command 'update-initramfs': No such file or directory`.
  sudo's `PATH` on that PC has no `/usr/sbin`, and the chroot inherited it. Prep
  now runs every chroot command under `env -i` with Debian's `PATH`, and checks
  for `update-initramfs` and `lsinitramfs` before writing anything.
- Second attempt: `74 passed, 0 failed`, `TEST COMPLETE: PASS`. Run 1 wrote
  `/usr/local/bin/pyra-gles` (0755 root:root, identical to `device/pyra-gles`) and
  both hooks, and rebuilt `/boot/initrd.img-5.6.19-pyradef` in the chroot: 13,011,480
  bytes before, 13,184,671 after. The image's `lsinitramfs` lists both hooks, and the
  initrd's `scripts/init-top/ORDER` runs both before `udev`. Run 1 as a whole took
  43 s (the selftest's snapshot timestamps), rebuild included.
- Run 2: every fix reported already in place, `/boot/initrd.img-5.6.19-pyradef
  already has both hooks`, no rebuild, and the snapshots of both partitions
  (type, mode, owner, size of every entry) are identical to run 1's.
  `fsck.f2fs` was clean afterwards.

Not boot-tested: no card was written from the prepared image. What the initrd
contains is checked; that it boots and mounts root early is what the device run
in the `troubleshooting.md` section showed for the same hooks.

## 2026-10-29 — fix 15, the Fn keyboard-light keys on m4-kbdled

Trixie card, `5.6.19-m4-kbdled`, `pyra-scripts` 0.31 (its
`pyra-brightkey.sh` byte-identical to the archive's 0.31 deb),
`funkeymonkey-pyrainput` 0.1.19, `pyra-backlight` 0.2. `pyra::kbd_backlight`
has `max_brightness` 100.

- `pyra-kbdlight.sh` installed to `/usr/local/sbin`, `--configure
  /etc/pyrainput.cfg` added the `fn` and `fnshift` lines to the three existing
  `*.export` lines, `systemctl reload pyrainput` took them.
- Run directly as root from 99: down 60, down 40, up 60, up 100, up 100.
- The keys, at the greeter (no MATE session), the LED logged every 0.1 s:
  Fn+brightness 40 → 60 → 100; Fn+Shift+brightness 60 40 20 10 5 2 1 0; then
  up again through 1 2 5 10 20 40 60 100.
- `dpkg -S` finds no owner for `/etc/pyrainput.cfg` or the script, `pyra-scripts`
  ships nothing under `/etc` or `/usr/local`, and no diversion names
  `pyra-brightkey`. A `pyra-scripts` upgrade has nothing of fix 15's to replace.
  Not done: an actual upgrade or reinstall.
- `pc/pyra-prep-selftest.sh`: 81 passed, 0 failed, with fix 15's checks (script
  matches the repository, 0755 root:root, both lines in `/etc/pyrainput.cfg`,
  the vendor script present and not diverted, run 2 reports both keys already
  set).

MATE's dimming on this kernel, same card, logged in, on AC (UPower
`on-battery: no`), `idle-dim-time 10`, `kbd-brightness-dim-by-on-idle 75`:

- `mate-power-backlight-helper --get-max-brightness` gives 15, the panel's.
- With the image's `backlight-enable false`, `pyra-idle-dim` stopped and
  `idle-delay` 1 min, 150 s idle changed neither light (panel 3 of 15, keyboard
  25). Setting `backlight-enable true` then moved the panel 3 → 5 within 1 s
  (30 % of 15, MATE's `idle-brightness`); the keyboard did not move.
  Settings restored afterwards.
- A nub touch took the keyboard 25 → 99; 20 s later it was back at 25.
- Fn+Shift+brightness in the session: the first press brought MATE's 99 back,
  then the keys stepped it 60 40 20 10 5. About 40 s later MATE set 25 (up from
  5), and the next touch 99.
- The level set through UPower (`KbdBacklight.SetBrightness 10`) was dimmed to 2
  after 36 s idle in one run; in the next, a touch restored 99, not 10, and 10 s
  later MATE set 25.
- Input made with `xdotool` did not trigger MATE's dim or restore at all, so
  these needed real touches.

## 2026-10-29 — fix 16, the governor setting at boot

Trixie card, `5.6.19-m4-kbdled`. The card has had `pyra-governor-tune` from
`pyra-install-helpers.sh`, which is the state prep's fix 16 writes, so no copy
was needed:

- `/usr/local/sbin/pyra-governor-tune.sh` and
  `/etc/systemd/system/pyra-governor-tune.service` have the same sha256 as
  `device/` (`3b674fed…`, `fb2a056c…`), modes 755 and 644 root:root, and
  `multi-user.target.wants/pyra-governor-tune.service` points at
  `/etc/systemd/system/pyra-governor-tune.service`, as prep links it.
- This boot (device clock 2026-10-30 00:31:57 CET), the unit's journal:
  `sampling_down_factor 1 -> 10`, `applied`, 16 s after boot; `systemctl
  status` `active (exited)`, 273 ms in `systemd-analyze blame`.
- `pyra-governor-tune.sh --check` 45 min later: `sampling_down_factor : 10`,
  governor `ondemand`, `applied.`
- Every `/boot/config-*` on the card, `5.6.19-pyradef` included, has
  `CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y` and `CONFIG_CPUFREQ_DT=y`, so the
  stock kernel a prepared card boots is on ondemand too. Not booted on pyradef
  this session.
- Prep's fix 16 block alone, run twice against a scratch root on the PC (without
  `-o 0 -g 0`, as a user): installed both files and the link, then reported
  both up to date and already enabled. The full selftest needs root on the PC
  and was not run.

## 2026-10-29 — fix 17, the PulseAudio script chosen per boot

Trixie card. It has had `pyra-audio-select` from `pyra-install-helpers.sh`,
which is the state prep's fix 17 writes:

- The six installed files (unit, the `zz-pyra-aess.conf` payload,
  `pyra-aess.pa`, the profile set, both mixer paths) are byte-identical to
  `device/`. The installed `pyra-audio-select.sh` is the previous commit's,
  which differs only by the new `--link` mode. The new script's `--link` on
  the card reported `same` for the existing link, exit 0.
- `dpkg -S` on the seven installed paths finds none of them. It finds only
  their directories (`pulseaudio` owns `/usr/share/pulseaudio/alsa-mixer/paths`
  and `profile-sets`). `pyra-config-pulseaudio` owns `daemon.conf.d/pyra.conf`
  and `pyra.pa`. So no package guard is needed.
- `5.6.19-m4-kbdled`: the unit logged `AESS kernel: PulseAudio gets
  /etc/pulse/pyra-aess.pa` 19 s into boot; `--check` read `path aess`, `ok`;
  the default sink was `aess` (module-alsa-card, s16le 2ch 48000 Hz, port
  `pyra-speaker`). `paplay -d aess Front_Center.wav`: sink `RUNNING`,
  `pcm5p` hw_ptr 29280 → 44460 in 0.3 s.
- `5.6.19-pyradef` (entry `l0`, one boot with `pyra-boot-kernel.sh debug l0
  --once`): the unit logged `direct-link kernel: PulseAudio gets the packaged
  /etc/pulse/pyra.pa` 21 s into boot; `/run/pyra-audio/` was empty, so the
  link dangled; `--check` read `path direct`, `script /etc/pulse/pyra.pa
  (packaged)`, `ok`; sinks `alsa_output.hw_CARD_L15_DEV_0`, `speakers`
  (default), `headphones`. `paplay -d speakers`: both sinks `RUNNING`, `pcm0p`
  hw_ptr 50387 → 78317 in 0.3 s; `Handsfree Left Playback` `HF DAC` (fix 9).
  The next boot returned to `l5` and `aess`.
- The data reached the codec on both kernels. Whether it was audible was not
  checked (no one listening).
- Prep's fix 17 block alone, run twice against a scratch root on the PC under
  `unshare -r`: it installed the seven files with their modes, made the link and
  the `multi-user.target.wants` link, then reported every file up to date, the
  link in place and the unit already enabled. `--link` was also run against a
  scratch root holding a regular file: an identical one was replaced, a
  differing one was kept as `.before-select`. The full selftest needs root on
  the PC and was not run (expected 88 + 20 = 108 passed).

## 2026-10-29 — the prep selftest through fix 19

`sudo pc/pyra-prep-selftest.sh` against a copy of `pyra-trixie-t1.img`, on the
same x86 Arch PC with qemu-user binfmt. Prep ran with `--kernel` pointing at
`m4-kbdled-kernel.tar.gz`, cross-built from the current kernel sources the same
day. This is the first full run with fixes 16-19 in it; the entries above for
fixes 16 and 17 ran only their own blocks.

- First attempt: every assertion passed (144/0), but the verdict was `FAIL
  (harness aborted)`. The selftest's own ERR trap went off at the new check that
  prep stops when given no kernel option. In bash a `trap - ERR` inside a
  function is undone when the function returns, so `disarm()` had never disarmed
  anything. Earlier disarmed commands never failed outside an `||`, which hid
  it. `arm` and `disarm` now set a flag the trap reads. Prep was unchanged.
- Second attempt: `144 passed, 0 failed, 0 skipped`, `TEST COMPLETE: PASS`.
  Fix 19 installed `5.6.19-m4-kbdled` into `user.cfg` slot `l5`, with the stock
  `l0` append line, its dtbs, modules and initrd (fix 14's loop found both hooks
  in it, ahead of udev), and `/etc/modprobe.d/pyra-m4-noautoboot.conf`. It made
  `l5` the base and the default, kept `extlinux.conf.orig` with `default l0`,
  armed no one-shot revert and left no staged tarball in `/var/tmp`. Both kernel
  scripts are in `/usr/local/sbin`, 0755 root:root.
- Run 2 reported every fix already in place, 16-19 included: the kernel was
  already installed, and `l5` already the base and the default. No initrd was
  rebuilt, and the snapshots of both partitions are identical to run 1's.
- A run with no kernel option, while nothing is pinned for download, stopped
  with `no kernel to install` and wrote nothing (the snapshot is unchanged).
  The missing-payload run still aborts before fix 1. `fsck.f2fs` was clean.

Not boot-tested: no card was written from the prepared image, so the first boot
on `l5` is still open.

## 2026-10-29 — first boot of a card prepared with fix 19

A fresh copy of `pyra-trixie-t1.img`, prepared on the PC with
`--kernel m4-kbdled-kernel.tar.gz --set-password --ssh-key <key>.pub` for the
image's `pyra` user, then written to a 256 GB card. Before writing, the image's
p1 (read with debugfs) had `default l5`, `pyra-base-label` `l5`, and the `l5`
entry with the stock `append` line. The SHA-256 of the image matched on both
machines before `dd`. First boot, checked over ssh as `pyra` with that key:

- `uname -r`: `5.6.19-m4-kbdled`, trixie. `extlinux.conf` still `default l5`,
  base `l5`, `pyra-boot-revert.service` not installed (no one-shot armed).
- `/etc/modprobe.d/pyra-m4-noautoboot.conf` ends in `blacklist omap_remoteproc`,
  and `omap_remoteproc` was not loaded.
- `systemd-analyze`: 6.5 s kernel + 26.9 s userspace; `graphical.target` at
  22.6 s. No failed units.
- `pyra-governor-tune.sh --check`: `applied.` (fix 16).
  `pyra-audio-select.sh --check`: `ok` (fix 17).
- lightdm and Xorg running; `pyrainput` active, with `pyraInput keyboard`,
  `Gamepad` and `Mouse` registered. procedure step 6's old check (`ls
  /dev/input/by-path | grep -i pyra`) counted the two platform devices instead,
  since the virtual pyraInput devices have no by-path link. The check now reads
  the input device names.
- Key login worked with password-less key auth; `sudo` asks for the password
  that `--set-password` set. Root is still the image's 5.8 GB (not yet grown).

Not checked on this card yet: sound out of the speaker, suspend, the Fn keys.

## 2026-10-30 — procedure §6 on the grown fix 19 card

The card from the previous entry, grown on a laptop's built-in SD slot, second
boot and later. Every §6 check, run over ssh as `pyra` (the root ones by the
owner with `sudo`), 2026-10-30 18:00-18:10:

- `uname -r` `5.6.19-m4-kbdled`. `pyra-boot-kernel.sh status`: next boot and
  base `l5`, one-shot revert disarmed. `linux.cfg` still has `label l0` on
  `vmlinuz-5.6.19-pyradef` (with `l0r`, `l0h`). `pyra-m4-noautoboot.conf` ends
  in `blacklist omap_remoteproc`.
- `pyrainput` active, three pyraInput devices. `pyra-usb3503-rescue` enabled,
  journal `hub already on the USB bus, nothing to do` (cold boot).
- Fix 16: `sampling_down_factor : 10` … `applied.`, unit active.
  Fix 17: `path aess`, `/etc/pulse/pyra-aess.pa`, `ok`; default sink `aess`.
- Fix 4: the only GLX line in `Xorg.0.log` is `Extension "GLX" is disabled`; no
  AIGLX, no `(EE)` entries, no signal 11. `xdpyinfo` lists DRI2, DRI3, Present.
  `/var/lib/lightdm/data` owned by lightdm.
- `pyra-gles2-smoke` (§6's build, `libx11-dev` installed for it): `ldd` picks
  the DDK's `libEGL.so.1` and `libGLESv2.so.1`; EGL vendor Imagination,
  `PowerVR SGX 544MP`, `OpenGL ES 2.0 build 1.14@3699939`, 6959 frames in 5.00 s
  = 1392 fps (320x240, vsync off). Fix 11: `/proc/pvr/version` present, pvr on
  `card2`, SGX up at boot without a hand-run `pvrsrvctl`.
- Fix 13: `pyra-gles --check` finds the blob's `libGLESv2.so.1`; the shim is
  made on first use. No Qt5 program is on the card, so a Qt draw was not tried.
- Prep's payloads: 17 installed files (fixes 5, 8-13, 15, 16, 18) are
  byte-identical to the repository (SHA-256). Fix 2 marker
  `/var/lib/pyra/first-run.done` present, no wizard ran. Fixes 6/7: both
  `pyra-thermal.sh.before-*` backups present, `pyra-thermal` active,
  `scaling_max_freq` 1500000. Fix 8: `max_current` 2000000 at boot. Fix 12:
  `pyra_volumed` runs `/usr/local/bin/pyra_volumed`, built on the first boot
  (03:55) by `pyra-volumed-run`. Fix 15: both `scripts.brightness.fn*` lines in
  `/etc/pyrainput.cfg`.
- Fix 14: the m4-kbdled initrd has `pyra-fw-nofallback` and `pyra-settle-nudge`;
  `ignore_sysfs_fallback` 1. `systemd-analyze` 8.9 s kernel + 22.4 s userspace,
  `graphical.target` at 15.8 s. The only "Falling back to sysfs" line is
  `regulatory.db` at 4.7 s, before the initramfs runs; it is the harmless kind
  (`troubleshooting.md`). `r8152`'s firmware miss at 8.2 s has none.
- Root: `df -h /` 239G, 4.9G used. `dmesg | grep -i f2fs`: `Found nat_bits`,
  `recover fsync data on readonly fs`, `Mounted with checkpoint version =
  435f643f`, nothing else. No `/lost+found` or `/lost_found` on root. No failed
  units.

§6 corrections from this run: the smoke test's source is named and located
(`device/pyra-gles2-smoke.c`), the rescue unit's journal needs `sudo`, the `l0`
fallback, `df`, `systemd-analyze` and the F2FS lines are now checks, and the
blob's `Buffer busy` lines are called harmless.

Not checked here (need hands, listed in the owner's TODO): charger
unplug/replug keeping `max_current` 2000000, the headphone jack switching
sinks, the Fn brightness keys, listening to the speaker, and a root fsck on the
built-in slot at the next PC check.

Owner follow-up, same day: `apt install mpv` failed with 404s on every
package. The card's lists in `/var/lib/apt/lists` dated from 2026-01-10 and
2026-02-01, which is when the image was built, and the archive had since dropped
the versions they named. §6 now runs `apt-get update` before its one install.
Fn+brightness did not change the keyboard light, which already sat at 99 of
100. Fn+brightness steps the light up, so this does not show a fault yet; Fn+Shift+brightness, which steps it down, is the test still to do.

Fn keyboard-light keys, 2026-10-31, same card: **fix 15 fails after a boot.**
The light sat at 60 for two minutes of the owner pressing Fn+brightness and
Fn+Shift+brightness. `sudo /usr/local/sbin/pyra-kbdlight.sh down` dimmed it, and
`/etc/pyrainput.cfg` had both lines. An strace of funkeymonkey during the presses
showed it running the built-in `pyra-brightkey.sh key up` and `key down`, which
fail on the missing `keyboard-backlight` directory (the journal has the errors),
and `screen up` for plain brightness. Cause, in funkeymonkey-pyrainput 0.1.19's
source: `init()` reads the config, then resets the four brightness commands to
the built-in ones (`pyrainput.cpp:158-161`); only SIGUSR1 (`systemctl reload
pyrainput`) applies the file. The 2026-10-29 pass came right after
`pyra-install-helpers.sh` reloaded the service. Details in `fixes.md`, fix 15.

## 2026-10-31 — fix 15 across cold boots, with the reload at start

Card: the grown fix 19 card, `5.6.19-m4-kbdled`. Installed by hand the same
files prep's fix 15 now installs (`pyra-kbdlight.sh` with `--reload`, and
`pyrainput.service.d/pyra-kbdlight.conf`); the prep selftest, run after the
change, passed (owner, 2026-10-31), so prep writes the same two files.

- **Restart** right after the install: the journal has `pyra-kbdlight:
  pyrainput reloaded, Fn keys from the config` 1.07 s after the start (most of
  it the one-second gap before the second USR1). Fn+Shift+brightness and
  Fn+brightness then stepped the light 100 60 40 20 10 5 and back to 100.
- **Cold boot 1:** the boot's own start logged the reload at 22.9 s of
  monotonic time, the handler up 300 ms after the process began (measured: the
  script's poll count). So an ExecStartPost that sent USR1 at once would have
  killed the daemon. The keys were pressed only after the restart above, so
  this boot shows the reload, not the keys.
- **Cold boot 2,** nothing run between boot and check: the reload logged at
  22.95 s (handler up after 100 ms), NRestarts=0. At 63 s up, the owner's presses
  stepped the light 60 → 100, then down through 60 40 20 10 5 2 1 0 and back up
  to 100, every step as a single change.

Fix 15 now holds after a boot.

## 2026-10-31 — the shipped kernel without the firmware sysfs fallback, five cold boots

Card: the card written from the prepared image and grown on its first boot.
Installed `5.6.19-m4-kbdled` rebuilt with `CONFIG_FW_LOADER_USER_HELPER_FALLBACK`
off (`pc/pyra-push-kernel.sh --install --slot l5`; vmlinuz SHA-256 on the card
matched the build), and rebuilt its initrd **without** `pyra-fw-nofallback`,
so the hook could not be what made the difference. The stock kernel's initrd
kept the hook. Five cold boots (owner, power off and on), USB LAN adapter
plugged in, checked each time with a script that reads `/proc/config.gz`, the
two `firmware_config` knobs and dmesg.

- Every boot: the running config has the fallback off, `force_sysfs_fallback=0`
  and `ignore_sysfs_fallback=0`, and no "Falling back to sysfs" or "Ignoring
  firmware sysfs fallback" line, for any firmware.
- On all five, `r8152` probed inside the initramfs, before the root mount, which
  is the shape B trigger. Its firmware load failed within 6-7 ms with `(-2)`.
- Root mounted at 7.18, 7.15, 8.42, 7.40 and 7.45 s (measured, dmesg). Carrier at
  26.0, 21.9, 22.5, 21.8 and 22.5 s. The adapter enumerates a second time at about
  13 s, after `pyra-usb3503-rescue` resets the hub, and that load fails at once too.
- Baseline, the previous m4-kbdled build with the hook, warm boot: fallback `=y`, both
  knobs 1; `regulatory.db` still reached the sysfs fallback at 4.8 s, before
  init-top runs, which the hook cannot prevent (udev cancels it). The new build
  has no such line.

Shape B can't happen on this build, with or without the hook.

## 2026-10-31 — `pyra-kbdlight.sh --reload` message, on the image-written card

Card: the image-written card, `5.6.19-m4-kbdled`. Installed the corrected
`pyra-kbdlight.sh` (0755 root:root, SHA-256 equal to the repo's); `dash -n`
clean. `--reload` against the running pyrainput printed `handler up after 0 ms`
(was `000 ms`), and the daemon stayed active on the same PID. Against a dash
stand-in that installs its USR1 trap after 0.35 s it printed `handler up after
300 ms`. Prep selftest after the change: 169 passed, 0 failed (owner).

The funkeymonkey-pyrainput 0.1.19 tree, original and with
`reports/patches/funkeymonkey-pyrainput/0001-brightness-defaults-before-config.patch`,
built on the same card with g++ 14.2.0 (`-std=c++20 -shared`, funkeymonkey 0.1.2
headers, about 3 min for both). The patched library was not run.

## 2026-10-31 — MATE and the keyboard light, on AC and on battery (fix 20)

Card: the image-written card, `5.6.19-m4-kbdled`, logged into MATE,
mate-power-manager 1.26.1-1.1 (Debian trixie), the image's settings:
`idle-dim-ac false`, `idle-dim-battery true`, `idle-dim-time 10`,
`kbd-backlight-battery-reduce true`, `kbd-brightness-dim-by-on-battery 50`,
`kbd-brightness-dim-by-on-idle 75`, `kbd-brightness-on-ac 100`. The LED and
UPower's `OnBattery` were logged on every change, polled every 0.2 s. The
owner's hands did the touches (`xdotool` input does not reach MATE's idle
detection).

- **AC, image settings.** Fn+Shift+brightness took the light 99 → 5. 60 s
  idle, a nub touch, a key press 10 s later, 30 s idle: it stayed at 5 throughout.
  This does not reproduce the 2026-10-29 entry above, where MATE dimmed and
  restored the light on AC. The source agrees with this run: on AC the idle
  path runs only if `idle-dim-ac` is true. What differed on that card is not
  known (it has since been overwritten).
- **Battery, image settings.** Unplugging took the light 5 → 49 → 99 → 50
  within 1.8 s (UPower flapped to `OnBattery false` and back once). About 15 s
  later MATE dimmed it to 12. The keys then set it to 1, and 20 s later MATE
  raised it to 12. A nub touch at 60 s took it to 50 (the owner saw "one level
  up"). Plugging back in took it to 99.
- **Battery, `kbd-backlight-battery-reduce false`** (set with `gsettings` in
  the session, without restarting MATE). The keys set 60. It stayed at 60
  through unplugging, a flap to AC and back after 2 s, 60 s idle, a nub
  touch, a key press, 30 s idle, and plugging back in.

Why the plug-in in the last run did not reset to 100: mate-power-manager steps
toward its target from the level it last set, and the keys write sysfs without
telling it, so it believed the light was already at 100
(`gpm_kbd_backlight_set`, `src/gpm-kbd-backlight.c`).

The override file, compiled in a copy of the card's schema directory with
`glib-compile-schemas --strict`, gave `kbd-backlight-battery-reduce false` on
the memory backend. A conflict test (the same key in both override files) took
this file's value over `99_pyra.gschema.override`'s.

Then, after fix 20's override was installed on the card (SHA-256 equal to the
repository's, schemas recompiled with `--strict`, the session's test value
reset), the owner logged out and in, and MATE started with the new default:

- Login on AC set 100 (MATE's start; expected). Unplugged at 01:31:01: it
  stayed at 99. The keys set 40 at 01:31:25. The owner ran the sequence (60 s
  idle, a nub touch, a key press 10 s later) and reported no change; the log has
  none until the owner's next key presses at 01:33:58.
- The owner then ticked "Reduce keyboard backlight brightness" (battery tab)
  and "Dim display when idle" (AC tab) in MATE's Power Management preferences.
  These set the user values `kbd-backlight-battery-reduce true` and
  `idle-dim-ac true`. With them, on battery: the keys set 100, idle dimmed it
  to 25, a touch gave 50, the keys set 100 again, idle dimmed it to 12 (75 % off
  MATE's 50, not off the 100 shown), a touch gave 50 and idle 12 again.
  Plugging in gave 99, and 4 min later on AC idle dimmed it to 25. So the
  AC-tab checkbox also dims the keyboard. That is a likely, unconfirmed
  explanation for the 2026-10-29 entry's AC result.

## 2026-10-31 — prep self-test from a hash-checked vendor image (fix 20's first run)

`pyra-trixie-t1.img`, the image every earlier prep self-test ran on, was not
the vendor's: it differed from what the `.7z` unpacks to (SHA-256 `d8e98ff6…`)
in 39062 4 KiB blocks, starting with p1's superblock, and its mtime was
2026-09-08, after the archive's 2026-02-01. It was most likely mounted
read-write, or prepped, in an early session. It is kept, renamed and read-only,
as `pyra-trixie-t1-notpristine-20260908.img`.

A fresh image unpacked from `pyra-trixie-t1-brokenxorg.7z` matched both pins
(archive `b2220b3f…`, image `d8e98ff6…`). The self-test now checks its source
image against the pin before it starts. `sudo pc/pyra-prep-selftest.sh` on it,
with the cross-build's m4-kbdled tarball: **176 passed, 0 failed, 0 skipped**.
That is the 169 checks that passed on the old image, plus fix 20's seven (the
override matches the repository and is 0644 root:root, `gschemas.compiled` is
rebuilt, three keys default to false, and run 2 reports it up to date). So none
of the earlier passes depended on what the old image had been given. Fix 20's
`glib-compile-schemas` and `gsettings` run cleanly in the qemu chroot.

## 2026-10-31 — prep `--release`, the image to share (self-test)

What the vendor image carries that no two cards should share, read from the
self-test's first snapshot of the pinned vendor image: six ssh host key files,
an `/etc/machine-id` of 33 bytes (a set ID), and `/var/lib/dbus/machine-id` as
a file of its own; no `random-seed` or `credential.secret`. Its `ssh.service`
runs `sshd -t` before sshd and makes no keys, and in the qemu chroot the
image's `sshd -t` with no host key prints `sshd: no hostkeys available --
exiting.` and fails. After `ssh-keygen -A` (RSA, ECDSA, ED25519) it passes.
ssh is enabled from `multi-user.target`. The image has
`systemd-firstboot.service` (`ConditionFirstBoot=yes`, prompts on tty1 for
locale, keymap, timezone and root password, before `sysinit.target`), which an
empty machine-id would start; release mode masks it. The image's
`/etc/sudoers.d/pyrainput` lets the `sudo` group run `pyrainputctl` without a
password; that rule stays.

`sudo pc/pyra-prep-selftest.sh`, with the cross-build's m4-kbdled tarball:
**206 passed, 0 failed, 0 skipped**. The new 30 checks: `--release` refuses
`--set-password`, `--ssh-key`, another user, an image with an authorised key,
with `90-pyra-nopasswd`, or with any NOPASSWD rule for all commands, each
writing nothing. With stdin closed, a release run exits 0 and prompts for
nothing. Afterwards `pyra`'s hash is `pyra` with last change 0, there are no host
keys, `pyra-ssh-hostkeys.service` matches the repository and is enabled, the
machine-id is empty, D-Bus's copy is a link, and `systemd-firstboot` is masked.
A second release run changes nothing. The session's first self-test run failed
there: release mode then refused any NOPASSWD rule and so refused the vendor's
`pyrainput` one. It was narrowed to rules for all commands.

Not booted: no card has been written from a release image, so the greeter's
handling of the expired password and the first-boot key generation are
untested on a Pyra.

## 2026-11-01 — a release image booted on the Pyra (R42)

`pyra-trixie-prepped-20261101-025203.img`, built from 293eb11 with
`--release --grow-on-boot --kernel m4-kbdled-kernel.tar.gz` (`repo_dirty=no`),
written to a 256 GB card and booted on kernel `5.6.19-m4-kbdled`. Everything
below is measured, from the card's journal (one boot) and the files themselves.

- **Grow:** it ran in the initramfs on the first boot, with no reboot. The log
  found 232 GiB unused and passed the capacity check (931 samples). The read-only
  fsck took 64 s, `resize.f2fs` 486 s and the fsck after it 67 s, all clean,
  ending with `done: the root filesystem is now 238 GiB`. `df -h /` then showed
  239G with 4.9G used. The grow is why everything else in userspace happened
  about 11 minutes after the kernel started: the RTC set the clock to 04:17:53
  CET, and the machine-id was written at 04:28:45.
- **machine-id:** new (33 bytes, written this boot); `/var/lib/dbus/machine-id`
  is a link to it.
- **No console prompt:** `systemd-firstboot.service` is `masked` and inactive,
  and nothing prompted on the console.
- **Host keys:** `pyra-ssh-hostkeys.service` logged `ssh-keygen: generating new
  host keys: RSA ECDSA ED25519` and finished after about 13 s (9.4 s CPU).
  `ssh.service` started right after it and was listening 0.2 s later. The key
  files are dated 04:29:07, and the new ED25519 fingerprint is not that of the
  card made from the vendor image without `--release`. A client that knew the
  vendor key would get the host-identification warning, which is what should
  happen.
- **Password at the greeter:** lightdm logged `pam_unix(lightdm:account): expired
  password for user pyra (root enforced)` and asked for a new one. A rejected
  choice (`new password not acceptable`) and a wrong current password each
  started again from the login screen. The third attempt logged `password changed
  for pyra`. The new password then worked for an ssh password login (`Accepted
  password for pyra`) and in the session.
- **Password over ssh:** the password was expired again with `passwd -e pyra`
  to test the ssh path on its own. A key login with no terminal was refused:
  `You are required to change your password immediately (administrator
  enforced).` … `Password change required but no TTY available.` (exit 1). With
  `ssh -t`, sshd accepted the key, PAM reported the expired password, and sshd
  ran `passwd`. That asked for the current password and then a new one (`password
  changed for pyra`). After that, key logins went straight to a shell. So an
  authorised key does not skip the forced change.

To make testing easier, the owner added a key to `~/.ssh/authorized_keys` and a
NOPASSWD sudo rule after the first login. Neither came from the image:
`~/.ssh` was created at 04:34, after the password change at 04:30, and the
image's `/etc/sudoers.d` holds only the vendor's `pyrainput` rule and README.

This was a test card, which will be rewritten. A card meant for sharing would be
written again from the image, not passed on after a boot.

## 2026-11-01 — the wsegl fdfix, from the vendor image to a card (fix 21)

- **The vendor image's library is the stock build.** The image at the vendor pin
  (`pc/pyra-vendor-image.sh`), its rootfs mounted read-only as user:
  `/usr/lib/libpvrDRI3WSEGL.so` is 67016 bytes, sha256 `d852ce4d…6daa0`
  (`SHA_STOCK` in `device/pyra-wsegl-fdfix.sh`), bytes `ff f7 0c ef` at
  `0x1548`; dpkg status says `dri3wsegl-pyra` 0.4. The trixie 0.4 deb carries the
  same file. The release card (written from a `--release` image, R42) read the
  same hash, and dpkg owns the path (`dpkg -S`; `/lib` links to `usr/lib`).
- **The script on the card** (the `--root` version, run with `sh`, which is dash
  there): `status` read `stock` and exited 0. `install` patched it and
  `status` then read `fixed` with `.stock: stock`. The hashes were
  `e431a307…3f90` and `d852ce4d…6daa0`, both files 0644 root:root. A second
  `install` said `already patched`. `rollback` restored the stock file, and
  `--root / status` gave the same answer as `status`. The card was left as found:
  the stock library and no `.stock` copy.
- **Not checked on the card:** a GLES program drawing with the patched library.
  The package's `dri3test` stopped at `Error creating gpu or npu` (as root, on
  `:0`, lightdm's X authority), once with the patched library and once with the
  stock one; the cause was not looked at. The patch's
  effect on a running game is in Shipwright report 10 §10.7: Ship of Harkinian
  kept its log open and held a flat descriptor count.
