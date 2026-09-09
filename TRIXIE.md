# Debian 13 (trixie) on the DragonBox Pyra

Status: **card boots to a working MATE desktop (2026-09-08).** lightdm starts,
the greeter renders on the panel, and the unit is reachable over SSH as `pyra`.
Getting there needed a fourth fix that supersedes fix 1: the documented DRI
symlink does not work on mesa 25.x and never could. See "Fix 1" and "Desktop
fixed" below. Written 2026-09-07. Target: V5.x Pyra, live boot from the left SD
slot, eMMC untouched. Kernel is the same 5.6.19-pyradef that bookworm-7 uses.

Companion script: `pyra-trixie-prep.sh` (in this directory).

---

## 0. What to buy

A **full-size SDXC card, 16 GB or larger**. A microSD in a full-size adapter is
fine.

The Pyra has two full-size SDXC slots plus a microSDXC slot under the battery
and 32 GB of eMMC. **The left full-size slot is the boot slot** — that is where
this card goes. The under-battery microSD is not the documented boot path and I
have not confirmed it is wired to a boot-capable controller, so don't plan
around it.

Class 10 / U1 or better. Nothing exotic is required.

---

## 1. Get the image

    cd ~/git/dragonbox-pyra
    wget https://packages.pyra-handheld.com/images/trixie/pyra-trixie-t1-brokenxorg.7z
    7z x pyra-trixie-t1-brokenxorg.7z

842 MB compressed, dated 2026-02-01. Confirmed present upstream on 2026-09-07.

There is also a `pyra-trixie-brokenxorg.img.7z` from 2025-06-28 in the same
directory — that is the older pre-t1 build. **Use the t1 one.**

The "brokenxorg" in the filename is accurate as shipped. Fix 1 below is what
un-breaks it.

---

## 2. Pre-flight — validate the fixes with no Pyra involved

Do this once the image is extracted, before the card even matters. It costs ten
minutes and turns card-day into a copy-paste job. Two of the three fixes rest on
assumptions the original forum post never verified.

    sudo losetup -fP --show pyra-trixie-*.img      # prints e.g. /dev/loop0
    sudo blkid /dev/loop0p1 /dev/loop0p2           # lsblk -f shows nothing useful here
    sudo modprobe f2fs                             # p2 is f2fs, not ext4
    sudo mkdir -p /mnt/pyra
    sudo mount /dev/loop0p2 /mnt/pyra

The layout is p1 = 256 MB ext2 labelled `boot`, p2 = 5.7 GB **f2fs** labelled
`rootfs`. `fstab` calls p1 ext4; the ext4 driver mounts ext2 fine, so that is
cosmetic. Both partitions are referenced by `PARTUUID`, derived from the MBR
disk identifier, so a whole-disk `dd` keeps them valid with no fixup.

Check the three assumptions by hand:

    # Fix 1: which DRI drivers actually exist? The forum post hardcodes
    # kms_swrast_dri.so, but trixie ships mesa 25.x which has been
    # consolidating these into a gallium megadriver.
    ls /mnt/pyra/usr/lib/arm-linux-gnueabihf/dri/

    # Fix 2: what marker does the first-run script really check?
    # NOTE: it is NOT in /usr/bin. Real path:
    cat /mnt/pyra/usr/share/pyra/scripts/pyra-first-run.sh
    cat /mnt/pyra/usr/lib/systemd/system/pyra-first-run.service

    # Fix 3: is the unit genuinely missing, and are its dependencies present?
    ls /mnt/pyra/lib/systemd/system/ | grep -i pyra
    ls -l /mnt/pyra/usr/sbin/funkeymonkey \
          /mnt/pyra/usr/lib/funkeymonkey/libpyrainput.so \
          /mnt/pyra/etc/pyrainput.cfg

Then run the script against the loop mount to confirm it completes cleanly:

    sudo ~/git/dragonbox-pyra/pyra-trixie-prep.sh /mnt/pyra testuser

The script reports what it found for each fix. If anything surprises you, adjust
before committing it to a card.

    sudo umount /mnt/pyra
    sudo losetup -d /dev/loop0

