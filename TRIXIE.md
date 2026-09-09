# Debian 13 (trixie) on the DragonBox Pyra

Status: **card boots; lightdm fails, so no desktop yet (2026-09-08).** The unit
comes up far enough to reach multi-user and is reachable over SSH as `pyra`.
The graphical target is the open problem. All three fixes were confirmed
necessary against the real image, applied offline, and verified on the card.
See "Pre-flight results", "Card as written" and "Boot result" below.
Written 2026-09-07. Target: V5.x Pyra, live boot from the left SD slot, eMMC
untouched. Kernel is the same 5.6.19-pyradef that bookworm-7 uses.

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

    # X server came up without the AIGLX crash
    grep -E 'AIGLX|\(EE\)' /var/log/Xorg.0.log

The two AIGLX errors about armsoc are expected and harmless — bookworm logs the
identical pair. What must be absent is `Segmentation fault` / `Caught signal 11`.

    # hardware GLES2 through the SGX blob
    # needs libx11-dev; build a minimal X11+EGL+GLES2 client against
    # /opt/omap5-sgx-ddk-um-linux/include

Expected output:

    DRI3 1.0
    present 1.2
    EGL_VENDOR:  Imagination Technologies
    GL_RENDERER: PowerVR SGX 544MP
    GL_VERSION:  OpenGL ES 2.0 build 1.14@3699939 (MAIN)
    ~1270 fps

Bookworm manages ~1170 fps on the identical test, so trixie is marginally
quicker and nothing was lost. The DRI3/present lines confirm `libpvrDRI3WSEGL`
is doing window integration — the same path the bookworm desktop uses.

**Do not use the DDK's own `gles2test1` for this.** It is a direct-KMS test that
wants DRM master and fails identically on bookworm when X is running.

---

## The three fixes, and what they actually do

### Fix 1 — Xorg segfault at startup

Symptom:

    (EE) AIGLX error: dlopen of .../dri/armsoc_dri.so failed (No such file or directory)
    (EE) AIGLX error: unable to load driver armsoc
    (EE) Segmentation fault at address 0x0
    (EE) Caught signal 11 (Segmentation fault). Server aborting

`armsoc_dri.so` does not exist on bookworm either. Bookworm's Xorg 21.1.7 logs
the same two AIGLX errors and carries on; somewhere between 21.1.7 and 21.1.16
that failure path picked up a NULL deref. The fix hands AIGLX any loadable DRI
driver so it never reaches the broken branch:

    ln -s <some>_dri.so /usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so

GLX then lands on swrast, which sounds like a loss until you check bookworm and
realise **GLX was always software rendered on this platform**. Desktop GL never
touched the SGX. The hardware path is GLES2 through the blob's EGL and
`libpvrDRI3WSEGL`, and that survives intact.

This is a workaround for an upstream Xorg bug, not a fix. It stops being needed
whenever Debian picks up a patched 21.1.x.

Confirmed on the t1 image: mesa 25.0.7 has indeed collapsed every DRI driver
into one `libdril_dri.so` megadriver, but it keeps `kms_swrast_dri.so` as a
symlink to it, so the script's first probe hits and the forum post's hardcoded
name would also have worked. `armsoc_dri.so` is genuinely absent.

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
alone. Don't burn the fallback to test a build that needed three fixes to reach
a desktop.

**The microSD slot under the battery.** Not the documented boot path, and not
confirmed to be on a boot-capable controller.

**USB boot.** OMAP5 peripheral boot exists, but it is an SPL-over-USB recovery
mechanism, not a way to run a rootfs.

---

## Troubleshooting

**Quarter-second of LED, then nothing.** You tapped instead of holding. See
step 5. This is by far the most likely "it doesn't boot".

**Still no boot after a proper long press.** Re-check that the card is in the
*left* full-size slot, that you `dd`'d to the whole device (`/dev/sdX`) and not
a partition (`/dev/sdX1`), and that `dd` finished with `conv=fsync` plus a
`sync`.

**It boots and then powers off.** Fix 2 didn't take — the marker path was wrong.
Pull the card, mount it, and read `/usr/bin/pyra-first-run.sh` to find the
actual guard condition.

**X still segfaults.** Pull the card and read `/var/log/Xorg.0.log`. Check that
`usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so` is a symlink pointing at a file
that actually exists — a dangling link behaves identically to a missing one.

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
