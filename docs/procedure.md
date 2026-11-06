# Writing a trixie card for the DragonBox Pyra

> **Type: instructions.** Steps to follow.

The procedure: buy a card, write the image, apply the fixes offline, boot it.
Target is a V5.x Pyra booting live from the left full-size SD slot, with the
eMMC untouched. The card boots the shipped kernel, `5.6.19-m4-kbdled`, which
prep installs (fix 19); the image's own 5.6.19-pyradef, the kernel bookworm-7
uses, stays on the card as the fallback.

Status: **working.** The card boots to a MATE desktop, hardware GLES2 runs on
the SGX, all the on-board hardware checks out, and the rootfs fills the card.
lightdm starts, the greeter renders on the panel, and the unit is reachable over
SSH as `pyra`.

Twenty-three fixes are needed, and `fixes.md` explains each one. Most of them are not
in the original forum writeup: fix 4 supersedes fix 1, because the documented
DRI symlink does not work on mesa 25.x and never could; fix 5 keeps USB alive
across a warm reboot; fix 6 makes the thermal daemon able to apply a frequency
cap at all; fix 7 corrects the ladder it applies, which throttles on the
fuel gauge's die temperature and can overwrite its own deeper cap; fixes 8
to 12 cover charging, sound, the greeter holding the sound card, GL on every
boot, and the volume wheel; fix 13 makes Qt5 programs draw, fix 14 stops
root mounting a minute or two late, fix 15 makes the Fn keyboard-light keys
work on the shipped kernel, fix 16 sets the measured governor tunable at
boot, fix 17 gives PulseAudio the script that matches the kernel's audio
path at each boot, fix 18 puts the keyboard's manual rescue on the path, and
fix 19 installs the shipped kernel and makes it what the card boots, fix 20
keeps MATE from taking the keyboard light over on battery, fix 21 stops the
SGX driver closing a descriptor twice, which can corrupt a game's saves, and
fix 22 installs a brightness applet and an idle dimmer that reach the screen,
and fix 23 removes the ssh host keys and machine-id every vendor card shares.

Companion script: `../pc/pyra-trixie-prep.sh`. It applies all twenty-three fixes offline.
Several fixes install files from `device/`, so run it from a checkout of the
repository rather than copying the script somewhere on its own. It needs the
card's boot partition mounted at the rootfs's `/boot`, and, on a PC that is not
armhf, qemu-user with binfmt: fixes 14, 19, 20 and 22 run the image's own tools in a
chroot (`fixes.md`). It checks both before writing anything.
`../pc/pyra-prep-selftest.sh` proves it does that correctly for fixes 1 to 8 and 13 to 23 against a copy of the
real image, without a Pyra and without touching a card. The image must hash to the vendor's pinned SHA-256
(`pc/pyra-vendor-image.sh`); the self-test refuses any other, and unpacks a fresh one from the `.7z` when there
is none.

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

    cd dragonbox-pyra                 # your checkout of this repository
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
    sudo mount /dev/loop0p1 /mnt/pyra/boot         # fix 14 rebuilds the initrds here

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

    sudo ./pc/pyra-trixie-prep.sh --no-kernel /mnt/pyra testuser

(or `--kernel FILE` in place of `--no-kernel`, step 4). The script reports what it found for each fix. If anything surprises you, adjust
before committing it to a card.

    sudo umount /mnt/pyra/boot /mnt/pyra
    sudo losetup -d /dev/loop0

**Or let the self-test do all of the above.** `../pc/pyra-prep-selftest.sh` does the loop-mount, runs the prep script against a *copy* of the
image so the image itself is untouched, and checks the result properly:

    sudo ./pc/pyra-prep-selftest.sh                 # or: ... /path/to/other.img

