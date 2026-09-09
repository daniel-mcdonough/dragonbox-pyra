# Debian 13 (trixie) on the DragonBox Pyra — progress log

Running timeline of what has actually been done, in order, with what each step
established. Newest work goes at the bottom.

Companion documents: `TRIXIE.md` is the procedure and the reference. This file
is the history. Where the two disagree, `TRIXIE.md` is the one to trust for
*how*, this one for *when* and *why*.

Times are local (US Eastern). Entries marked **reported** were observed by the
operator on the device rather than verified on the PC.

---

## Before this project

**2026-02-01** — Upstream publishes `pyra-trixie-t1-brokenxorg.7z`, the t1
build, to `packages.pyra-handheld.com/images/trixie/`. 862,273,362 bytes,
expanding to a 6 GiB image. An older pre-t1 build from 2025-06-28 sits beside
it and is not the one to use.

The "brokenxorg" in the filename is accurate as shipped.

---

## 2026-09-07 — research and preparation, no hardware

Written up from a Pyra forum post, "Debian 13 (trixie) working on the Pyra:
three fixes", reported working on a V5.3 unit.

- `TRIXIE.md` written: the buy/write/fix/boot procedure, the three fixes and
  what they do, rejected alternatives, and troubleshooting.
- `pyra-trixie-prep.sh` written to apply the three fixes offline against a
  mounted rootfs, replacing the fragile parts of the forum procedure. Notably
  it uses `useradd --root` instead of appending raw lines to `/etc/passwd`,
  prompts for the password instead of putting it in shell history, and probes
  for a DRI driver instead of hardcoding one.
- Upstream image confirmed still present.

Status at end of day: blocked on hardware. No SD card.

---

## 2026-09-08 — pre-flight, card written, first boot

### 20:52 — image acquired

Download started and the target card inspected in parallel. The card at
`/dev/sdi` is a 128 GB SDXC in a USB reader, factory exFAT, mounted read-only
to confirm it was empty. It was.

Downloaded archive matched the upstream `content-length` exactly.

### 20:54 – 21:00 — pre-flight against the loop-mounted image

This is the step that paid for itself. Four documented assumptions were wrong.

| Assumption | Reality |
| --- | --- |
| Rootfs is ext4 | **f2fs.** Needs `modprobe f2fs` to mount |
| First-run script is in `/usr/bin` | **`/usr/share/pyra/scripts/pyra-first-run.sh`** |
| `/etc/pyrainput.cfg` exists | **Missing**, and shipped by no package in either suite |
| U-Boot location unstated | **Raw sectors before partition 1**, so only a whole-device write works |

Confirmed correct, on the other hand:

- `armsoc_dri.so` is genuinely absent, so fix 1 is needed. `kms_swrast_dri.so`
  is present as a symlink into mesa 25.0.7's `libdril_dri.so` megadriver, so
  the script's first probe hits.
- The first-run marker really is `/var/lib/pyra/first-run.done`, and it is the
  `ConditionPathExists=!` guard on `pyra-first-run.service`, which is enabled
  in `graphical.target.wants`. Touching the marker disables the wizard at the
  systemd level rather than relying on the script's own logic.
- The image has **no user accounts at all** and an empty `/home`. The wizard
  was the only thing that would ever have created one, so skipping it without
  creating a user offline leaves no way to log in.
- Every group the prep script wants exists in the image.
- The display manager is **lightdm**, not slim, despite the wizard still
  carrying slim-theme code.
- The wizard calls `poweroff` on its success path too, not only on cancel.

**Fix 3 verified properly** by downloading both the bookworm and trixie
`funkeymonkey-pyrainput` packages and diffing their contents. Same version
0.1.19. Bookworm ships `lib/systemd/system/pyrainput.service`; trixie does not.
The unit the prep script writes is byte-identical to bookworm's, so it is a
faithful restore rather than a reconstruction. A scan of all 68 pyra packages
in each suite found no package shipping `/etc/pyrainput.cfg` in either, so that
gap is not a trixie regression.

### 21:00 — prep script patched

Two changes, both from pre-flight findings:

- Widened the first-run search to `/usr/share/pyra` and `/usr/lib/systemd/system`
  so it verifies the marker path instead of falling back to a warned guess.
