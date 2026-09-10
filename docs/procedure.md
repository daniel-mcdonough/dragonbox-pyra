# Writing a trixie card for the DragonBox Pyra

The procedure: buy a card, write the image, apply the fixes offline, boot it.
Target is a V5.x Pyra booting live from the left full-size SD slot, with the
eMMC untouched. The kernel is the same 5.6.19-pyradef that bookworm-7 uses.

Status: **working.** The card boots to a MATE desktop, hardware GLES2 runs on
the SGX, all the on-board hardware checks out, and the rootfs fills the card.
lightdm starts, the greeter renders on the panel, and the unit is reachable over
SSH as `pyra`.

Five fixes are needed, and `fixes.md` explains each one. Two of them are not in
the original forum writeup: fix 4 supersedes fix 1, because the documented DRI
symlink does not work on mesa 25.x and never could, and fix 5 keeps USB alive
across a warm reboot.

Companion script: `../pyra-trixie-prep.sh`. It applies all five fixes offline.
Fix 5 installs two files that live beside it, so run it from a checkout of the
repository rather than copying the script somewhere on its own.
`../pyra-prep-selftest.sh` proves it does that correctly against a copy of the
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

**Or let the self-test do all of the above.** `../pyra-prep-selftest.sh` does the loop-mount, runs the prep script against a *copy* of the
image so the image itself is untouched, and checks the result properly:

    sudo ./pyra-prep-selftest.sh                 # or: ... /path/to/other.img

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

## 7. Optional: log straight into the desktop

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
