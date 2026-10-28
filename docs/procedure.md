# Writing a trixie card for the DragonBox Pyra

The procedure: buy a card, write the image, apply the fixes offline, boot it.
Target is a V5.x Pyra booting live from the left full-size SD slot, with the
eMMC untouched. The kernel is the same 5.6.19-pyradef that bookworm-7 uses.

Status: **working.** The card boots to a MATE desktop, hardware GLES2 runs on
the SGX, all the on-board hardware checks out, and the rootfs fills the card.
lightdm starts, the greeter renders on the panel, and the unit is reachable over
SSH as `pyra`.

Twelve fixes are needed, and `fixes.md` explains each one. Most of them are not
in the original forum writeup: fix 4 supersedes fix 1, because the documented
DRI symlink does not work on mesa 25.x and never could; fix 5 keeps USB alive
across a warm reboot; fix 6 makes the thermal daemon able to apply a frequency
cap at all; fix 7 corrects the ladder it applies, which throttles on the
fuel gauge's die temperature and can overwrite its own deeper cap; and fixes 8
to 12 cover charging, sound, the greeter holding the sound card, GL on every
boot, and the volume wheel.

Companion script: `../pc/pyra-trixie-prep.sh`. It applies all twelve fixes offline.
Fix 5 installs two files that live beside it, so run it from a checkout of the
repository rather than copying the script somewhere on its own.
`../pc/pyra-prep-selftest.sh` proves it does that correctly for fixes 1 to 8 against a copy of the
real image, without a Pyra and without touching a card.

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

The "brokenxorg" in the filename is accurate as shipped. Fix 1 in `fixes.md`
is what un-breaks it.

---

## 2. Pre-flight — validate the fixes with no Pyra involved

Do this once the image is extracted, before the card even matters. It costs ten
minutes and turns card-day into a copy-paste job. Two of the three fixes taken
from the original forum post rest on assumptions it never verified.

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

    sudo ./pc/pyra-trixie-prep.sh /mnt/pyra testuser

The script reports what it found for each fix. If anything surprises you, adjust
before committing it to a card.

    sudo umount /mnt/pyra
    sudo losetup -d /dev/loop0

**Or let the self-test do all of the above.** `../pc/pyra-prep-selftest.sh` does the loop-mount, runs the prep script against a *copy* of the
image so the image itself is untouched, and checks the result properly:

    sudo ./pc/pyra-prep-selftest.sh                 # or: ... /path/to/other.img

It snapshots the whole rootfs before and after — type, mode, uid, gid, size and
symlink target for every one of ~148,000 entries — so a stray write anywhere
shows up, not only at the paths someone thought to assert on. It then runs the
prep script a second time and requires the filesystem to be bit-identical, and
finally removes a fix 5 payload to confirm the script aborts *before* fix 1
writes anything. Ends in a single `TEST COMPLETE: PASS` or `FAIL`.

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
    sudo ./pc/pyra-trixie-prep.sh /mnt/pyra yourusername
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

    # the USB3503 warm-reboot rescue is installed and armed
    systemctl is-enabled pyra-usb3503-rescue

On a cold boot it should be `enabled` and its journal should read `hub already
on the USB bus, nothing to do`. It only does work after a warm reboot, so the
real test is a `reboot` followed by checking that the USB devices came back.

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


---

## 7. Optional: set the machine up for development

If you are going to work on this device rather than only use it, three things
save a lot of time, and one script does all three against the mounted card
before you ever boot it:

    sudo ./pc/pyra-devsetup.sh /mnt

It authorises your SSH key for the account, grants that account sudo without a
password, and makes the desktop come up with no login prompt. It also makes
sure the SSH server starts at boot, and turns on mDNS if avahi is installed, so
you can reach the device by name instead of hunting for its address.

**Do it offline, with the card in the reader.** Two of those three are what you
need in order to get in at all, and a freshly written card has neither. Doing
it before first boot avoids needing the access it is meant to grant. A reflash
during this project cost network access to the device for exactly this reason.

Everything it does is reversible:

    sudo ./pc/pyra-devsetup.sh /mnt --undo

**Be clear about the cost.** Passwordless sudo means anything that reaches the
account is root, including something you ran by accident. Autologin means
anyone holding the device is one power button away from the desktop and the
session keyring. An authorised key means whoever holds the private half is in.
These are reasonable on a development handheld on your own desk and
unreasonable on anything else. The script does not touch password
authentication, root login or the firewall, so it never removes a way in that
you already had.

`./pc/pyra-devsetup-selftest.sh` checks all of the above against a synthetic
rootfs in a container, if you would rather not take the script's word for it.

### Doing the autologin part by hand

The image ships a login screen and no autologin. `/etc/lightdm/lightdm.conf.d/`
already carries `90_pyra.conf` with a commented-out `autologin-user=`
placeholder, which is the intended knob. Leave that packaged file alone and add
a drop-in that sorts after it, so a package upgrade never prompts about a
modified conffile:

    sudo tee /etc/lightdm/lightdm.conf.d/99-autologin.conf >/dev/null <<'CONF'
    [Seat:*]
    autologin-user=pyra
    autologin-user-timeout=0
    autologin-session=lightdm-xsession
    CONF
    sudo systemctl restart lightdm