- Create `/etc/pyrainput.cfg` empty when absent, which is what `pyrainputctl`
  does on first use, rather than only warning. Without it `libpyrainput` logs
  `ERROR: Could not open config file` and the unit is `Restart=on-failure`.

### 21:03 — fixes applied to the image

Prep script run by the operator against the loop-mounted rootfs, so the
password prompt stayed interactive and never passed through the session.

Verified afterwards: `armsoc_dri.so` resolving to a real file, the marker
present, user `pyra` at uid 1000 with a `$6$` hash, `/home/pyra` owned 1000:1000
and populated from skel, `gshadow` agreeing with `group` on every group, the
unit installed and enabled, and the empty config created.

The gshadow check matters: disagreement between `group` and `gshadow` is the
exact corruption the forum procedure's hand-editing produces, and it makes
`useradd` refuse to run later.

### 21:07 – 21:15 — card written

Whole-device write to `/dev/sdi`, behind a guard that re-checked size,
removable flag and absence of mounts before writing. Because the fixes went
onto the image first, the card was written once, already fixed.

    6442450944 bytes copied, 480.934 s, 13.4 MB/s

### 21:15 – 21:21 — write verified

- Readback of the first 6 GiB off the card is md5-identical to the fixed image.
- Partitions read back as `boot` (ext2) and `rootfs` (f2fs) with PARTUUIDs
  `21a4c285-01` and `-02`, matching what `fstab` and `extlinux.conf` reference.
  These derive from the MBR disk identifier, so the whole-device write kept
  them valid with no fixup.
- U-Boot SPL present in the raw gap on the card.
- All three fixes present on the card's own filesystem.

### 21:22 — repository created

The directory had no version control despite living under `~/git/`. Initialised
and committed, with the image and archive gitignored.

### 21:34 — first boot **(reported)**

The card boots. Reaches multi-user with networking, and is reachable over SSH
as `pyra` at <usb-address>.

**lightdm fails and there is no desktop.** This is the open problem. Worth
noting that the forum writeup only ever demonstrated a desktop through the bare
`xinit` session the first-run wizard used, which is not the code path lightdm
takes, so fix 1 may simply not cover this case.

---

## 2026-09-09 (device clock, CEST) — desktop fixed, hardware verified

Worked entirely over SSH on the running unit. Times are the device's.

### 03:40 — SSH access

The key was already authorised on the device; the earlier session's note about
falling back to a password was wrong. `id_rsa` is passphrase-protected and the
agent socket in this shell's environment held no identities, which produced an
identical "Permission denied (publickey,password)". Using the agent socket that
does hold the key connected first time. Nothing needed installing.

Sudo did need a password, so an operator-approved `/etc/sudoers.d/90-pyra-nopasswd`
was added to let the rest of the session run unattended. **This is a real
weakening and should be removed when the build is finished:**

    sudo rm /etc/sudoers.d/90-pyra-nopasswd

### 03:41 – 03:47 — lightdm diagnosed

lightdm is not the problem and never was. `/var/log/lightdm/lightdm.log` shows
it launching `/usr/bin/X :0 ... vt7`, that process dying on signal 6 in 250 ms,
and lightdm retrying five times into systemd's start limit. The only fault is
the Xorg segfault.

### 03:47 – 03:59 — fix 1 shown to be wrong, and why

`/var/log/Xorg.0.log` showed the symlink had changed the message but not the
crash:

    (EE) AIGLX error: armsoc exports no extensions
         (armsoc_dri.so: undefined symbol: __driDriverExtensions)
    (EE) Segmentation fault at address 0x0

`nm -D` on the image's `libdril_dri.so` explains it. Mesa 25's DRI-legacy stub
exports 58 `__driDriverGetExtensions_<name>` symbols and no legacy
`__driDriverExtensions` at all. `armsoc` is not one of the 58, and Xorg derives
the symbol name from the DDX's hardcoded DRI2 driver name. **No symlink target
can satisfy that lookup**, so the documented fix could never have worked on this
image.

Five further attempts, all still segfaulting:

- A C shim exporting `__driDriverGetExtensions_armsoc` and forwarding to
  `kms_swrast`. The lookup then succeeds, and it fails one step later with
  `Error creating gpu or npu` — mesa's stub cannot build a gallium screen on
  the omapdrm fd.