Note: the modified loop image is now already fixed. You can `dd` *that* to the
card and skip step 4 entirely — but re-running the script on the card is
harmless (it's idempotent) and confirms it applied.

---

## 3. Write the card

Identify it first, and actually read the output before typing anything:

    lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT

With `/dev/sdX` replaced by the **whole card device**, not a partition:

    sudo umount /dev/sdX?* 2>/dev/null
    sudo dd if=pyra-trixie-*.img of=/dev/sdX bs=4M status=progress conv=fsync
    sync

---

## 4. Apply the fixes, before first boot

The wizard bug (fix 2) powers the unit off seconds after boot, so fixing this
from a half-booted device is a chicken-and-egg fight worth skipping entirely.

    sudo partprobe /dev/sdX
    sudo blkid /dev/sdX1 /dev/sdX2        # p2 is the f2fs rootfs
    sudo modprobe f2fs
    sudo mount /dev/sdX2 /mnt/pyra
    sudo ~/git/dragonbox-pyra/pyra-trixie-prep.sh /mnt/pyra yourusername
    sudo umount /mnt/pyra && sync

The script prompts for a password (hidden, entered twice) and is idempotent —
re-running it is safe and just reports what is already in place.

---

## 5. Boot it

Card in the **left** slot.

**Hold the power button until both LEDs go green, then release.**

A short tap gives you a quarter second of LED and then silence, which looks
exactly like a dead card or a flat battery. It is neither. This image's U-Boot
(2016.11, rebuilt 2024) asks the Palmas PMIC why the unit powered on and refuses
anything that is not a real long press. The older U-Boot on a stock eMMC has no
such check, which is why bookworm boots off a tap and this card appears not to
boot at all.

---

## 6. Verify

Log in as the user the script created. Then:

    # nubs, keyboard, gamepad
    systemctl status pyrainput
    ls /dev/input/by-path | grep -i pyra

You should get three pyraInput devices: keyboard, Gamepad, Mouse.

    # X server came up
    grep -E 'AIGLX|GLX|\(EE\)' /var/log/Xorg.0.log

With fix 4 applied the only GLX-related line should be:

    (**) Extension "GLX" is disabled

There should be **no** `AIGLX` lines at all, and no `Segmentation fault` /
`Caught signal 11`. An AIGLX line reappearing means fix 4 is not in effect.

    # the extensions that matter are still there
    DISPLAY=:0 xdpyinfo | grep -E 'DRI2|DRI3|Present'

`DRI3` and `Present` must both be listed. Those are what the SGX blob's window
integration uses; `GLX` is deliberately absent.

    # hardware GLES2 through the SGX blob
    sudo apt-get install libx11-dev
    gcc -O2 -o gles2-smoke gles2-smoke.c \
        -I/opt/omap5-sgx-ddk-um-linux/include \
        -L/opt/omap5-sgx-ddk-um-linux/lib -lEGL -lGLESv2 -lX11
    sudo env DISPLAY=:0 XAUTHORITY=/var/run/lightdm/root/:0 ./gles2-smoke

Check with `ldd` that it picked up `/opt/omap5-sgx-ddk-um-linux/lib/libEGL.so.1`
and not the mesa one in `/usr/lib/arm-linux-gnueabihf`.

Measured on the fixed card:

    DRI3 1.0
    present 1.2
    EGL_VENDOR   Imagination Technologies
    GL_RENDERER  PowerVR SGX 544MP
    GL_VERSION   OpenGL ES 2.0 build 1.14@3699939 (MAIN)
    7073 frames in 5.00 s = 1414 fps   (clear + swap, 320x240, vsync off)

The `DRI3`/`present` lines are printed by `libpvrDRI3WSEGL` itself — that module
lives at `/usr/lib/libpvrDRI3WSEGL.so` and comes from the `dri3wsegl-pyra`
package, not from the DDK tree. Seeing them is the proof that window integration
is going through the blob, which is the same path the bookworm desktop uses, and
that disabling GLX did not disturb it.

Do not compare the fps figure to the forum post's ~1270 without matching the
window size; it is a driver-throughput number, not a benchmark.

**Do not use the DDK's own `gles2test1` for this.** It is a direct-KMS test that
wants DRM master and fails identically on bookworm when X is running.

---

## The four fixes, and what they actually do

### Fix 1 — Xorg segfault at startup (SUPERSEDED, see fix 4)

**This fix does not work. Keep reading only for the diagnosis; fix 4 is what
you actually apply.** The prep script still creates the symlink because it is
harmless, but it does not solve anything and the file is best removed.

Symptom as shipped:

    (EE) AIGLX error: dlopen of .../dri/armsoc_dri.so failed (No such file or directory)
    (EE) AIGLX error: unable to load driver armsoc
    (EE) Segmentation fault at address 0x0
    (EE) Caught signal 11 (Segmentation fault). Server aborting

The documented fix symlinks `armsoc_dri.so` to `kms_swrast_dri.so`. On the real
t1 image that changes the message and nothing else:

    (EE) AIGLX error: armsoc exports no extensions
         (/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so: undefined symbol: __driDriverExtensions)
    (EE) Segmentation fault at address 0x0

Why no symlink can ever work: Xorg's AIGLX builds the symbol it looks up from
the DRI2 driver name the DDX reports. `xf86-video-armsoc` hardcodes that name
as `armsoc`, so Xorg dlopens `armsoc_dri.so` and asks for
`__driDriverGetExtensions_armsoc`, falling back to the pre-2013
`__driDriverExtensions`. Mesa 25.0.7 has collapsed every DRI driver into
`libdril_dri.so`, its DRI-legacy stub, which exports exactly one
`__driDriverGetExtensions_<name>` per driver name it was *built* for — 58 of
them, and `armsoc` is not among them — and does not export the legacy symbol at
all. The symlink target is irrelevant: the lookup is by name, and the name is
wrong. Verified with `nm -D` on the image's own `libdril_dri.so`.

Things that were tried on the device and did **not** work:

| Attempt | Result |
| --- | --- |
| Symlink to `kms_swrast_dri.so` (the documented fix) | Segfault, different message |
| C shim exporting `__driDriverGetExtensions_armsoc`, forwarding to `kms_swrast` | Lookup succeeds, then `Error creating gpu or npu`, segfault |
| Same shim forwarding to `swrast` | Segfault |
| Either shim with `LIBGL_ALWAYS_SOFTWARE=1` and/or `GALLIUM_DRIVER=llvmpipe` | `Error creating gpu or npu`, segfault |
| `Section "ServerFlags" Option "AIGLX" "off"` | No effect — the option no longer exists; the string is absent from the 21.1.16 binary |
| `Section "Extensions" Option "DRI2" "Disable"` | No effect — does not stop the AIGLX probe |

The shim is worth understanding because of *where* it fails. Once the symbol
resolves, mesa's stub tries to build a gallium screen on the omapdrm fd and
cannot, because there is no gallium driver for omapdrm and its software
fallback does not take over. It returns failure, and Xorg 21.1.16 then
segfaults.

That is the actual bug, and it is bigger than the missing driver: **every**
failure path in 21.1.16's AIGLX DRI2 probe NULL-derefs instead of returning
cleanly. Xorg is supposed to fall back to software GLX when that probe fails,
which is exactly what bookworm's 21.1.7 does with the identical missing driver.
There is no way to make the probe *succeed* on this hardware, so the only
remedy is to stop it running.

### Fix 2 — first-run wizard powers the unit off

With X fixed you boot to the fullscreen Pyra wallpaper and then the device
powers off. Nothing crashed. `pyra-first-run.sh` sets the wallpaper, then shows
a zenity question dialog whose cancel button is labelled "Shutdown". In that
bare xinit session the dialog gets no usable input, so the script takes the
cancel branch and calls `poweroff`.

The script marks the run done and creates offline the user the wizard would
have created.

Caveat from the original report: the wizard was never retested *after* X was
properly fixed, so it may well behave now. Skipping it is the path known to
work.

### Fix 3 — dead nubs

A genuine packaging bug. `funkeymonkey-pyrainput` 0.1.19 in the **trixie** repo
ships without `/lib/systemd/system/pyrainput.service`. The identical version in
the **bookworm** repo has it. The script writes the unit and enables it offline.

Verified by pulling both `.deb`s and diffing their contents. Same version
0.1.19 in both suites; bookworm's ships `lib/systemd/system/pyrainput.service`
and trixie's does not. The unit the script writes is byte-identical to
bookworm's, so this is a faithful restore rather than a reconstruction.

`/etc/pyrainput.cfg` is a separate, smaller problem. No package in *either*
repo ships it, so this is not a trixie regression, but `libpyrainput` logs
`ERROR: Could not open config file` when it is missing and the unit is
`Restart=on-failure`. The script now creates it empty, which is exactly what
`pyrainputctl` does on first use and leaves the module on its built-in
defaults.

Worth filing upstream so the package gets rebuilt, rather than everyone working
around it forever:
https://dev.pyra-handheld.com/packages/funkeymonkey-pyrainput

---

### Fix 4 — disable the GLX extension (this is the one that works)

    # /etc/X11/xorg.conf.d/20-pyra-glx.conf
    Section "Extensions"
        Option "GLX" "Disable"
    EndSection

Xorg then skips GLX entirely, never runs the AIGLX probe, never reaches the
broken error path, and starts normally. The log carries one line about it:

    (**) Extension "GLX" is disabled

`Section "Module" Disable "glx"` would also work; the `Extensions` form is the
documented one and leaves the module alone.

**What this costs.** No GLX on the X server at all. Bookworm has software GLX
here, so this is a real regression against bookworm, and `glxinfo` and anything
that insists on desktop GL will not work. GTK4 applications fall back to the
cairo renderer.

**What this does not cost.** `DRI3` and `Present` are untouched, and those are
what `libpvrDRI3WSEGL` uses, so the hardware path — GLES2 through the SGX blob
via EGL — is unaffected. Desktop GL never touched the SGX on this platform
anyway; GLX was always software rendered, so nothing that was ever fast has
been lost.

Also remove the useless symlink from fix 1 while you are here:

    rm -f /usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so

This is a workaround for an upstream Xorg bug and should be reverted whenever
Debian ships a 21.1.x whose AIGLX probe fails gracefully, or whenever mesa
grows an omapdrm-capable stub. Both are worth reporting:

- xorg-server: AIGLX DRI2 probe NULL-derefs on every failure path in 21.1.16
  rather than returning NULL and falling back to swrast.
- mesa: `libdril_dri.so` cannot create a screen for omapdrm and reports
  `Error creating gpu or npu`.

---

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
- SSH in as the `pyra` account the prep script created, at <usb-address>.

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

**`pyra-usb3503-rescue.service`.** Re-resets the on-board USB3503 hub at boot if
it did not enumerate, which is what a warm reboot leaves behind. It checks for
the hub on the USB bus first, so on a cold boot it exits without touching
anything. Script at `/usr/local/sbin/pyra-usb3503-rescue`, unit in
`/etc/systemd/system/`, enabled in `multi-user.target`.

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

## Growing the rootfs

The image is 6 GiB and nothing grows it on boot, so on a 128 GB card about
113 GB sits unused. Growing it means extending partition 2 and running
`resize.f2fs`.

**This cannot be done on the Pyra.** f2fs online resize goes through
`F2FS_IOC_RESIZE_FS`, and the 5.6.19 kernel's implementation only shrinks — ask
it to grow and it returns `EINVAL`. Confirmed by calling the ioctl directly
against a throwaway loopback f2fs on the device, rather than inferring it.
`f2fs_io` in f2fs-tools 1.16.0 has no `resize` subcommand either, so there is no
userspace path to it regardless. And `resize.f2fs` is a symlink to `fsck.f2fs`,
which is an offline tool and will not operate on a mounted filesystem. Since the
filesystem in question is the rootfs, it cannot be unmounted in place.

So: power the Pyra down, move the card to a reader on a PC, and run

    sudo ./pyra-trixie-grow.sh /dev/sdX

`pyra-trixie-grow.sh` (in this directory) refuses to touch anything that is not
a Pyra trixie card. It checks the MBR disk identifier and both partition start
sectors, refuses a partition or a mounted device, and backs up the first 1 MiB
and the partition table before it writes. Partition 2's start sector does not
move, so the PARTUUIDs that `fstab` and `extlinux.conf` reference stay valid. It
is idempotent: run it on an already-grown card and it reports there is nothing
to do.

Then put the card back in the **left** slot, cold boot, and check with `df -h /`.

## Where this deviates from the forum post

The original writeup works, but a few steps are fragile enough to be worth
replacing:

- **User creation.** The post appends raw lines to `/etc/passwd`, `/etc/group`
  and `/etc/shadow` and has you hand-edit group membership. That is how you end
  up with `gshadow` disagreeing with `group` and `useradd` refusing to run
  later. The script uses `useradd --root` / `usermod --root`, which write all
  four files consistently and honour the image's own `login.defs`.
- **Password handling.** `openssl passwd -6 'yourpassword'` puts the password
  in shell history and in `ps` output. The script prompts with `read -rs` and
  pipes to `chpasswd -e -R`, so it never reaches the process table.
- **The DRI symlink target.** The post hardcodes `kms_swrast_dri.so`. If mesa
  25.x has dropped that name, a blind `ln -s` creates a dangling symlink and you
  get the same segfault with a more confusing log. The script probes for
  `kms_swrast_dri.so`, then `swrast_dri.so`, then any `*_dri.so`, and hard-fails
  rather than leaving a broken link.
- **The first-run marker.** `/var/lib/pyra/first-run.done` is asserted, not
  verified. The script greps the actual `pyra-first-run.sh` for the path it
  really checks, and warns if it has to fall back to the documented default.
- **Enabling pyrainput.** The post has you run `systemctl enable --now
  pyrainput` after boot. The script symlinks it into `multi-user.target.wants`
  offline, so the nubs work on the very first boot.

---

## Rejected alternatives (for when you're tempted)

**Installing trixie to the eMMC instead of a card.** Technically possible, and
it sidesteps the long-press quirk since the eMMC's older U-Boot has no PMIC
check. But it overwrites bookworm-7 — your only known-good system and your only
recovery path. This image is deliberately a live SD image that leaves the eMMC
alone. Don't burn the fallback to test a build that needed four fixes to reach
a desktop.

**The microSD slot under the battery.** Not the documented boot path, and not
confirmed to be on a boot-capable controller.

**USB boot.** OMAP5 peripheral boot exists, but it is an SPL-over-USB recovery
mechanism, not a way to run a rootfs.

---

## Troubleshooting

**Quarter-second of LED, then nothing.** You tapped instead of holding. See
step 5. This is by far the most likely "it doesn't boot".

**The unit disappears from the network after `reboot`.** It rebooted fine. What
died is USB, and with it the USB ethernet adapter. See "USB is dead after a warm
reboot" below. If wifi is configured the unit is still reachable there; if it is
not, you need the screen.

**USB is dead after a warm reboot.** No devices at all behind the on-board hub:
no ethernet adapter, no mouse, no keyboard dongle. `lsusb` shows only the root
hub, which makes it look like the controller failed. It did not — `dmesg` shows
`ehci-omap` starting normally and the root hub finding its 3 ports.

The USB3503 hub chip is the problem. It is reset over i2c at probe, and after a
warm reboot its reset GPIO is still deasserted from the previous boot, so the
reset is a no-op and the hub never connects. `dmesg` gives it away:

    usb3503 0-0008: reset gpio state 1

On a cold boot that reads `0`. Rebinding the driver re-runs the sequence from a
known state and everything behind the hub comes back within seconds:

    echo 0-0008 | sudo tee /sys/bus/i2c/drivers/usb3503/unbind
    echo 0-0008 | sudo tee /sys/bus/i2c/drivers/usb3503/bind

`pyra-usb3503-rescue.service` does this automatically at boot; see below. A cold
power cycle also avoids it entirely.

**Configure wifi before you reboot remotely.** With USB gone the ethernet adapter
goes with it, and wifi is the only way back in.

**Still no boot after a proper long press.** Re-check that the card is in the
*left* full-size slot, that you `dd`'d to the whole device (`/dev/sdX`) and not
a partition (`/dev/sdX1`), and that `dd` finished with `conv=fsync` plus a
`sync`.

**It boots and then powers off.** Fix 2 didn't take — the marker path was wrong.
Pull the card, mount it, and read `/usr/bin/pyra-first-run.sh` to find the
actual guard condition.

**X still segfaults / lightdm fails and there is no desktop.** Read
`/var/log/Xorg.0.log`. If you see any `AIGLX` line, fix 4 is not in effect:
check that `/etc/X11/xorg.conf.d/20-pyra-glx.conf` exists and disables the GLX
extension. Do not chase the `armsoc_dri.so` symlink — it cannot fix this, for
the reasons under fix 1. `/var/log/lightdm/lightdm.log` and
`/var/log/lightdm/x-0.log` tell you whether lightdm or X is the one failing.

**Nubs still dead.** `systemctl status pyrainput` on the device. If the unit
failed to start, confirm `/usr/sbin/funkeymonkey`,
`/usr/lib/funkeymonkey/libpyrainput.so` and `/etc/pyrainput.cfg` all exist.

**General principle:** the device powers itself off faster than you can debug on
it. Pull the card, mount it on the PC, read the logs there
(`/var/log/Xorg.0.log`, `journalctl --directory=/mnt/pyra/var/log/journal`).
That is the working debug loop for this image.

---

## Not tried yet

- gl4es on trixie
- box86 on trixie

Side note from the original report: a test binary compiled on bookworm ran
unmodified on trixie, so the armhf 64-bit `time_t` transition did not bite this
particular stack.

---

## Sources

- Image: https://packages.pyra-handheld.com/images/trixie/
- Original writeup: pyra-handheld.com forums, "Debian 13 (trixie) working on
  the Pyra: three fixes" — reported working on a V5.3 unit.
