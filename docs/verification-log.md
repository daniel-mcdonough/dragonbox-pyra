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
  checked (no one listening). On m4-kbdled it was: the speakers and the
  headphones on 2026-11-01 (below). pyradef's has still not been listened to.
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
`patches/userspace/funkeymonkey-pyrainput/0001-brightness-defaults-before-config.patch`,
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

`pyra-trixie-prepped-20261101-025203.img`, built from 3383ca2 with
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

## 2026-11-01 — fix 21 kept across a package run (`pyra-wsegl-guard`)

- **On the Pyra** (the R42 release card, which had no fix 21 files; the script,
  the guard and its dpkg config installed by hand), with real dpkg runs:
  `install` patched the library, and `dpkg -i dri3wsegl-pyra_0.4_armhf.deb`
  (the vendor's trixie deb, sha256 `1f7494f8…10c4`) reinstalled the stock
  build, after which the guard re-patched it and printed its line. After
  `rollback`, the same reinstall left the stock build and the guard said
  nothing. With an unknown build in place (the stock file plus one byte),
  `dpkg --configure -a` printed the guard's banner and left the file alone:
  an empty dpkg run still fires `post-invoke` hooks. dpkg exited 0 every time,
  and the journal had the guard's notice and warning. The card was left as
  found: the stock library, no fix 21 files, `dpkg --verify dri3wsegl-pyra` clean.
- **ldconfig and the rollback marker:** a first version kept the marker as an
  empty `libpvrDRI3WSEGL.so.rolled-back` beside the library; the libc trigger's
  ldconfig then printed `File /lib/libpvrDRI3WSEGL.so.rolled-back is empty, not
  checked`. The marker moved to `/var/lib/pyra-wsegl-fdfix/rolled-back`.
  `ldconfig: /lib/libpvrDRI3WSEGL.so is not a symbolic link` comes from the
  vendor package on every reinstall, patched or not.
- **Prep selftest:** 236 passed, 0 failed, 0 skipped, with the real 0.4 deb
  reinstalled by the image's dpkg in the qemu chroot (re-patched; rolled-back
  image stayed stock; unknown build warned, unchanged, dpkg exit 0).

## 2026-11-01 — the grow lock's initrd on a Pyra (R45)

- **On the Pyra** (the R42 release card, already grown to 238 GiB), the new
  `pyra-grow-root` and its hook installed by hand into the paths prep's
  `--grow-on-boot` uses, then `update-initramfs -u -k 5.6.19-m4-kbdled` (the
  stock kernel's initrd left alone; the old initrd, script and hook kept under
  `/root/*.pre-r45`).
- **Before:** the initrd had `60-block.rules` and no `flock`; its busybox has
  no `flock` applet.
- **After:** `lsinitramfs` lists `usr/bin/flock` (util-linux 2.41, runs in the
  unpacked tree), `usr/lib/udev/rules.d/60-block.rules` (`OPTIONS+="watch"`)
  and `usr/sbin/pyra-grow-root` (identical to the repo copy).
- **Next boot** (`l5`, m4-kbdled): `/run/initramfs/pyra-grow-root.log` says
  `nothing to do: disk 500006912, partition 499480576, filesystem 499349504
  sectors`; root mounted at 7.19 s (dmesg).
- **Not run:** a grow with the lock on a Pyra (`grow-rootfs.md`).

## 2026-11-01 — a first-boot grow with the lock on a Pyra (R46)

`pyra-trixie-prepped-20261101-050948.img`, built from e41cf7b with
`--release --grow-on-boot --kernel m4-kbdled-kernel.tar.gz` (`repo_dirty=no`),
written to the 256 GB card and booted once on `5.6.19-m4-kbdled`. Read over
ssh after that boot, with nothing changed on the card except the login
password, an ssh key and a sudoers line, plus a serial console capture
(`ttyO2`, 1500000 baud) of the same boot.

- **initrd:** `lsinitramfs` lists `usr/bin/flock` (util-linux 2.41),
  `usr/lib/udev/rules.d/60-block.rules` and `usr/sbin/pyra-grow-root`. The
  unpacked script is byte-identical to the repo copy (SHA-256 `13da9c02…`).
- **Grow log** (`/run/initramfs/pyra-grow-root.log`): 232 GiB unused, capacity
  check passed (931 samples), read-only fsck 64 s, `partition 2 is now 499480576
  sectors`, `resize.f2fs` 490 s, fsck after it 67 s, all clean, then
  `done: the root filesystem is now 238 GiB`. No `next boot will finish it`, no
  `moved`, no `could not lock`. (The only "Move" lines are `resize.f2fs`'s own
  `[FIX] Move curseg` output.)
- **After:** `blockdev --getsz` gives 500006912 for the disk and 499480576 for
  p2; `df -h /` 239G, 4.9G used; no failed units.
- **Timing:** `Run /init` at 3.66 s; root mounted at 652.9 s (dmesg, F2FS
  `Mounted with checkpoint version = 435f63aa`). The serial console shows
  nothing between 33.8 s and 651.9 s.
- **udev re-reads:** dmesg has 80 `mmcblk1: p1 p2` lines between 11.7 s and
  18.0 s, during the capacity check: its 931 one-sector `dd of=/dev/mmcblk1`
  writes each close a write-opened disk, and the `watch` rule re-reads the
  table on that close. None appear after that, including after `sfdisk`, which
  runs under the lock. That fits the lock keeping udev off, but no run without
  the lock was made to compare.
- **Serial console:** the grow's own messages never reach it. `console=tty0`
  comes last on the command line, so `/dev/console`, where the initramfs
  scripts write, is the LCD; only kernel messages go to `ttyO2`.

## 2026-11-01 — the headphone jack on the release card, by ear

The R46 card (the release image, grown on first boot), `5.6.19-m4-kbdled`.
Done by hand on the device and reported by the owner, with no log captured.

- **Plug in during playback:** the sound moves to the headphones.
- **Unplug while the headset amplifier is on:** the sink stays on the
  headphones, as `known-limitations.md` 2.9 predicts.
- **The amplifier powers off:** the sink goes back to the speakers on its
  own. Until now, only the case where someone picked Speakers by hand had been
  seen (`experiments/jack-detect/amp-blinds-removal-20261024.log`). Over ssh
  afterwards, `aess` was on `pyra-speaker`.

- **Audible:** both the headphones and the speakers, through the `aess`
  sink. This is the first listen on `5.6.19-m4-kbdled`. It is also the first
  card built by prep with fix 17 that got as far as sound: the card chose
  `aess` on its own.

So the unplug half comes late but needs nothing from the user.

## 2026-11-02 — root fsck on the X220's built-in slot

The card that held the speaker and jack checks the day before (the R46 release
card, grown on first boot to 238 GiB), shut down with `poweroff` and read in
the X220's built-in SD slot (`/dev/mmcblk0`), not a USB reader. Run by the
owner:

    echo n | sudo fsck.f2fs -f --dry-run /dev/mmcblk0p2

- **Clean, exit 0.** Checkpoint `435f64ba`, state `nat_bits crc unmount`;
  149639 nodes; every check `[Ok..]` (unreachable NAT entries 0, SIT bitmap,
  hard links, block, node and inode counts against the checkpoint, free
  segments, next block offset, other corrupted bugs). Free space 239566 MB of
  243823 MB.
- The run printed `fixing SIT types`. `-f` prints it unconditionally, and
  `--dry-run` drops every write, so it reports no damage.