- The same shim forwarding to `swrast`.
- Both, under `LIBGL_ALWAYS_SOFTWARE=1` and `GALLIUM_DRIVER=llvmpipe`.
- `Section "ServerFlags" Option "AIGLX" "off"` — the option no longer exists;
  the string is absent from the 21.1.16 binary.
- `Section "Extensions" Option "DRI2" "Disable"` — does not stop the probe.

The underlying defect is that **every** failure path in 21.1.16's AIGLX DRI2
probe NULL-derefs rather than returning NULL and falling back to software GLX,
which is exactly what bookworm's 21.1.7 does with the same missing driver. The
probe cannot be made to succeed on this hardware, so it has to not run.

### 03:59 — fix 4, and a desktop

    # /etc/X11/xorg.conf.d/20-pyra-glx.conf
    Section "Extensions"
        Option "GLX" "Disable"
    EndSection

X started immediately. lightdm came up with the GTK greeter, and a screenshot
pulled off `:0` with `xwd` shows the greeter rendering at 1280x720 with the
`pyra` user listed. `xdpyinfo` confirms `DRI3` and `Present` are still there and
`GLX` is gone, so the SGX GLES2 path should be unaffected.

The useless `armsoc_dri.so` was removed. `/var/lib/lightdm/data` was created to
silence a cosmetic lightdm warning.

Cost of the fix: no desktop GLX at all, where bookworm has software GLX. On this
platform GLX never touched the SGX, so nothing that was ever fast was lost, but
it is a genuine regression against bookworm and is worth reverting if Xorg ever
fixes the fallback.

### hardware checks

- **pyrainput** active with no restart loop, all three pyraInput devices present
  (keyboard, Gamepad, Mouse), empty `/etc/pyrainput.cfg` accepted. Fix 3 is now
  validated on hardware, not just by package diff.
- **Audio**: 5 ALSA cards, the real one being card 4 `Letux Cortex 15` (TWL6040).
  PulseAudio running for the user session; pipewire is not in use.
- **Wifi**: `wlan0` present, scans, lists access points. Not connected because
  the unit is on a USB ethernet adapter, which is what <usb-address> is.
- **Bluetooth**: `hci0` UP RUNNING, HCI 4.1, valid BD address.
- **Battery and charging**: confirmed gaining, 14% to 16% over the session. Note
  the `bq24297` charger reports `online=0` / `Not charging` while the
  `bq27421-0` gauge reports `Charging` with positive current. The gauge's
  capacity trend is the one to trust.

### prep script

Fix 1 now *removes* the symlink rather than creating it, and a new fix 4 writes
the GLX config and creates the lightdm data directory. Both blocks were tested
against a fake rootfs for correctness and idempotency.

---

### 04:05 — reboot, and a wrong diagnosis

Rebooted to confirm fix 4 survives a cold boot. The unit vanished from the LAN
on every address, and I concluded it had powered off — that U-Boot's long-press
check had refused a warm reboot. **That was wrong** and is corrected below; the
claim briefly made it into `TRIXIE.md` and has been removed.

### 05:31 — what actually happened

Operator reported the desktop up and the unit on wifi at <wlan-address>, with USB
not working. `uptime` read 1:27, putting boot at 04:04, exactly when the reboot
was issued. **The unit rebooted normally.** It was unreachable because USB died,
and the USB ethernet adapter was the only network path configured at the time.

That fix 4 survives a cold boot is therefore confirmed: the Xorg log after the
reboot carries only `Extension "GLX" is disabled`, no AIGLX line and no
segfault.

---

### 05:32 — USB after a warm reboot

`lsusb` showed only the root hub. That looks like a dead controller, but `dmesg`
had `ehci-omap` starting normally and the root hub finding its 3 ports, so the
controller was fine and nothing behind the hub had enumerated.

The USB3503 hub chip is reset over i2c at probe, and after a warm reboot its
reset GPIO is still deasserted from the previous boot, so the reset does nothing
and the hub never connects:

    usb3503 0-0008: reset gpio state 1

On a cold boot that reads `0`. Rebinding the i2c driver re-runs the sequence and
the hub, the ethernet adapter and the wireless mouse all came back within
seconds.

Made persistent as `pyra-usb3503-rescue.service`, which checks for the hub on
the USB bus before doing anything, so it is a no-op on a cold boot.