Use the account name the setup script created; `pyra` is the default. The
session name must match a file in `/usr/share/xsessions/`, and
`lightdm-xsession` is the one a normal greeter login uses on this image, so
setting it explicitly reproduces the session you already have rather than
guessing at one. Confirm with `cat ~/.dmrc` before changing it.

No group membership is needed. Debian's `/etc/pam.d/lightdm-autologin` permits
any non-root account, so there is nothing to add to an `autologin` or
`nopasswdlogin` group.

Verify by restarting lightdm rather than by reading the config back. The greeter
should not appear at all:

    pgrep -a lightdm-gtk-greeter || echo "no greeter, as intended"
    loginctl list-sessions          # a seat0 session for the user
    pgrep -a marco mate-panel       # the desktop actually came up

Delete the file to go back to the login screen.

**This removes the password prompt at boot.** On a handheld that is usually the
point, but be clear about what it costs: anyone holding the device is one power
button away from the desktop and everything in the session's keyring. The screen
locker still applies after the session is running. It is not a substitute for
encrypting the card if the data on it matters.

---

## 8. Recommended after the first boot: power behaviour

Two things about this machine's power handling are wrong out of the box, and
what you should do about them depends on whether you are going to build the
patched kernel. Both are covered in detail in `troubleshooting.md`.

**Suspend.** On the stock kernel it cannot complete, and a failed attempt
leaves the desktop frozen behind a working mouse pointer with no way back
except a reboot. Refuse the operation outright rather than trusting a desktop
setting to avoid it:

    sudo systemctl mask sleep.target suspend.target hybrid-sleep.target \
                        suspend-then-hibernate.target hibernate.target

With those masked an idle timeout fails immediately instead of freezing the
session, because nothing starts the service that freezes it.

`patches/0003` fixes the cause, and `reproduce.md` is the path to a kernel
carrying it. On that kernel, unmask all five and test with
`sudo pyra-sleep-test.sh`, which arms the clock to wake the machine by itself
and tells you whether the session really came back.

**Make the screen actually dim.** MATE's own dimming adjusts the keyboard light
rather than the panel, which is why the image ships with it disabled. The
replacement is `pyra-idle-dim`, in the `pyra-backlight` package, which lives in
its own repository and also carries a panel applet for the screen and keyboard
backlights. Build and install it:

    ./build-deb.sh                                   # on the PC, in ~/git/pyra-backlight
    sudo apt install ./pyra-backlight_0.1_all.deb    # on the Pyra
    systemctl --user start pyra-idle-dim.service     # or log out and in

    gsettings set org.mate.session idle-delay 5      # minutes before it dims

The service takes its timing from `idle-delay` and has no timer of its own, so
that one setting controls it. Leave `org.mate.power-manager backlight-enable`
false.

---

## 9. After the repository changes: updating a prepared card

Once the card has booted, `pyra-trixie-prep.sh` is no longer the way to bring
it up to date. That script works on a mounted rootfs, offline, with the card
in a reader, and it is written for a card that has never booted. On a running
card, the device scripts do the same work: prep calls each of them (fixes 6 to
12) to generate its files, so there is one implementation, and on the device
they apply it directly.

Start by seeing what changed since your card was prepared or last updated:

    git log --oneline OLD..HEAD -- device/ pc/pyra-trixie-prep.sh patches/
    git diff --stat OLD..HEAD -- device/ pc/pyra-trixie-prep.sh

`OLD` is the commit you last installed from. Then work down this list in
order, and skip any step whose files did not change.

**1. Get the new `device/` onto the Pyra.** Either `git pull` in a checkout on
the device, or from the workstation:

    ./pc/pyra-push-helpers.sh --dry-run pyra@<address>   # what would change
    ./pc/pyra-push-helpers.sh pyra@<address>

The second form copies `device/` to `~/dragonbox-pyra/device` on the Pyra
(`--no-install` stops there) and runs step 2 for you.

**2. The helpers: `sudo ./pyra-install-helpers.sh`, from `device/`.** Always
safe to re-run. It compares each file with what is installed, reports `same`
for the ones that match and replaces the rest, then re-enables and restarts
its three units (governor, AESS script choice, undervolt) and re-applies the
sysctl settings. `--dry-run` says what it would change first. It installs no
kernel and applies none of the twelve fixes. It does put the fix 6, 7 and 8
scripts on `$PATH`, and it updates fix 5's `pyra-usb3503-rescue` script in
place, because the two share a path.

**3. A fix whose script changed: re-run that script on the device.** Run it
from `device/`, with `--check` first if you want to see the state:

