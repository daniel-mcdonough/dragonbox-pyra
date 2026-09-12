# Verification log

What was checked, when, and what it established. The procedure is `procedure.md`;
the running history of the project is `progress.md`.

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
kernel as before the experiment. `/boot` holds four kernels and is 54% full.