Also installed `firmware-realtek`: the RTL8153 had been running on the driver's
fallback path after `Direct firmware load for rtl_nic/rtl8153a-4.fw failed with
error -2`. After installing and rebinding it loads properly.

### 05:40 — GLES2 through the SGX blob confirmed

Built a minimal X11 + EGL + GLES2 client against the DDK headers rather than
using the DDK's `gles2test1`, which is a direct-KMS test that wants DRM master
and fails on bookworm too whenever X is running. `ldd` confirms it binds the
DDK's `libEGL.so.1`, not mesa's.

    DRI3 1.0
    present 1.2
    EGL_VENDOR   Imagination Technologies
    GL_RENDERER  PowerVR SGX 544MP
    GL_VERSION   OpenGL ES 2.0 build 1.14@3699939 (MAIN)
    7073 frames in 5.00 s = 1414 fps   (clear + swap, 320x240, vsync off)

The `DRI3`/`present` lines come from `libpvrDRI3WSEGL` itself, which lives at
`/usr/lib/libpvrDRI3WSEGL.so` and ships in `dri3wsegl-pyra`, not in the DDK tree.

**This is the check that justifies fix 4.** Disabling GLX cost nothing on the
path that was ever hardware accelerated. The fps figure is not comparable to the
forum post's ~1270 without matching window sizes; treat it as evidence of
hardware rendering, not as a benchmark.

---

### 05:50 — the rootfs cannot be grown on the device

Established that f2fs online growth is impossible on this kernel, rather than
assuming it either way:

- `resize.f2fs` is a symlink to `fsck.f2fs`, an offline tool that will not work
  on a mounted filesystem. The filesystem here is the rootfs.
- `f2fs_io` in f2fs-tools 1.16.0 has no `resize` subcommand, so nothing in
  userspace reaches `F2FS_IOC_RESIZE_FS`.
- Calling that ioctl directly, from a small C probe against a throwaway 200 MiB
  loopback f2fs grown to 400 MiB, returns `EINVAL`. The kernel symbol
  `f2fs_resize_fs` exists in 5.6.19, but its implementation only shrinks.

So the resize is a PC-side job with the card in a reader.

### 06:00 — `pyra-trixie-grow.sh`, and a bug the test caught

Wrote the resize script with guards, then a test harness that builds a fake
8 GiB card with the real Pyra geometry and exercises it, including the cases
where it must refuse.

The test found a real bug. The check for "you passed a partition, not a disk"
was `[[ $DEV =~ [0-9]$ ]]`, which rejects any device whose name ends in a digit
— so `/dev/loop0` was refused for the wrong reason, and two of the three refusal
tests were passing by accident rather than exercising the guard they named. The
same bug would reject `mmcblk0` and `nvme0n1`, and the Pyra sees this very card
as `mmcblk3`.

Fixed by asking the kernel instead: `/sys/class/block/<dev>/partition` exists
only for partitions. Partition naming is now derived too, since `sda` gives
`sda1` but `loop0`, `mmcblk3` and `nvme0n1` give a `p1` suffix.

The lesson was in the test, not the script: asserting only that a command failed
lets it fail for the wrong reason. The refusal tests now assert on the error
message. Re-run after the fix: all pass, including idempotency.

---

### 06:20 — first resize attempt aborted, and why

`pyra-trixie-grow.sh` grew p2 from 5.7 GiB to 119 GiB cleanly, then `fsck.f2fs`
aborted before the filesystem resize:

    [ASSERT] (get_current_sit_page:2110) dev_read_block(sit_blk, blk_addr) >= 0

The script refusing to resize after that was correct. Nothing was written to the
filesystem, p2's start did not move, and the card would still have booted.

`dmesg` showed what it actually was, and it was not the filesystem:

    usb 1-4: reset high-speed USB device number 9 using xhci_hcd   (x3)
    sdi: detected capacity change from 249999360 to 0
    sd 15:0:0:0: [sdi] tag#0 access beyond end of device
    I/O error, dev sdi, sector 543136

The card reader dropped off the USB bus. Sector 543136 is ~265 MB in, at the
very start of the partition, so this was not an end-of-device arithmetic
problem — the `access beyond end of device` lines are the kernel reporting
in-flight reads against a device it had just been told was 0 sectors long.

Confirmed against the filesystem itself: checkpoint state read
`crc compacted_summary unmount`, i.e. cleanly unmounted, and a read-only mount
listed the tree and checksummed files fine.