It mounts p1 at the rootfs's `/boot`, as prep needs, and snapshots both
partitions before and after — type, mode, uid, gid, size and symlink target for
every one of ~148,000 entries — so a stray write anywhere shows up, not only at
the paths someone thought to assert on. It reads each rebuilt initrd with the
image's own `lsinitramfs` for fix 14. It then runs the prep script a second
time and requires every entry to be unchanged, with no initrd rebuilt, and
finally removes a fix 5 payload to confirm the script aborts *before* fix 1
writes anything. For fix 19 it hands prep the cross-build's
`m4-kbdled-kernel.tar.gz` (`PYRA_KERNEL_TARBALL` names another). Without one it
runs prep with `--no-kernel`, and the verdict says the kernel install was
skipped. For fix 22 it lets prep download the pinned pyra-backlight release
(network) and checks that the download matched; `PYRA_BACKLIGHT_DEB` names a
`.deb` to pass with `--backlight` instead, and `PYRA_BACKLIGHT_DEB=none` runs
prep with `--no-backlight` and counts a skip. It also makes two small `.deb`s, another
package and a `pyra-backlight` with a dependency no image has, and requires
each to stop prep before fix 1 writes. Ends in a single `TEST COMPLETE: PASS` or `FAIL`.

Note: if you ran the prep script by hand above, the image file itself is now
prepared, with the user you named and the initrds rebuilt. You can `dd` *that*
to the card and skip step 4 entirely — but re-running the script on the card is
harmless (it's idempotent) and confirms it applied. The self-test only ever
changes its copy, `pyra-trixie-t1-preptest.img`.

---

## 3. Write the card

Identify it first, and actually read the output before typing anything:

    lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT

With `/dev/sdX` replaced by the **whole card device**, not a partition:

    sudo umount /dev/sdX?* 2>/dev/null
    sudo dd if=pyra-trixie-*.img of=/dev/sdX bs=4M status=progress conv=fsync
    sync

### Or: build a prepared image and write that

Sections 3 and 4 can be done the other way round: prep an image file on the PC,
then write the finished image to the card. That also lets the card be written on
another machine, the one with the reader.

    sudo ./pc/pyra-image-build.sh                # on the PC: vendor .7z + prep -> images/
    ./pc/pyra-image-push.sh [IMAGE] [user@host]  # copy it, and the write script, to the reader machine
    cd ~/pyra-images && sudo ./pyra-image-write.sh IMAGE /dev/sdX   # there

- **Build.** `pyra-image-build.sh` unpacks the vendor `.7z` itself and checks
  both the archive and the unpacked image against pinned SHA-256s, so the result
  never starts from an image that was mounted or booted. By default it runs prep
  with `--grow-on-boot --set-password --kernel <m4-kbdled tarball>` for the
  `pyra` user, which asks for the password. Options after `--` replace those.
  An image to share is
  `sudo ./pc/pyra-image-build.sh -- --release --grow-on-boot --kernel <tarball>`
  (section 4, "An image to share"). One built that way was written and booted
  on a Pyra on 2026-11-01.
  Output goes to `../dragonbox-pyra-build/images/`: the image, a `.sha256`, and
  an `.info` with the repository commit and prep options.
- **Push.** `pyra-image-push.sh` rsyncs the image to `PYRA_WRITER` (or the host
  given) and checks the checksum there. `PYRA_WRITER` can live in
  `pyra-local.conf`; copy `pyra-local.conf.example` to start one.
- **Write.** `pyra-image-write.sh` refuses a partition, a non-removable disk, the
  disk holding `/`, and anything mounted. It shows what is on the card, warns if
  that is already a Pyra system, and asks for the device name to be typed. It
  writes with direct I/O, then reads the card back with direct I/O and requires
  the same SHA-256.

With that route, skip section 4 and go to section 5.

---

## 4. Apply the fixes, before first boot

The wizard bug (fix 2) powers the unit off seconds after boot, so fixing this
from a half-booted device is a chicken-and-egg fight worth skipping entirely.

    sudo partprobe /dev/sdX
    sudo blkid /dev/sdX1 /dev/sdX2        # p2 is the f2fs rootfs
    sudo modprobe f2fs
    sudo mount /dev/sdX2 /mnt/pyra
    sudo mount /dev/sdX1 /mnt/pyra/boot
    sudo ./pc/pyra-trixie-prep.sh /mnt/pyra yourusername
    sudo umount /mnt/pyra/boot /mnt/pyra && sync

The script prompts for a password (hidden, entered twice) and is idempotent —
re-running it is safe and just reports what is already in place. Fix 14
rebuilds each initrd under qemu the first time, which took under a minute on
an x86 PC for the stock image's one kernel.

**The user.** Pick a name the image doesn't have. The image already has a
`pyra` account, and its password isn't documented. If you name `pyra`, or any
other existing user, prep leaves that password alone unless you add
`--set-password`, which asks for a new one the same way. `--ssh-key
~/.ssh/yourkey.pub` authorises one public key for the user, so the first boot
can be reached over ssh (only the key type and key are written, not the
comment). It refuses a private key. Both options are off unless you ask.

**Growing on the first boot.** `--grow-on-boot` makes the card grow its rootfs
to fill itself on its first boot, from the initramfs, after a capacity check and
a read-only fsck. Without it, grow the card from the PC afterwards, as below.
It takes about 10 minutes on a 256 GB card; do not switch off. `grow-rootfs.md` has the details.

**An image to share (`--release`).** `--release` prepares an image to give to
other people rather than a card of your own, and asks nothing. The `pyra` user
gets the password `pyra`, expired, so the first login (the greeter, a console or
ssh) makes the user choose a new one before going on. Fix 23 removes the ssh
host keys and empties `/etc/machine-id` whatever they are, not only the
vendor's, and release mode also deletes systemd's random seed and credential
secret, so no two cards written from the image share them. It refuses `--set-password`, `--ssh-key`, a user other
than `pyra`, and an image that already has an authorised ssh key or a
`NOPASSWD` sudo rule for all commands: start from the vendor image. The
vendor's own `/etc/sudoers.d/pyrainput` (`pyrainputctl` without a password, for
the `sudo` group) stays. Asserted by
`pc/pyra-prep-selftest.sh`, and booted on a Pyra on 2026-11-01. With
`--grow-on-boot` on a 256 GB card, the greeter appeared about 11 minutes after
power-on, because the grow runs first. The forced change works at the greeter
and over ssh. A key login still has to change the password, so it needs
`ssh -t`: without a terminal, sshd refuses with `Password change required but no
TTY available`.