| Fix | Changed file | Re-run with | Re-running it |
|---|---|---|---|
| 5 | `pyra-usb3503-rescue` | step 2 | updated by step 2 |
| 5 | `pyra-usb3503-rescue.service` | `sudo install -m 0644 pyra-usb3503-rescue.service /etc/systemd/system/ && sudo systemctl daemon-reload` | nothing else installs the unit on a running card |
| 6 | `pyra-thermal-fix.sh` | `sudo ./pyra-thermal-fix.sh` | does nothing once applied; see below |
| 7 | `pyra-thermal-ladder.sh` | `sudo ./pyra-thermal-ladder.sh` | does nothing once applied; see below |
| 8 | `pyra-charge-current.sh` | `sudo ./pyra-charge-current.sh` | rewrites its four files, sets the input limit |
| 9 | `pyra-audio-route.sh` | `sudo ./pyra-audio-route.sh` | rewrites its rule and helper, sets the routes |
| 10 | `pyra-greeter-audio.sh` | `sudo ./pyra-greeter-audio.sh` | rewrites its two files |
| 11 | `pyra-sgx-init.sh` | `sudo ./pyra-sgx-init.sh` | rewrites the rule; takes effect when the GPU driver next loads, so at the next boot |
| 12 | `pyra-volumed/` | `sudo ./pyra-volumed/install.sh` | rewrites its three files, rebuilds and restarts the daemon |

Fixes 8 to 12 write their files through the same function that prep's
`--emit-into` uses. Re-running one replaces its files with the current
version, so a change in the repository reaches the card.

**Fixes 6 and 7 are the exception.** They edit the vendor's
`/usr/share/pyra/scripts/pyra-thermal.sh` in place and decide "already
applied" by a marker line, not by comparing with the current version. A newer
version of either change in the repository therefore reports `already
applied, nothing to do` and leaves the old one in place. Prep behaves the same
way offline. To take a new version, undo in the reverse order and apply again:

    sudo ./pyra-thermal-ladder.sh --undo     # back to the file as fix 6 left it
    sudo ./pyra-thermal-fix.sh --undo        # only if fix 6 itself changed
    sudo ./pyra-thermal-fix.sh
    sudo ./pyra-thermal-ladder.sh

`--undo` needs the `.before-pyra-thermal-*` backup beside the vendor file.
Prep and the device scripts both write one the first time they apply.

**Fixes 1 to 4 have no device-side script.** If prep's fixes 1 to 4 change,
put the card in a reader and re-run prep on it, as in section 4. Prep is
idempotent. It finds the user already there and does not ask for a password
again, and it reports what is already in place. Two things to know first.
It re-applies every fix, including fix 12's override. And it does not know
about the `0.38+pyra1` `pyra-hacks` package (`fixes.md`, "Fixes 6, 7 and 12
as a package"), so on a card with that package installed, undo the override
again afterwards with `pyra-volumed/install.sh --undo`.

**4. A kernel change: rebuild and install it.** If `patches/` changed, the
kernel is the only thing that picks it up. Build it on the workstation
(`building.md`), then install it with
`sudo pyra-install-debug-kernel.sh <tarball>` (step 2 put it on `$PATH`), or
in one go with `./pc/pyra-push-kernel.sh --install --reboot`. Re-running the
installer is safe. Its rules, from its header and code:

- It only writes the `l1` entry in `/boot/extlinux/user.cfg`. Other entries
  in that file are kept. The kernel `l1` pointed at before keeps its files in
  `/boot` but no longer has a boot entry.
- It refuses unless `default` in `extlinux.conf` is `l1` or the base kernel
  (`pyra-boot-kernel.sh base`). Run `pyra-boot-kernel.sh stock` first if it
  is neither.
- It will not install over the release that is running unless you pass
  `--replace-running`. A rebuild keeps the same release name, so that is the
  normal case when you update the kernel you boot. The live module tree is
  replaced, so reboot straight afterwards. `pyra-push-kernel.sh` passes the
  flag for you when the names match.
- It builds the initrd for the kernel it installs, with whatever hooks are in
  `/etc/initramfs-tools` at that moment.

Then choose what boots with `pyra-boot-kernel.sh` (section 3 of
`reproduce.md`).

**5. An initramfs hook change: install it and rebuild the initrd for each
kernel.** `device/etc/initramfs-tools/scripts/init-top/pyra-fw-nofallback` is
not installed by anything yet: not by prep and not by step 2. Copying it into
place does not change any existing initrd, so after a copy, rebuild the
initrd of every kernel you boot:

    sudo install -m 0755 pyra-fw-nofallback /etc/initramfs-tools/scripts/init-top/
    sudo update-initramfs -u -k <release>      # once per kernel you boot

`lsinitramfs /boot/initrd.img-<release> | grep nofallback` confirms it.

### What can undo an update

- **A `pyra-hacks` upgrade or reinstall** silently puts the vendor's thermal
  script back, which reverts fixes 6 and 7. Fix 12 survives it, because it
  is a drop-in beside the package rather than an edit to it. The exception is
  a card where that drop-in was removed in favour of the `0.38+pyra1`
  package: there, an archive upgrade also brings back the uncalibrated wheel,
  so re-run `pyra-volumed/install.sh`. After any upgrade that touches
  `pyra-hacks`, run:

      sudo pyra-thermal-fix.sh --check
      sudo pyra-thermal-ladder.sh --check

  If either one reports not applied, run it without `--check`. Nothing does
  this for you yet.
- **A new kernel whose initrd was built before the hook was installed** boots
  without the hook. Check with `lsinitramfs`, as above.