- 95 s through that slot (measured, fsck's own `Done:` line). The first-boot
  grow's fsck of the same size took 64 s on the Pyra.

So a card that boots the shipped kernel, plays sound and powers off leaves a
clean root filesystem. The damage the USB reader reported on 2026-10-29 and
2026-10-30 was not seen through the built-in slot (`troubleshooting.md`, "fsck
finds damage before the grow").

## 2026-11-03 — the pyra-backlight applet added from the panel menu

An older trixie card on `5.6.19-m4-kbdled`, with `pyra-backlight` 0.2 and
`gir1.2-matepanelapplet-4.0` 1.27.1-4.1 both installed by hand (2026-09-26),
not by prep's fix 22. The owner added the applet with right-click on the panel,
*Add to Panel…*, *Pyra Brightness*. Checked over ssh afterwards:

    gsettings get org.mate.panel object-id-list   # ends in 'pyra-brightness'
    systemctl --user is-active pyra-idle-dim      # active

- **The menu offers it and the panel keeps it:** `pyra-brightness` is in the
  panel's object list.
- `pyra-idle-dim` runs in the session.

So `fixes.md` fix 22's "add it from Add to Panel" works with the packages prep
installs, at the same versions. Still unchecked: a card prepared with fix 22,
which is what the next release image is, and whether `pyra-idle-dim` actually
dims the panel after `idle-delay`.

## 2026-11-03 — pyra-idle-dim dims and restores the panel

The same card and session as the entry above (`5.6.19-m4-kbdled`,
pyra-backlight 0.2 installed by hand, on AC). `org.mate.session idle-delay` set
to 1 for the test, then put back to 30. Watched over ssh with `dbus-monitor` on
the session bus (`StatusChanged`, `org.mate.ScreenSaver`), the service's
journal, and `/sys/class/backlight/backlight/brightness` every 5 s.

    06:32:23  StatusChanged 0 (a key)   awake: restoring 11
    06:33:24  StatusChanged 3 (idle)    idle: 11 -> 3
    06:33:59  StatusChanged 0           awake: restoring 11
    06:34:59  StatusChanged 3           idle: 11 -> 3

- **Dims 60 s after the last input and comes back on a key**, both twice
  (measured, the timestamps above; the owner saw the dim). Brightness 3 is
  20 % of 15, the service's default.
- **MATE's own brightness controls do nothing,** by design: the slider in
  *Power Management Preferences* stays inert because `backlight-enable` is
  false (`fixes.md`, fix 22). The Pyra Brightness applet's sliders work
  (owner).
- **One earlier run did not match** and is not explained. Right after the delay
  was changed from 30 to 1, the screen blanked (mate-screensaver, `blank-only`)
  at about a minute, while presence sent no `StatusChanged` for 11 minutes
  (`gdbus monitor` on the Presence object). The first dim came at 06:29:53,
  presumably a minute after the owner woke the screen. During the two cycles
  above the screen did not blank at all.
- The dim and the screensaver's blank both key off `idle-delay`, so on a card
  that still blanks, the dim cannot be seen first. With blanking off, as the
  README's first-boot steps advise, the dim is what idle looks like.

Still not seen: the same on a card prepared with fix 22.

## 2026-11-10 — the first CI-built release image on a Pyra (R49)

`pyra-trixie-release-ef8b2dc1b6f0`, the first artifact of
`.github/workflows/release-image.yml` on a GitHub-hosted runner. Its `.info`:
`built_utc=20261111-020128`, `repo_commit=ef8b2dc1b6f0…` (`repo_dirty=no`),
`prep_options=--release --grow-on-boot --kernel m4-kbdled-kernel.tar.gz`,
kernel tarball SHA-256 `8c00c70b…`, vendor image SHA-256 `d8e98ff6…` (the pin).
Downloaded as the workflow artifact, written to the 256 GB card and booted once
on `5.6.19-m4-kbdled`. Read over ssh after that boot, with nothing changed on
the card except the login password, an ssh key and a sudoers file
(`01-dev`, development only), plus a serial capture that recorded nothing
usable (115200 baud set by mistake; the console is 1500000).

- **Artifact:** the `.img.xz` matches its `.sha256` (`4aeb551e…`), and the
  decompressed image matches the build's own `.sha256` (`49eee3aa…`), both
  checked on the PC. The prep log ends `done`; the image's fsck log is clean.
- **Release mode on first boot:** new ssh host keys, written at 04:02 card
  time by `pyra-ssh-hostkeys.service` (5.2 s); a new `/etc/machine-id`;
  `systemd-firstboot.service` masked; the password change was forced (owner).
  No failed units; `graphical.target` 24.5 s into userspace.
- **initrd:** `lsinitramfs` lists `usr/bin/flock`, `60-block.rules`,
  `usr/sbin/pyra-grow-root`, `pyra-fw-nofallback` and `pyra-settle-nudge`. The
  unpacked `pyra-grow-root` is byte-identical to the repo copy (SHA-256
  `48ec95b5…`).
- **Grow log:** 232 GiB unused, capacity check passed (931 samples), read-only
  fsck 56 s, `partition 2 is now 499480576 sectors`, fsck after the resize
  67 s, all clean, then `done: the root filesystem is now 238 GiB`. No
  `next boot will finish it`, no `moved`, no `could not lock`. `df -h /` 239G,
  4.9G used.
- **No re-reads during the capacity check:** dmesg has one
  `mmcblk1: p1 p2` line, at 2.2 s (the probe). R46's boot had 80, from the
  capacity check's writes. This is the first Pyra run of the lock taken
  before the capacity check (`grow-rootfs.md`).
- **Early initramfs:** `Ignoring firmware sysfs fallback due to sysctl knob`
  at 8.3 s with the USB ethernet adapter plugged in; `settle-nudge.log` says
  `5.14 armed`, `7.30 settle exited` (no nudge needed).
- **Timing (dmesg):** `Run /init` at 4.8 s; the grow's first `drop_caches` at
  18.0 s; root mounted at 662.7 s; systemd started at 711.4 s. Kernel phase
  11 min 52 s, userspace 27.9 s.
- **A udev settle timeout after the grow** (R52, fixed; booted 2026-11-17, below): the owner saw a udev
  timeout message on the LCD after the grow's `DO NOT SWITCH OFF` line. It is
  in no log: the initramfs writes to `/dev/console`, the LCD. dmesg has
  nothing for 48.7 s between the root mount and systemd's start, where
  `init-bottom/udev` runs `udevadm settle --timeout=60`. The gap was not
  measured on a boot without a grow. Not yet explained; the leading suspicion
  is in `grow-rootfs.md`.
- **Expected noise only:** `F2FS-fs (mmcblk1p2): invalid crc_offset: 0` once
  (`grow-rootfs.md`), sensor probes failing with -121, missing wl18xx and
  rtl8153 firmware, `alsactl restore` exit 99 (no saved state yet).

Not recorded: the run's duration and whether the f2fs module came from
`linux-modules-extra` (the run log was not read).

## 2026-11-11 — the keyboard across suspend, with and without `patches/0050` (R53)

On the release-image card, by the owner's hands with the readings taken over
ssh. Each run: hold a key on the built-in keyboard, suspend 3 s later with an
RTC wake 45 s after arming, let go of the key while asleep, leave the keyboard
alone until the wake. Then read the tca8418 interrupt count (both CPU columns of
`/proc/interrupts`), `INT_STAT` (`0x02`) and `KEY_LCK_EC` (`0x03`) on i2c-1 `0x34`,
and press one key.

    sudo rtcwake -m no -s 45
    sudo systemd-run --on-active=3 --timer-property=AccuracySec=100ms systemctl suspend

| Kernel | Run | Count before → after wake → after one key | `INT_STAT` / `KEY_LCK_EC` after wake | Keyboard |
| --- | --- | --- | --- | --- |
| `5.6.19-m4-kbdled` #10 (shipped, 0006 only) | control | 362 → 362 → 362 | `0x01` / `0x01`, then `0x0a` after typing | dead |
| `5.6.19-m4-kbdled-test` (+ 0050) | 1 | 35 → 47 (keys pressed before the read) | `0x00` / `0x00` | works, count rising while typing (47 → 137) |
| | 2 | 138 → 138 → 140 | `0x00` / `0x00` | works |
| | 3 | 161 → 161 → 163 | `0x00` / `0x00` | works |

- **Control:** the release event stayed queued with the pin asserted, and the
  count did not move as the owner typed. `sudo i2cset -f -y 1 0x34 0x02 0x0f`
  recovered it: count 363, queue empty, keyboard back.
- **Patched:** an unchanged count across the sleep with an empty queue after
  it means the release was drained by the resume callback, which does not go
  through the interrupt handler and so is not counted. One key afterwards adds
  exactly two (press and release). No `tca8418` message in dmesg.
- **The test build** is `kernel-m4-kbdled` with only the release name changed
  (configs diffed against the card's `/boot/config-5.6.19-m4-kbdled`: only
  `CONFIG_LOCALVERSION` differs), installed into `l1` and booted once with
  `pyra-boot-kernel.sh debug --once`; l5 stayed the base.
- **A first try at run 3 did not count.** `systemd-run --on-active=3` uses
  systemd's default `AccuracySec=1min`, so the suspend started 41 s after arming,
  6 s before the RTC alarm, and the key was let go while still awake (count
  +1). With `--timer-property=AccuracySec=100ms` the suspend starts at 3 s.
  The control (8 s) and runs 1 and 2 (13 s and 28 s; 33 s and 17 s asleep)
  were late but still slept through the release. Run 3 is the redo.
- The boot WARN from `omap_l3_noc` (L3 custom error, taint 512) is on the
  shipped kernel's boots too (9 the boot before), not from this patch.

## 2026-11-11 — HDMI out, mode by mode, with X stopped (R51)

On the release-image card, kernel `5.6.19-m4-kbdled` (l5). lightdm was stopped
with no monitor attached, then modes were set straight on DRM with `modetest`
(`experiments/hdmi-signal`) and held 20-45 s each. The owner reported what each
monitor showed. Monitor 1 is a 1080p monitor; monitor 2 is a BenQ GW2760HS. The
bit rate is the TMDS rate per lane (10 × pixel clock).

| Mode | Bit rate | Monitor 1, 3' cable | Monitor 1, 8" cable + 5" adapter | BenQ, 3' cable, direct |
| --- | --- | --- | --- | --- |
| 640x480 | 252 Mb/s | bars, clean | bars, clean | bars, clean |
| 720x480 | 270 Mb/s | bars | — | — |
| 1024x768 | 650 Mb/s | bars ("I think") | black | black |
| 1280x720 | 742.5 Mb/s | black, synced | black | black (monitor went to standby) |
| 1366x768 | 855 Mb/s | bars with static, blanked twice | black | — |
| 1600x900 | 1080 Mb/s | bars with static | — | — |
| 1920x1080 | 1485 Mb/s | — | black | black |

- **The kernel console** came up on monitor 1 at 640x480 on its own when HDMI
  was plugged in with X stopped (fbdev emulation), showing the top-left corner
  of the 1280x720 console.
- **At plug-in the EDID read failed once** (`omapdss error: HDMI I2C Master
  Error`, modes list `640x480` only). A re-probe through the connector's
  `status` file read it in full.
- **With 720p held, two PLL changes made no difference:** SELFREQDCO set to the
  high range, and an integer M (619, no fraction). Both re-locked (STATUS 3).
  Switching the core to DVI mid-stream lost the monitor's lock. Register values
  are in `experiments/hdmi-signal/README.md`.
- An HDMI switch in front of the BenQ gave nothing at any mode, including
  640x480 (first BenQ run). Those results aren't in the table.
- Before X was stopped, plugging in monitor 1 under the stock X driver hung the
  GC320 (`etnaviv-gpu 59000000.bb2d: MMU fault`, `recover hung GPU!`). That left
  `Xorg` spinning and unkillable in `etnaviv_cmdbuf_init` (troubleshooting.md,
  "A second loop with the same symptoms"). Recovered with `sync; sudo systemctl
  reboot -f`.

## 2026-11-11 — HDMI hotplug under X on the etnaviv fix (R55)

Release card, `5.6.19-m4-kbdled-test` (patches/ through 0052) booted once from l1, stock
`armsoc-omap5` 0.6, lightdm running, a 1080p monitor (EDID preferred 1920x1080).

- Four plug-ins (one, then three unplug/plug cycles of about 10 s / 20 s). No GC320 fault:
  no `etnaviv`, `MMU fault` or `hung` line in dmesg (watched with `dmesg -w`). `Xorg` stayed
  in `S`, `SigPnd` 0.
- Each plug-in: `hotplug=1`, the X screen grew to 2640x1080, then two
  `drm failed to set mode: No space left on device` (8 in `Xorg.0.log` by the end).
  `xrandr`: `HDMI-1 connected` with its EDID modes, not enabled. The monitor showed nothing;
  after each unplug the panel showed part of the taskbar.
- So the repro never reached the fault, and 0051-0052 aren't confirmed against it. The kernel
  ran the desktop normally.

## 2026-11-11 — where the X mode sets' `ENOSPC` comes from (R51)

Release card, `5.6.19-m4-kbdled-test` from l1, stock `armsoc-omap5` 0.6, panel rotated `right`, the
1080p monitor plugged and `connected` but disabled after the R55 plug-ins.

- `/sys/kernel/debug/dri/0/framebuffer` before the test: the only Xorg fb was 1280x720, while
  `xrandr` reported a 2640x1080 screen.
- With `echo 0x04 > /sys/module/drm/parameters/debug`, `xrandr --output HDMI-1 --mode 1920x1080
  --right-of Unknown16-1` failed (`Configure crtc 1 failed`). dmesg, in order:
  `drm_framebuffer_check_src_coords: Invalid source coordinates 1280x720+0+0 (fb 1080x3200)` on
  crtc-0 (panel), then `1080x1920+1280+0 (fb 1280x720)` on crtc-1 (HDMI), then
  `1280x720+0+0 (fb 1080x2640)` on crtc-0 again. Debug set back to 0 afterwards.
- Read against the stock 0.6 source: `armsoc_dumb.c` allocates the rotated buffer with width and
  height swapped, and `drmmode_revert_mode` resizes it to the panel's unrotated mode. The driver
  sets the panel's rotation on every plane, which is why HDMI's viewport is swapped too.
  `ddx-patches/0002` (branch `hdmi-r51`) changes all three. Explanation in troubleshooting.md, "An HDMI monitor
  shows nothing above 640x480".

## 2026-11-11 — HDMI hotplug under X with `armsoc-omap5` 0.6+pyra1 (R51, R55)

Release card, `5.6.19-m4-kbdled-test` from l1, `xserver-xorg-video-armsoc-omap5_0.6+pyra1`
(ddx-patches 0001-0002, built 2026-11-03) installed over stock 0.6 with `dpkg -i`, lightdm
restarted. The 1080p monitor (EDID preferred 1920x1080) was plugged the whole time. `drm.debug=0x04`
during the test, 0 afterwards.

- X start with the monitor attached: screen 3200x1080, panel `1280x720+0+0 right`, HDMI
  `1920x1080+1280+0`. No `(EE)`, no `No space left` in `Xorg.0.log`.
- Owner unplugged, waited about 10 s, plugged back in. dmesg: `HDMI-A-1 disconnected`, then on the
  replug `drm_mode_setcrtc` on crtc-1, crtc-0, crtc-1 with no `Invalid source coordinates` line.
  X logged `hotplug=1` and resized to 2640x1080 (MATE's layout, HDMI at `+720+0`). Both mode
  sets succeeded. After the replug the kernel probed HDMI-A-1 about 120 times in roughly
  35 s (EDID read each time), then stopped.
- What the owner saw: the monitor alternated between black and "no signal", with the
  wallpaper for a split second once. The panel went black briefly, then showed the desktop
  with the wallpaper overlapping on the right (the +720 placement).
- `xrandr --output HDMI-1 --mode 640x480 --pos 1280x0`: rc 0, screen 1920x720. The DRM
  state was right (both planes on one 1920x720 fb; panel src 1280x720+0+0 rotation 270, HDMI
  src 640x480+1280+0), but both the panel and the monitor were black, even with a white
  xterm on the HDMI area. Backlight 6/15, DPMS on, no DSS errors. `xwd -root` still had
  the taskbar.
- Back to `--mode 1920x1080 --pos 1280x0` (screen 3200x1080): panel back, monitor black.
- `xrandr --fb 3200x1080 --output HDMI-1 --mode 640x480 --pos 1280x0`: the monitor showed the
  white xterm ("HDMI TEST 640x480"), panel fine. That's the first X picture on an external
  monitor from a release card.
- R55: no GC320 fault the whole session (no `etnaviv` hang/recover/MMU line in dmesg).
  The GC320's debugfs `gpu` showed `idle: 0x7fffffff` with the FE parked on END, which is
  etnaviv's runtime-suspend state, not a hang. So no `systemctl restart lightdm` recovery test.
- The card keeps 0.6+pyra1 (owner's choice). The stock deb for the undo is in `~/ddx-undo/`.

## 2026-11-11 — a screen resize on `armsoc-omap5` 0.6+pyra1 and 0.6+pyra2 (R56)

Release card, `5.6.19-m4-kbdled` from l5 (the card rebooted on l5 after the hang in
troubleshooting.md, "Reading a TILER framebuffer with the CPU"). The 1080p monitor was plugged
the whole time. The owner watched the screens.

- `0.6+pyra1`, X at 3200x1080 (panel `1280x720+0+0 right`, HDMI `1920x1080+1280+0`, both planes
  on fb 61). `xrandr --output HDMI-1 --off`: screen 1280x720, panel plane on the new fb 58,
  1280x720. The owner saw the panel **black**. So the panel alone reproduces it.
- Cause from the source: `src/viv2d/viv2d_exa.c` imports the scanout into etnaviv once in
  `InitViv2DEXA` (`v2d->bo`). After `resize_scanout_bo` swaps the scanout,
  `Viv2DModifyPixmapHeader` and `Viv2DAttachBo` still give the screen pixmap that old import. So
  the GC320 draws into the old buffer, and the planes scan out the new one, which
  `armsoc_bo_clear` left black.
- `ddx-patches/0003` (`ScanoutChanged` hook, re-import through a PRIME fd), built as `0.6+pyra2`
  (hdmi-r51 2584736) and installed with `dpkg -i`. lightdm restarted: X at 3200x1080, HDMI at
  `+1280`, no `(EE)`.
- `xrandr --output HDMI-1 --off`: screen 1280x720, panel on fb 61. The owner saw the **desktop,
  and it redrew**.
- `xrandr --output HDMI-1 --mode 640x480 --right-of Unknown16-1`: screen 1920x720 with no
  `--fb`, both planes on fb 60. The owner saw the **desktop on both** the panel and the monitor.
- Not explained: on `0.6+pyra1`, growing back to 3200x1080 brought the panel back, though the
  import was just as stale.

## 2026-11-11 — HDMI PHY and PLL registers under X, decoded (R51)

Release card, `5.6.19-m4-kbdled`, X running with `armsoc-omap5` 0.6+pyra2, HDMI at 640x480 beside the
panel. Read-only: `sudo python3 /tmp/hdmireg.py dump`, plus `r 0x4A002E0C`. No register was written.

- PHY `+0x00`-`+0x1C`: `00000000 f0000000 bf1bcc80 00107d80 11002c00 00007800 00000000 00000800`. The PHY
  decodes 5 address bits: `+0x20`-`+0x3C` reads the same eight words again.
- PLL CONFIGURATION2 `00602004`: PHY_CLKINEN (bit 14) is 0, where the AM572x TRM's Table 11-14 recommends 1.
- HDMI_WP_PWR_CTRL `000000aa` (PHY TXON, PLL ON_ALL); CONTROL_HDMI_TX_PHY `10000000` (reset value).
- ldo4 (the HDMI and DSI VDDA): 1800 mV, from the regulator debugfs summary.

The field-by-field decode, and which fields no public document covers, are in `experiments/hdmi-signal`.


## 2026-11-11 — HDMI at 1024x768: the two documented PLL writes, and the core's PHY I2C master (R51)

Release card, `5.6.19-m4-kbdled`, X stopped, BenQ GW2760HS on the 3' cable. With the EDID read cleanly, the
console came up at 1024x768 (wrapper video size `03000400`; PLL N 8, M 541.667, M2 2, DCO 1300 MHz, 650 Mb/s per
lane), and the monitor kept dropping its picture with sideways static between drop-outs. The owner timed the
seconds between drop-outs by eye; each write was made with `hdmireg.py` with the mode held and read back.

| PLL state | Seconds between drop-outs | Median | Longest |
| --- | --- | --- | --- |
| driver's point (CONFIGURATION2 `00602004`) | 19 8 12 3 3 7 4 6 1 5 5 1 4 7 11 9 1 4 | 5 | 19 |
| PHY_CLKINEN on (`00606004`, no GO, STATUS 3) | 17 6 16 1 1 1 2 6 6 2 4 4 2 2 17 | 3 | 17 |
| M2 3, DCO 1950 MHz (CFG1 `0006580e`, CFG3 `00002000`, CFG4 `000e0000`, CFG2 `00602008`, GO, STATUS 3) | 4 3 9 4 19 7 14 2 12 3 7 125 45 | 7 | 125 |
| driver's point again (CFG1 `00043a0e`, CFG3 `00001800`, CFG4 `000aaaaa`, CFG2 `00602004`, GO, STATUS 3) | 4 3 4 11 5 19 8 4 9 8 4 10 4 | 5 | 19 |

Order: an untimed look at the driver's point ("1.5-5 s"), then PHY_CLKINEN on, then the bit back off and the
first row timed, then M2 = 3, then the driver's point again. The static looked the same in every state. M2 = 3 was applied once; the owner stopped the
testing before a repeat.

The core's PHY I2C master (`phyi2c.py`): `PHY_CONF0` `06` (PDZ 0), `PHY_STAT0` `01`, `MC_PHYRSTZ` `00`,
`I2CM_DIV` `0b`, `IH_MUTE` `00`. Reads at slave `0x69` (registers 0x00, 0x09, 0x0e, 0x19) and `0x49` (0x00) all
timed out after 50 ms with neither DONE nor ERROR in `IH_I2CMPHY_STAT0`. No dmesg output. Afterwards the PLL was
back at the driver's values and lightdm was restarted.

## 2026-11-12 — the CI release image with `kernel-5.6.19-r2` (R54)

A card written from the Release image run 43138203935 (master, 2026-11-12), whose
kernel is the `kernel-m4-kbdled` artifact of Kernel release run 43135826496
(`kernel-5.6.19-r2`). First boot grew the root filesystem to 239 GiB.

- **The kernel is the published asset.** `/boot/vmlinuz-5.6.19-m4-kbdled` has the
  same SHA-256 as the one in r2's `m4-kbdled-kernel.tar.gz` as downloaded, and
  the tarball matches r2's `SHA256SUMS` (`aa2498ff…53bc2`). It carries 0001-0052.
- **Release mode:** password changed at first login, ssh host keys made by
  `pyra-ssh-hostkeys.service` on that boot, a new machine-id, no NOPASSWD rule
  from the image. No failed units.
- **Suspend:** one `rtcwake -m mem -s 20` cycle, suspend_stats success 1, fail 0.
  The keypad answered on i2c-1 `0x34` afterwards. The resume printed only what
  `troubleshooting.md` already lists: `Unbalanced enable for IRQ 144` (SGX) and
  four `DSI error: VC(n) busy`.
- **Key let go while asleep** (the R53 procedure, by the owner's hands): the
  keyboard worked after the wake.
- **Headphone jack switching** (owner): sound moved between the speakers and
  the headphones on plug and unplug.
- **ldconfig warning on `apt install`:** `ldconfig: /lib/libpvrDRI3WSEGL.so is
  not a symbolic link`. The vendor package `dri3wsegl-pyra` installs that library
  as a regular file whose name is its own SONAME; fix 21's patched copy was in
  place (`.stock` beside it). Harmless, `troubleshooting.md`.
- Not covered: the no-option prep run on a fresh vendor image (R54), HDMI.

## 2026-11-12 — game buttons as wake sources; patches/0053 per-button wake

Release card. Suspend to RAM through `/sys/power/state`, RTC armed as a backstop, one button
pressed per round while asleep. Interrupt counts read from `/proc/interrupts` before and after.

- **Shipped `5.6.19-m4-kbdled`:** all 14 `pyra-game-buttons` nodes carry `gpio-key,wakeup`.
  Each shoulder button woke a 60 s-backstopped suspend in 3-6 s; only its own count rose.
- **Same kernel, `pyra-game-buttons/power/wakeup` = `disabled`:** left shoulder top, then A,
  each slept the full 45 s and was woken by IRQ 152 (palmas, the RTC). Put back to `enabled`.
- **`5.6.19-m4-kbdled-test` (the shipped build plus 0053) from l1:** `wakeup_keys` read
  `54,97,100,102-109,126,272-273` on `pyra-game-buttons`, `169` on `user-buttons`;
  `wakeup_switches` read `0` on `pyra-lid-wakeup`. Writing `1` was refused (`Invalid
  argument`) and left the set unchanged. With `102-109,272-273` written: left shoulder top
  slept 46 s (RTC), A woke it in 9 s (IRQ 113, `48051000.gpio`, A 0 -> 3), right shoulder
  bottom slept 47 s (RTC).
- Not covered: the lid as a wake source, the udev rule, the `fdtput` DTB edit, the shoulder
  buttons as input after the resume.

## 2026-11-12 — critical battery: shutdown, not hibernate (fix 24)

Release card, shipped `5.6.19-m4-kbdled`, desktop session logged in. Before the change:
`action-critical-battery` read `'hibernate'`; logind `CanHibernate` and `CanHybridSleep` were
`na`; `/sys/power/state` read `freeze mem`; UPower 1.90.9 ran with `CriticalPowerAction=HybridSleep`,
and its `GetCriticalAction` returned `PowerOff`.

Method: fix 24's override installed by hand and the schemas recompiled. `GSETTINGS_BACKEND=memory
gsettings get` then read `'shutdown'`. For one boot, upowerd was pointed at a copy of
`UPower.conf` in `/run`, with `PercentageLow/Critical/Action` at 97/96/95. That was done through
`UPOWER_CONF_FILE_NAME` in a runtime drop-in, which is gone after a reboot. The battery read
77 %, discharging. The charger chip reported `ONLINE=0` throughout, even with a charger plugged
in (the known `bq24297` quirk, 2026-09 note above), so UPower's `OnBattery` read `true`.

- **Test:** upowerd started at 06:09:54.99 with `warning-level: action`. MATE showed "…about to
  shutdown" (seen by the owner). logind logged "The system will power off now!" at 06:10:15.24,
  20.2 s later. After the next boot the drop-in was gone and `GetCriticalAction` returned
  `PowerOff`.
- **An earlier, aborted run:** upowerd was restarted at action level at 06:05:31.74, then
  restarted again without the test config at 06:05:43, which left the warning level at `none`.
  logind still powered off at 06:05:52.24, 20.5 s after the first restart. UPower's timer
  had died with its process, so this was mate-power-manager's 20 s timer, which it never
  cancels (`gpm-manager.c`). That mate-power-manager started after the override went in.
- Prep selftest with fix 24 (a043b11), run by the owner: 280 passed, 0 failed, 0 skipped.
- Not covered: a real drain to 2 %, and whether the fuel gauge reaches 2 % before the cell's
  cut-off.

## 2026-11-14 — login time: ukui-polkit's timeout and mate-session's GL check (fix 25)

Release card, `5.6.19-m4-kbdled`, MATE through lightdm, logged in at the greeter with a password.
Times from the journal (`-o short-precise`) and from each process's start time in
`/proc/PID/stat`, the latter corrected by +0.9 s to the journal's clock (dconf-service: 15.61 in
`/proc`, 16.53 in the journal). Method: `profiling-guide.md` §3.3.

- **As shipped** (second login of the boot, warm): session opened 17:50:47.57; mate-settings-daemon
  and `polkit-ukui-authentication-agent-1` started at 17:50:54.0; marco at 17:51:23.9, 36.3 s after
  the session opened. `~/.xsession-errors`: "Application 'polkit-ukui-authentication-agent-1.desktop'
  failed to register before timeout". The first login after the boot took about 42 s to marco.
- **First override, without `Exec=`:** no change. mate-session logged "Could not parse desktop
  file … does not have key 'Exec'" and started the agent from `/etc/xdg/autostart` anyway.
- **Override with `Exec=` and `Hidden=true`:** session opened 17:53:10.29; marco at 17:53:16.8,
  6.5 s later. No timeout warning; the running agent was `polkit-mate-authentication-agent-1`.
  The owner saw the desktop come up faster.
- **GL check:** in that 6.5 s, the first `mate-session-check-accelerated` ended at 17:53:10.99 and
  the second, with `LIBGL_ALWAYS_SOFTWARE=1`, at 17:53:16.39 (`gl_failed!` at 16.51). The second
  asked for `org.a11y.atspi.Registry` at 17:53:11.18 and logged nothing more until it exited. Run
  by hand over ssh with `_GNOME_SESSION_ACCELERATED` removed from the root window, each mode took
  0.26 s. A `grep -a` of marco, mate-panel, caja, mate-settings-daemon and libmarco-private found
  neither `_GNOME_SESSION_ACCELERATED` nor `_GNOME_SESSION_RENDERER`.
- apt's choice of agent, simulated with `apt-get install -s` of a stand-in `pyra-meta-mate` in a
  `debian:trixie` armhf container: as shipped, both agents; `mate-polkit` listed before
  `network-manager-gnome`, only `mate-polkit`; listed last, both.
- The card's apt history shows both agents installed on 2026-02-01 by the image build's
  `apt install pyra-meta-mate`, so the vendor image carries ukui-polkit.
- Prep selftest with fix 25 (96975ec), run by the owner: 289 passed, 0 failed, 0 skipped. The
  first run, at 9974cd3, stopped before fix 1: prep looked for `--disable-acceleration-check` in
  the mate-session binary, but GOption keeps the name without its dashes.
- **Both in place** (18:20 login): the session ran as `x-session-manager --disable-acceleration-check`;
  session opened 18:20:38.81, dconf requested at 18:20:39.28 (0.5 s, was about 6 s behind the GL
  check), marco at about 18:20:39.6, 0.8 s after the session opened. `~/.xsession-errors` had no
  acceleration, ukui or timeout lines; `polkit-mate-authentication-agent-1` was running.

## 2026-11-17 — the CI release image with `kernel-5.6.19-r3` and pyra-settings 0.14 (R62, R52)

A card written from the Release image run 44230398383 (master ef6ee24, 2026-11-18 UTC), whose
kernel is the `kernel-m4-kbdled` artifact of Kernel release run 44223360396 (`kernel-5.6.19-r3`).
Serial console (FTDI, 1500000 baud) and ssh.

- **The kernel is the pinned asset.** `/boot/vmlinuz-5.6.19-m4-kbdled` has the same SHA-256
  (`f57911a5…6dc5ce7`) as the one in r3's `m4-kbdled-kernel.tar.gz`, downloaded and checked
  against prep's pin. `l5` is the default. No failed units.
- **Fix 26:** `pyra-settings 0.14`, `pyra-hacks 0.38+pyra3` and `pyra-backlight 0.8` installed.
  The run raised no "no pyra-settings" warning (its only annotations were GitHub's Node.js 20
  deprecation notices). The `.info` itself sits in the job log, which needs a login to read.
- **Wake page** (owner): the settings app's wake-button page shows and works on this kernel.
- **First-boot grow:** `done: the root filesystem is now 238 GiB`, with the samples written
  through `/dev/.pyra-grow-mmcblk1` (the 2026-11-17 change). fsck dry runs 55.8 s and 67.1 s,
  `resize.f2fs` 407.2 s. Root 239G, 234G free.
- **R52 closed:** root mounted at 553.88 s and systemd started at 554.07 s (serial console),
  0.2 s between them, against 35.6 s and 48.7 s on the two earlier CI images. The owner saw no
  udev timeout on the LCD. Kernel phase 9 min 14 s (the grow), userspace 27.4 s.
- **Not in the image:** pyra-sound, so MATE's own sound icon is in the tray. Prep never
  installed it; it ships with the release (owner, 2026-11-17).

## 2026-11-18 — the CI release image with pyra-sound 0.4 (fix 27, R66)

A card written from the Release image run 44238538079 (master 1bd7e2b, 2026-11-18 UTC), same
kernel artifact as the entry above (`kernel-5.6.19-r3`, Kernel release run 44223360396). ssh.

- **Image:** the run raised no "no pyra-sound" warning (its only annotations were GitHub's
  Node.js 20 deprecation notices). `5.6.19-m4-kbdled #10`; `pyra-sound 0.4`,
  `pyra-settings 0.14` and `pyra-backlight 0.8` installed.
- **Fix 27 at the desktop:** `/usr/bin/pyra-sound` starts with the session, and no
  `mate-volume-control-status-icon` runs. `/etc/xdg/pyra/autostart/mate-volume-control-status-icon.desktop`
  is the link into `/usr/share/pyra-sound/`. No traceback in `~/.xsession-errors`; pyra-sound's
  only lines there are Gtk warnings about the `pyra` icon theme's index (a directory with no
  size field, a theme file with no name), which do not stop the icon showing.
- **Owner:** one sound icon in the tray. Left click mutes and unmutes, right click switches
  between speakers and headphones, and the wheel moves the volume it shows.

## 2026-11-18 — wake buttons end to end through pyra-settings 0.14 (R60)

The card from the 2026-11-18 entry above (Release image run 44238538079, `5.6.19-m4-kbdled`
from `kernel-5.6.19-r3`, `pyra-settings 0.14`). ssh, and the owner at the Pyra pressing the
buttons.

- **App to sysfs:** with the shoulder buttons already off, the owner unticked the d-pad group on
  the app's wake page. `pyra-game-buttons/wakeup_keys` read `102,104,107,109,272-273`, and
  `/etc/pyra-settings/pyra-settings.conf` held `game-buttons = 102,104,107,109,272,273`.
  `power/wakeup` stayed `enabled`.
- **Across a reboot:** after `systemctl reboot`, `wakeup_keys` read the same set (the device
  tree's default is all 14). `pyra-settings-apply.service` ran
  `pyra-settings-helper apply` and exited 0 during boot. Before the app had saved anything, the
  unit is skipped (`ConditionPathExists` on the config file), which is expected.
- **Suspend:** a detached script, three rounds, each with the RTC armed 45 s out, and the owner
  pressing that round's button a few times while the screen was dark:

  | round | button | in the set | slept | `pm_wakeup_irq` | its interrupt count |
  | --- | --- | --- | --- | --- | --- |
  | 1 | left shoulder bottom (54) | no | 46 s | 152 (Palmas, RTC) | 0 → 0 |
  | 2 | d-pad up (103) | no, removed in this session | 46 s | 152 | 0 → 0 |
  | 3 | A (102) | yes | 5 s | 113 (`48051000.gpio`) | 0 → 3 |

  The buttons left out were masked, not merely ignored: their counts did not move. The card
  was left with the d-pad off (owner).

## 2026-11-18 — prep's default kernel path: no `--kernel`, the pinned r3 download (R54)

`pc/pyra-trixie-prep.sh` at master 0a22732, run as root on the PC against a fresh copy of the
pinned vendor image (`pyra-trixie-t1.img`, SHA-256 `d8e98ff6…` as in `pyra-vendor-image.sh`),
loop-mounted, user `pyra`, `--ssh-key` and no other option. This is the path a stranger takes;
the selftest always passes `--kernel` and the CI image takes the kernel artifact.

- **Download:** prep asked to download `kernel-5.6.19-r3` from the release URL (default answer
  Y), fetched 23.00 MB and printed `OK fix19: the download matches the pinned SHA-256`. The
  pyra-backlight 0.8, mate-panel GIR, pyra-settings 0.14, pyra-hacks 0.38+pyra3 and
  pyra-sound 0.4 downloads matched their pins too. Fix 19 installed `5.6.19-m4-kbdled` into
  `l5` with its initrd and ended `done`.
- **The image it wrote** (p1 mounted read-only afterwards): `extlinux.conf` says `default l5`,
  `user.cfg`'s `l5` boots `/vmlinuz-5.6.19-m4-kbdled`, and that file's SHA-256 is
  `f57911a5…6dc5ce7`, the same as the `vmlinuz` in r3's `m4-kbdled-kernel.tar.gz`.
- **Not written to a card.** The kernel prep installed is byte-for-byte the one on the r3 CI
  card (2026-11-17 entry: same `vmlinuz` hash, boots from `l5`), installed by the same fix 19
  code, so a boot of this image would repeat that check (owner's call).
- **Keyboard after a key is let go during suspend** (`building.md`, "Stop the built-in keyboard
  going silent"), on the r3 CI card, whose running `vmlinuz` has the same hash: the owner held a
  letter key, suspended (deep), let go while asleep and woke it. The keyboard worked, the held
  key included. The resume's only warnings were the SGX `Unbalanced enable for IRQ 144` and
  DSI `VC busy` lines `troubleshooting.md` already lists.

## 2026-11-19 — `pyra_volumed` retries until the card is there (fix 26, pyra-hacks 0.38+pyra4)

A card written from the Release image run 44602488525, which installs the fork's `0.38+pyra4`
(7ae5da8's pin).
`5.6.19-m4-kbdled #10` (r3); `pyra-hacks 0.38+pyra4`, `pyra-settings 0.14`, `pyra-sound 0.4`.
ssh.

- **Unit:** `pyra_volumed.service` has `Restart=on-failure`, `RestartSec=2`,
  `StartLimitBurst=30`, `StartLimitIntervalSec=120`.
- **First boot:** the root grow held the boot back, so the L15 card registered (`AESS path,
  9 DAI links`) at 563 s and the daemon started after it, at 571.7 s: no exit, `NRestarts=0`.
  The retry was not exercised.
- **Second boot (owner's reboot):** the kernel printed `AESS path, 9 DAI links` at 18.04 s, but
  the daemon, started at 18.58 s, could not yet open the card by name (`Cannot get card index
  for L15`, `no volume controls on hw:CARD=L15 yet`) and exited with status 1. systemd restarted it at 21.99 s and it stayed up:
  `NRestarts=1`, `active`. With 0.38+pyra3 that start would have left the wheel dead for the
  boot.
- **Owner:** the pyra-sound tray icon works on both boots. After the reboot, audio played and
  the tray switched it between headphones and speakers. That path is pyra-sound's, not the
  daemon's. The wheel then moved the volume on the speakers and on the headphones, so the
  restarted daemon drives both.

## 2026-11-19 — the vendor image's host keys, offline, and who makes them on a release card (R29)

The pinned vendor image (`pyra-trixie-t1.img`, SHA-256 matches `pyra-vendor-image.sh`), its
rootfs read as user (p2 cut out with `dd`, `udisksctl loop-setup -r`, mounted read-only), and the card from Release image run 44602488525 over
ssh.

- **Vendor keys:** three pairs in `/etc/ssh`, dated 2026-02-01 14:02:20 (-0500), comment
  `root@tmp.hqbumtgUce`. `ssh-keygen -lf`: RSA 3072 `SHA256:iv6iHTNxKendhnQSZVsq5kt34xkCrIKKWGVj4ZbSOtw`,
  ECDSA 256 `SHA256:qPFn0/ETBAaBT68QWH8F45z0qxu4IsfRXoB3XzBxtWA`, ED25519 256
  `SHA256:lFvFpp1MSRkDvXSaniRV2e4MsdzRojegxgMkdXBnq74`. The SHA-256 of each public blob
  matches fix 23's pins. `/etc/machine-id` and `/var/lib/dbus/machine-id` (a separate file)
  both hold `79a963ec48d841ac8059acf6d6c75649`.
- **openssh-server's keygen unit:** the image has `/usr/lib/systemd/system/sshd-keygen.service`
  (from openssh-server; `ConditionFirstBoot=yes`, runs `ssh-keygen -A`), enabled through
  `ssh.service.wants`, `sshd.service.wants`, `sshd@.service.wants` and `ssh.socket.wants`. On
  a vendor card it never runs, because the set machine-id means no boot is a first boot.
- **On the release card's first boot** (the grow boot), from its journal: `pyra-ssh-hostkeys.service`
  started at 570.0 s and logged `generating new host keys: RSA ECDSA ED25519`;
  `sshd-keygen.service` was `skipped because of an unmet condition check (ConditionFirstBoot=yes)`.
  So an empty `/etc/machine-id` is not a first boot. The image's own `machine-id(5)` (systemd
  257.9) says so (rule 4: exists and empty, not a first boot). Prep's unit is what makes the
  keys, and `systemd-firstboot` would not have started either; its mask stays as a guard.
  `fixes.md` fix 23 and `procedure.md` §4 said the empty file made a first boot; corrected.

## 2026-11-19 — the pack thermistor on the Palmas GPADC (BACKLOG E9, read-only)

The CI release image (Release image run 44602488525) on a V5.3 board, `5.6.19-m4-kbdled`, over ssh. Only
`cat` of sysfs; no charger or GPADC writes. The owner plugged the charger in partway through.

- **Channels:** `palmas-gpadc` (`iio:device1`) exposes IN0-IN2, IN4-IN11, IN14, IN15 as voltages and
  IN3, IN12, IN13 as temperatures. The DT node (`omap5-board-common.dtsi`) enables the 5 µA channel-0
  and 10 µA channel-3 current sources. IN3 reads 4095 raw (full scale) with or without a charger.
- **Battery, no charger:** IN0 111 mV, IN1 5-9 mV (6 reads), IN10 0, bq27421 `temp` 27.1-27.5 °C.
- **Charger in** (`bq2429x: VBUS became available`, `r9=00`, `Charging`): IN0 843 mV, IN1 5-9 mV,
  IN10 4963 mV. The bq24297's `temp` stays 225: the driver's fixed value, not a reading.
- **20 minutes charging**, 40 samples at 30 s (`experiments/charging/gpadc-in0-charge-20261119.tsv`):
  IN0 841 → 800 mV while the gauge went 27.6 → 32.0 °C; linear fit -10.2 mV/°C, r = -0.96. IN1
  stayed 7-13 mV.
- **Result:** IN0 is the BTEMP tap through R2001/R2002, biased only while REGN is on. IN1, which
  Goldelico's `battery-monitor` node names the temperature channel, carries nothing on this board.
  The conversion to °C is a fitted model, not a calibration (`experiments/charging/README.md`).
- **Re-check for the report (R67), same card, later that night, charging at 153 mA:** IN6 (the node's
  "voltage") 4006-4007 mV against the gauge's 4045-4046 mV; IN11 ("current") 0; IN1 2-8 mV; IN0
  780-785 mV. `battery-monitor` exists as a platform device (`MODALIAS=of:Nbattery-monitorT(null)Clinux,generic-adc-battery`)
  and the module's alias matches it. What keeps it unbound is `/etc/modprobe.d/pyra-noadcbat.conf`
  (`blacklist generic_adc_battery`, package `pyra-config-modprobe` 0.39).

## 2026-11-20 — margin to the bq24297's hot cut-off through one charge (R69, read-only)

The CI release image on a V5.3 board, `5.6.19-m4-kbdled`, over ssh. `pyra-chgwatch.sh --ts` run as root
from `/tmp` (10 s samples), sysfs and `dmesg` reads only; no charger or GPADC writes. The owner
plugged the charger in at 86 %.

- **Driver:** no "failed to request chg_irq ... polling" line at probe, so the bq2429x driver reads
  REG09 only from its interrupt handler. Its `registers` sysfs file does a raw i2c read of REG09 that
  clears the latch without updating the driver (source, `show_registers`); `--ts` avoids it.
- **Charge** (`experiments/charging/ts-margin-charge-20261120.tsv`): fast charge 368 → 145 mA, then
  `r8=b4 ADAP CHGTERM` after 27 min. IN0 839 → 786 mV (min 778), computed VTCO 666-671 mV (IN10
  4889-4988 mV), margin 171 → 117 mV, minimum **111 mV**. Gauge 27.5 → 32.9 °C; IN0 −9.9 mV per gauge
  °C, r = −0.95.
- **Faults:** none. The bq24297 `temp` read 225 throughout. The kernel log showed only `r9=10 UNPLUG` and
  `r9=00` at plug-in and `r9=00` at termination.
- **Result:** the mode works end to end. No natural `HOT`, so the trip itself (TODO E9 b) is still
  unmeasured.

## 2026-11-20 — `registers` reg 09 is the driver's copy with 0054 (R70)

The CI release image on a V5.3 board, `5.6.19-m4-kbdled-test` (the shipped patch set plus `patches/0054`,
cross-built that day) booted once from `l1`; `l5` stayed the default. Over ssh, a root shell loop once a
second: `registers` reg 09, the last `r9=` in `dmesg`, `bq24297/online`, and kprobe hit counts on
`bq2729x_irq_work_func` (interrupt path) and `usb_detect_work_func` (polling path). The owner unplugged
the charger for about 18 s and plugged it back in; then one `rtcwake -m mem -s 20` suspend.

- **reg 09 against the driver:** 118 samples, 0 mismatches. While the charger was out, `registers` showed
  `10` (UNPLUG) on all 16 samples, the same as the driver's `r9=10`. Before 0054 the first read would have
  cleared it, and the next sample would show `00`. At plug-in both went back to `00` together
  (`r9=10 UNPLUG`, then `r9=00` 0.12 s later in the log).
- **Interrupt only, also after resume:** 4 interrupt-path calls (unplug, plug-in twice, one during
  suspend entry), 0 polling-path calls, including the 25 s after the resume. The driver's
  `.driver.suspend`/`.resume` hooks never run. On 5.6 the i2c bus has no PM ops, and the PM core doesn't
  call a `device_driver`'s legacy hooks (`drivers/base/power/main.c`), so nothing ever starts the 1 s
  polling work on a board with the interrupt.
- **Boot:** desktop up, no new `BUG:`/`WARNING:` (only the `omap_l3_noc` one every kernel prints).

## 2026-11-20 — the charge voltage limit is 4.048 V, written by the driver at probe (R71, read-only)

The CI release image on a V5.3 board (`Pyra-Handheld-V5.3`), `5.6.19-m4-kbdled-test`, charger in, `Full`,
over ssh. Nothing was written to the charger.

- **Register:** `registers` reg 04 = `8a`, i.e. VREG = 3.504 V + 34 × 16 mV = 4.048 V; BATLOWV 3.0 V, VRECHG
  100 mV. reg 05 = `8c`: watchdog off. The chip's reset value for reg 04 is `0xB2` (4.208 V; SLUSBP6D
  §9.6.1.5), so this is a host write, not a default or a watchdog reset.
- **Writer:** `bq2429x_init_registers()` computes min(vsys `regulator-max-microvolt` − 150 mV, battery
  `voltage-max-design-microvolt`) = min(4.05, 4.2) V and rounds it down to 34 steps. Boot log:
  `bat_volt_max = 4200000`, then `found regulator-max-microvolt = 4200000`. The source of the driver's init path
  and the DT node is the same in the vendor's 5.6.19-pyradef, the shipped patch set and current letux. 0054
  changes only the `registers` read, so `5.6.19-m4-kbdled` (l5) writes the same value (from the source; not read
  on l5 this session).
- **Userspace:** no udev rule, unit or script on the card writes charge voltage, `i2cset` isn't installed,
  and the driver has no `constant_charge_voltage` property.
- **Gauge at the limit:** `bq27421-0` 4.035 V, 87 %, charger `Full`.

## 2026-11-20 — the r5 release image on a Pyra, and a charger replug (R29, R15)

Release image run 44856229687 (draft `image-2026.11-r5`, built from 19234e0) written to a card and booted
on a V5.3 board. Checks over ssh, read-only; the owner unplugged and replugged the charger.

- **Download:** `sha256sum -c` OK; `gh attestation verify` with `--signer-workflow
  .../release-image.yml` exits 0 for the `.img.xz`, both `.sha256` and the `.info`. A copy with one byte
  changed gets HTTP 404 (no attestation). `.info`: `repo_dirty=no`, pyra-hacks 0.38+pyra4, pyra-settings
  0.14, pyra-sound 0.4, pyra-backlight 0.8, the r3 kernel tarball.
- **Card:** `5.6.19-m4-kbdled`, `systemctl is-system-running` = running, no failed units, root grown to
  239 G, host keys and machine-id made at first boot, password changed at first login, dpkg guards
  `pyra-thermal-guard`, `pyra-wheel-guard`, `pyra-wsegl-guard`.
- **Charger limit (fix 8, R15):** charger in at boot, `max_current` 2000000. After a physical unplug and
  replug on the USB3 micro port: **3000000**. Kernel log: `VBUS became available` at 2240.640 s, then
  `r8=a4 ADAP FCHG PWRGOOD` at 2240.761 s. The udev rule matches the device (`udevadm test`), and the only
  writer on the card is `pyra-charge-current-apply` (2 A); so the chip's own adapter detection set 3 A after
  the rule ran (inferred, not traced). Fix 8's purpose holds (not stuck at 500 mA); the "2 A after every plug"
  claim did not.

## 2026-11-21 — fix 8 after a charger replug, traced and fixed (R74)

The r5 release card, `5.6.19-m4-kbdled` (l5), same 15 W brick and cable throughout; the owner did the
replugs. Tracing: kprobes on `bq2429x_set_input_current_limit_uA` (with its `uA` argument),
`bq2429x_input_current_limit_uA_store` and `bq2429x_usb_detect`; the `i2c_write` tracepoint filtered to
address 0x6b and length > 1; a python poller reading `max_current` every 10 ms (REG00 only, `registers` not
read). Times are monotonic seconds.

- **Cause (USB3 port, stock helper):** VBUS interrupt 11853.517, driver writes REG00 `0x36` at .522;
  `max_current` 100000 from .526; the helper writes `0x36` at .548 and the reads stay 100000; detection
  interrupt (`r8=a4 ADAP`) at .639 with no host write; `max_current` 3000000 at .643. The chip holds 100 mA
  during D+/D− detection, discards host writes, and writes its result last.
- **With the re-check helper, USB3 port:** 100000 at 11986.964, 3000000 at 11987.089 (ADAP), 2000000 at
  11987.301 from the settle job; journal `limit was 3000000, set 2000000 again`.
- **With the re-check helper, normal micro port:** 100000 at 12015.490, 500000 at 12016.040 (detection
  ends `r8=24`, no type, 0.55 s after VBUS), 2000000 at 12016.137; journal `limit was 500000, set 2000000
  again`. Two helper writes during detection (12015.535, .898) were lost, as on USB3.
- After both: `max_current` 2000000, no failed units, the transient units collected.
- Not tested: a laptop port after a replug (does the chip detect SDP and pick 500 mA, and does 2 A pull
  it out of spec); a supply whose detection takes longer than the 10 s re-check window.

## 2026-11-21 — which U-Boot runs, and the vendor archive upstream (R75, read-only)

The r5 release card in the left slot, `5.6.19-m4-kbdled`; the card is `mmcblk1`, the eMMC `mmcblk0`. Method:
`dd` of the first 8192 sectors of each device through `strings -n 6`, grepping for the version banners and
for `vidconsole`, `usb_kbd`, `sysboot`, `pxelinux.cfg`, `Enter choice`.

- **Card:** `U-Boot SPL 2016.11 (Sep 11 2024 - 22:42:22)` and `U-Boot 2016.11 (Sep 11 2024 - 22:42:22 +0000)`,
  matching the installed `u-boot-pyra` 0.1.5 (`/usr/lib/u-boot/pyra/MLO`, `u-boot.img`).
- **eMMC (this unit):** `U-Boot SPL 2016.11-g8e417ba870-dirty (Jan 07 2021 - 21:35:15)` and
  `U-Boot 2016.11-g0fecbc0a98-dirty (Dec 24 2020 - 19:14:56 +0100)`. Forum posts by the team (2021-2025) say
  later units were flashed with newer U-Boot builds; their version is not known here.
- Both: no `vidconsole` or `usb_kbd`; `sysboot`, `pxelinux.cfg` and `Enter choice` present. building.md's
  "no display driver" holds for both copies.
- **Vendor archive, 07:34-07:36 UTC from the PC:** `images/trixie/pyra-trixie-t1-brokenxorg.7z` HTTP 200,
  862273362 bytes, last-modified 2026-02-01 20:33:15 GMT; the downloaded file's SHA-256 equals `SHA_7Z` in
  `pc/pyra-vendor-image.sh`. A request for the apt repo's `/trixie/` directory answers 403 (individual
  files not checked). The Wayback Machine has no snapshot of the archive.

## 2026-11-21 — a forum DBP on the trixie card (R76)

The r5 release card, `5.6.19-m4-kbdled`, `dbp` 0.6.12.2-2. Package: GBA.emu 1.5.46.02 (`GBAemu`), the most
downloaded in the DBP repository (1532), fetched from the repository's download link, SHA-256
`f96c710b9adc31dd79f44e33c474c992c7f101f434d23e76f5303822f9039537`. Written up in `dbp.md`.

- Copied to `/dragonbox/packages/` on the root f2fs (`/dragonbox` chowned to the user). Not picked up: the
  folder was created after `dbpd` started, and dbpd sets its inotify watches only at mount or start. After a
  restart, removing the file unregistered it and copying it back registered it within 3 s. Registering exported `__dbp__GBAemu_default.desktop` and
  `/usr/local/games/GBAemu.sh`.
- `dbp-cmd mount` without `dragonbox/appdata/GBAemu` present: `Unable to set up AuFS union`, dmesg
  `aufs opt_add:811:dbpd[...]: lookup failed /dragonbox/appdata/GBAemu (-2)`. In dbp's source, `dbp-run`
  creates that directory as the user and `dbp_loop_mount` never does.
- With the directory present: `squashfs` on `/dev/loop7` at `/mnt/dbp/images/GBAemu` and `aufs` at
  `/mnt/dbp/union/GBAemu`. The modules (`aufs 5.6-20200622`, `squashfs`) loaded on demand. A file written in
  the union landed in `/dragonbox/appdata/GBAemu`. `ldd` of `gbaemu`: no `not found`; EGL and GLESv2 from
  the SGX DDK.
- `DISPLAY=:0 timeout 25 dbp-run --log-output --chdir GBAemu gbaemu`: the appdata directory was created,
  `xwininfo` showed a `"GBA.emu"` window, 1280x720. The timeout killed `dbp-run` before its unmount, which
  left both mounts until they were unmounted by hand. No game was loaded and input wasn't tried. The
  launcher's `pyrainputctl overload` was skipped.
- `dbp-run GBAemu <nonexistent>` printed the dependency check: `System packages: libvorbisidec1,
  libpng16-16, libglib2.0-0`. The first isn't in trixie, the other two are installed as `t64` packages.
  dbp matches names in `/var/lib/dpkg/status` exactly and ignores `Provides:`.
- `python3-apt` (for the DBP Installer): not installed; the candidate after `apt update` is 3.0.0.
- Left on the card: `/dragonbox/packages/GBAemu.dbp`, `/dragonbox/appdata/GBAemu/` (empty except AuFS's
  `.wh..wh.orph`), the registration. Undo: `dbp-cmd unregister` the file, then `rm -r /dragonbox`.

## 2026-11-21 — pyrainput 0.1.19: nub deadzone, key names, recovery after a crash (R77)

The r5 release card, `5.6.19-m4-kbdled`, funkeymonkey-pyrainput 0.1.19 (the bookworm and trixie source
tarballs are identical, SHA-256 `9e8439af…5c791c`). Written up in `troubleshooting.md`. A logger read the
`pyraInput keyboard` and `Gamepad` evdev nodes and polled `EVIOCGABS` on them and on the raw `nub0`/`nub1`
nodes every 0.25 s; the owner pressed the keys, following a prompted script.

- At rest, before any test: raw nub0 -4,-6, nub1 0,-24; gamepad X,Y 60,58 and RX,RY 78,-23, the values from
  the last movement.
- Stock library, nubs pushed to full travel and let go fast, three times each: after release the raw nubs
  read 0,0 and -2,6, the gamepad stayed at -38,-232 and -14,-248.
- The 0.1.19 tree with `patches/userspace/funkeymonkey-pyrainput/0001`-`0003`, built on the card (g++
  14.2.0, `-std=c++20 -O2 -shared`, funkeymonkey 0.1.2 headers, 81 s), bind-mounted over the installed
  library: the gamepad returned to 0,0 after every release. The right nub's Y came to rest anywhere from 0 to
  -30; a resting value outside the deadzone of 10 is passed on, as it should be.
- `nubs.deadzone = -1` through `pyrainputctl overload`, stock library: the gamepad followed the raw nubs at
  rest (raw 4,-16, gamepad 4,-16).
- Keys, stock: d-pad right gave `KEY_RIGHT` and no `ABS_HAT0X`; left gave both. Usr1, Fn+Usr1 and Fn+Esc
  produced no event. Patched: d-pad right `ABS_HAT0X=65535`, Usr1 `KEY_PAUSE` (119), Fn+Usr1 `KEY_SCALE`
  (120), Fn+Esc `KEY_SYSRQ` (99).
- Crash path, stock: GBA.emu's overload file (`gamepad.export = 0`) through `sudo pyrainputctl overload`
  in a shell running the launcher's two commands, then `kill -9`. `/etc/pyrainput.cfg` kept `profile.9`
  and `profile.current = 9`; A and d-pad up sent `KEY_HOME`/`KEY_UP` only. `sudo pyrainputctl enable
  gamepad` brought `BTN_A` back and left both profile lines; `sudo pyrainputctl no-overload` removed them,
  with `BTN_A` still working. `pyrainputctl` left `/etc/pyrainput.cfge` (its `sed -ie`).
- Restored: `/etc/pyrainput.cfg` equal to the original (MD5), `.cfge` deleted, bind mount removed (the
  script's own `umount` failed while the daemon held the file; done after stopping it), stock library
  (MD5 `52b33eec…`) running, three pyraInput devices. Left on the card: `~/r77-build/` (sources, both
  builds, the logs).

## 2026-11-21 — Fn symbols under X and on the console (R78)

The r5 release card, `5.6.19-m4-kbdled`, pyra-config-xorg 0.39 (`symbols/pyra` MD5 `6de8513e…`), console-setup
1.242~deb13u1 (layout `us`, variant `euro`), funkeymonkey-pyrainput 0.1.19. Written up in `troubleshooting.md`.
No keys were pressed by hand: `experiments/fn-keys/` sends the keycodes the daemon's `pyraKeyMap.cpp` gives
each Fn key through a throwaway uinput keyboard, into a terminal on `:0` (`fn-x.sh`) or tty1's login prompt
read back from `/dev/vcsu1` (`fn-tty.sh`). The owner compared the keycap legends with the list.

- X layout: `pc+pyra(pyra)+inet(evdev)`. xterm and mate-terminal, Fn+Q..P, ', A..L, M, Z..N , . typed
  `° § € è é à ç ¨ ü ß : ? + _ { } | ~ ö ä ´ = - [ ] \ ` ; /`. With Shift: capitals for the accented letters
  and `+ _ { } | ~ : ?` for the bottom row, but nothing for Fn+D and Fn+' (level 2 of keycodes 204/205 is
  `Alt_L`/`Meta_L`).
- `xmodmap -pm`: mod1 holds `colon (0xcc)` and `underscore (0xcd)`. Rollover (a, 197 down, b down/up, 197 up,
  c): xterm `a_âc`, mate-terminal `a_` ESC `bc`; the same with 196. With 195 (Fn+M, acute) held: `a´bc`.
- Keycaps (owner): é on R, è on T; all other legends match the keymap.
- `patches/userspace/pyra-config-xorg/0001`, compiled with `xkbcomp -I` and loaded on `:0`: both terminals
  typed the full set with é/è on R/T, Shift+Fn+D `_`, Shift+Fn+' `:`, rollover `a_bc` and `a:bc`. The
  documented divert-copy-patch steps produce the tested file; undone, `dpkg -V pyra-config-xorg` clean.
- Package history (archive copies): 0.36 (bullseye) has `key <I221> { [ underscore ] }` and `<I247>` colon;
  0.38 and 0.39 have `<META>`/`<ALT>`.
- tty1, stock keymap: only Fn+Z X C V B N , . typed (`= - [ ] \ ` ; /`, Shift `+ _ { } | ~ : ?`). Fn+Q gave
  `^[[M`, Fn+W `^[[3~`, all the other Fn letters, Fn+' and Fn+Space nothing.
- `device/etc/console-setup/pyra-fn.kmap` with `loadkeys`: every Fn key typed its keycap symbol, Shift giving
  the capitals. Through `remap.inc`: `setupcon --save-only` left the cache unchanged (MD5 `f4c6c62b…`) until
  `/etc/default/keyboard` was touched; then the cached map held the lines and typed the same.
- Initramfs: KEYMAP=n and no input daemon, so there is no Fn layer there (from the image, not booted into).
- Restored: `remap.inc`, the cached keymap and `cached_setup_keyboard.sh` equal to their MD5s before, the
  mtime of `/etc/default/keyboard` put back, the live console keymap byte-identical to the `dumpkeys` taken
  first (`loadkeys` of the cache alone leaves added keycodes in place), the X keymap identical to its
  `xkbcomp` dump (rebuilt with `setxkbmap`; reloading the dump with `xkbcomp` dropped a mod3 entry). Left on the
  card: the test files in `~/r77-build/`.

## 2026-11-21 — funkeymonkey-pyrainput 0.1.19+pyra1 as a package (R87, fix 29)

- Card: the r5 release card, `5.6.19-m4-kbdled`. Package: `./pc/pyra-crossbuild.sh pyrainput`, SHA-256
  `de94357a…cbda2638`; a second build gave the same file. Its unit is byte-identical to fix 3's (`ff41b7f2…`).
- Install: `sudo dpkg -i` over the vendor's 0.1.19. dpkg took over fix 3's unowned unit without a word
  (`dpkg -S` now names the package), the existing `multi-user.target.wants` link (to `/lib/...`) stayed, the
  self-`Alias=` made no extra link, and the postinst restarted the daemon (new PID, library MD5 `4910982c…`).
- Method: a prompted script run by the owner over `ssh -t`; R77's logger polled the uinput keyboard and gamepad
  and the raw nubs; the keyboard LED's sysfs value was read before and after each step. Fix 15's drop-in was
  moved aside and the daemon restarted first (`DropInPaths=` empty), so nothing reloaded it.
- Brightness (0001): Fn+brightness twice took the light 5 → 20, Fn+Shift+brightness twice 20 → 5:
  `pyra-kbdlight.sh`'s steps, from `/etc/pyrainput.cfg`, with no reload since the start.
- Keys (0003): d-pad right `KEY_RIGHT` with `ABS_HAT0X=65535`, left `-65535`; Usr1 `KEY_PAUSE` (119);
  Fn+Usr1 `KEY_SCALE` (120). Fn+Esc not pressed in this run (the owner pressed Fn+Usr1 twice); R77 saw
  `KEY_SYSRQ` (99) from the same patch.
- Nubs (0002): three hard flicks on each; after every release the gamepad axis followed the raw value back
  (left: pad 0,0 or 0,-12 with raw 2,-12; right: pad 0,14 with raw -6,14, the nub's own rest point outside the
  deadzone of 10). No stuck values like R77's -14,-248.
- Selftest: 401 pass, 0 fail, 0 skip (owner, 2026-11-21), including the input guard fired by a real downgrade to
  the vendor's 0.1.19 (unit put back, enabled) and the return.
- Left: the drop-in back (`DropInPaths=` lists it), 0.1.19+pyra1 installed (rollback: `sudo dpkg -i
  ~/r77-build/funkeymonkey-pyrainput_0.1.19_armhf.deb`), test files in `~/r77-build/r87/`. The guard is not on
  this card (only prep installs it).

## 2026-11-21 — programs that need GLX, and the F2BGL crash (R80)

- Card: the r5 release card, `5.6.19-m4-kbdled`, `libgl-gl4es-pyra` 1.1.7.1, fix 21's library in place
  (`pyra-wsegl-fdfix.sh status`: fixed). X has 27 extensions and no GLX (`xdpyinfo`).
- Ice Field Frenzy 1.0.0.2 (`icefieldfrenzy.farox`, repo MD5 matched): SDL 1.2 (`libsdl1.2pyra`) plus
  `libGL`, launcher without `gl4es`. Plain and under `gl4es`: `Unable to open graphics mode!`. An
  `LD_PRELOAD` logger showed `SDL_GL_SetAttribute(DEPTH=32)`, then `SDL_SetVideoMode` failing with
  `Couldn't find matching GLX visual`. Clamping depth to 24 (gl4es.md's shim) under `gl4es`: the mode set
  succeeded and the title screen drew fullscreen at 1280x720 (`xwd` screenshot), run from the extracted image
  and again through the registered DBP's launcher, so `dbp-run` passes `LD_PRELOAD` and `LD_LIBRARY_PATH` on.
- SDL2 test program (window with `SDL_WINDOW_OPENGL`, context, `glGetString`): plain `SDL_CreateWindow: GLX is
  not supported`; `gl4es` and `LD_LIBRARY_PATH=/usr/lib/arm-linux-gnueabihf/gl4es` both `GL_RENDERER: GL4ES
  wrapper`; `SDL_VIDEO_X11_FORCE_EGL=1` `Could not create GLES window surface`.
- F2BGL 0.3.1 (repo MD5 matched): not runnable here (needs the commercial data and `libfluidsynth.so.1`;
  trixie has `.so.3`). A test program in f2bgl's order (window, context, swap interval 1, eight `fopen`s,
  180 frames under `gl4es`), with the stock library selected by `LD_LIBRARY_PATH` (`/etc/powervr.ini` names it
  by bare name; `/proc/<pid>/maps` confirmed the copy) and a `close()` logger:
  - window or `FULLSCREEN_DESKTOP`, no resize: no close from `libpvrDRI3WSEGL`, no file lost, both builds.
  - resize to 800x480 at frame 60: stock closed fd 10 three times from `+0x154d` (the first returned 0), the
    file's `fseek` returned -1; 3 of 3 runs lost one file. Fixed build: 0 of 3.
  - swap interval 0 then 1 at frame 60: no rebuild, no loss, both builds.
  - `FULLSCREEN_DESKTOP` plus the resize: the window stayed 1280x720 and nothing was lost.
- Left: nothing. The DBP was unregistered; its image and union mounts (left by a `timeout`-killed `dbp-run`)
  were unmounted, the loop device detached and the mount points removed; `/tmp/r80` and `/tmp/dragonbox`
  deleted. The card's library was not touched (still `fixed`).

## 2026-11-21 — touchscreen calibration and stylus jitter (R81)

- Card: the r5 release card, `5.6.19-m4-kbdled`, fix 29's package installed by hand. `xinput` and
  `libinput-tools` installed for the test and purged after. The install also brought Debian's security update
  `libinput10`/`libinput-bin` 1.28.1-1+deb13u1 (CVE-2026-50292). It was left installed: 1.28.1-1 is no longer in
  the archive.
- X uses libinput for the TSC2007 (`Applying InputClass "libinput touchscreen catchall"`, then
  `"TSC2007 Touchscreen"`). `xinput list-props`: `libinput Calibration Matrix` = the vendor's
  `0.998032 -0.004569 0.016723 -0.006564 1.083056 -0.031356 0 0 1` from `99-pyra-touchscreen.conf`
  (`pyra-config-xorg`), so the X config matrix is honoured. `strings xinput_calibrator` (0.8.0): only evdev
  properties and an evdev `Option "Calibration"` snippet.
- `evtest`: `ABS_X` 0..719, `ABS_Y` 0..1279, no fuzz on either; `ABS_PRESSURE` 0..1000 fuzz 50. DT:
  `touchscreen-fuzz-x/-y = <5>`, `touchscreen-swapped-x-y`, `ti,min-x/y = <50>`, `ti,max-x/y = <3900>`.
  `udevadm info`: `LIBINPUT_FUZZ_00=5`, `LIBINPUT_FUZZ_01=5`, moved there by `90-libinput-fuzz-override.rules`.
- `pyra-touch-calibrate`, owner's taps: run 1 (sample-count version) matrix
  `1.006181 0.004592 0.002738 0.016297 1.053841 -0.032213`, worst point 7.1 px, saved. Spreads while held at the
  first two corners 84 x 43 and 176 x 57 px, which are the raw `evtest` ranges for those touches (47 and 99
  `ABS_X` steps, 1.78 px per step); the median absorbed them. `systemctl restart lightdm` (owner's OK): the Xorg log
  applied `"Pyra touchscreen calibration"` after `"TSC2007 Touchscreen"`, and the property read the saved matrix.
  Run 2 (hold-time version, `--no-save`): `1.002628 0.000913 0.008262 0.002850 1.062362 -0.033482`, worst
  3.9 px, spreads 4-7 x 4-11 px. The owner: taps land right. No reboot was made.
- Firm still hold, 4.12 s, kernel fuzz 0 (middle of the touch, 0.25 s dropped each end): 78 reports, position
  changed in 75; sd 3.9 px across, 2.8 px down; range 12 x 10 px. `libinput debug-events` run alongside:
  99 positions, identical to the 115 evdev reports with consecutive repeats removed.
- Kernel fuzz set to 5 on both axes with `EVIOCSABS` (by hand, live), two firm holds of 1.55 s: about 7
  reports/s against 22, X did not change, Y range 1 px. The owner: "I think it's steadier". Fuzz reset to 0.
- Left: nothing. The calibration file was removed with `--reset` (vendor matrix back, verified with `--show`),
  the two packages and their automatic dependencies (`python3-libevdev`, `python3-pyudev`) were purged, and the
  `/tmp` files were deleted. The libinput security update above stays.

## 2026-11-21 — fix 30: the calibration tool, its menu entry and the kernel fuzz (R89)

- Card: the r5 release card, `5.6.19-m4-kbdled`, libinput 1.28.1-1+deb13u1, systemd 257.9-1~deb13u1. No
  `xinput` installed. Fix 30's three files copied in by hand to their prep paths.
- Before: `evtest` on `/dev/input/event4` showed no fuzz on `ABS_X`/`ABS_Y` (`ABS_PRESSURE` fuzz 50);
  `udevadm info`: `LIBINPUT_FUZZ_00=5`, `LIBINPUT_FUZZ_01=5`.
- First version of the rule: no effect. udev's debug log showed none of its lines: `ATTRS{name}!="TSC2007
  Touchscreen"` is true at `event4` itself, which has no `name`, so it jumped to the end. With a positive
  `ATTRS{name}==` match: kernel fuzz set back to 5 by hand (the boot state, before libinput's rule), then
  `udevadm trigger --action=change` on `event4`. udev's debug log ran `libinput-fuzz-to-zero`, then the keyboard
  builtin: `keyboard: 0 overridden with 0/719/0/5/0`, `keyboard: 1 overridden with 0/1279/0/5/0`. Kernel fuzz
  read back 5 and 5 (`EVIOCGABS`), and `udevadm info` added `EVDEV_ABS_00=:::5` and `EVDEV_ABS_01=:::5`.
  `udevadm test` can't show this: it skips `libinput-fuzz-extract`, so `LIBINPUT_FUZZ` is never set.
- A second trigger, with nothing reset by hand: `evtest` showed `Fuzz 5` on `ABS_X` and `ABS_Y`. The journal
  had nothing from libinput. The Xorg log, each time X opened the device: `(EE) event4 - TSC2007 Touchscreen:
  libinput bug: kernel fuzz of 5 even with LIBINPUT_FUZZ_00 present` and the same for `_01`. libinput
  1.28.1's `evdev_read_fuzz_prop` logs that whenever the kernel fuzz is not 0, and returns 0 for its own view.
- One `udevadm trigger --subsystem-match=input` (all input devices): X added `mouse0` as "TSC2007
  Touchscreen", then failed to re-add `event4` (`not using input device '/dev/input/event4'`, `Couldn't init
  device`). The touchscreen was gone from X's device list. A trigger of `event4` alone re-added it, with the
  rule still in place; so did the two before it.
- Each re-add applied R81's run-1 matrix, whose file was deleted after X last started: X keeps the
  `xorg.conf.d` it read at startup. `--reset` put the vendor matrix back.
- `pyra-touch-calibrate` through ctypes `libXi`: `--show` read the live matrix; a set/get round trip of
  `1.01 0.02 -0.03 0.04 1.05 -0.06 0 0 1` read back exactly to 6 places; `--reset` set the vendor matrix.
  The selftest's checks, run natively: `--help`, libXi's and Xlib's calls found, GTK 3 present, the entry
  loads with Terminal and the tool in Exec, Gio with the session's `XDG_DATA_DIRS`
  (`/usr/share/mate:/usr/local/share/:/usr/share/`, from mate-panel's environment) resolves
  `xinput_calibrator.desktop` to `/usr/local/share/applications`, `udevadm verify` passes the rule.
- The owner opened "Calibrate Touchscreen" from the menu: the tool ran in a terminal, and saved with sudo
  (journal: `TTY=pts/0 ... install -m 644 /tmp/tmp….conf /etc/X11/xorg.conf.d/99-zz-pyra-touch-calibration.conf`),
  matrix `0.996126 0.003231 0.011264 0.006748 1.067094 -0.035172`. With fuzz 5, dragging and writing with the
  stylus: "the touch screen feels fine" (owner).
- Prep selftest (owner, same day): 417 passed, 0 failed, 0 skipped, up from 401 (fix 30's 15 assertions and its
  run-2 check).
- Left: nothing. The saved calibration was removed with `--reset`, the three files deleted (and the empty
  `/usr/local/share/applications`), then `event4` triggered again: kernel fuzz 0, the touchscreen re-added
  in X with no fuzz lines, and `--reset` once more after the re-add restored R81's stale matrix. `--show`:
  the vendor matrix. `/tmp` files deleted.

## 2026-11-22 — a CPU ceiling the thermal daemon keeps (pyra-hacks 0.38+pyra5, R82)

- Card: the r5 release card, `5.6.19-m4-kbdled` (`0007`: 250-1500 MHz in eleven steps), `ondemand`, pyra-hacks
  `0.38+pyra4`, its thermal script byte-identical to the fork's. No `/etc/default/pyra-thermal`.
- The reader under the card's `/bin/sh` (dash), extracted from the new script, 14 cases: `CPU_MAX_MHZ=1000`,
  `CPU_MAX_MHZ = 1000  # cool`, `"875"`, `'750'` and a last line with no newline (`1250`) are taken; `#CPU_MAX_MHZ=500`,
  `0800`, `abc`, `99999`, `2000`, an empty value, `$(touch …)` (nothing ran) and a missing file all leave 1500;
  with `1125` and `1400` on two lines, 1125.
- `dpkg -i` of a local build of `0.38+pyra5` (SHA-256 `4c554a21…45ff07`) over pyra4: `dpkg --verify` clean, both
  `pyra-thermal-fix.sh` and `pyra-thermal-ladder.sh --emit-patched` pass the installed file through unchanged,
  `pyra-thermal-guard` silent (no output, no journal entry), the postinst restarted the daemon.
  The release asset published afterwards (SHA-256 `28e6242f…2c5d73`, what prep pins) hashes differently, as the
  fork's builds do, but carries a byte-identical `pyra-thermal.sh`.
- No restart needed: `CPU_MAX_MHZ=875` written, `scaling_max_freq` 875000 at +1 s, +2 s, +3 s. 1500000 written
  by hand: 875000 again 2.5 s later. File deleted: 1500000 2.5 s later. `NRestarts=0`, same start time throughout.
- Two busy-loop shells (`while :; do :; done`, one per core) started 5 s in, then samples of `scaling_max_freq`,
  `scaling_cur_freq`, `core_thermal`, `cpu_thermal`, `bq27421-0` with a 1 s sleep between them. The reads add to
  that, so under load samples came about 1.3 s apart (estimated: the 180 s load ended near sample 140):
  - ceiling 1000, 150 s of load: 1000000 in all 170 samples; `scaling_cur_freq` at most 1000000. Peaks: core
    60.6°C, cpu 63.6°C, gauge 31.6°C. No rung reached.
  - ceiling 1400, 180 s of load: 1400000 in 94 samples and 1250000 in 106, never above 1400000. Four changes:
    1250 at sample 28 (cpu 78.5°C), 1400 at 41 (73.0°C), 1250 at 47 (78.9°C), and 1400 at 140, the first sample
    after the load ended (cpu 69.6°C, clock 375 MHz). Peaks: core 73.0°C, cpu 79.4°C, gauge 35.1°C.
- Left: pyra5 stays installed (it changes nothing without the file). `/etc/default/pyra-thermal` deleted,
  `scaling_max_freq` 1500000, `ondemand`; `/tmp` files deleted.

## 2026-11-22 — the card's SPL carries the team's 2023 RAM-init fix (R85, read-only)

The question: units that fail the bootloader's RAM check need "the new bootloader". Does the card's one have it?
Written up in `troubleshooting.md`, "No LED at all, even with a long press".

- **Source.** The vendor's `u-boot-pyra` source packages 0.1 (files dated 2022-04-21), 0.1.2 (2023-05-20) and
  0.1.5 (2024-09-11), from the apt archive. 0.1 → 0.1.2 adds the rework: `omap5_ddr3_init` with DLL on for
  calibration, a full leveling trigger, `ref_ctrl_final`, the field-by-field DDR3 table in
  `board/dragonbox/omap5_pyra/dram.c`, EMIF power saving off in `board_spl_board_init`, and
  `memory_test_with_shutdown` (one word at `CONFIG_SYS_SDRAM_BASE + 0x1000`, eight `READBACK` lines, then
  `Memory test failed, powering off` and a PMIC power-off). 0.1.2 → 0.1.5 leaves the RAM code alone (board
  revision clean-up, armv7-a tuning, `CONFIG_BAUDRATE 1500000`).
- **Upstream.** The GitLab API's commit list for `packages/pyra-uboot`, default branch, read from the PC: the
  rework is `a8898441` and `17601d31` (2023-03-31) and `cccad406`, `f3697cdd` and `a4a4272e` (2023-04-01). The
  last commit is 0.1.4's changelog (2023-08-21). No later RAM change; 0.1.5's baud change is not pushed there.
  `kernel/pyra-uboot` ends at `0fecbc0a` (2020-09-01), the commit the tested unit's eMMC U-Boot proper is built from.
- **Packages.** `strings` on the 0.1.5 `MLO` (trixie and bookworm debs) and the 0.1.2 one (bullseye) all carry
  `Memory test failed, powering off` and `EMIF power ctrl changed to`. Trixie 0.1.5: `MLO` SHA-256
  `ad125236…cd75ef73`, `u-boot.img` `148bab44…6caa901a50`.
- **The r5 card** (`5.6.19-m4-kbdled`, left slot, `mmcblk1`): the raw `MLO` at 128 KiB (65788 bytes) and
  `u-boot.img` at 384 KiB (336152 bytes) hash the same as the trixie 0.1.5 deb's files, and the installed
  package is 0.1.5. The eMMC's SPL (`2016.11-g8e417ba870-dirty`, 2021-01-07) has `READBACK %08x` and
  `Status before starting init:` but neither 0.1.2 string, so it is an earlier variant.
- **Forum dating.** Bad boards fail the check at power-on (EvilDragon 2021-05-28 /1693139/, 2022-12-08
  /1711841/). pimaster's build booted 20 of 20 set-aside boards (2023-02-23 /1713044/) and was pushed
  2023-04-01 (/1713378/). Askarus (/1719423/, edit before 2024-09-27): their Debian 10 flashing card had "an older
  less compatible uboot"; with the new one 74 dead boards booted and 16 did not.
- Not tested: a board that fails the check (none here), and the LED and serial signs of a failure, which come
  from the source.

## 2026-11-22 — the CPU ceiling from pyra-settings 0.15's Performance page (R90)

The r5 release card (`5.6.19-m4-kbdled`, pyra-hacks 0.38+pyra5), `dpkg -i` of pyra-settings 0.15 (local build,
payload identical to the published `v0.15` asset), ondemand governor, idle, no ceiling file before or after.

- **The parser.** Nineteen file texts (spaces and quotes around the value, a trailing comment, no final newline,
  `\r\n`, a leading zero, five digits, `$(…)`, `==`, lower case, `export`, several lines) run through the fork's
  own `pyraReadCeiling` under the card's dash and through the page's Python reader: the same MHz for all 19.
- **End to end.** The installed app's window on the Pyra's screen, its Performance page's buttons pressed through
  GTK (`clicked`, as a tap does), the helper run through `sudo -n` instead of pkexec (the polkit agent would ask
  for a password at the screen; pkexec itself was checked with the other pages). cpu0's `scaling_max_freq` read
  every 50 ms. Measured:

  | click | helper done, after the click | `scaling_max_freq` | click → applied | written → applied |
  | --- | --- | --- | --- | --- |
  | 875 | 0.58 s | 875000 | 2.30 s | 1.72 s |
  | 1400 | 0.81 s | 1400000 | 1.15 s | 0.34 s |
  | 500 | 0.54 s | 500000 | 1.89 s | 1.35 s |
  | No limit | 0.98 s | 1500000 | 0.76 s | before the helper exited |
  | 1000 | 0.51 s | 1000000 | 1.36 s | 0.85 s |
  | 625 | 0.65 s | 625000 | 2.25 s | 1.60 s |
  | 1250 | 1.00 s | 1250000 | 0.81 s | before the helper exited |
  | No limit | 0.62 s | 1500000 | 1.37 s | 0.75 s |

  After the file is written the daemon's next pass (every 2 s) applies it: at most 1.72 s here. From the press it
  took up to 2.30 s, the helper run (sudo and Python on the Pyra, 0.5-1.0 s from the click in this table) coming first. The page's
  "Saved. Applies within 2 seconds." appears when the helper is done, so the claim holds from that line.
  No limit deleted the file each time.
- Not tested here: the pkexec password dialog on this page, and the page's look on the Pyra's own theme (the
  layout was checked under Xvfb at 1280x720 on the PC).
- **0.15 too wide; 0.16.** Opened on the Pyra itself, 0.15's window would not maximize: at the Pyra's font
  (Sans 12, 117 dpi) the Performance row's buttons beside the label needed 1009 px, the window 1403 px
  (`get_preferred_width`, measured on the card). The Xvfb check above ran at the PC's smaller font. 0.16 puts the
  buttons on their own line: row 845 px, window 1239 px, maximized at 1280x720; checked on the Pyra by the owner
  in Menta. Fix 26 pins `v0.16` (asset `8b826990…124f34`, payload identical to the local build).
- **Through pkexec.** The owner picked 1250 on 0.16's Performance page and entered the password in mate-polkit's
  dialog. Journal: `pkexec[1534]: ... COMMAND=/usr/libexec/pyra-settings/pyra-settings-helper set-cpu-max 1250`
  (11:10:02); `/etc/default/pyra-thermal` 0644 root with the helper's header and `CPU_MAX_MHZ=1250`;
  `scaling_max_freq` 1250000. Read back over ssh afterwards, not timed.

## 2026-11-22 — reading the board revision and RAM size (R91)

- Card: the r5 release image, kernel `5.6.19-m4-kbdled`, read over ssh, then one reboot with the serial console
  attached (FTDI, 1500000 baud). Nothing written to the card.
- Running system: `/proc/device-tree/model` `Pyra-Handheld-V5.3` (mainboard), first `compatible`
  `goldelico,lc15-v5.3` (CPU board), `MemTotal: 4034760 kB`. `/proc/device-tree/memory@80000000/reg` holds two
  banks, `0x80000000` + `0x7f000000` and `0x2_00000000` + `0x80000000`: exactly u-boot-pyra 0.1.5's fixed
  `dram_init_banksize` for its `omap5_pyra_4gb_defconfig` build, so MemTotal reflects U-Boot's build, not the
  fitted RAM. `/proc/cmdline` carries no revision (the `extlinux` `append` line only). `/sys/kernel/debug/gpio`:
  `gpio-33` (the RAM-size resistor pin) is claimed as `encoder` by the running kernel.
- Serial, from the reboot: `ram code 0x0`, `version code 0xa`, `Found Pyra V5.3 with 4GB RAM`,
  `HW Revision: CPU: v5.3 Mainboard: v5.3`, `BOOTDEV: SD Left`, then
  `Retrieving file: /dtb/linux-image-5.6.19-m4-kbdled/omap5-letux-cortex15-v5.3+pyra-v5.3.dtb`. The codes decode
  per `board.c` (`version code 0xa`: both CPU-board pins floating = V5.3; `ram code 0x0`: pulled down = 4 GB).
- From source, not seen on hardware: a missing `.dtb` makes `sysboot` print `Skipping <label> for failure
  retrieving fdt` and try the next entry; an unknown resistor code names `v0.0`. No 2 GB unit tried.
- Docs: new `board-revision.md`, indexed in README.

## 2026-11-22 — pyra-info and pyra-settings 0.17's About page (R93)

The r5 release card (`5.6.19-m4-kbdled`, boot entry `l5`), `device/pyra-info` installed by hand in
`/usr/local/bin` (755 root:root, as fix 31 does), pyra-settings 0.17 by `dpkg -i` (local docker build of the
`v0.17` commit; the release asset is CI's, not byte-identical).

- **pyra-info as user `pyra`:** exit 0 in 0.11 s (`time`). Mainboard `Pyra-Handheld-V5.3`, CPU board
  `goldelico,lc15-v5.3`, kernel `5.6.19-m4-kbdled #10 SMP PREEMPT Wed Nov 18 02:28:17 UTC 2026`, boot entry
  `l5; default l5`, OS `Debian GNU/Linux 13 (trixie)`, "Prepared: no record" (r5 predates fix 31), and the
  seven packages at the versions `dpkg-query -W` gives. `--help` prints the header; an unknown argument exits 2.
- **Boot-entry fallback and the marker,** with copies of the card's `extlinux` files (default changed to `l0`,
  `l5`'s kernel renamed) and a sample marker: "none matches the running kernel; default l0", and
  "commit abc1234, 2026-11-22, kernel-5.6.19-r3, release image".
- **About page,** the installed app on the Pyra's screen (Menta, Sans 12 at 117 dpi), opened through
  `_go_page`, measured with `get_preferred_width`: window 1239 px (unchanged from 0.16), About's page box
  398 px minimum (the text wraps), maximized at 1280x651. The Copy button's action put the text on the
  clipboard (`wait_for_text` read it back) and the status line said "Copied". Screenshot checked: long lines
  (RAM, kernel, Prepared) wrap; the package list lines up.
- Not run here: prep's fix 31 and the selftest (need root on the PC; handed to the owner), and the page's Copy
  pasted into another app by hand.

## 2026-11-22 — white-noise bursts, both audio paths (R79)

CPU board V5.3, mainboard V5.3. The r5 release card on `5.6.19-m4-kbdled` (AESS, entry `l5`), then one boot of
`5.6.19-pyradef` (direct link, entry `l0`) through `pyra-boot-kernel.sh debug l0 --once`, then back to `l5` and
the revert disarmed by hand. Scripts: `experiments/white-noise/`.

- **Recording:** headphone output into the PC's analog line-in, `parecord` 48 kHz S16, PC input at 10 %. Sink
  volume 100 % on AESS. `reproduce.sh 20 1`: twenty cycles of `pactl suspend-sink` 1 s, 3 s silence, a 0.5 s
  -20 dBFS beep, then 120 s of -26 dBFS beeps (4 s on, 2 s off).
- **AESS, headphones:** 118 events over +10 dB in 3-16 kHz, 110 of 20 ms and 8 of 40 ms, none longer.
  Two transients per cycle: -0.73 to full scale at sink open, +0.63 to +0.78 at close, 55-75 ms, all energy
  under 100 Hz (DC steps). 1-16 kHz level in silence -55 dBFS.
- **Direct link, headphones** (`PULSE_SINK=headphones`): 59 events, all 20 ms; the same 42 transients
  (+0.63 / -0.73 mean); silence -53 dBFS.
- **Speakers, by ear (owner), `reproduce.sh 10 1`:** AESS: pops between beeps early on, no clear hiss ("if I
  did, it was very faint"). Direct: pops only, softer than AESS.
- **DAPM during AESS playback** (debugfs, widgets On while playing vs idle): McPDM DL1 Playback, MMLP
  Playback, the HSDAC and HS driver chain. No uplink, ADC or mic bias widget. PulseAudio lists no source but
  `aess.monitor`.
- Agreed beforehand: a burst is audible hiss or static of about 0.2 s or more not in the source. Not
  reproduced on either path.

## 2026-11-23 — DBPs from a second card (ext4, exFAT) and the DBP Installer (R86)

The r5 release card in the left slot, `5.6.19-m4-kbdled`, `mmcblk1`. The second card: a 119 GB card that had
held an older dev install, in the right slot (`mmcblk3`), repartitioned to one partition per test. Package:
GBA.emu 1.5.46.02 (`GBAemu`), the same file as on 2026-11-21. The system card's copy was unregistered and moved
aside first so the two didn't share an id.

- **First boot, both cards from the image:** kernel `5.6.19-m4-kbdled` from the left card (the dev card's own
  default was `5.6.19-m4-kbdled-sched`), but `/` and `/boot` on `mmcblk3p2`/`p1`, the right card. Both cards
  carried PARTUUID `21a4c285-02` and rootfs UUID `93b4acaf-…`. With the card pulled, booted and reinserted, `/`
  was `mmcblk1p2`. troubleshooting.md, "Two cards from the image in the Pyra".
- **ext4** (`mkfs.ext4 -L dbpcard`, mounted with `sudo mount` at `/media/pyra/dbpcard`; udisks refuses an ssh
  session): `dragonbox/packages` made after the mount got no watch, so the copy didn't register; after a
  remount it registered at once (`dbp-cmd list`, menu entry, `/usr/local/games/GBAemu.sh`). `dbp-run
  --log-output --chdir GBAemu GBAemu.sh` with `DISPLAY=:0`: window "GBA.emu" 1280x720, squashfs on
  `/dev/loop7`, AuFS union, `dragonbox/appdata/GBAemu/` created on the card. SIGTERM to `gbaemu`: both mounts
  gone, `pyrainput` active. Unmounting the card: package unregistered, menu entry and launcher removed.
- **exFAT** (exfatprogs 1.2.9 `mkfs.exfat`, partition type 7; staging `exfat.ko`, "exFAT: Version 1.3.0";
  mounted `uid=1000,gid=1000,dmask=0022,fmask=0133`): copy SHA-256 intact, registered after a remount. Launch:
  `kernel BUG at fs/buffer.c:3082!`, `PC is at submit_bh_wbc`, trace `exfat_write_begin` ←
  `cont_write_begin` ← `do_xino_fwrite [aufs]` ← `au_xino_set` ← `aufs_fill_super`, process `dbpd`. No window;
  the image mounted, the union not; `dbp-run` stuck in poll; `dbp-cmd list` timed out after 10 s. `systemctl
  restart dbpd` brought `dbp-cmd` back; the image umount stayed "busy", as did the card. Lazy unmounts, then
  `sync` segfaulted with a second oops (`Unable to handle kernel paging request at virtual address ff000010`,
  `PC is at rwsem_down_read_slowpath`). Card pulled, reboot clean.
- **DBP Installer** 1.2.1 (`dbpInstaller_sebt3`, MD5 `0177ded6…bcb80` matched the repository), after
  `apt-get install python3-apt` (3.0.0; pulled `python-apt-common`, `distro-info-data`): the window opened
  ("dbp installer", 853x578) and listed the repository with package details (screenshot by `xwd`). `cards`:
  only `RootFs`. `-d RootFs install icefieldfrenzy.farox`: downloaded to `~/dragonbox/packages`, MD5
  `69aecdd5…` matched, not registered, not even after a `dbpd` restart. With `~/dragonbox` → `/dragonbox`: the
  same download registered within 4 s. `installed` answered over D-Bus (three packages). Its dependency check
  (`parse_packages`, run in the mounted package): fmtg_synth_m-ht → nothing to install (`libasound2` "not
  found"); GBAemu → `libvorbisidec1` (in trixie, 1.2.1+git20180316-8+b1; the other two "not found").
  `pkexec apt-get` and the GUI's DownLoad button not run.
- Left on the card: python3-apt, the Installer and GBA.emu in `/dragonbox/packages`, the `~/dragonbox` link.

## 2026-11-23 — the one-shot revert disarms itself (R97)

Release card (r5), base and default `l5` (`5.6.19-m4-kbdled`), `device/pyra-boot-kernel.sh` with `stock` always
running `systemctl --no-reload disable pyra-boot-revert.service` installed to `/usr/local/sbin`.

- **No reboot:** `debug l0 --once --quiet` → `is-enabled` `enabled`; `/usr/local/sbin/pyra-boot-kernel.sh stock
  --quiet` (the unit's own command) → `disabled`, `status` "next boot l5 … one-shot revert: disarmed".
- **Test boot:** `debug l0 --once`, reboot → `uname -r` `5.6.19-pyradef`; `status` "next boot: l5", "one-shot
  revert: disarmed"; `is-enabled` `disabled`; the unit `active (exited)`, ExecStart status 0. `systemctl status`
  warns that the unit "changed on disk" and asks for a daemon-reload: a cosmetic effect of `--no-reload`, gone
  on the next boot.
- **Next boot:** `5.6.19-m4-kbdled`; `status` "next boot: l5", "one-shot revert: disarmed"; `is-enabled`
  `disabled`, `is-active` `inactive`, no link in `sysinit.target.wants/`.
- Before the change (R79, 2026-11-22) the same round trip left the unit enabled and `status` saying "enabled".

## 2026-11-23 — web browsers on the trixie card (R98)

Release card (r5), `5.6.19-m4-kbdled`, ceiling 1.5 GHz, `ondemand`, MATE desktop, no browser installed before.
`apt-get install --no-install-recommends firefox-esr chromium epiphany-browser netsurf-gtk dillo xdotool` (24
packages). Test page: Wikipedia "OMAP", live and as a local `wget -p -k` copy. A `/proc` poller recorded the
first window, the CPU settle time, PSS/RSS of the process tree, and an `xwd` screenshot. Results and method
in `browsers.md`.

- **firefox-esr 153.7.0esr:** renders both pages. Window 15.0 s cold, 4.6–5.1 s warm. PSS 437–447 MiB warm
  (613 MiB first start), RSS about 1.0 GiB. 71% of one core while idle on the page (60–90 s after launch).
- **netsurf-gtk 3.11:** renders both pages, simplified. Window 1.6 s cold, 0.6 s warm. PSS 43 MiB, RSS 69 MiB.
- **dillo 3.0.5:** window in 1.0 s / 0.6 s, PSS 12 MiB, but the page area stays blank on both copies.
- **epiphany-browser 48.5** (GTK4, WebKitGTK 6.0 2.54.3): aborts at start with `malloc(): invalid size
  (unsorted)`. With `GSK_RENDERER=cairo` the web process crashes instead. No WebKit switch tried changes that.
- **chromium 156.0.8078.108:** black window after 26–39 s. The GPU process exits (`GLX is not present`, signal 6)
  and the renderer is terminated for a bad Mojo message. The same happens with `--disable-gpu`, swiftshader and
  `--use-gl=egl`. The chromium packages all match at 156.
- Chromium's first start asked for the login keyring's password. `pyra` unlocked it, not the password set at the
  first login on 2026-11-21 (`troubleshooting.md`, "Asked for a keyring password that is not yours").
- Afterwards everything except `firefox-esr` (plus `libevent-2.1-7t64`) was purged. `dpkg -l` otherwise matches
  the list taken before the install. `x-www-browser` → `firefox-esr`.

## 2026-11-23 — a release card's first-boot password and its login keyring (R99)

**Cause, on the r5 card** (release image of 2026-11-20, first login 2026-11-21 04:46), from its own journal:
`gkr-pam: unable to locate daemon control file` and `stashed password to try later in open session` at sign-in,
`expired password for user pyra`, `pam_unix(lightdm:chauthtok): password changed`, `unable to locate daemon
control file` again in the password step, then `gkr-pam: unlocked login keyring` as the session opened, which
created the keyring with the stashed `pyra`. Read against gnome-keyring 48.0's `pam/gkr-pam-module.c` (`fixes.md`,
fix 33).

**Fix, on a fresh release card.** Image built with `pyra-image-build.sh -- --release --grow-on-boot --pyrainput
<0.1.19+pyra1 .deb>` from `8c3a35d` (clean), kernel r3 by the pinned download. Written to a 119 GB card from the
running r5 card with `dd`; SHA-256 of the card's first 6 GiB equal to the image's (`ffe059a9…3674`). Booted alone
in the left slot.

- `00:30:14` `pyra-first-boot.service` started; the window came up under `xinit` with no window manager and took
  keyboard input. Password set at `00:30:48` (`chpasswd` logged `gkr-pam: couldn't update the login keyring
  password: no old password was entered`, harmless: there is no keyring yet). Unit finished `00:30:49`, then lightdm.
- Before the first login: no `~/.local/share/keyrings/login.keyring`.
- First login at the greeter: `00:31:27` `stashed password to try later in open session`, `00:31:28` `unlocked
  login keyring`. `login.keyring` 105 bytes, mtime `00:31:28`.
- Which password opens it, checked on the card by a script that decrypts the file as gnome-keyring 48.0 does
  (AES-128-CBC, key from iterated SHA-256, MD5 check; validated first on a keyring made with a known password,
  which opened only with that one): `pyra` does not open it; the password set in the window does.
- The two journal lines `Gdk.Screen.get_width/get_height is deprecated` are cosmetic.

## 2026-11-23 — microphones and capture, both audio paths (R103)

CPU board V5.3, mainboard V5.3, the R99 release card (prep `8c3a35d`, kernel r3). No 4-pole headset to hand, so
the headset mic is untested. Details and the full table in `experiments/microphone/`.

- `5.6.19-m4-kbdled` (`l5`): `arecord -l` lists L15 capture devices 0 (MultiMedia1), 1 (MultiMedia2), 2 (Voice),
  4 (MODEM). `arecord -D hw:CARD=L15,DEV=0|1|2 -f S16_LE -r 48000 -c 2` all fail with `audio open error: Invalid
  argument`. `pactl list short sources`: only `aess.monitor`. Cause from source: no AESS uplink routers in the DAPM
  graph and no `PDM_UL1` route in the DT (`audio.md`, "Recording: the microphones").
- `5.6.19-pyradef` (`l0`, one boot via `pyra-boot-kernel.sh debug l0 --once`): one capture device,
  `hw:CARD=L15,DEV=0`. Built-in mic (`Main Mic`): speech at 30 cm (+12 dB) and loud speech, claps and scratches
  at 10 cm (+30 dB) within 1 dB of a quiet room; floor -82 dBFS RMS at +12 dB, -68 at +30 dB. Every capture
  starts with a click of up to 0 dBFS lasting under 100 ms. A tone recorded at 96000 came out at 1088 Hz, and at
  1000 Hz when recorded at 88200.
- Codec during a capture (debugfs, root): `AMICBCTL 0x11`, `MICLCTL 0x0d`, `MICGAIN 0x09`; `Main Mic Bias`,
  `MAINMIC`, `MicAmpL`, `ADC Left` On. The codec side is set up correctly; the input sees no sound.
- Back on `l5` after the next boot: `pyra-boot-kernel.sh status` showed `5.6.19-m4-kbdled`, revert disarmed.

## 2026-11-24 — kernel config: AF_ALG, UVC webcams, task I/O accounting (R106)

CPU board V5.3, mainboard V5.3, the R99 release card (kernel r3 in `l5`). Decisions and the full
results are in `kernel-notes.md` §8.

- `5.6.19-m4-kbdled` (r3): `cryptsetup benchmark` printed "Required kernel crypto interface not
  available. Ensure you have algif_skcipher kernel module loaded." and only the PBKDF2/argon2 lines.
  A Logitech C920 enumerated (`lsusb` 046d:08e5), but no `/dev/video*` appeared.
- `5.6.19-m4-kbdled-test` (built from `pc/pyra-crossbuild.sh kernel-m4-kbdled-test` with
  `M4_KBDLED_ASKED`, tarball SHA-256 `16478cec08934a51e411971f35df9a3bd6c353c83b85480bf67fad1b99cf8304`, installed into
  `l1`, one boot via `pyra-boot-kernel.sh debug l1 --once`): `cryptsetup benchmark` ran every test (aes-xts
  256b 61.0/60.9 MiB/s, all on `aes-generic`). A LUKS2 file was formatted and passphrase-checked as the user,
  then opened, given ext4, written and read back with sudo. The C920 captured at 29.9 fps (YUYV 640x480) and
  30.1 fps (MJPG 1280x720). `write_bytes` in `/proc/self/io` counted an 8 MiB fsynced ext4 write.
  `systemctl --failed` was empty. The boot's only kernel trace was the documented L3 error during panel power-on
  (`troubleshooting.md`, "One more thing the display does on every boot"), which r3's previous boot also logged.
- The next boot came back to `l5` (`pyra-boot-kernel.sh status`: running `5.6.19-m4-kbdled`, revert disarmed).
  The test kernel stays installed in `l1`.

## 2026-11-24 — the `kernel-5.6.19-r4` release asset, now the one prep pins (R107)

CPU board V5.3, mainboard V5.3, the R99 release card. The asset is `m4-kbdled-kernel.tar.gz` from the release
(Kernel release run 45350444408), downloaded on the PC.

- **Download:** SHA-256 `a09fabbc96a77fc25bfd3b585187e5d85916af1bf0085759995d786c45105ea0`, the same as the
  release's `SHA256SUMS`. `gh attestation verify` (gh 2.104.0) with `--repo` and `--signer-workflow` exited 0;
  a copy with one byte changed exited 1 (`building.md`, "Checking a download").
- **Install:** booted `l1` (`5.6.19-m4-kbdled-test`) once with `pyra-boot-kernel.sh debug l1 --once`, since the
  installer will not replace the running release. Then `pyra-install-debug-kernel.sh --slot l5` put r4 in place
  of r3. The installed `vmlinuz` hashes `646e033b…a459fdd`, the same as the `vmlinuz` in the tarball. `l5` stays the
  base. Fallbacks: `l0` stock and `l1`.
- **Boot:** `5.6.19-m4-kbdled #10 SMP PREEMPT Tue Nov 24 07:46:23 UTC 2026` came up on `l5` to the greeter.
  `systemctl is-system-running` returned `running`, and `systemctl --failed` was empty. The AESS card
  (`Letux Cortex 15`) is present, with eleven CPU steps up to 1.5 GHz. The only kernel warning was the
  documented L3 error during panel power-on.
- **The r4 additions:** `cryptsetup benchmark -c aes-xts -s 256` gave 60.4/58.6 MiB/s on `xts(ecb(aes-generic))`;
  r3 refuses it. One process wrote 8 MiB with an fsync, and its `/proc/self/io` `write_bytes` read 8413184.
  The `registers` file reads reg 09 as `00` before the first charger interrupt, as 0054 describes. No webcam
  this time: `CONFIG_USB_VIDEO_CLASS=m` is in the config (the C920 capture is in the entry above).
- **Selftest:** `pc/pyra-prep-selftest.sh` with this asset as `PYRA_KERNEL_TARBALL`: 476 passed, 0 failed,
  0 skipped. Prep reported the tarball as "the published release kernel-5.6.19-r4".

## 2026-11-24 — charge guard: the register path, on the R99 test card (E9 step c)

CPU board V5.3, mainboard V5.3, the R99 release card (kernel r4 in `l5` since R107), charger at `Full`
(CHGTERM, 89%, `current_now` 0) throughout — no active fast charge this session, so this is the register
path only, not a margin-driven reduction. `device/pyra-charge-guard.sh` added; see `experiments/charging/README.md`
"The guard" for what it does and why.

- **REG02 is read-only from sysfs.** The bq2429x_charger client exposes only `max_current` (REG00) and `otg`
  as writable attributes; `registers` is read-only. There is no sysfs knob for the charge current, unlike the
  input limit, so the guard goes straight to the i2c bus: `i2cget -f -y 1 0x6b 0x02` reads `0x60` without
  disturbing the bound driver (`-f` bypasses the `I2C_SLAVE` busy check the kernel driver's claim on the
  address would otherwise trip). Confirmed against TI SLUSBP6D (rev D, April 2023) Table 9-9: REG02 bits 7:2
  are ICHG[5:0], offset 512 mA, 64 mA/step, range 512-3008 mA (`000000`-`100111`); `0x60` decodes to ICHG
  `011000` = 2048 mA, bits 1:0 (BCOLD, FORCE_20PCT) both 0 — exactly the `chg_current = 2048000` the driver
  logs from the device tree at probe, so nothing between probe and now has touched it.
- **A real write/readback round trip, by hand:** `i2cset -f -y 1 0x6b 0x02 0x00 b` (512 mA, the floor), then
  `i2cget` and the driver's own `registers` file both read back `0x00`/`00` — no cache divergence between the
  forced userspace write and the driver's view. Restored with `i2cset -f -y 1 0x6b 0x02 0x60 b`, confirmed
  `0x60` both ways. `online` stayed 1 and `status` stayed `Full` throughout; nothing else observed to change.
- **The script itself**, live (not `--dry-run`), 20 s at a 5 s step: asserted 2048 mA on start (logged to the
  journal as `pyra-charge-guard`), then four samples with `in0_mV` 732-758 (consistent with a charger in) but
  `in10_mV` reading 0 the whole time — channel 10 (VBUS) only updates during an active charge; at CHGTERM it
  reads stale/zero, so `vtco_mV`/`margin_mV` were `NA` throughout and the guard correctly took no action. This
  matches the script's own NA handling (`in10 < 4000` mV), not a bug: the two logged charges in NEXT E9 (steps
  2a/2b, `ts-margin-charge-20261120.tsv`) were both taken during active fast charging, where IN10 reads ~4900 mV.
- **The margin/hysteresis arithmetic**, checked separately against synthetic IN0 at a fixed VBUS (4900 mV)
  since no real margin was available this session: a run from 800 down to 678 mV and back to 800 correctly
  dropped into `REDUCED` at margin 55 mV (`<=` 60), stayed there through the 13 mV trough without chattering,
  and only returned to `FULL` at margin 95 mV (`>=` 90) — the 30 mV gap holding as designed.
- **Not done this session:** a real charge with the guard attached, through an actual margin-driven reduction
  and restore. The card was at 89%/`Full` the whole session; triggering fast charging again needs either the
  pack to self-discharge below the ~100 mV recharge threshold (hours, unforced) or a physical unplug/replug,
  neither of which fit here. Left as a NEXT step.

## 2026-11-24 — four ssh-only booted checks from R15, on the R99 test card

CPU board V5.3, mainboard V5.3, the R99 release card, kernel r4 in `l5` since R107.

- **Root lock (R101): cannot be checked on this card — it predates the fix.** `sudo passwd -S root` prints
  `root P 2026-02-01 0 99999 7 -1` (`P`, not `L`); `su` asks for a password and refuses; `getent shadow root`
  shows a bare yescrypt hash with no `!` prefix, last changed day 20485 (2026-02-01), the same vendor hash
  `fixes.md` documents. Neither `emergency.service.d/` nor `rescue.service.d/` drop-in exists. This isn't a
  regression: the R99 image was built from `8c3a35d` (2026-11-23 17:14), and the root-lock change (`d4dd8c2`,
  R101) landed about three hours later the same day (20:32) — `git merge-base --is-ancestor d4dd8c2 8c3a35d`
  fails. The R99 card is "older" with respect to this specific fix, the same bucket as r5 in `PROMPT.md` Part
  A. This check needs a release card built from a commit at or after `d4dd8c2`, then booted for real; R99
  doesn't qualify. Left in NEXT R15 for a future card (see NEXT.md note added this session).
- **Fix 31, `pyra-info` (R93): pass.** `Prepared : commit 8c3a35dc6048, 2026-11-23, kernel-5.6.19-r3, release
  image`; `Boot entry : l5; default l5`. Matches the commit this card was built from and its pinned kernel at
  prep time (the Prepared line is a static record from `/etc/dragonbox-pyra-prep`, not the currently running
  kernel — `uname -r` reports `5.6.19-m4-kbdled` #10, r4, installed later by R107).
- **Fix 32, DBP Installer (R94): partial — the two state-of-the-image facts pass; the Installer app itself
  isn't on this card to launch.** `python3 -c 'import apt, apt_pkg; print(apt_pkg.VERSION)'` → `3.0.3`, no
  error. `ls -l ~/dragonbox` is a symlink to `/dragonbox`, owned `pyra:pyra`. `dbpd` is active
  (`dbp-cmd ping` exits 0); `dbp-cmd list` prints nothing (exit 1, nothing registered). Neither
  `dbpInstaller_sebt3` nor any `.desktop`/package entry for a DBP Installer exists anywhere on the card
  (`dpkg -l`, `find / -iname '*dbpinstaller*'` both empty) — per `docs/dbp.md` it's obtained from the DBP
  repository, not shipped by prep; fix 32 only makes the image ready for it (`apt_pkg` import, the
  `~/dragonbox` link). `curl` isn't installed either, so reachability to the DBP repository wasn't checked.
  Launching the Installer and watching a RootFs register in `dbp-cmd list` needs the Installer's `.dbp` file
  fetched onto the card first, which is new device state beyond this session's plain ssh checks. Left in NEXT
  R15 for a session that fetches it (see NEXT.md note added this session).
- **pyra-hacks 0.38+pyra5 CPU ceiling (R82): pass.** `dpkg-query -W pyra-hacks` → `0.38+pyra5`.
  `scaling_max_freq` read `1500000` before. `echo CPU_MAX_MHZ=1000 | sudo tee /etc/default/pyra-thermal` then
  `sudo systemctl restart pyra-thermal`: within 3 s, `scaling_max_freq` read `1000000` on cpu0. Restored with
  `sudo rm /etc/default/pyra-thermal`; within 3 s the ceiling returned to `1500000`, matching `fixes.md`'s "no
  file, no ceiling" default and the selftest's assumption.

## 2026-11-24 — fix 32, DBP Installer launch+download, on the R99 test card

R99, same card as above. Finishes the partial check from earlier the same day: the Installer
app itself, not shipped by prep, fetched onto the card and launched.

- **Fetched `dbpInstaller_sebt3` 1.2.1.** The app page `https://pyra-handheld.com/repo/apps/161` is HTML, not
  the package; its embedded JSON gives the real link,
  `https://pyra-handheld.com/repo/packages/dbpInstaller_sebt3/download`. Fetched on the PC with `curl` (no
  `curl`/package-manager changes made on the card): MD5 `0177ded6197a2f9df0f4e3d1a76bcb80`, matching the
  repository listing and `docs/dbp.md`. scp'd to `~pyra` on the card, MD5 re-checked there (same hash).
- **Install (R94): pass.** Copied the `.dbp` into `/dragonbox/packages/`; `dbpd`'s inotify watch on that folder
  was already live (fix 32's link predates this session), so `dbp-cmd list` showed `dbpInstaller_sebt3`
  registered within 3 s, no manual `dbp-cmd register` needed.
  `dbp-run --chdir dbpInstaller_sebt3 dbpInstaller.sh cards` updated its package cache from the DBP repository
  and printed `RootFs` — no `ModuleNotFoundError: No module named 'apt_pkg'`.
  `dbp-run --chdir dbpInstaller_sebt3 dbpInstaller.sh -d RootFs install icefieldfrenzy.farox` downloaded to
  100% and exited 0. `~/dragonbox/packages/icefieldfrenzy.farox.dbp` appeared immediately after, and
  `dbp-cmd list` showed it registered (`'/dragonbox/packages/icefieldfrenzy.farox.dbp' 'icefieldfrenzy.farox'
  nodesktop`) right away — the `~/dragonbox` → `/dragonbox` link (fix 32) is what let `dbpd`'s existing watch
  pick it up. NEXT R15's fix-32 sub-item is done on this card.

## 2026-11-24 — fixes 9 and 10 across real reboots, on the R99 test card

R99, kernel r4 in `l5`. NEXT R15's fix-9/fix-10 sub-item: both audio fixes were only ever
confirmed by a manual trigger before (fix 9: `udevadm trigger`; fix 10: `systemctl start user@105.service` by
hand). Three real boots this session, two `sudo reboot` over ssh and one owner-initiated power cycle between
them (the USB3503 hub died on the second `sudo reboot` — see below). Checked right after each boot, before any
login at the console could tear down the greeter's manager.

- **Fix 10 (greeter PulseAudio): pass, both times it could be checked (boot 1 and boot 3).** Within seconds of
  each boot, `user@105.service` (the lightdm greeter's manager) was `active (running)` with nobody yet logged
  in at the console, and
  `sudo -u lightdm XDG_RUNTIME_DIR=/run/user/105 systemctl --user show pulseaudio.service -p ConditionResult`
  (and the same for `.socket`) read `ConditionResult=no` on both — no manual start needed, confirming the
  drop-ins from `device/pyra-greeter-audio.sh` skip the greeter's PulseAudio on a real boot, not just when
  started by hand. The journal shows it directly too: `pulseaudio.socket - Sound System was skipped because of
  an unmet condition check (ConditionUser=!lightdm)`, same for the service, both within a second of
  `pyra-audio-select.service` finishing. Boot 2 (the power-cycle) couldn't be checked for this: by the time ssh
  came back the owner had already logged in at the console and the greeter's manager had already exited.
- **Fix 9 (audio routing): a real, reproducible boot-time bug, not caught before.** All three boots: `Handsfree
  Left/Right Playback` came up `HF DAC` (speakers routed) every time, but `Headset Left/Right Playback` came up
  `Off` every time — headphones silent, speakers fine, same rule, same boot. Confirmed this isn't transient: on
  boot 3 it was still `Off` 20+ s after boot. `amixer -c L15 cget` showed `values=1,1,0,0` for the four controls
  in enum order (`Off`=0 for both pairs) — not the literal string "On" either way, since neither control's enum
  has an item by that name; "routed" (`HF DAC`/`HS DAC`) vs `Off` is what matters.
  `sudo udevadm trigger --subsystem-match=sound --action=add` fixed it instantly, every time it was tried, which
  rules out the rule or `pyra-audio-route-apply` itself being broken — it's specifically a boot-time race. The
  script has no error logging for the four-route loop (only the AESS-DSP block below it does), so nothing in the
  journal records the miss; `journalctl -b` just shows `omap-abe-twl6040 sound: twl6040-dl2 <-> mcpdm-abe-dl2
  mapping ok` and the headset jack input device registering a good second or so after the card's `controlC*`
  node appears (card number wasn't stable across boots either, 3 then 4), which is around when the rule's
  `RUN+=` would fire. Left as a new NEXT item (fixes.md Fix 9 section updated with this finding) rather than
  fixed in this session.
- **The USB3503 hub died on the second `sudo reboot`.** R99 was unreachable on both its USB-ethernet
  and WLAN addresses for about nine minutes — boot 1 had come back in under
  20 s — matching Fix 5's documented failure mode (`docs/fixes.md`, `docs/troubleshooting.md` "USB is dead after
  a warm reboot"): the rescue unit normally recovers the hub within seconds, but this time it didn't, and the
  stated way back in without console access is a physical power cycle. The owner power-cycled the card by hand;
  it came back and fix 9's headset bug reproduced identically on that boot too (see above), but fix 10 couldn't
  be checked on it (see above). No further diagnosis attempted — this is Fix 5's known class of fault, not a new
  one, and the session had no console access to investigate further.
- NEXT R15's fix-9/fix-10 sub-item: fix 10 is done; fix 9 is not — moved to a new NEXT item for the boot race.

## 2026-11-25 — R109: fix 9's headset-route boot race, diagnosed and fixed

R99, kernel r4 in `l5`. Owner approved rebooting R99 for this session (Part B rule 5), after
flagging the USB3503 hub risk from the prior session's second reboot; the hub survived every reboot this time
(back up in 21-24 s each time, no power cycle needed).

- **The two working guesses in `fixes.md` were both wrong.** Installed the unmodified `pyra-audio-route-apply`
  with `logger` calls added on failure (no retry) and rebooted: the four-route loop never logged a failure on
  any boot, and an instrumented copy that logged every `cset` attempt plus the resulting value at +0 s, +2 s
  and +5 s showed the headset pair set correctly on the very first attempt, still correct 5 s later, every
  time. So the udev rule's own run of the helper was never losing a race against the codec or against the
  controls not existing yet — it always worked. The routes were still `Off` by the time a check ran minutes
  later, which meant something *after* the rule finished was undoing it.
- **Confirmed the actual cause directly, without needing a boot:** on an already-up card with both headset
  routes sitting at `HS DAC`, running `systemctl --user restart pulseaudio.service` alone — nothing else
  touched — put both back to `Off` every time it was tried. `module-alsa-sink`'s own open of `hw:CARD=L15`
  (from `pyra.pa`) is what resets the headset pair; the handsfree pair is never touched by it. On a real boot
  this PulseAudio start happens a second or so after the udev rule's `RUN+=` already ran, which is why the rule
  always looked correct right up until the point it didn't.
- **The fix:** `/etc/systemd/user/pulseaudio.service.d/20-pyra-audio-route.conf` (now installed by
  `device/pyra-audio-route.sh`) adds `ExecStartPost=/usr/local/sbin/pyra-audio-route-apply` to
  `pulseaudio.service`. That unit is `Type=notify`, so `ExecStartPost` only runs once PulseAudio has signalled
  ready — after it has already opened the card and reset the mixer — making the reassertion ordered correctly
  by construction rather than by guessing a window. Confirmed by hand first (force both controls to `Off`,
  `systemctl --user restart pulseaudio.service`, both read `HS DAC` again within about a second, repeatable
  across three consecutive restarts) before deploying it as the real fix.
- **Two real boots, both clean.** Boot 1: `Handsfree Left/Right Playback` and `Headset Left/Right Playback` all
  read `1` (`HF DAC`/`HS DAC`) a few seconds after the card came up, nothing touched by hand. Boot 2: caught
  mid-startup once (`Headset Left/Right Playback` briefly `0`, in the few-second window between PulseAudio's
  `Starting` and `Started` — i.e. before `ExecStartPost` had run yet), then settled to `1`/`1` and held there,
  confirmed stable for 20+ s of continuous polling inside one ssh session. (A naive series of separate `ssh`
  invocations polling the same boot looked unstable — pulseaudio flapped between a torn-down and a fresh
  `user@1000.service` because login lingering isn't enabled for `pyra`, which starts and stops
  `pulseaudio.service` on its own with every session open/close. That instability is a side effect of checking
  it that way over ssh, not something a real console session does; polling from inside one persistent
  connection was stable throughout.) No `pyra-audio-route` logger entries on either boot — the four-route loop's
  `cset` calls never failed.
- `device/pyra-audio-route.sh`'s four-route loop also gained `logger -t pyra-audio-route` calls on failure,
  previously entirely absent (only the AESS block had them) — why this shipped two months unnoticed: every
  earlier check of fix 9 used a manual `udevadm trigger` retrigger, which always worked, so a cold boot was
  never actually watched end to end before R15's reboot pass.
- `docs/fixes.md` Fix 9 updated with this finding and the fix; `docs/audio.md`'s troubleshooting step 2 notes
  that restarting PulseAudio is itself what resets the headset pair. NEXT R109 deleted.
- Learned: when a "fixed once triggered by hand, broken on a cold boot" bug doesn't reproduce with instrumented
  logging *inside* the suspected script, stop assuming the race is inside that script. Checking whether the
  state holds immediately after the script runs, rather than only checking whether the script's own calls
  succeeded, is what found the real culprit here — the script was always right; something arriving later undid
  it.

## 2026-11-25 — fix 29, funkeymonkey-pyrainput from the packaged unit, on the R99 test card

R99, kernel r4 in `l5`. NEXT R15's fix-29 sub-item: the only prior check (R87) was a
`dpkg -i` of the `.deb` on the r5 card, not the packaged install path through prep, and the SysRq press was
never attempted. R99 has the package from prep itself, and was already sitting on a real boot from the same
session that closed R109 (booted 04:27:14 CET, no reboot forced for this check):

- `dpkg-query -W funkeymonkey-pyrainput` → `0.1.19+pyra1`.
- `systemctl status pyrainput.service` → active (running) since 04:27:40, 26 s after boot — started by the
  unit at boot, not a manual start. `dpkg -S /usr/lib/systemd/system/pyrainput.service` confirms the package
  owns that file (not a leftover fix-3 write); `dpkg -V funkeymonkey-pyrainput` flags only the expected
  conffile (`/etc/sudoers.d/pyrainput`), nothing else altered.
- Fn+Esc: watched `sudo journalctl -k -f` over ssh while the owner pressed it three times on the device. All
  three presses opened MATE's screenshot tool (its default binding for the `Print` keysym, which is what
  `KEY_SYSRQ` maps to in a desktop session) and nothing was added to the kernel log — expected, since the
  kernel's magic-SysRq console handler isn't what a desktop session exercises; this is the same "SysRq
  (PrtScrn)" key patch 0003's commit message refers to. Confirms the patched keycode reaches the running
  session correctly; the first watch attempt (plain `journalctl -k -f`, no sudo) showed nothing at all because
  this ssh user isn't in `adm`/`systemd-journal` and can't read kernel-facility journal entries without sudo —
  worth knowing for any future over-ssh kernel-log check on this card.

All three of fix 29's R15 checks pass on the packaged path, from a real boot. NEXT R15's fix-29 bullet marked
done.

## 2026-11-25 — fix 28, Fn symbols on a real boot, on the R99 test card

R99, kernel r4 in `l5`, the same real boot as the fix-29 and fix-10/9 work above (`uptime -s`
04:27:14 CET, no reboot forced). NEXT R15's fix-28 sub-item: the selftest had only proved the patched X file,
the diversion and the rebuilt console cache were in the image, not that a real boot's daemon and keymap
produce the right character from an actual key press (R78's check used uinput injection, not fingers). All
presses below were physical, done by the owner on the Pyra's own keyboard; this session only switched VTs and
read the result back over ssh.

- **X** (mate-terminal, desktop already up at `:0` since 04:36): Fn+D and Shift+Fn+D both typed `_`; Fn+' and
  Shift+Fn+' both typed `:` (both combos used to type nothing with Shift). Checked for the Alt regression by
  typing `foo bar`, then the chord, then a fast plain `b`: in every case `_b`/`:b` landed in place with the
  cursor right after it, never jumping back over "bar" the way Alt+b would. Fn+R typed é, Fn+T è — keycap-correct,
  not swapped.
- **Console** (tty1): `sudo systemctl restart getty@tty1 && sudo chvt 1` gave a clean `login:` prompt; the
  owner pressed Fn+E, R, T, Y, U, I, O, P, A, S, D, F, G, H, J, K, L, ', M in that order, no Enter. Read back
  the same way `experiments/fn-keys/fn-tty.sh` reads its injected runs, applied here to real presses:
  `sudo python3 -c '... open("/dev/vcsu1","rb").read().decode("utf-32-le") ...rsplit("login: ")...'` →
  `€éèàç¨üß?+_{}|~öä:´` — all eighteen keycap symbols, in order, none missing and none showing as `ESC [ M` or
  Delete. `sudo chvt 7 && sudo systemctl restart getty@tty1` returned the screen to the desktop and left tty1
  with a fresh prompt.

Both halves of fix 28 confirmed on a real boot with physical key presses. NEXT R15's fix-28 bullet marked
done.

## 2026-11-25 — fix 30, touchscreen calibration and fuzz, on the R99 test card

R99, kernel r4 in `l5`, booted 17:31:50 CET this session (`uptime -s`; no reboot forced).
NEXT R15's fix-30 sub-item: R89's original check (`fixes.md`) copied the three files onto the r5 card by hand
and triggered udev on an already-running X server, not through prep or a real cold boot — the same gap fixes
28 and 29 had before this session and last session.

- All three of fix 30's files are present from prep's own install, not copied in: `/usr/local/bin/pyra-touch-calibrate`,
  `/etc/udev/rules.d/91-pyra-touch-fuzz.rules`, `/usr/local/share/applications/xinput_calibrator.desktop`.
  (libinput's own `90-libinput-fuzz-override.rules` is package-shipped under `/usr/lib/udev/rules.d/`, not one
  of fix 30's files.)
- `/proc/bus/input/devices` confirms `/dev/input/event4` is the TSC2007 Touchscreen. `sudo evtest /dev/input/event4`
  showed Fuzz 5 on both `ABS_X` (0-719) and `ABS_Y` (0-1279).
- `/var/log/Xorg.0.log` for this boot's cold X start carried four `libinput bug: kernel fuzz of 5 ...` lines (two
  pairs, `LIBINPUT_FUZZ_00`/`_01` each), not the two R89's check and `fixes.md` describe. Checked whether this was
  a regression: every input device in the same boot's log (`palmas_pwron`, `tca8418`, `pyra-game-buttons`, the
  headset jack, `user-buttons`, `pyraInput keyboard`/`Mouse`) shows the same "config/udev: Adding ... " /
  "device removed" pair during this stage of startup — the touchscreen gets hotplug-added once, immediately
  removed, then re-added a second time once `99-pyra-touchscreen.conf`'s static `CalibrationMatrix` option is
  applied, and each add produces its own correct fuzz-5 pair. Nothing else appears for `event4` besides the
  expected tag/fuzz/touch-device lines — no third add, no other errors. R89's check never saw this because it
  reused an already-running X server and only triggered one add via `udevadm trigger`. `docs/fixes.md` Fix 30
  updated: two lines per device add, not per X open overall.
- Menu check (physical, owner): MATE's "Calibrate Touchscreen" was confirmed via `ps -ef` to launch
  `mate-terminal -x /bin/sh -c /usr/local/bin/pyra-touch-calibrate` → `python3 /usr/local/bin/pyra-touch-calibrate`,
  not `xinput_calibrator` — the two `.desktop` files share a display name but `XDG_DATA_DIRS` resolves to the
  pyra one first, as `fixes.md` says. In the course of this check the owner went through the five-point
  calibration by accident. `/etc/X11/xorg.conf.d/99-zz-pyra-touch-calibration.conf` now holds a freshly saved
  matrix (`1.006570 0.005049 0.005519 0.005165 1.056097 -0.031142 0.000000 0.000000 1.000000`) in place of the
  vendor default from `99-pyra-touchscreen.conf` (`0.998032 -0.004569 0.016723 -0.006564 1.083056 -0.031356
  0.000000 0.000000 1.000000`). Owner's call: keep the new calibration rather than reset it.

All three of fix 30's NEXT-R15 checks pass on a real boot through prep's own install path. NEXT R15's fix-30
bullet marked done.

## 2026-11-25 — charge guard: a real margin-driven reduction and restore (BACKLOG E9, done)

On the R99 test card, kernel r4 in `l5`. Pack at 15% / 3.675 V, discharging, no charger — below the ~3.95 V
recharge threshold the owner had been waiting for (BACKLOG E9's deliberate wait). `device/pyra-charge-guard.sh`
and `pyra-chgwatch.sh` had never been copied to this card; deployed to `~pyra` and started under its NOPASSWD
sudo (`~/pyra-charge-guard.sh ~/pyra-charge-guard-20261125-181011.tsv 14400 10`, nohup'd and disowned so it
survives the ssh session) before the charger went in, logging every 10 s.

- Start: asserted `FULL` (2048 mA, `reg02` `0x60`); margin read `NA` on battery, as expected (IN10 stale
  without a charger).
- Charger plugged in at t=51s: `chg_status` flipped to `Charging`, `bat_ua` went positive (~1.4 A in), margin
  started at 101 mV and fell as the gauge warmed.
- Three full thermostat cycles over ~35 minutes of active charging, cap 15% → 23%:
  - 18:19:36 reduced 2048 → 512 mA, margin 60 mV (cap 18%)
  - 18:25:30 restored 512 → 2048 mA, margin 91 mV (cap 19%)
  - 18:27:11 reduced, margin 59 mV (cap 20%)
  - 18:34:14 restored, margin 96 mV (cap 21%)
  - 18:35:25 reduced, margin 56 mV (cap 21%)
  - 18:45:31 restored, margin 90 mV (cap 23%)
- `reg02` tracked `ichg_mA` exactly on every sample (`0x00` in `REDUCED`, `0x60` in `FULL`) — no divergence, no
  `FORCE_20PCT` warning. `dmesg` showed only the normal `bq2429x_usb_detect` line at plug-in, no `HOT`/fault.
- Left running (nohup, default 4 h duration) on the card past the end of this session; it keeps logging to the
  same file and auto-restores on charger-offline while it runs. (Audit, same day: that holds only for an
  unplug inside the four hours. If the run ends while `REDUCED`, REG02 stays at 512 mA, since the script
  doesn't restore on exit, until something rewrites it; NEXT R117 reads it back.)
- (R117, 2026-11-26: REG02 read `0x60`. The run ended at 19:07:53, when the Pyra was powered off, after
  five cycles, not three. At 19:06:52 a 0.4 s VBUS drop reset REG02 to `0x60` while the guard stayed `REDUCED`,
  so `reg02` did diverge for the last 7 samples. The guard now re-applies the reduction. See the R117 a section.)

Full log: `experiments/charging/charge-guard-real-charge-20261125.tsv` (the complete 345-line file since R117). Resolves BACKLOG E9's last open item — see `experiments/charging/README.md`
"The guard".

This same real charge also answers R15's "charging on `5.6.19-m4-kbdled`" line: charger detected
(`bq2429x_usb_detect`, `chg_status` → `Charging`), `bq2429x` status in `dmesg`/sysfs sane (`reg02` tracking
exactly, no divergence), no `HOT` fault, and capacity rising (15% → 23%) — all on kernel r4, which is
`5.6.19-m4-kbdled`. No separate charge was needed for that line.

## 2026-11-25 — U-Boot's own banner on the serial line at power-on (R85)

FTDI adapter (`ttyUSB1`, 1500000 baud, `stty raw` + `cat`) opened and capturing on the PC before the Pyra
was powered on, then the owner powered it off and back on (the R99 test card, left slot, was already in and
running; the same power cycle). R75's earlier capture only ever showed kernel lines because the port was
opened after power-on; this time the capture caught the bootloader's own output from the first line:

```
U-Boot SPL 2016.11 (Sep 11 2024 - 22:42:22)
OMAP5432-GP ES2.0
cold reset
rsttime1 has not yet been configured
>>spl:board_init_r()
spl_init()
EMIF power ctrl changed to 00000000, 00000000
Trying to boot from MMC1
SPL: Please implement spl_start_uboot() for your board
SPL: Direct Linux boot not active!
spl: payload image: U-Boot 2016.11 for omap5_pyra bo load addr: 0x807fffc0 size: 336152
Jumping to U-Boot
loaded - jumping to U-Boot...

U-Boot 2016.11 (Sep 11 2024 - 22:42:22 +0000)

LPAE build running in hypervisor mode!
CPU  : ARM Cortex-A15 r2p2
SoC  : OMAP5432-GP ES2.0
Board: OMAP5432 Pyra
I2C:   ready
DRAM:  4 GiB
MMC:   OMAP SD/MMC: 0, OMAP SD/MMC: 1, OMAP SD/MMC: 2
*** Warning - bad CRC, using default environment

ram code 0x0
version code 0xa
Found Pyra V5.3 with 4GB RAM
HW Revision: CPU: v5.3 Mainboard: v5.3
BOOTDEV: SD Left
```

- No `READBACK` or `Memory test failed` lines: the RAM check passed, as expected for this card's SPL (R85,
  2026-11-22). The SPL and U-Boot banners' build timestamp (`Sep 11 2024 - 22:42:22`) matches the installed
  `u-boot-pyra` 0.1.5 confirmed read-only in the R75 entry above.
- After the banner: the extlinux menu (five entries, matching R99's `user.cfg`), kernel boot, and a login
  prompt, then a real ssh login to the card confirmed it came up clean (`uname -r` = `5.6.19-m4-kbdled`,
  `uptime` 2 minutes). Nothing was changed on the card; this was read-only serial capture plus a power cycle.
- R15's U-Boot-on-serial bullet is done; closes R85 for NEXT.

## 2026-11-25 — charger replug on a laptop port (R15, fix 8)

The R99 test card answered ssh this session — neither of the two SD cards (trixie, bookworm) is in the Pyra
right now. Kernel r4 (`5.6.19-m4-kbdled`), `max_current` at the 2 A default and nothing plugged in beforehand.
`device/pyra-chgwatch.sh` copied to `/tmp` and started in the background (240 s, 1 s resolution,
`experiments/charging/chgwatch-laptop-port-replug-20261125.tsv`), then the owner plugged the Pyra's charge
cable into a laptop's USB port, waited, unplugged it, and replugged it once.

`dmesg`:

```
bq2429x_charger 1-006b: bq2429x_usb_detect: r8=04 PWRGOOD r9=10 UNPLUG
bq2429x_charger 1-006b: bq2429x: VBUS became available
bq2429x_charger 1-006b: bq2429x_usb_detect: r8=64 HOST FCHG PWRGOOD r9=00
bq2429x_charger 1-006b: bq2429x_usb_detect: r8=40 HOST r9=10 UNPLUG
bq2429x_charger 1-006b: bq2429x: VBUS became unavailable
bq2429x_charger 1-006b: bq2429x_usb_detect: r8=04 PWRGOOD r9=00
bq2429x_charger 1-006b: bq2429x: VBUS became available
bq2429x_charger 1-006b: bq2429x_usb_detect: r8=64 HOST FCHG PWRGOOD r9=00
```

- The chip classifies the laptop port `HOST` every time (SDP, no charger type), never `ADAP` — the same class
  the normal micro port got in the R74 trace, not the USB3 port's charger-class result.
- `pyra-chgwatch.sh`'s 1 s samples read `reg00` `0x36` (`max_current` `2000000`, 2 A) on every row, including
  the rows right after the replug's VBUS-available line; no sample caught the chip's own
  100 mA/500 mA floor. That is coarser than R74's kprobe trace (which caught the floor and a sub-0.3 s
  correction on the other two ports), not evidence the floor didn't happen here — the task asked only for
  `max_current`/`online`/`status` at this resolution, which is what fix 8's re-check is meant to guarantee.
- No `HOT`/`r9` fault lines; `bat_status` and `chg_status` tracked the plug state normally in between.
- Correction (2026-11-25 audit, development log R116): the committed TSV covers t=0-97 s, not 240 s, and
  its first row already shows the cable in (`chg_status` `Charging`, `reg08` `0x6c`). So it holds one unplug
  (t=7-11 s) and one replug (t=12 s); the first plug happened before the log starts. All 88 sample rows read
  `reg00` `0x36`. While charging, `reg08` `0x6c` has DPM_STAT (bit 3) set, which `dmesg`'s detect-time `r8=64`
  doesn't: the charger sat in input dynamic power management on this port, so the laptop port was not
  delivering what the 2 A limit allows and the chip held back to keep VBUS up (decoded from the TSV against
  SLUSBP6D's REG08 layout; not measured further).
- Answer: the chip detects SDP on this port (not a charger-class negotiation), fix 8's re-check still holds a
  sane 2 A limit after the replug at the resolution asked for, and yes — 2 A is asserted on a port whose SDP
  class is rated for 500 mA, same "2 A on any supply" policy already in place for the normal micro port's
  floor case (owner decision, 2026-11-21), not a bug.
- Closes R15's charger-replug bullet; the laptop-port clause was its last open part (`docs/fixes.md` fix 8
  updated).

## 2026-11-25 — does rumble/vibra work? (R111)

Neither of the two SD cards answered over ssh (host key mismatch on both); the R99 test card
answered, kernel `5.6.19-m4-kbdled` (r4 in `l5`). Not tried on the stock `5.6.19-pyradef`
card this session. The owner gave permission first (Part B rule 5) and watched the Pyra while the motor was
triggered.

- `lsmod`: `twl6040_vibra` is loaded. `/proc/bus/input/devices` shows `twl6040:vibrator` at `event8`
  (`EV=200001`, `FF=1 7030000 0 0`) — an FF-capable evdev device exists. `pyraInput Gamepad` (`event11`,
  funkeymonkey-pyrainput) exposes the same FF bitmap, so a game using pyrainput's force feedback (the forum's
  DuckStation report) has somewhere to forward it.
- `evtest /dev/input/event8` lists `FF_RUMBLE`, `FF_PERIODIC`, `FF_SQUARE`, `FF_TRIANGLE`, `FF_SINE`,
  `FF_GAIN` as supported — a rumble-type motor, not a force-feedback wheel.
- ALSA (card 3, `L15`) has `Vibra Left Playback` and `Vibra Right Playback`, each an enum of `Input FF` /
  `Audio PDM`. Both are already set to `Input FF` — the data path an `FF_RUMBLE`/`FF_PERIODIC` upload uses, not
  the `Audio PDM` path the forum's old alsamixer trick (sliding "Vibra Right" to bleed audio into the motor)
  needed. Mixer routing is not the blocker.
- `fftest` isn't packaged under that name; it's in `joystick` (not installed before this session — installed
  with `sudo apt-get install -y joystick`, clean, pulled in `inputattach`).
- `fftest /dev/input/event8`: uploaded `Periodic sinusoidal` and both rumble effects (`Strong rumble, with
  heavy motor`, `Weak rumble, with light motor`) OK; `Constant`/`Spring`/`Damper` failed with `Invalid
  argument` as expected (this device has no constant-force axis). Master gain set to 75% OK.
- Played the strong-rumble effect twice, about a second apart (`printf '1\n1\n-1\n' | fftest`): no error from
  `fftest`, and `sudo dmesg` has no `twl6040`/`vibra` lines at all around that time — the i2c writes went
  through without the driver complaining.
- **The motor did not move.** The owner was watching/holding the unit and felt and saw nothing.
- Answer: on this card and kernel, the kernel module, the evdev/FF layer and the ALSA routing accept and play
  the effect with no error, but the physical motor does not respond (one unit, one session). That puts the
  failure below the FF API; it does not yet rule out software. Not checked: the stock `5.6.19-pyradef` kernel
  and its device tree; whether the TWL6040's vibra control registers actually change while an effect plays
  (not read back); and the vibra supply — no `regulator_summary` entry names a vibra rail, so the driver may
  hold a dummy regulator while the real rail stays off, which is a device-tree question as much as a meter
  one. Forum reports describe board-to-board hardware variance (the volume-wheel-daemon bounty thread: "some
  CPU boards where vibration only sometimes work ... sounds like the motor doesn't get enough power"; the
  final-order-email news thread: assembly-time "vibro motor not working" traced to flux/corrosion), which fits
  but isn't shown for this unit. (Verdict narrowed by the 2026-11-25 audit, development log R116.)
- Left on the card: `joystick`/`inputattach` installed (harmless, no daemon).
- **Superseded 2026-11-26 (R117 c, below):** the motor works. The vibra registers do change and the
  supplies are real (`vsys`), but fftest's strong rumble drives it at code 19, below its start level of
  about 25-32. Driven at 51 it rumbles.

## 2026-11-25 — ScummVM-Pyra 2026.4.0: "properly working fullscreen" claim (R113)

Neither of the two SD cards answered over ssh (host key mismatch on both); the R99 test card
answered, kernel `5.6.19-m4-kbdled` (r4 in `l5`). From the forum review's compatibility
list (section B of the forum review): does the forum post's "new properly working fullscreen"
actually hold on trixie?

- **Fetched.** `https://pyra-handheld.com/boards/posts/1726994/` is a thread post, not the repo app page: it
  embeds a `contentRow` unfurl linking `https://pyra-handheld.com/repo/apps/274` ("App ScummVM-Pyra - DBP
  repository"). That app page's own embedded JSON (not a plain `<a href>`, same pattern as R94/R110) lists the
  2026.4.0 release as download id 397: `https://pyra-handheld.com/repo/packages/ScummVM/397/download`, MD5
  `d36ea3207c5a420d0b0bc3a8b36cd813`, 173288132 bytes. Its own changelog entry (fetched on the PC with `curl`,
  no package-manager changes) reads: "R1 or CTRL+F5 displays the Global Main Menu of ScummVM ... (Alt + Enter
  for fullscreen mode) Fullscreen mode is now working properly!" — the claim under test, in the author's own
  words.
- **Install: pass.** Downloaded on the PC, MD5 matched before transfer. scp'd to `/dragonbox/packages/` on the
  card (MD5 re-checked there, same hash); that folder already existed and was already watched (fix 32's link
  predates this session, same as R94), so `dbp-cmd list` showed `ScummVM` registered immediately, no manual
  `dbp-cmd register` needed. `/usr/share/applications/__dbp__ScummVM_default.desktop` appeared with
  `Exec=run-scummvm-pyra.sh`.
- **Launch: fails, doesn't start.** Running the freshly-fetched binary itself needed the owner (same tool
  refusal as R94/R110). `dbp-run --chdir ScummVM run-scummvm-pyra.sh` printed a dependency dialog (`libunity9,
  libflac12, libmpeg2-4, libvpx7, liba52-0.7.4, libspeechd2`), then: `./scummvm-pyra: error while loading shared
  libraries: libFLAC.so.12: cannot open shared object file: No such file or directory`. Unlike the GBAemu case
  in `docs/dbp.md` (where the same dialog's claimed-missing deps turn out to be present), this one is real:
  `dpkg -l` and `find / -iname "libFLAC.so*"` on the card show only `libflac14` (`libFLAC.so.14`); trixie's repo
  has no `libflac12` package at all (`apt-cache policy libflac12` empty, `apt-cache search libflac` lists
  `libflac14` as the only runtime). Mounted the package read-only (`dbp-cmd mount ScummVM`, union at
  `/mnt/dbp/union/ScummVM`) to check for a bundled copy: the DBP ships only its own data files and the
  `scummvm-pyra` binary, no bundled `.so`s — it depends entirely on the system's `libFLAC.so.12`, a soname
  trixie dropped when it moved to `libflac14`. Cleanly unmounted after (`dbp-cmd umount`; `mount | grep -i
  scummvm` confirmed nothing left behind).
- Answer: **no** — the "properly working fullscreen" claim can't be reached on trixie at all. The app never
  starts; it fails at the dynamic linker before any window opens, so fullscreen (or anything else about the
  2026.4.0 release) is untestable on this card as shipped. The failure is an ABI gap between this forum build
  (linked against bookworm-era `libFLAC.so.12`) and trixie's `libflac14`, not anything prep's thirty-three
  fixes touch. A bookworm card would need the same test to see if 2026.4.0 starts there; not tried
  this session (that card wasn't in — see above).
- Left on the card: `/dragonbox/packages/ScummVM-Pyra-2026.4.0.dbp` (registered, won't launch); harmless to
  leave in place as evidence, matches how other dead-end DBPs in that folder are already kept.

## 2026-11-25 — Streets of Rage Remake (bennugd): does it start, and do saves survive ALT+ENTER? (R115)

Neither of the two SD cards answered over ssh (host-key mismatch on both). The R99 test
card answered, kernel `5.6.19-m4-kbdled` (r4 in `l5`). From the forum review's compatibility list: the
forum says the bennugd port failed on bookworm with missing libraries, and that with sdl12-compat plus
gl4es "after every play the savegame seems corrupt". That is the question whether fix 21's double `close()`
writes log records into a save.

- **In the DBP repository: yes.** The release thread (2021-01-01) links `https://pyra-handheld.com/repo/apps/2`
  ("Streets of Rage Remake", TrashyMG). Its embedded JSON lists 5.1 (newest, download id 38,
  `https://pyra-handheld.com/repo/packages/SoRR_Trashy/38/download`, MD5 `a583bc081638eac004678f0b06f5ee13`,
  868117 bytes) and 5.0 (id 3). Downloaded on the PC, MD5 matched. It is a 2021 squashfs that holds the
  bennugd engine only. The thread says the game data (`SorR.dat` and friends) is not shipped: "you will need to
  source the data files yourself". Metadata: `Id=SoRR_Trashy`, `Exec=SoRR`,
  `Dependency[deb]=libsdl-mixer1.2;`.
- **Install: pass.** scp'd to `/dragonbox/packages/` (MD5 re-checked on the card). The watched folder
  registered it in about 4 s: `dbp-cmd list` shows `SoRR_Trashy`. It got
  `/usr/share/applications/__dbp__SoRR_Trashy_default.desktop` and `/usr/local/games/SoRR`. Its one declared
  dependency is installed (`libsdl-mixer1.2` 1.2.12-19+b1, an exact name in `/var/lib/dpkg/status`), so
  `dbp-run`'s missing-dependencies dialog has nothing to list.
- **Libraries: one is really missing, `libcrypto.so.1.1`.** Mounted read-only (`dbp-cmd mount SoRR_Trashy`). The
  package is `bin/bgdi` (the bennugd interpreter, armhf PIE), `bin/bgdc`, `bin/moddesc` and 49 bennugd modules
  in `lib/`, launched by `LD_LIBRARY_PATH=.../lib ./bin/bgdi ./SorR.dat`. With that `LD_LIBRARY_PATH`, `ldd`
  across all 52 ELF files gives only one `not found`: `libcrypto.so.1.1`, which every file links (`readelf -d`:
  52 of 52, `bgdi` included). The other external sonames resolve: `libSDL-1.2.so.0` (29 files) loads
  `libsdl1.2pyra` 1.2.15, the vendor's SDL 1.2, not sdl12-compat; `libSDL_mixer-1.2.so.0` (which brings in
  `libfluidsynth.so.3` and SDL2); `libz`, `libpng16`, `libX11`.
  I checked the missing one with apt before trusting `ldd`. `find / -xdev -name 'libcrypto.so*'` finds only
  `libcrypto.so.3`. `apt-cache policy libssl1.1` is empty. `apt-cache search --names-only '^libssl'` lists
  `libssl3t64` as the only runtime. trixie ships no OpenSSL 1.1 and the DBP bundles none. Bookworm also
  ships only OpenSSL 3, so this most likely explains the bookworm report ("missing libraries ... higher
  versions than the one required", 2025-09-29). That part is an inference: the forum post doesn't name the
  libraries.
- **Starts: no (from `ldd`, not run).** `bgdi` needs `libcrypto.so.1.1` directly, so the dynamic linker
  stops it before any engine code runs. Tool permissions block running a freshly fetched binary in this
  session, as in R94, R110 and R113. To see the loader message on the card:
  `dbp-run --log-output --chdir SoRR_Trashy SoRR`, then
  `cat /tmp/dbpout/dbprun-SoRR_Trashy-stderr.log`. Expected: `./bin/bgdi: error while loading shared libraries:
  libcrypto.so.1.1: cannot open shared object file`. Even with the library present, the game also needs data
  files you supply yourself in its appdata folder.
- **Save corruption after ALT+ENTER: not reachable.** The game doesn't start, and there is no game data.
  Neither fix 21's signature (text or log lines inside the save) nor the forum's own explanation (TrashyMG,
  2025-07-09: the config file rewritten on exit corrupts something) could be checked. One forum detail cuts against a
  fix-21-only story: #42 (2025-08-18) says the start-up failure "shows the same problem at the start even
  without" gl4es. Without gl4es the game doesn't render through the SGX WSEGL, so fix 21's double close
  shouldn't apply.
- Unmounted after (`dbp-cmd umount`; a few seconds later `mount | grep -i sorr` was empty). Left on the card:
  `/dragonbox/packages/SoRR_Trashy-5.1.dbp`, registered, plus an empty `/dragonbox/appdata/SoRR_Trashy/`.
  Same as the other dead-end DBPs there.
- To get further: a rebuild of bennugd against trixie's OpenSSL 3, or a DBP that bundles `libcrypto.so.1.1`
  in its own `lib/` (`docs/dbp.md`, "Library names"). Then supply the data files and repeat the save check.
  No prep fix applies.

## 2026-11-25 — charge guard: how the real-charge run ended, and a replug it missed (R117 a)

On the R99 test card, kernel r4 in `l5`, read back the next night (device clock 2026-11-26 00:41 CET).

- REG02 now: `sudo i2cget -f -y 1 0x6b 0x02` → `0x60` (2048 mA). Not left at 512 mA.
- The run didn't last the planned 4 h. It stopped at 19:07:53 (t=3462 s) because the Pyra was powered off
  from the desktop session at 19:07:54 (`systemd-logind: The system will power off now!`, a clean shutdown
  that killed `pyra-charge-guard` with SIGTERM). The next boot started at 19:08:29.
- The full file has 344 samples and **five** reduce/restore cycles, not the three in the first copy: the
  three already recorded, then 18:46:41 reduced (margin 60 mV), 18:50:23 restored (91 mV), 18:51:44 reduced
  (59 mV). The committed TSV is now the complete file (it was a 215-line prefix).
- **The guard missed a replug.** At 19:06:52.05 `bq2429x_usb_detect` logged `r8=00 ... UNPLUG`, then VBUS
  back as `ADAP` 0.42 s later (cause not recorded). After that, REG02 read `0x60`, but the guard stayed
  `REDUCED`: its last 7 samples (19:06:53-19:07:53) log `REDUCED 512 0x60`. The margin went from 78 mV to
  7-13 mV within one sample and `bat_ua` swung, which is consistent with full current going back in. No `HOT` fault in
  the journal before the poweroff. The guard only acts on an unplug when a 10 s sample happens to see the
  charger offline. A 0.4 s drop falls between samples, and the replug puts REG02 back to 0x60 behind it. The
  header's "nothing else ever writes REG02 after probe" was wrong for replugs.
- Fixed in `device/pyra-charge-guard.sh`: every sample while `REDUCED` compares the live REG02 with the
  reduced byte and writes it again if it moved (note `reg02 was 0x60 while reduced, re-applied 512 mA`).
  While `FULL`, a divergence is only logged. Tested on the card, 00:42 CET, charger in, pack full:
  `sudo env PYRA_CHARGE_GUARD_LOW_MV=2000 PYRA_CHARGE_GUARD_HIGH_MV=3000 bash /tmp/pcg.sh /tmp/pcg-test.tsv 60 5`
  reduced at the first sample (forced by the thresholds), then `sudo i2cset -f -y 1 0x6b 0x02 0x60 b` by hand.
  The next sample logged the re-apply and REG02 read `0x00` again. Afterwards the guard was killed and REG02
  set back to `0x60` (read back).

## 2026-11-26 — fix 9's headset pair after startup: idle, playback, suspend, replug (R117 b)

On the R99 test card, kernel r4 in `l5`, PulseAudio up since the 19:08 boot (5.5 h). Read with `amixer -c L15
cget name='Headset Left Playback'` (and Right), `pactl list short sinks`, and the jack control `numid=37`
(`Headset Stereophone Jack`).

- At rest, sink `SUSPENDED`, no headphones: pair `1/1` (`HS DAC`).
- Playback after idle (`paplay`, sink volume at 0 %): `1/1` while `RUNNING`, then `IDLE`. This card's
  `module-suspend-on-idle` has `timeout=300`, so the sink stays `IDLE` for 5 min, not 5 s.
- Suspend/resume: `systemctl suspend` at 00:44:04, woken at 00:44:17 by a key press (the owner touched the nub;
  an RTC alarm had been set for +30 s, so RTC wake is still untested). Pair `1/1` after resume, and again after a
  `paplay`. The resume carried the known `Unbalanced enable for IRQ 144` (SGX, `troubleshooting.md`).
- Replug, logged once a second (owner, headphones): out `0/0` on port `pyra-speaker`, in `1/1` on
  `pyra-headphones`, out `0/0`, in `1/1`. Each switch showed up within a second. The `0/0` on the speaker port
  is by design (`pyra-speaker.conf` selects `Headset ... Playback: Off`). A first attempt at
  00:48-00:49 logged no transitions at all. The sink was still `IDLE` from the 00:44:57 `paplay` (300 s
  timeout), so the headset amplifier was on and unplugs weren't detected: `known-limitations.md` 2.9, not new.
  The repeat at 00:51 came after the sink had suspended.
- Answer: none of the three cases resets the pair. After startup, PulseAudio sets it only through the port
  paths, and those set it correctly. Fix 9's `ExecStartPost` drop-in is enough.

## 2026-11-26 — rumble/vibra: the motor works, fftest's strong rumble is below its start level (R117 c)

On the R99 test card, kernel `5.6.19-m4-kbdled` (r4). Owner holding the Pyra. Overturns the R111 verdict
above.

- Supplies: `vddvibl` and `vddvibr` of `0-004b` are both consumers of the fixed `vsys` regulator (3300 mV in
  `regulator_summary`), not dummies. `dmesg` has no vibra supply warning.
- Registers while `fftest /dev/input/event8` plays effect 4 (strong rumble), read both from
  `/sys/kernel/debug/regmap/0-004b/registers` and raw with `i2cget -f -y 0 0x4b`: VIBCTLL `0x01`, VIBDATL
  `0x00`, VIBCTLR `0x01`, VIBDATR `0x13`. Afterwards VIBCTLL/R go back to `0x00`. The driver does enable the
  channels and write a duty. Owner felt nothing (00:52:55).
- Device tree (`twl@4b/vibra`): left `ti,vibldrv-res` 8, `ti,viblmotor-res` 999999 (no motor), right
  `ti,vibrdrv-res` 3, `ti,vibrmotor-res` 32. With `TWL6040_VIBRA_MOD` 85 and 50 mV per code, the driver's code
  at full magnitude is 3300 × 32 × 85 / (100 × 35) / 50 = 51. Only the right ("strong") channel drives a motor.
- Direct drive of the right channel (`i2cset ... 0x1b <code>`, then `0x1a 0x01`, 2-3 s, then `0x1a 0x00`):
  - `0x33` (51): owner felt a clear rumble.
  - A sweep, 2 s each: `0x13`, `0x19` nothing; `0x20`, `0x28`, `0x33` felt.
  - Start threshold on this unit: between code 25 and 32 (about 1.25-1.6 V peak, about 50-63 % of full
    magnitude). Measured by feel, one unit.
- Answer: the motor, its wiring and the TWL6040 output work. Effects weaker than about 60 % magnitude don't
  start it, and fftest's strong rumble lands at code 19. The R111 "motor doesn't respond" result was a
  drive-level result. Not explained: why that effect gives 19 rather than the 25 that half of 0xFFFF would.
  fftest's magnitude wasn't checked. Not run: the stock card (no longer needed to locate the fault).

## 2026-11-26 — Heart of the Alien Redux (SDL2): does it start, draw, play sound, take input? (R119)

R99 test card, kernel `5.6.19-m4-kbdled` (r4 in `l5`). From the forum review's compatibility list: in 2023
jedi23 reported that M-HT's SDL2 build drew "very small" in fullscreen with the rest of the screen black, on
the Pyra only (https://pyra-handheld.com/boards/posts/1714479/).

- **In the DBP repository: yes, a newer build.** jedi23's 2023 SDL 1.2 package (`repo/apps/230`) is gone:
  the page redirects. M-HT's 2024 release thread links `https://pyra-handheld.com/repo/apps/306`: 1.2.4.4,
  2024-04-29, `https://pyra-handheld.com/repo/packages/hota_redux_m-ht/311/download`, MD5
  `0c8ce326f768d66ea5c2cdea01b7d17c`, 795418 bytes. Downloaded on the PC, MD5 matched. Metadata:
  `Id=hota_redux_m-ht`, `Appdata=hota`, `Exec=hota.sh`,
  `Dependency[deb]=libc6;libx11-6;libsdl2-2.0-0;libsdl2-mixer-2.0-0;`. All four are installed under those
  exact names, so `dbp-run` has no dependencies to list. The game data isn't shipped: you supply the Sega CD
  ISO (and optionally the audio tracks as OGG/MP3) in `dragonbox/appdata/hota/`.
- **Install: pass.** scp'd to `/dragonbox/packages/` (MD5 re-checked on the card). The watched folder
  registered it (`dbp-cmd list` shows `hota_redux_m-ht`). It got
  `/usr/share/applications/__dbp__hota_redux_m-ht_default.desktop` and `/usr/local/games/hota.sh`.
- **Libraries: all resolve.** The package is `alien` (armhf PIE, not stripped) and `lib/libGL.so.1`, a
  bundled gl4es. `alien` needs `libSDL2-2.0.so.0` (trixie's 2.32.4), `libSDL2_mixer-2.0.so.0` (2.8.1) and
  `libc.so.6`; `ldd` gives no `not found` for either ELF file. `hota.sh` puts the bundled `lib/` on
  `LD_LIBRARY_PATH`, then runs `./alien --scale=3 --fullscreen --iso --iso-prefix <name>`.
- **Starts: yes, as far as the data check.** Run by hand from the appdata folder with no ISO, it prints
  `panic: can't read GAME2.BIN file` and exits. That is the point where it reads the ISO (source: `initialize()`
  in `src/main.c`, M-HT/hota `e3e443c`). By then SDL has initialised video and audio and opened the mixer.
  `hota.sh` turns this case into a zenity error naming the folder, then shows the README (`zenity` 4.1.90 is on
  the card; the dialogs themselves weren't opened).
- **Window and sound, with fake data.** The window is created only after the data loads. To get that far, I
  pointed it at a 9.6 MB zero-filled file named as the ISO (`truncate -s 0x925000`, the end of the last file in
  the engine's ISO table). This is a synthetic run, not play:
  - Fullscreen: `xwininfo` showed the window at 912x576, then 1280x720+0+0. `/proc/<pid>/maps` held the bundled
    `libGL.so.1` (gl4es) and the SGX `libEGL`, `libGLESv2` and `libpvrDRI3WSEGL.so`. So it renders on the SGX
    through its own gl4es, with no GLX from the X server needed (fix 4). It died with SIGSEGV after 1.3 s. The
    core's PC is `unlzss+384`, the game's own decompressor, running over the zeros. That's an effect of the
    fake data, not a trixie problem.
  - Windowed (no `--fullscreen`): ran for over 2 minutes at about 70 % CPU, window 912x576. SIGTERM (`pkill`)
    didn't stop it (likely because SDL turns it into a quit event, and the game didn't act on it in this state; not checked); SIGKILL did.
  - Sound: `pactl list short sink-inputs` showed its stream on PulseAudio, `s16le 2ch 44100Hz`. Nothing was
    audible to check, because there was no data.
- **Fullscreen size: should be fixed in this build (from the source; not seen on screen).** With `-DPYRA`
  (`Makefile-Pyra`), `render.c` skips `SDL_RenderSetLogicalSize` and copies the 912x576 texture to the whole
  window (`SDL_RenderCopy(..., NULL, NULL)`). The commit that added this, "add support for DragonBox Pyra", is
  dated 2024-04-29, the same day as the DBP and ten months after the 2023 report. On the 16:9 screen the picture
  is stretched from 1.58:1 rather than letterboxed. That's inferred from the code.
- **Not tested: what it draws, what sound it plays, and input.** All three need the game's ISO, which is
  proprietary and not on the card or the PC. The package stays registered on the card. To finish the check, put
  the ISO in `/dragonbox/appdata/hota/` and start "Heart of The Alien Redux" from Games. Check that the picture
  fills the screen, that the music plays, and that the d-pad, X (shoot), B (whip) and A (jump) work.
- Left on the card: `/dragonbox/packages/hota_redux_m-ht-1.2.4.4.dbp`, registered, plus
  `/dragonbox/appdata/hota/` (only AuFS's whiteout directory in it). Fake ISO and core deleted. No prep fix
  applies.

## 2026-11-26 — Pyrafox: does it start, draw and load a page, and which GL path does it take? (R120)

R99 test card, kernel `5.6.19-m4-kbdled` (r4 in `l5`, installed `vmlinuz` `646e033b…a459fdd`), `ondemand`, 1.5 GHz
ceiling, no swap. From the forum review's compatibility list: jedi23's Firefox build for the Pyra, built with PGO and ThinLTO
(https://pyra-handheld.com/boards/posts/1726809/). The questions were whether it starts without GLX (fix 4), which GL
path WebRender takes, and whether fix 21 matters.

- **In the DBP repository:** `https://pyra-handheld.com/repo/apps/372` lists four builds. The newest is 160.0.1-pyra,
  uploaded 2026-11-23, `https://pyra-handheld.com/repo/packages/Pyrafox/415/download`, MD5
  `2660872c417f57dd6dd57b1f0bc7c50a`, 116723397 bytes. Downloaded on the PC, MD5 matched there and again on the card. Metadata:
  `Id=Pyrafox`, `Exec=pyrafox.sh`, `Categories=Network;WebBrowser;`, empty `Dependency[deb]`.
- **Install: pass.** Copied to `/dragonbox/packages/`, and the watched folder registered it (`dbp-cmd list`).
  It got `/usr/share/applications/__dbp__Pyrafox_default.desktop` and `/usr/local/games/pyrafox.sh`.
- **Libraries: all resolve.** A Firefox 160.0.1 tree (`application.ini`: `CodeName=Nightly`, BuildID
  20261123133322) with its own NSS, NSPR and SQLite. Plain `ldd libxul.so` reports trixie's `libnss3.so` lacking
  `NSS_3.113`/`3.126`/`3.131`, but the launcher puts its own directory first. With `LD_LIBRARY_PATH` set to the
  package directory, nothing is `not found`, and the bundled `libnss3.so` is the one picked. `libxul.so` contains the names `libEGL.so.1`,
  `libGLESv2.so.2`, `libGL.so.1`, `libgbm.so.1`, `libva.so.2` and `libdrm.so.2` (for dlopen; `strings`).
- **GL probe:** `gfxtest glx -f 1` (Firefox's probe binary) printed `libpci missing`, `libEGL missing methods`,
  `GLX extension missing`. Under `LD_DEBUG=libs` it opened no EGL or GL library at all.
- **Starts, draws and loads a page: pass.** `./firefox --no-remote --profile ./profile https://en.wikipedia.org/wiki/OMAP`
  over the USB ethernet link. The window was `"OMAP - Wikipedia — Nightly"`, 1280x651+0+36. `xwd -id` of it showed the
  article header, Wikipedia's donation banner, and the toolbar and tabs, all drawn correctly. (`xwd -root` failed with
  `BadDrawable`, apparently a window that disappeared during the grab.) The menu path also works: `/usr/local/games/pyrafox.sh` gave a "Nightly" window,
  the profile went to `/dragonbox/appdata/Pyrafox/profile`, and the union unmounted when it exited. No crashes in seven starts.
- **GL path: software WebRender, with no SGX libraries mapped.** `/proc/<pid>/maps` of the parent held glvnd's
  `libGL.so.1.7.0`, `libGLX`, `libGLdispatch` and `libepoxy`. No `libEGL`, no `/opt/omap5-sgx-ddk-um-linux`
  library and no `libpvrDRI3WSEGL.so` were mapped, and the content, socket and forkserver children mapped no GL library at all. `nsIGfxInfo`
  over Marionette gave the compositor as `WebRender (Software)`, and `webrender`, `wrCompositor` and
  `WEBRENDER_PARTIAL` as `blocklisted:FEATURE_FAILURE_GLXTEST_FAILED`. `HW_COMPOSITING` was
  `blocked` ("Acceleration blocked by platform"), `openglCompositing` was `FEATURE_FAILURE_OPENGL_NEED_HWCOMP`, and
  `windowProtocol` was `x11`. The SGX's `libEGL.so.1` (DDK 1.14) exports only the 34 EGL 1.4 core functions; extensions would come through `eglGetProcAddress`, and they were not queried.
  **Fix 21 doesn't apply:** the SGX window system is never loaded.
- **Frame rate: 60 Hz.** `requestAnimationFrame` on the page: 181 frames in 3002 ms, twice. `about:support`'s
  `Display0: 1280x720@3Hz` is a wrong label (`xrandr`: 720x1280 rotated, 60.00 Hz). Pages see `screen` 1045x588 at
  `devicePixelRatio` 1.22.
- **Numbers (one run each, R98's method, shell polling):**
  - Warm (same profile, started with the page URL): window 3065 ms, PSS 473 MiB, RSS 1047 MiB over 11 processes at 90 s,
    and the tree used 56% of one core between 60 and 90 s.
  - Cold (caches dropped, empty profile): window 15204 ms. At 90 s, PSS 619 MiB and RSS 1302 MiB over 12 processes.
    It used 141% of one core between 60 and 90 s; that run also opens the privacy-notice tab and syncs its settings.
  - An earlier first start, measured at about 100 s: PSS 691 MiB, and 28% of one core over 30 s.
  - Firefox ESR in R98, measured on the r5 card with the same CPU settings: 15.0 s cold and 4.6–5.1 s warm, 437–447 MiB PSS warm, 71% of one core
    between 60 and 90 s.
- **Marionette on Firefox 160:** chrome-scope scripts need `MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1` in the environment
  (`RemoteAgent.sys.mjs`). With only the `-remote-allow-system-access` flag, `ExecuteScript` failed ("does not support
  browsing contexts in privileged scope"), and so did navigating to `about:support`.
- Left on the card: `/dragonbox/packages/Pyrafox-160.0.1-pyra.dbp`, registered, plus
  `/dragonbox/appdata/Pyrafox/` from the menu start. The test profiles were deleted. No prep fix applies. `docs/browsers.md`
  "Pyrafox" has the user-facing result.

## 2026-11-26 — OpenTyrian and Hostile Takeover (SDL 1.2): start, fullscreen, scaling, one D-pad press (R121)

R99 test card, kernel `5.6.19-m4-kbdled` (r4 in `l5`, `vmlinuz` `646e033b…`), funkeymonkey-pyrainput 0.1.19+pyra1,
`libsdl1.2pyra` 1.2.15+dfsg2-9, sdl12-compat (`libsdl1.2debian`) not installed. From the forum review's compatibility
list: SDL 1.2 fullscreen position and scaling, and the D-pad double events
(https://pyra-handheld.com/boards/posts/1691314/, https://pyra-handheld.com/boards/posts/1691414/). Both games are
freeware and ship their data.

- **In the DBP repository: both are there.** OpenTyrian, `repo/apps/218`: one build, 1.0 by TrashyMG (2023-03-25),
  `/repo/packages/OpenTyrian_C4ALL/223/download`, MD5 `102c21c98623120e4434a22d9c46dc10`. Hostile Takeover,
  `repo/apps/4`: newest of three builds is 1.6.0.03 by ptitSeb (2021-07-19, "Using fixed SDL1 for correct fullscreen"),
  `/repo/packages/ptitSeb_ht/69/download`, MD5 `5c07f1251591192000c20d6cc5adad3e`. Both MD5s matched. Copied to
  `/dragonbox/packages/`; both registered. HT declares `Dependency[deb]=libsdl1.2pyra;` (installed, so no dialog);
  OpenTyrian declares none.
- **Libraries.** OpenTyrian's `ot` needs `libSDL-1.2.so.0` and `libSDL_net-1.2.so.0` (trixie's `libsdl-net1.2`
  1.2.8, installed). It bundles sdl12-compat 1.2.61 in `sdl12comp/` (built against SDL2 at run time). Its launcher
  `opentyrian` is `sudo pyrainputctl disable gamepad`, then
  `LD_LIBRARY_PATH=<union>/sdl12comp/ gl4es ./ot`, then `sudo pyrainputctl enable gamepad`. HT's `ht` needs only
  `libSDL-1.2.so.0` plus libstdc++, and its launcher sets `HOME` to the union dir. Nothing `not found` in either.
- **OpenTyrian: starts, pass.** Maps: the bundled `libSDL-1.2.so.1.2.61`, SDL2 2.32.4, gl4es `libGL.so.1`
  (`libgl-gl4es-pyra`), the SGX `libEGL`/`libGLESv2`/`libsrv_um` and `libpvrDRI3WSEGL.so`. So sdl12-compat draws
  through SDL2's GL renderer on the SGX. First start: a 640x400 window (`"OpenTyrian"`, decorated, at 1,36), because
  its default is windowed. It keeps its settings in `~/.opentyrian/opentyrian.conf` (JSON; source `config.c`), not
  in appdata. With `{"video": {"fullscreen": true, "scaler": "Scale2x"}}`: window 1280x720+0+0. `xwd -id` of it
  (it works on this window) showed the menu, aspect kept: the 640x400 picture stretched to 1152x720 (x 1.8) at
  x = 64, black bars of 64 px left and right, none top or bottom.
- **OpenTyrian on `libsdl1.2pyra` instead** (`./ot` from the union dir without the launcher's `LD_LIBRARY_PATH`):
  starts too, maps only the system `libSDL-1.2.so.0.11.4`, no GL. Fullscreen window 1280x720+0+0, but the 640x400
  picture is not scaled: centred at 320,160 with a black border all round (`xwd -root`).
- **Hostile Takeover: starts, pass.** Maps the system `libSDL-1.2.so.0.11.4` (`libsdl1.2pyra`), no GL, no SGX.
  SDL 1.2's fullscreen pair: an override-redirect window 1280x720+0+0 with its 1280x720 child; neither has a name.
  The menu is drawn at the native 1280x720, 1:1, nothing scaled or offset (`xwd -root`). PulseAudio sink-input
  `ht`, `u8 1ch 8000Hz`, uncorked. 9 % of a core at the menu (`top`, one sample).
- **Hostile Takeover on sdl12-compat: crashes.** With OpenTyrian's bundled 1.2.61, and with Debian's 1.2.68
  (`apt-get download libsdl1.2debian`, unpacked to `/tmp`, never installed), `ht` segfaults within a second. Under
  `LD_DEBUG=bindings` the last symbols it bound were `SDL_LockSurface`, `SDL_UnlockSurface`, `SDL_UpdateRect`,
  `SDL_SetColors`, so it dies on its first palette draw. sdl12-compat 1.2.68 logged only its version banner. Not
  investigated further: HT needs `libsdl1.2pyra`, which the card has.
- **One D-pad press (the owner pressed, at the Pyra).** Logged with an `LD_PRELOAD` shim on `SDL_PollEvent` /
  `SDL_PeepEvents` / `SDL_JoystickOpen` / `SDL_JoystickGetHat` (built on the card with its gcc), plus `evtest` on
  `pyraInput keyboard` and `pyraInput Gamepad`.
  - HT, export on (the default): down once and right once each gave one `KEYDOWN`/`KEYUP` in SDL (sym 274, 275).
    HT never opens a joystick (it imports no `SDL_Joystick*`). The kernel side had both `KEY_DOWN` on the keyboard
    and `ABS_HAT0Y` on the gamepad, as always. **Arrives once.**
  - OpenTyrian through its launcher (gamepad export off while it runs): one `KEYDOWN`/`KEYUP`; nothing on the
    gamepad device; the menu highlight moved one item (owner). **Arrives once.**
  - OpenTyrian with gamepad export on (`./ot` started directly, the forum's case): SDL saw the hat go to
    `SDL_HAT_DOWN` and two `KEYDOWN`/`KEYUP` pairs within 100 ms; the highlight moved two items (owner). The second
    press is OpenTyrian's own: `push_joysticks_as_keyboard()` (`src/joystick.c`) turns a polled hat into
    `SDL_PushEvent` key presses in menus, and pyrainput exports the D-pad on both devices. The launcher's
    `pyrainputctl disable gamepad` is the fix, and needs the vendor's passwordless `pyrainputctl` sudo rule.
    It joystick-opens `pyraInput Gamepad` even when export is off; the device stays, it just sends nothing.
- **Exit.** SIGTERM to `ot` segfaulted it on the way out (its config was not saved); the launcher still ran
  `pyrainputctl enable gamepad`. SIGTERM ended `ht` normally.
- Left on the card: both `.dbp`s in `/dragonbox/packages/`, registered, and their `/dragonbox/appdata/` folders.
  Removed: `~/.opentyrian`, the shim, the unpacked sdl12-compat. `gamepad.export = 1` checked afterwards.

## 2026-11-26 — Fasttracker 2 clone and Farox's demos: start, fullscreen, GL path, sound (R122)

R99 test card, kernel `5.6.19-m4-kbdled` (r4 in `l5`, `vmlinuz` `646e033b…`), `libgl-gl4es-pyra` 1.1.7.1,
`libsdl1.2pyra` 1.2.15+dfsg2-9, SDL2 2.32.4, PulseAudio 17.0, AESS sink at 100 %. From the forum review's
compatibility list: gl4es fullscreen, and audio noise or a crash (https://pyra-handheld.com/boards/posts/1704299/,
https://pyra-handheld.com/boards/posts/1715481/). The owner sat at the Pyra, speakers only, wheel near the bottom,
and listened to each one.

- **In the DBP repository: all four.** ft2-clone `repo/apps/393`: 2.26 by jedi23 (2026-10-16),
  `/repo/packages/ft2-clone/400/download`, MD5 `8ad801d904d5a57c9c61d33b80682fbf`. Fiat Homo `repo/apps/236`,
  Ante Dominum `repo/apps/237`, Fit for Autopsy `repo/apps/246`: 1.0.0.2 by Farox (2023-12-04), ids 270, 268, 269,
  MD5 `3f20b1460232b31f71a2c1e9d833687c`, `b7939b722e36a4a92b8dfbaf6e3bb5b5`, `59972895db395659246480d051fc020d`.
  All four MD5s matched. Copied to `/dragonbox/packages/`, all registered.
- **Libraries.** ft2-clone needs `libSDL2-2.0.so.0`, `libGLESv2.so.1` (RUNPATH the SGX lib dir), `libasound.so.2`.
  It bundles a `libpvrDRI3WSEGL.so` (RUNPATH from someone's SGX rebuild tree). Its `run-ft2.sh` puts that first on
  `LD_LIBRARY_PATH` and sets `SDL_VIDEO_X11_FORCE_EGL=1` plus the SGX `libEGL`/`libGLESv2` as SDL's drivers. Fiat
  Homo and Ante Dominum need `libGL.so.1`, `libGLU.so.1`, `libSDL-1.2.so.0` and their bundled `libfmod.so.13` /
  `libfmod.so.10` (found through the launcher's `LD_LIBRARY_PATH=./`; plain `ldd` says `not found`). Their
  launchers run `gl4es ./<binary>`. Fit for Autopsy's menu and demos need `libSDL-1.2.so.0` and `libGL.so.1`, and
  the launcher runs `gl4es ./autopsy`. Nothing else missing.
- **Hand mounts failed at first** with `Error: Unable to set up AuFS union`; dmesg had
  `aufs opt_add: lookup failed /dragonbox/appdata/fiathomo (-2)`. The demos' `Appdata=` (`fiathomo`,
  `antedominum`, `autopsy`) differs from their ids. Making those folders fixed it (`dbp.md`, "Check a DBP's libraries").
- **ft2-clone: starts, pass.** Prints `GL_RENDERER: PowerVR SGX 544MP`, `GL_VERSION: OpenGL ES 2.0 build
  1.14@3699939`, `DRI3 1.0`, `present 1.2`. Maps the bundled WSEGL, the SGX `libEGL`/`libGLESv2`/`libsrv_um`, SDL2;
  no gl4es. Opens `/dev/dri/card0` and `renderD130`. First start: a decorated 632x400 window; `xwd -id` showed the
  main screen drawn correctly. Alt+Enter (its own help text names it) and F11 changed nothing, with the window
  focused and keys reaching it (Escape opened its quit box; keys and clicks sent with `experiments/dbp-compat/xsend.c`,
  built on the card). Config → Miscellaneous → Fullscreen: "This setting is not applied until you close and reopen the
  program". Saved to `~/.config/FT2 clone/FT2.CFG`. After a restart: window 1280x720+0+0 with
  `_NET_WM_STATE_FULLSCREEN`, and `xwd -root` showed the 632x400 picture stretched over the whole screen ("Stretched"
  off). Sink-input `ft2-clone`, `s16le 2ch 48000Hz`, uncorked from start. Its config page: default device, 48 kHz,
  16-bit, 8-point sinc. Started with Fiat Homo's `music.xm` as argument, Right Ctrl played it. Owner: **clean
  music**. 46 % of a core while playing (`top`, one sample).
- **Fiat Homo: starts, pass.** Maps gl4es `libGL.so.1`, the SGX `libEGL`/`libGLESv2`, `/usr/lib/libpvrDRI3WSEGL.so`,
  `libsdl1.2pyra`'s `libSDL-1.2.so.0.11.4`, the bundled `libfmod.so.13`. gl4es logged v1.1.7, GLES 2.0 backend.
  X reports a 1280x720 client at 1,36 inside a 1282x757 marco frame, `_NET_WM_STATE` only FOCUSED, and `xwd -id` of
  the frame shows a title bar. But `xwd -root` shows the demo over all 1280x720, title bar area included, and the
  owner saw it fill the screen with no title bar. Sink-input `FMOD Audio`, `s16le 2ch 48000Hz`. Owner: **clean
  music**. Escape quit it.
- **Ante Dominum: starts, pass.** Same libraries with `libfmod.so.10`, same window report, same `FMOD Audio`
  `s16le 2ch 48000Hz` stream. Owner: **clean music, fills the screen**. Escape quit it.
- **Fit for Autopsy: starts, pass.** Menu: a 300x480 window at 35,92 (decorated), the picture exactly inside the
  client area (pixel edges 35..334, 92..571), no audio stream. A click on a logo runs that demo
  (`sh -c "cd boy;./boy"`). Boy (2008): window reported 1280x720 at 1,36 as above; on screen a 4:3 picture with
  black bars left and right, full height. Sink-input `boy`, `s16le 2ch 44100Hz`, through SDL 1.2's PulseAudio
  backend. Owner: **clean music**. Escape returned to the menu. Division by Zero (1993): fills the screen,
  sink-input `dbzero`, `s16le 1ch 44100Hz`. Owner: **clean, and no noise burst all session**. The other eight
  demos were not run. The menu ignores Escape. SIGTERM ended it, and its union and image (twice) stayed
  mounted until unmounted by hand (`dbp.md`, "When a program is killed or crashes").
- **Kernel log:** nothing from the audio drivers (no `abe`, `aess`, `mcpdm`, xrun lines) between 02:45 and the end of
  the run (`dmesg -T`).
- Left on the card: the four `.dbp`s in `/dragonbox/packages/`, registered, and their appdata folders
  (`ft2-clone`, `fiathomo`, `antedominum`, `autopsy`). Removed: `~/.config/FT2 clone`, the XTest program and the
  copied modules in `/tmp`.

## 2026-11-26 — ptitSeb's P* emulators (PSNes, PNes, PGen, PFBneo): libraries, start, window, GL path (R123)

R99 test card, kernel `5.6.19-m4-kbdled` (r4 in `l5`), `dbp` 0.6.12.2-2, `libgl-gl4es-pyra` 1.1.7.1, SDL2
2.32.4, `dri3wsegl-pyra`. From the forum review's compatibility list: build 03 broke on bullseye and bookworm over
library names (https://pyra-handheld.com/boards/posts/1714566/, https://pyra-handheld.com/boards/posts/1724389/).
Nobody was at the Pyra. The sink was lowered from 101 % to 30 % for the run and set back afterwards.

- **In the DBP repository: all four, build 03.** 6.06.0.03 by ptitSeb, 2023-09-04. PSNes `repo/apps/199`,
  `/repo/packages/psnes/244/download`, MD5 `141bde0fb35fdbfb62b43727608603ee`. PNes `apps/198`, id 245, MD5
  `b1295b37f188757f0750e141ee6ef30c`. PGen `apps/197`, id 246, MD5 `44a21eb2751c385933387dde8fb55243`. PFBneo
  `apps/195`, id 247, MD5 `82faf80792aba123f5f4b3ad9fde2b80`. All four MD5s matched. Older builds 01/02 are still
  listed. Copied to `/dragonbox/packages/`, all registered. No `Appdata=` key, so appdata is the id.
- **Declared:** `Dependency[deb]=libsdl2-2.0-0;libtinyxml2-6a;libminizip1;libfuse2;libcurl4;` (all four).
  `dbp-run` reported `libtinyxml2-6a, libminizip1, libfuse2, libcurl4` missing. `libminizip1t64` and
  `libcurl4t64` are installed (t64 renames). `libfuse2t64` 2.9.9-9 is in trixie, not installed.
  `libtinyxml2-6a` doesn't exist in trixie (`libtinyxml2-11` 11.0.0 does, not installed).
- **Libraries (`readelf -d`, `ldd` with the launcher's `LD_LIBRARY_PATH=<union>/lib`):** all four NEED
  `libSDL2-2.0.so.0 libGLEW.so.2.1 libGL.so.1 libcrypto.so.1.1 libfuse.so.2 libcurl.so.4 libtinyxml2.so.6
  libminizip.so.1` plus libz/freetype/png16/lzma/stdc++. PNes also needs `libarchive.so.13`. Each DBP's `lib/`
  holds `libGLEW.so.2.1`, `libcrypto.so.1.1` and `libssl.so.1.1`, which resolve. **Not found: `libfuse.so.2`
  and `libtinyxml2.so.6`**, in all four. `libcurl.so.4` pulls in the system's `libcrypto.so.3` alongside the
  bundled 1.1 (both mapped at run time).
- **As shipped: no start.** PSNes through `dbp-run --log-output`: `bin/psnes: error while loading shared
  libraries: libfuse.so.2: cannot open shared object file`. `dbp-run` exited and unmounted. The launcher's
  `pyrainputctl overload` / `no-overload` both ran. The other three need the same two missing libraries, so they
  weren't run as shipped.
- **Probe with buster's libraries: all four start to their menu, pass.** `libtinyxml2-6a_7.0.0+dfsg-1_armhf.deb`
  and `libfuse2_2.9.9-1+deb10u1_armhf.deb` from archive.debian.org. The SHA-256s matched buster's `Packages`
  (`e6e812f6…`, `c0a8c4ab…`). Their `.so` files went in a scratch folder on `LD_LIBRARY_PATH` for `dbp-run`, with
  nothing installed and the DBPs untouched. Each emulator mounted its FUSE romfs at `/tmp/c2d_romfs`, wrote a new
  `config.cfg`, saw `pyraInput Gamepad` as a GameController, and logged `GL1Renderer`, `GL renderer : GL4ES
  wrapper`, `GL version : 2.1 gl4es wrapper 1.1.7`, `SDLRenderer(SDL2): 1280x720`. Window `CROSS2D_SDL2_GL`
  1280x720+0+0, `_NET_WM_STATE_FULLSCREEN, _NET_WM_STATE_FOCUSED`. `/proc/<pid>/maps`: gl4es `libGL.so.1`,
  SGX `libEGL`/`libGLESv2` 1.14.3699939, `/usr/lib/libpvrDRI3WSEGL.so`, system SDL2. `xwd -root`: each one's game
  list with its own skin over the whole screen. In the menu, `top` (one sample each) showed 18 % of a core. RSS: PSNes 54 MB,
  PNes 50 MB, PGen 55 MB, PFBneo 108 MB. No sink-input of their own. No ROM was loaded.
- **Keys (XTest, `experiments/dbp-compat/xsend.c` built on the card):** Down moved the list. Left Alt (the
  config's `KEY_START`) did nothing in the menu. Return opened the per-ROM options. Escape opened Main Options.
  Up wrapped to `QUIT GO`, and End (`KEY_A` 77) quit. After each quit: no process, union, image or romfs left
  mounted. Physical buttons were not tried.
- **`libfuse2t64` instead of buster's libfuse: fail.** Same probe with trixie's `libfuse.so.2` (from
  `libfuse2t64_2.9.9-9`) and buster's tinyxml2. PSNes opened its 1280x720 window and mounted the romfs, but every
  skin texture failed: `stbi_load failed (/tmp/c2d_romfs/skins/default/buttons/11.png): unknown image type`. The
  screen was white and black, nothing else. Keys did nothing. The main thread was `R` at 91 % CPU while the
  `SDL2Thread` waited in `fuse_dev_do_read`, and SIGTERM had no effect. After SIGKILL, `dbp-run` exited and
  unmounted the union, but `/tmp/c2d_romfs` stayed as a dead mount ("Transport endpoint is not connected").
  Reading: the 32-bit-`time_t` binary and the 64-bit-`time_t` library disagree on `struct stat` (estimated cause,
  not traced further).
- **Dead romfs recovers.** PGen, started next with buster's libraries, replaced the dead mount, drew its skin
  and quit cleanly. Nothing was left mounted afterwards.
- Left on the card: the four `.dbp`s in `/dragonbox/packages/`, registered, with their appdata folders
  (`config.cfg`, `configs/`, `roms/`, `saves/`, `pyrainput.cfg`), plus `/tmp/p-shim` (buster's two libraries) and
  `/tmp/xsend`. Removed: the `libfuse2t64` probe folder and screenshots.

## 2026-11-26 — P* emulators start on trixie from appdata files alone (R124)

R99 test card, kernel `5.6.19-m4-kbdled` (r4 in `l5`), same packages as R123. Nobody was at the Pyra. The sink
was lowered from 101 % to 30 % for the run and set back afterwards. No ROM was loaded.

- **Launcher path.** `/etc/dbp/run_script` adds `$DBP_IMAGE_DIR/lib` (the read-only image), not the union. Each
  P* launcher (`psnes.sh` etc.) runs `export LD_LIBRARY_PATH=$pwd/lib:$LD_LIBRARY_PATH` with `$pwd` the union, then
  `LIBGL_VSYNC=1 gl4es bin/<name>`. A running emulator's environment had
  `LD_LIBRARY_PATH=/mnt/dbp/union/<id>/lib:/mnt/dbp/images/<id>/lib::/usr/lib/arm-linux-gnueabihf/gl4es/`.
- **AuFS merges `appdata/<id>/lib/`: pass.** Buster's `libtinyxml2.so.6` (SHA-256 `8c41daed…`) and `libfuse.so.2`
  (`eb638c36…`) copied into `/dragonbox/appdata/<id>/lib/` for all four. After `dbp-cmd mount <id>`,
  `/mnt/dbp/union/<id>/lib` listed them next to the image's `libGLEW.so.2.1`, `libcrypto.so.1.1`, `libssl.so.1.1`,
  and `ldd` (with `<union>/lib` on the path) resolved both from there. `dbp-cmd umount` took a few seconds to
  release the mounts.
- **From the MATE menu: all four start, pass.** Applications → Emulators → PSNes / PNes / PGen / PFBneo, clicked with
  `xsend` (the panel's own environment, nothing added). `dbp-run`'s "One or more dependencies ... missing" dialog
  appeared each time (`libtinyxml2-6a`, `libminizip1`, `libfuse2`, `libcurl4`). "Launch anyway" was clicked, and
  15 s later each emulator was running with `/mnt/dbp/union/<id>/lib/libfuse.so.2` and `libtinyxml2.so.6` in
  `/proc/<pid>/maps`, gl4es `libGL.so.1` and `libpvrDRI3WSEGL.so` mapped, `/tmp/c2d_romfs` mounted
  (`fuse.c2d_romfs`), and a `CROSS2D_SDL2_GL` window at 1280x720+0+0, `_NET_WM_STATE_FULLSCREEN, _NET_WM_STATE_FOCUSED`.
  `xwd -root`: each one's skinned game list. `top` (two samples 2 s apart, second one): PSNes 23 % CPU / 53 MB RSS,
  PNes 23 % / 49 MB, PGen 22 % / 53 MB, PFBneo 22 % / 106 MB.
- **Quit: pass.** Escape → Up → End (QUIT → GO in Main Options) ended each one; no emulator, `dbp-run`, union,
  image or romfs left. Up in the game list wraps to the last game, not to QUIT, so the first attempt on PSNes only
  moved the list.
- **`device/pyra-ptitseb-libs.sh`: pass.** `--undo` removed the eight hand-copied files and `--check` reported
  them missing. A plain run fetched both debs from `https://archive.debian.org`, checked them against buster's
  `Packages` SHA-256s, extracted and checked the two libraries, and copied them into all four appdata folders.
  `--check` then said `ok` for each. `--debs DIR` with one byte appended to the libfuse deb stopped with
  `SHA-256 doesn't match buster's Packages; not using it` (exit 1). `--debs` with intact debs worked. Run under sudo
  it refused. PSNes then started from the menu again on the script's files, same result as above.
- **Signature chain checked on the card.** Buster's `InRelease` from archive.debian.org: `gpgv --keyring
  /usr/share/keyrings/debian-archive-removed-keys.gpg` → `Good signature from "Debian Stable Release Key (10/buster)"`
  (key `6D33866EDD8FFA41C0143AEDDCC9EFBF77E11517`). `debian-archive-keyring.gpg` alone: no public key. Its SHA256
  for `main/binary-armhf/Packages.xz`, `b6dd3b4e…cc110c`, matched the download. In that `Packages`:
  `libtinyxml2-6a` 7.0.0+dfsg-1 `e6e812f6…106e8e`, `libfuse2` 2.9.9-1+deb10u1 `c0a8c4ab…b303d`, matching the debs.
- Left on the card: the four `.dbp`s, registered, with the two libraries in each `appdata/<id>/lib/`; `/tmp/p-shim`,
  `/tmp/xsend`, `/tmp/menurun.sh`, `/tmp/pyra-ptitseb-libs.sh`. Also still mounted from before this session:
  `casio_sw-10_m-ht`'s image and union with no process using them (not touched).

## 2026-11-26 — DevilutionX: libraries, start from the menu, GL path, shareware play (R126)

R99 test card, kernel `5.6.19-m4-kbdled` (r4 in `l5`). Nobody was at the Pyra; input went in through `xsend`
(`experiments/dbp-compat/`). The sink was lowered from 101 % to 30 % for the run and set back afterwards.

- **Package.** Repository `apps/250`, current version 1.5.2 (2024-02-08), from
  `repo/packages/DevilutionX/289/download`: squashfs, 12 333 214 bytes, MD5 `e4e2c6ef0771d130a5bd50a939f9578b`, both
  as listed. Copied to `/dragonbox/packages/`, it registered within 4 s: menu entry
  `__dbp__DevilutionX_default.desktop`, launcher `/usr/local/games/devilutionx.sh`. No `Appdata=` key. The
  `Dependency[deb]=` line is commented out.
- **Libraries: pass.** `devilutionx.sh` is `gl4es ./devilutionx`, and there is no `lib/` in the image. The binary's
  `NEEDED` entries are libm, libpthread, libc, libz, libbz2, `libSDL2_image-2.0.so.0`, `libsodium.so.23` and
  `libSDL2-2.0.so.0`. `ldd` inside `dbp-cmd mount DevilutionX` resolved everything from trixie (SDL2 2.32.4, SDL2_image
  2.8.8, libsodium23 1.0.18).
- **From the MATE menu, no data: pass.** Applications → Games → Adventure and RPG → DevilutionX. No dependency dialog.
  The process ran with
  `LD_LIBRARY_PATH=/mnt/dbp/images/DevilutionX/lib::/usr/lib/arm-linux-gnueabihf/gl4es/`, and `/proc/<pid>/maps` held
  gl4es `libGL.so.1`, the SGX `libEGL`/`libGLESv2` 1.14.3699939 and `libpvrDRI3WSEGL.so`. The window was `DevilutionX`,
  1280x720+0+0, `_NET_WM_STATE_FULLSCREEN, _NET_WM_STATE_FOCUSED`. `xwd -root` showed the "Data File Error ...
  (diabdat.mpq or spawn.mpq)" box drawn. Return exited it.
- **With shareware data: pass.** `spawn.mpq` (25 448 219 bytes, MD5 `9d9a48413a8e38c0e0ee41d08c9451dd`, from
  `github.com/diasurgical/devilutionx-assets` release v2) went in `/dragonbox/appdata/DevilutionX/`, and the game
  was started from the menu again. At 12 s the Blizzard intro video was on screen, with a PulseAudio sink input
  `s16le 2ch 22050Hz` open. Escape and Return led into a Normal game in Tristram. A click on the ground walked the
  hero, and the view scrolled. `top` in town, three samples 3 s apart: 64 %, 69 %, 67 % CPU, 41.7 MB RSS. In the game
  menu, Escape → Quit Game exited it, and the union was unmounted. The save (`spawn_0.sv`) and `diablo.ini` were
  written to `~/.local/share/diasurgical/devilution/`, not to appdata.
- **Black screen at start (forum): not reproduced.** The pyrainput mouse was left on (default). Five starts through
  `/usr/local/games/devilutionx.sh` (`setsid`, stopped by PID with SIGTERM, each one exited within 10 s), plus
  the two menu starts: each showed the intro. A run with screenshots at 10 s and 20 s showed the Blizzard logo, then
  the Diablo title.
- Not tested: the nubs (how fast the right nub moves the cursor, and the deadzone) and the pyraInput gamepad,
  because both need hands on the device; and Hellfire, which needs the owner's files.
- Left on the card: `devilx-1.5.2.dbp`, registered; `spawn.mpq` in its appdata; the shareware save in
  `~/.local/share/diasurgical/`; `/tmp/dvx-rep.sh`.

## 2026-11-26 — CorsixTH: as shipped, started from appdata files, fullscreen with sound (R127)

R99 test card, kernel `5.6.19-m4-kbdled` (r4 in `l5`), sound through AESS. Nobody was at the Pyra. Input went in
through `xsend` (`experiments/dbp-compat/`). The sink was lowered from 101 % to 30 % for the run and set back
afterwards.

- **Package.** Repository `apps/325`, `CorsixTH_maquis196` 0.68.0-r1 (2025-03-04), from
  `repo/packages/CorsixTH_maquis196/331/download`: squashfs, 887 721 bytes, MD5 `ee8dd0928bdf2e8014be5b15a3ed6d63`,
  both as listed. It registered within 5 s: menu entry `__dbp__CorsixTH_maquis196_default.desktop` (Games →
  Simulation and Strategy), `Appdata=CorsixTH`. The image has 6 inodes: `corsix-th`, `CorsixTH.launch`,
  `defaults/config.txt`, `defaults/hotkeys.txt`.
- **Libraries: fail.** `NEEDED` includes `liblua5.3.so.0`, `libavformat.so.59`, `libavcodec.so.59`, `libavutil.so.57`,
  `libswscale.so.6`, `libswresample.so.4` and `libcurl-nss.so.4`. All seven are `not found` inside
  `dbp-cmd mount`. The image has no `lib/`.
- **Lua scripts: missing.** The binary's only search path besides `--interpreter=` is
  `/home/<builder>/workspace/dragonbox-corsixth/CorsixTH/CorsixTH/CorsixTH.lua` (from `strings`). Upstream 0.68.0
  `main.cpp` searches local directories only with `SEARCH_LOCAL_DATADIRS`, which is off by default on Linux.
- **From the menu, no data: nothing on screen.** The launcher reached its `HOSPITAL.EXE` check, and its zenity
  error aborted (`Fatal glibc error: malloc.c:4434 (_int_malloc): assertion failed`). zenity by hand: 6 of 6 aborted
  with heap errors (3 with the session's `HOME`, 3 with a fresh one), and so did 3 of 3 with `GSK_RENDERER=ngl`.
  3 of 3 with `GSK_RENDERER=cairo` drew and timed out (rc 5).
- **From the menu, with the demo data: nothing on screen.** The stderr log said
  `./corsix-th: error while loading shared libraries: liblua5.3.so.0`.
- **With appdata files (`dbp.md` "CorsixTH"): starts.** `package.user_prerun`, 19 libraries in `lib/`, lpeg and lfs
  in `lua/5.3/`, the v0.68.0 Lua tree and the demo, in `/dragonbox/appdata/CorsixTH/` (79 MB). `ldd` with `lib/` on
  the path left nothing unresolved, for the binary and for each copied library. From the menu, the process ran as
  `./corsix-th --interpreter=/mnt/dbp/union/CorsixTH_maquis196/corsixth-0.68.0/CorsixTH.lua` with
  `LD_LIBRARY_PATH=<union>/lib:<image>/lib::/usr/lib/arm-linux-gnueabihf/gl4es/`. Its maps held the copied FFmpeg,
  libcurl-nss and Lua libraries, gl4es `libGL.so.1`, SGX `libGLESv2` 1.14.3699939, `libpvrDRI3WSEGL.so` and trixie's
  `libfluidsynth.so.3`. The update check got through ("Update Available! 0.70.3"). One PulseAudio stream:
  `corsix-th`, `s16le 2ch 22050Hz`.
- **Stability runs** in the demo hospital, timed by `/tmp/cth-run.sh`. It sampled `top` every 10 s, recorded
  `aess.monitor` at 48 kHz, diffed `dmesg` (fullscreen runs only) and checked the PulseAudio user journal:

  | Run | Window | Length | CPU (one core) | Game clock | Exact silence ≥ 10 ms |
  |---|---|---|---|---|---|
  | win1 | 800x600 decorated | 120 s | 20–50 % | advancing | one 93 ms gap, after a 3 s fade |
  | fs1 | Alt+Enter: 1280x720 fullscreen, 960x720 picture | 300 s | 20–50 % | 3 Apr → 23 May | one 93 ms gap, after a 4 s fade |
  | fs2 | `fullscreen = true`, 1280x720 native, from the menu | 300 s | 27–60 % | 1 Jan → 14 Feb | one 186 ms gap, after a 5 s fade |

  The process was alive at the end of each run. The kernel log and the PulseAudio journal stayed empty. Each gap
  follows the music fading to a peak of 1–2, so it's the pause between XMI tracks, not a stall. The monitor captures
  what PulseAudio mixed, not what the codec played, and nobody listened.
- Not tested: listening for crackle on the speakers or headphones; sound effects under load (no reception desk, so
  no patients); gamepad and nubs; Theme Hospital's full data.
- Left on the card: `corsixth_0.68.0-r1_maquis196.dbp`, registered; `/dragonbox/appdata/CorsixTH/` with the demo,
  the appdata files and the demo's autosave; `/tmp/cth-run.sh`, `/tmp/shot.sh`. The game's `config.txt` was put back
  to the package's default.

## 2026-11-26 — rumble from a game's side: pyraInput Gamepad and SDL2 reach the motor

R99 test card, kernel `5.6.19-m4-kbdled` (r4). Effects checked by reading VIBCTLR/VIBDATR (`0x1a`/`0x1b` in
`/sys/kernel/debug/regmap/0-004b/registers`) while they played, not by feel.

- Access: `twl6040:vibrator` (`event8`) and `pyraInput Gamepad` (`event11`) are `root:input 660`, and the
  desktop user `pyra` is in `input`. A game running as that user can open both read-write, which uploading an
  effect needs.
- `libpyrainput.so` handles rumble itself (`PyraJoystick::rumble_handle`, `handleRumble`) and opens
  `twl6040:vibrator`. An `FF_RUMBLE` upload to `event11` returns at once and plays through.
- `FF_RUMBLE`, 32-bit `EVIOCSFF`, strong/weak magnitude → VIBDATR, same on `event8` and `event11`:
  `0xffff/0` → `0x33` (51), `0xc000/0` → `0x26`, `0xa000/0` → `0x1f`, `0x8000/0` → `0x19`, `0x4000/0` → `0x0c`,
  `0/0xffff` → `0x00` (VIBCTLR still `0x01`), `0xffff/0xffff` → `0x33`. Linear in the strong magnitude. The
  weak magnitude goes to the left channel, which has no motor (`viblmotor-res` 999999), so it never moves
  anything.
- SDL2 2.32.4 (Debian armhf): `pyraInput Gamepad` is a game controller (14 buttons, 4 axes),
  `SDL_JoystickHasRumble` is 1, and `SDL_JoystickRumble(j, 0xffff, 0, 1500)` returns 0 and writes VIBDATR `0x33`.
  SDL passes the low-frequency motor as `strong_magnitude`. `SDL_GetError` held a stale
  "Unexpected controller element crc", which isn't from this call.
- Answer: an SDL2 or evdev game can find the rumble and drive the motor with no setup. What it feels is
  limited by `known-limitations.md` 2.10. Not run: RetroArch, DuckStation, or any other real emulator.

## 2026-11-26 — rumble in Ship of Harkinian: weak at 100 %, and the speakers click while it plays

R99 test card, kernel `5.6.19-m4-kbdled` (r4), `soh-pyra` running with game audio on the speakers. The owner
listened and held the Pyra. Register writes were traced with the `regmap:regmap_reg_write` tracepoint, filtered to
`0x18`-`0x1b`.

- SoH's rumble Test button at 100 %, pressed twice, doesn't hold the motor on. It pulses: VIBCTLL/R `0x01` with
  VIBDATR `0x33` for 32 ms, then both `0x00` for 65 ms, about 10 Hz, for the whole test (138 writes). A steady
  `SDL_GameControllerRumble(0xffff, 0, 0)` every 1/60 s from a separate SDL2 program gives one enable and one
  disable, so SDL doesn't make the pulses. The likely source is SoH: the test calls `StartRumble` every UI
  frame while the game's `osMotorStop` path (`libultraship/libultra/os.cpp`) keeps stopping it. In-game rumble
  is pulsed by design, and 32 ms bursts just above the motor's start level barely spin it up.
- pyrainput (`joystick.cpp`, `UI_FF_UPLOAD`) handles an update to a known effect by `EVIOCRMFF` on the
  vibrator, then a fresh `EVIOCSFF`. The erase stops the effect, so each strength change also turns the driver
  off and on.
- Owner reported static in the speakers, pulsing, during Test. Not in headphones.
- A/B 1, writes over i2c straight to the chip with only the right channel enabled (VIBDATR `0x33`): steady for 3 s,
  and pulsed for 3 s. Neither gave SoH's static. The only noise heard was the speakers clipping on game audio.
- A/B 2, all pulsed: A right channel only, B left and right (what the driver does), C left channel only (no
  motor moves). **B and C gave the static** ("isn't loud but it's noticeable"), A didn't. `twl6040_vibra_enable`
  sets VIBENA on both channels, and the left has no motor (`ti,viblmotor-res` 999999). Switching the left driver
  on and off is what clicks in the speakers.
- Also: the left code's `vddvib * motor_res * TWL6040_VIBRA_MOD` is 3300 × 999999 × 85, which overflows `int`, so
  VIBDATL comes out as 0. That's harmless here, but it's why the weak magnitude never shows up on the left.
- Answer: the clicks come from the motorless left channel being enabled. Software can fix that by never
  enabling a channel with no motor. The weak feel comes from the 51-code cap (`TWL6040_VIBDAT_MAX` is 100) and
  from the 32 ms pulses.

## 2026-11-26 — patches/0055 on the vibra driver: register check

R99 test card, kernel `5.6.19-m4-kbdled` (r4, the CI build). 0055's `twl6040-vibra.c` built as an external module
against `src-m4-kbdled` with the r4 compiler (Debian 12.2.0-14). `.text`, `.data`, `.rodata`, `.bss` and `__param`
came out identical when built against `src-m4-kbdled-test`, whose config matches the device's
`/boot/config-5.6.19-m4-kbdled` apart from the release name. Installed in `updates/` (unsigned, so the kernel is
tainted `OE`), then `modprobe -r` / `modprobe`, then `systemctl restart pyrainput`.

- Before the swap, the owner played SoH with the stock driver (hitting things, bombs) and heard no static in
  game. The clicks were plain only on SoH's Test button.
- `FF_RUMBLE` on `pyraInput Gamepad`, strong/weak → VIBCTLL, VIBCTLR, VIBDATR: `0x0001/0` → `00 01 0x20`,
  `0x4000/0` → `0x26`, `0x8000/0` → `0x2e`, `0xffff/0` → `0x3c`, `0/0x4000` → `0x26`, `0/0xffff` → `0x3c`,
  `0x2000/0xc000` → `0x35`. VIBCTLL stayed `00` throughout. The floor (32), the cap (60) and weak-to-right all
  behave as designed.