**The vendor image's ssh host keys (fix 23).** The vendor image ships its ssh
host keys and machine-id, the same on every card written from it, so anyone
with another card could pose as yours on the network. Prep removes them, and
the card makes its own on its first boot: `pyra-ssh-hostkeys.service` runs
`ssh-keygen -A` before sshd, and systemd writes a new machine-id. It masks
`systemd-firstboot`, which the empty machine-id would otherwise start with
console prompts. Prep removes only the vendor's, so re-running it on a card
that has booted keeps the card's own. If your PC has talked to another Pyra at
the same address, it warns once that the host key changed; that is expected.

A card prepared before fix 23 still has the vendor's. Make new ones once it is
up:

    sudo rm /etc/ssh/ssh_host_* && sudo ssh-keygen -A && sudo systemctl restart ssh

**The kernel (fix 19).** The script offers to download the shipped kernel,
`m4-kbdled-kernel.tar.gz` from the project's `kernel-*` release, and installs it
only if it matches the SHA-256 pinned in the script. To use a tarball you
already have, downloaded or built with `./pc/pyra-crossbuild.sh kernel-m4-kbdled`
(`building.md`), name it:

    sudo ./pc/pyra-trixie-prep.sh --kernel m4-kbdled-kernel.tar.gz /mnt/pyra yourusername

Until a release is pinned in the script there is nothing to download, and a run
without `--kernel` stops before writing anything. `--no-kernel` prepares a card
that boots the stock `5.6.19-pyradef`, with every other fix in place. The card
boots the shipped kernel from `l5` and keeps the stock one as `l0`. If it does
not come up on the new kernel, `troubleshooting.md`, "The card does not boot
after prep installed the kernel", switches it back from the PC.

**Brightness (fix 22).** The script installs `pyra-backlight`, the brightness
applet and idle dimmer (§8), with the image's own `dpkg`. Before writing
anything it checks that the image has every package the `.deb` depends on. The
vendor image lacks one, `gir1.2-matepanelapplet-4.0`: prep adds Debian's build
of it, pinned by SHA-256, from a copy beside the pyra-backlight `.deb` or else
from `deb.debian.org` (`fixes.md`, fix 22). With no option it
downloads the `.deb` from pyra-backlight's release and installs it only if it
matches the SHA-256 pinned in the script (v0.2). To use a `.deb` you already
have, downloaded or built with pyra-backlight's `./build-deb.sh`, name it:

    sudo ./pc/pyra-trixie-prep.sh --kernel m4-kbdled-kernel.tar.gz --backlight pyra-backlight_0.2_all.deb /mnt/pyra yourusername