### 06:35 — verifying the card before trusting it

Everything ever written to or read from this card had lived in the first 6 GiB.
The upper 113 GiB was completely untested, so a capacity-overstating card would
not have shown up yet, and resizing onto space that does not exist produces a
filesystem that looks healthy and then silently destroys data.

`verify-card-capacity.sh` writes unique samples across the untested region only
(never below sector 12582912, so the rootfs is untouchable), reads them back,
and then does a sustained 256 MiB round trip to exercise the link. Result: all
40 samples verified, round trip clean, 119 GiB real.

This should have been run **before** growing the partition, not after.

### two bugs in the tooling, both found by running it

- `verify-card-capacity.sh` generated samples with `openssl ... | head -c 1M`.
  `head` exits once satisfied, `openssl` takes SIGPIPE, and under
  `set -o pipefail` that is a failed pipeline, so `set -e` killed the script on
  the first sample. It exited silently, which looked exactly like a fast pass.
  Fixed by dropping the pipeline, plus an `ERR` trap and an explicit
  `TEST COMPLETE: PASS/FAIL` banner so a silent exit can never read as success.
  The same pipeline hazard was hardened in `pyra-trixie-grow.sh`.
- `pyra-trixie-grow.sh` decided there was nothing to do from free space *after*
  the partition. With the partition already grown and the filesystem not, that
  is exactly the state a failed run leaves behind, and it would have reported
  "nothing worth doing" and skipped the resize. It now compares the filesystem
  size from `dump.f2fs` against the partition size and resizes when they
  disagree, so it resumes correctly.

Also added an optional `RESIZE_MARGIN_SECTORS`, applied via `resize.f2fs -t` so
it needs no second write to the partition table.

---

### 06:50 — resize completed

Re-ran with a 64 MiB margin. The partition already filled the disk from the
first attempt, so the script left the table alone and resized only the
filesystem, which is the resume path the earlier fix added.

Verified on the device after a cold boot:

| | |
| --- | --- |
| `df -h /` | 119G total, 4.5G used, 115G available |
| filesystem | 249341952 sectors |
| partition | 249473024 sectors |
| difference | 131072 sectors, exactly the requested 64 MiB margin |
| checkpoint | clean mount, no f2fs errors in `dmesg` |
| services | lightdm, pyrainput and pyra-usb3503-rescue all active, no failed units |

The eMMC is still untouched: `/dev/mmcblk0` shows its own 256 MB boot partition
and 31 GB rootfs, so the bookworm-7 recovery path is intact.

### note on load average

Two `events_freezable` kworkers sit permanently in `D` state, which pins the
load average near 2.0 while the CPU is ~80% idle. This was present at the very
first SSH connection, before any change here, so it is inherent to the image.
Not chased further. Documented in `TRIXIE.md` so it is not mistaken for a
symptom later.

---

## Open items

- **Log in to MATE and confirm the session works.** The greeter renders and the
  operator reports the UI working; a session has not been driven from here.
- **Verify `pyra-usb3503-rescue.service` on a real warm reboot.** It no-ops
  correctly with the hub present, but the path that matters has not been
  exercised.
- **Remove `/etc/sudoers.d/90-pyra-nopasswd`** when the build is finished. This
  is the last outstanding change to the device:

      sudo rm /etc/sudoers.d/90-pyra-nopasswd
- **No desktop GLX.** Consequence of fix 4. Revert when Xorg's AIGLX probe
  fails gracefully, or when mesa's stub can create a screen for omapdrm.
- **Two upstream bugs to file**, beyond the pyrainput one:
  - xorg-server 21.1.16: AIGLX DRI2 probe NULL-derefs on every failure path
    instead of falling back to swrast. This is the whole "brokenxorg" problem.
  - mesa 25.0.7: `libdril_dri.so` reports `Error creating gpu or npu` for
    omapdrm rather than falling back to software.
- **Upstream bug to file.** `funkeymonkey-pyrainput` 0.1.19 in the trixie repo
  ships no systemd unit while the identical version in bookworm does.
  https://dev.pyra-handheld.com/packages/funkeymonkey-pyrainput
- **f2fs cross-kernel caveat.** Resolved in practice: the card was written by a
  Linux 7.1 host and has now booted and rebooted cleanly under 5.6.19.