`--no-backlight` leaves it out.

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

    # the shipped kernel (fix 19), and what boots next
    uname -r                                 # 5.6.19-m4-kbdled
    sudo pyra-boot-kernel.sh status          # next boot and base: l5
    cat /etc/modprobe.d/pyra-m4-noautoboot.conf

`status` prints the running kernel and three lines, `next boot`, `base kernel`
and `one-shot revert : disarmed`, the first two naming `l5`. The last file
should end in `blacklist omap_remoteproc`. A card prepared with `--no-kernel`
reads `5.6.19-pyradef`, and `l0` as the base.

    # the stock kernel is still there as the fallback
    grep -A2 '^label l0$' /boot/extlinux/linux.cfg   # linux /vmlinuz-5.6.19-pyradef

    # root: the whole card, mounted promptly, no filesystem errors
    df -h /                                  # about the card's size if it was grown
    systemd-analyze                          # "(kernel)" well under 15 s
    sudo dmesg | grep -i f2fs

The `dmesg` lines should be `Found nat_bits`, `recover fsync data on readonly
fs` (normal: root is mounted read-only first) and `Mounted with checkpoint
version`, and nothing else. A `(kernel)` time near a minute or more is the late
root mount fix 14 is for (`troubleshooting.md`, "Root mounts a minute or two
late").

    # the SGX window system no longer closes a descriptor twice (fix 21)
    sudo pyra-wsegl-fdfix.sh status          # /usr/lib/libpvrDRI3WSEGL.so: fixed

The second line, `/usr/lib/libpvrDRI3WSEGL.so.stock: stock`, is the vendor's
file, kept for `sudo pyra-wsegl-fdfix.sh rollback`. `stock` on the first line
after a package run means the guard that re-patches it is missing or was
skipped (`fixes.md`, fix 21); after a rollback, a third line says so.

    # nubs, keyboard, gamepad
    systemctl status pyrainput
    grep -h pyraInput /sys/class/input/input*/name

You should get three pyraInput devices: keyboard, Gamepad, Mouse. They are
virtual devices with no `/dev/input/by-path` link, so grepping by-path for
`pyra` finds the two platform devices (`pyra-game-buttons`, `pyra-lid-wakeup`)
instead.

    # the USB3503 warm-reboot rescue is installed and armed
    systemctl is-enabled pyra-usb3503-rescue

On a cold boot it should be `enabled`, and `sudo journalctl -b -u
pyra-usb3503-rescue` should read `hub already on the USB bus, nothing to do`
(without `sudo` the journal shows only your own messages, so it says `No
entries`). It only does work after a warm reboot, so the
real test is a `reboot` followed by checking that the USB devices came back.

    # the governor setting (fix 16) was applied at boot
    /usr/local/sbin/pyra-governor-tune.sh --check

The first line should read `sampling_down_factor : 10` and the last `applied.`.
`systemctl status pyra-governor-tune` should be `active (exited)`.

    # PulseAudio got the script that matches the kernel (fix 17)
    /usr/local/sbin/pyra-audio-select.sh --check

The last line should be `ok`. On the stock `5.6.19-pyradef` it reads `path
direct` and the packaged `/etc/pulse/pyra.pa`; on `5.6.19-m4-kbdled`, `path
aess` and `/etc/pulse/pyra-aess.pa`. A `MISMATCH` line means the session's
sound is the dummy output: `audio.md`, "Two paths, chosen by the kernel".

    # X server came up
    grep -E 'AIGLX|GLX|\(EE\)' /var/log/Xorg.0.log

With fix 4 applied the only GLX-related line should be:

    (**) Extension "GLX" is disabled

There should be **no** `AIGLX` lines at all, and no `Segmentation fault` /
`Caught signal 11`. An AIGLX line reappearing means fix 4 is not in effect.

    # the extensions that matter are still there (as the user logged in on :0)
    DISPLAY=:0 xdpyinfo | grep -E 'DRI2|DRI3|Present'

`DRI3` and `Present` must both be listed. Those are what the SGX blob's window
integration uses; `GLX` is deliberately absent.

    # hardware GLES2 through the SGX blob; copy device/pyra-gles2-smoke.c
    # from this repository to the card first. The image's package lists are
    # months old, so refresh them before any install or the fetch 404s.
    sudo apt-get update
    sudo apt-get install libx11-dev
    gcc -O2 -o gles2-smoke pyra-gles2-smoke.c \
        -I/opt/omap5-sgx-ddk-um-linux/include \
        -L/opt/omap5-sgx-ddk-um-linux/lib -lEGL -lGLESv2 -lX11
    sudo env DISPLAY=:0 XAUTHORITY=/var/run/lightdm/root/:0 ./gles2-smoke

Check with `ldd` that it picked up `/opt/omap5-sgx-ddk-um-linux/lib/libEGL.so.1`
and not the mesa one in `/usr/lib/arm-linux-gnueabihf`. A dozen
`WSEGL_GetDrawableParameters: Buffer busy, waiting` lines at the start are the
blob's own chatter and harmless.

Measured on the fixed card:

    DRI3 1.0
    present 1.2
    EGL_VENDOR   Imagination Technologies
    GL_RENDERER  PowerVR SGX 544MP
    GL_VERSION   OpenGL ES 2.0 build 1.14@3699939 (MAIN)
    7073 frames in 5.00 s = 1414 fps   (clear + swap, 320x240, vsync off)
    (1392 fps on a fix 19 card, m4-kbdled, 2026-10-30)

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

## 7. Optional: set the machine up for development

If you are going to work on this device rather than only use it, three things
save a lot of time, and one script does all three against the mounted card
before you ever boot it:

    sudo ./pc/pyra-devsetup.sh --user yourusername /mnt/pyra

It authorises your SSH key for the account, grants that account sudo without a
password, and makes the desktop come up with no login prompt. It also makes
sure the SSH server starts at boot, and turns on mDNS if avahi is installed, so
you can reach the device by name instead of hunting for its address.

**Do it offline, with the card in the reader.** Two of those three are what you
need in order to get in at all, and a freshly written card has neither. Doing
it before first boot avoids needing the access it is meant to grant. A reflash
during this project cost network access to the device for exactly this reason.

Everything it does is reversible:

    sudo ./pc/pyra-devsetup.sh --user yourusername /mnt/pyra --undo

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
what you should do about them depends on which kernel the card runs: the
shipped one that prep installs (fix 19), or the stock one (`--no-kernel`, or
back on `l0`). Both are covered in detail in `troubleshooting.md`.

**Suspend.** On the stock kernel it cannot complete, and a failed attempt
leaves the desktop frozen behind a working mouse pointer with no way back
except a reboot. Refuse the operation outright rather than trusting a desktop
setting to avoid it:

    sudo systemctl mask sleep.target suspend.target hybrid-sleep.target \
                        suspend-then-hibernate.target hibernate.target

With those masked an idle timeout fails immediately instead of freezing the
session, because nothing starts the service that freezes it.

`patches/0003` fixes the cause, and the shipped kernel, `5.6.19-m4-kbdled`,
carries it. Prep installs it (fix 19); `uname -r` says which one you are on. On
that kernel, unmask all five and test with
`sudo pyra-sleep-test.sh`, which arms the clock to wake the machine by itself
and tells you whether the session really came back.

**Make the screen actually dim.** The image ships MATE's own screen dimming
off (`org.mate.power-manager backlight-enable false`), because on the stock
`5.6.19-pyradef` it adjusts the keyboard light rather than the panel. On
`5.6.19-m4-kbdled` it would reach the panel: the keyboard light is an LED there,
`/sys/class/backlight` holds only the panel, and switching the setting on set
the panel to MATE's 30 % idle level within a second (measured 2026-10-29). The
documented path is still `pyra-idle-dim`, in the `pyra-backlight` package,
which lives in its own repository (https://github.com/daniel-mcdonough/pyra-backlight) and also carries a panel applet for the
screen and keyboard backlights. Prep installs it (fix 22, step 4), with
`pyra-idle-dim.service` enabled for every user; add the applet with
right-click on the panel, *Add to Panel…*, *Pyra Brightness*. Set how long
before it dims:

    gsettings set org.mate.session idle-delay 5      # minutes before it dims

On a card prepared without it, download the `.deb` from its release on the
Pyra and install it:

    wget https://github.com/daniel-mcdonough/pyra-backlight/releases/download/v0.2/pyra-backlight_0.2_all.deb
    sudo apt install ./pyra-backlight_0.2_all.deb
    systemctl --user start pyra-idle-dim.service     # or log out and in

or build it yourself on the PC:

    git clone https://github.com/daniel-mcdonough/pyra-backlight.git
    cd pyra-backlight && ./build-deb.sh              # makes dist/pyra-backlight_0.2_all.deb
    sudo apt install ./pyra-backlight_0.2_all.deb    # on the Pyra, after copying it over
    systemctl --user start pyra-idle-dim.service     # or log out and in

The service takes its timing from `idle-delay` and has no timer of its own, so
that one setting controls it. Leave `org.mate.power-manager backlight-enable`
false, or the two dim the panel at once. With it false, the brightness slider in
*Power Management Preferences* and MATE's own *Brightness Applet* do nothing;
use the Pyra Brightness applet instead.

**The keyboard light on `5.6.19-m4-kbdled`.** MATE's power manager drives it
through UPower, and with MATE's defaults it takes it over on battery: at each
power change it sets half of its own 100 %, dims that by 75 % when idle, and
puts its 50 % back at the next touch, so a level set with the Fn keys (fix 15)
or the applet would last until the next idle period. Prep's fix 20 sets
`org.mate.power-manager kbd-backlight-battery-reduce` false by default, which
switches all of that off. On AC MATE leaves the light alone already
(`idle-dim-ac` is false). Measured 2026-10-31 on a prepared card, with the
setting false: a level set with the keys stayed through unplugging, 60 s idle,
a touch, a key press and plugging back in. The one reset left is at login on
AC, when MATE starts and sets 100 %.

Two checkboxes in MATE's Power Management preferences hand the light back to
MATE. On the battery tab, "Reduce keyboard backlight brightness" is
`kbd-backlight-battery-reduce`, which fix 20 leaves unticked. On the AC tab,
"Dim display when idle" (`idle-dim-ac`) also dims the keyboard light on AC,
which the label doesn't say. With either ticked, MATE dims the light when idle
and on the next touch puts back its own level (100 % on AC, 50 % on battery),
not the one you set with the keys (measured 2026-10-31). MATE has no setting
that makes it restore your level.

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
its three units (governor, AESS script choice, undervolt), re-applies the
sysctl settings, points the Fn keyboard-light keys at `pyra-kbdlight.sh` and
reloads `pyrainput`, and rebuilds any initrd that lacks the initramfs hooks
(step 5). `--dry-run` says what it would change first. It installs no kernel,
and of the twenty-three fixes it applies only 13 to 18 and 20, whose files it shares
with prep (fix 19's two kernel scripts it puts on `$PATH` too). It does put the fix 6, 7 and 8 scripts
on `$PATH`, and it updates fix 5's `pyra-usb3503-rescue` script in
place, because the two share a path. It installs fix 21's script and its dpkg
guard but does not patch the library; `sudo pyra-wsegl-fdfix.sh install` does.

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
| 13 | `pyra-gles` | step 2 | updated by step 2, which installs it at the same path |
| 14 | an init-top hook | step 2 | updated by step 2, which rebuilds each initrd that needs it (step 5) |
| 15 | `pyra-kbdlight.sh` | step 2 | updated by step 2, which also writes its two `/etc/pyrainput.cfg` lines |
| 16 | `pyra-governor-tune.sh` or its unit | step 2 | updated by step 2, which restarts the unit, so the value is re-applied |
| 17 | `pyra-audio-select.sh`, its unit or a `pulse/` file | step 2 | updated by step 2, which also makes the `daemon.conf.d` link and restarts the unit; a running PulseAudio keeps its script until `systemctl --user restart pulseaudio.service` |
| 18 | `pyra-keypad-rescue` | step 2 | updated by step 2, which installs it at the same path |
| 21 | `pyra-wsegl-fdfix.sh` or `pyra-wsegl-guard` | step 2, then `sudo pyra-wsegl-fdfix.sh install` | says `already patched` once applied; a new patch would come with new SHA-256s |

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
(`./pc/pyra-crossbuild.sh kernel-m4-kbdled`, `building.md`), then install it with
`sudo pyra-install-debug-kernel.sh <tarball>` (step 2 put it on `$PATH`), or
in one go with `./pc/pyra-push-kernel.sh --install --reboot`. Re-running the
installer is safe. Its rules, from its header and code:

- It only writes the `l1` entry in `/boot/extlinux/user.cfg`, or the one
  `--slot LABEL` names (`building.md`, "Boot slots"). Other entries in that
  file are kept. The kernel the slot pointed at before keeps its files in
  `/boot`, and loses its boot entry unless another entry also boots it.
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

**5. An initramfs hook change: step 2 does it.** The two hooks in
`device/etc/initramfs-tools/scripts/init-top/`, `pyra-fw-nofallback` and
`pyra-settle-nudge` (`troubleshooting.md`, "Root mounts a minute or two late",
shapes B and A), are in `pyra-install-helpers.sh`'s map. Copying a hook changes
no existing initrd, so the helper then rebuilds, with `update-initramfs -u -k`,
every `/boot/initrd.img-<release>` that does not list both hooks or is older
than either installed one. It reports `same` for the rest, so a second run
rebuilds nothing. Each rebuild took about 20 s on the trixie card (measured
2026-10-29, four rebuilds in one 84 s run), and the helper checks `/boot` has
room for it first. A kernel installed later gets the hooks from `pyra-install-debug-kernel.sh`, which builds its initrd with
whatever is in `/etc/initramfs-tools`. Prep installs the same hooks and
rebuilds the same initrds as fix 14, so a newly prepared card already has
them. To check one initrd by hand:

    lsinitramfs /boot/initrd.img-<release> | grep -e nofallback -e nudge

### What can undo an update

- **A `pyra-hacks` upgrade, downgrade or reinstall** puts the vendor's
  thermal script back, which reverts fixes 6 and 7. A prepared card carries a
  dpkg hook for this (`/etc/dpkg/dpkg.cfg.d/pyra-thermal-guard`): after every
  package run it re-applies both and prints
  `pyra-thermal-guard: ... re-applied fixes 6 and 7`, or, if the new vendor
  file is one the fixes don't recognise, changes nothing and prints a
  `THE THERMAL FIXES ARE NOT APPLIED` banner on every package run until it is
  dealt with. A card prepared before the hook existed gets it from step 2
  (`pyra-install-helpers.sh`). The hook leaves alone a fix you undid with
  `--undo`, because the undo deletes the backup it keys on. Fix 12 survives
  an upgrade by itself, because it is a drop-in beside the package rather
  than an edit to it. The exception is a card where that drop-in was removed
  in favour of the `0.38+pyra1` package: there, an archive upgrade also
  brings back the uncalibrated wheel, so re-run `pyra-volumed/install.sh`.
  The hook does not watch fix 12.
- **A `dri3wsegl-pyra` reinstall or upgrade** puts the stock
  `libpvrDRI3WSEGL.so` back, which reverts fix 21. A second dpkg hook
  (`/etc/dpkg/dpkg.cfg.d/pyra-wsegl-guard`) re-patches it after the package
  run and prints `pyra-wsegl-guard: ... re-applied fix 21`; programs already
  running keep the stock build until they restart. A newer package is a build
  the fix does not know: the hook changes nothing and prints a
  `FIX 21 IS NOT APPLIED` banner on every package run. It leaves alone a card
  you rolled back with `sudo pyra-wsegl-fdfix.sh rollback`, and a card where
  the fix was never applied. A card prepared before the hook existed gets it
  from step 2, which installs it but does not patch.
- **A new kernel whose initrd was built before the hook was installed** boots
  without the hook. Check with `lsinitramfs`, as above; step 2 rebuilds it.
