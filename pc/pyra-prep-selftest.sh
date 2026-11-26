#!/usr/bin/env bash
# Validate pyra-trixie-prep.sh against the real trixie image, loop-mounted.
#
#   sudo ./pc/pyra-prep-selftest.sh [/path/to/pyra-trixie-t1.img]
#
# The image must be the vendor's exactly: its SHA-256 is checked against the
# pin in pyra-vendor-image.sh, and a mismatch stops the test, because an image
# that was once mounted read-write or prepped hides what prep itself changes.
# With no image argument and no pyra-trixie-t1.img at the top of the
# repository, it is unpacked from the vendor .7z (archive checked too). Runs on
# a COPY, so the image itself stays pristine for the next run. Snapshots the whole rootfs before and after, so an unexpected write
# anywhere in the tree cannot go unnoticed. Then runs the prep script, asserts
# the end state of fixes 1 to 33 (fix 2 with --set-password and
# --ssh-key, fix 14 with --grow-on-boot), runs it a second time and requires the
# filesystem to be unchanged, checks that fix 23 keeps a card's own host keys
# and machine-id (and removes a vendor key mixed in with them), checks that a missing fix 5 payload and an
# unknown driver library (fix 21) each abort before fix 1 writes anything,
# fires fix 21's dpkg guard with the image's own dpkg (it must re-patch after a
# reinstall, leave a rolled-back card stock, and warn about an unknown build
# without touching it), fires fix 26's wheel guard with a downgrade to the
# vendor's pyra-hacks and a return to the fork, fires fix 29's input guard the
# same way with the vendor's funkeymonkey-pyrainput, and finally runs --release twice on the same
# image: what it refuses (writing nothing), the release end state (no password,
# the first boot asks for one, no host keys and an empty machine-id even where the card's
# own were kept, no prompts, no NOPASSWD rule for all commands, systemd-firstboot
# masked), idempotency, the image's sshd -t before and after ssh-keygen -A, and
# fix 33's password step with the image's chpasswd.
#
# Fix 19 installs the shipped kernel from a tarball. The image carries only the
# stock kernel, so the test hands prep the cross-build's output
# (PYRA_BUILD_DIR/kernel/m4-kbdled-kernel.tar.gz, by default in
# dragonbox-pyra-build beside the repository; PYRA_KERNEL_TARBALL names another).
# Without one, it downloads the release prep pins (network), checks it against
# prep's SHA-256 and hands prep that. Prep has no kernel-less run to fall back
# on, so the runs that only test an abort take the same tarball.
#
# Fix 22 installs pyra-backlight: with PYRA_BACKLIGHT_DEB unset, prep downloads
# the pinned release (network) and the run checks that it matched; a path there
# is passed as --backlight; PYRA_BACKLIGHT_DEB=none runs prep with
# --no-backlight, and that is a SKIP too. The image lacks
# gir1.2-matepanelapplet-4.0, which prep downloads (pinned) unless a copy sits
# beside that .deb. A .deb that is not
# pyra-backlight, and one whose dependency the image lacks, are made here and
# must each stop prep before fix 1 writes anything.
#
# Fix 26 installs pyra-settings and the pyra-hacks fork: PYRA_SETTINGS_DEB names
# the pyra-settings .deb (--settings). Unset, prep downloads the pinned release
# if there is one; while none is pinned, and with PYRA_SETTINGS_DEB=none
# (--no-settings), nothing is installed and that is a SKIP. The fork is
# downloaded (pinned) unless a copy sits beside that .deb. A .deb that is not
# pyra-settings, and --settings with --no-backlight, must each stop prep before
# fix 1 writes anything.
#
# Fix 27 installs pyra-sound: PYRA_SOUND_DEB names a .deb (--sound); unset,
# prep downloads the pinned release (network); PYRA_SOUND_DEB=none runs prep
# with --no-sound, and that is a SKIP. A .deb that is not pyra-sound, one whose
# dependency the image lacks, and (with PYRA_SOUND_DEB unset) a copy of prep
# whose pin the download does not match must each stop prep before fix 1
# writes anything.
#
# Fix 29 installs the rebuilt funkeymonkey-pyrainput: PYRA_PYRAINPUT_DEB names a
# .deb (--pyrainput); unset, the cross-build's output
# (PYRA_BUILD_DIR/pyrainput/funkeymonkey-pyrainput_<version>_armhf.deb, from
# ./pc/pyra-crossbuild.sh pyrainput) if there is one, else prep downloads the
# pinned release (network); PYRA_PYRAINPUT_DEB=none runs prep with
# --no-pyrainput, and that is a SKIP. A .deb that is not funkeymonkey-pyrainput,
# and one that is not a +pyra build, must each stop prep before fix 1 writes.
# Its guard is fired by a real downgrade to the vendor's 0.1.19 deb
# (PYRA_PYRAINPUT_VENDOR_DEB, by default the package archive beside the
# repository, with its pinned SHA-256), which has no unit, and a return.
#
# Fix 21's guard is fired by a real reinstall of the vendor's dri3wsegl-pyra 0.4
# deb when PYRA_WSEGL_DEB (by default the package archive beside the
# repository) holds it with the pinned SHA-256. Without it, the stock library
# is written back by hand and an empty dpkg run fires the same hook; the log
# says which.
#
# Fix 26's wheel guard is fired by a real downgrade to the vendor's pyra-hacks
# 0.38 deb, from PYRA_HACKS_VENDOR_DEB (by default the package archive beside
# the repository) with the pinned SHA-256, and a return to the fork (beside
# PYRA_SETTINGS_DEB, or the pinned release). Without either, that is a SKIP.
#
# Leaves its snapshots, diffs and logs in a directory it names on the way out;
# set OUTDIR to choose one.

set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# This script lives in pc/. The image and the working copy sit at the top of
# the repository, and the fix 5 payloads live with the rest of the device
# files, so neither is simply "beside this script".
ROOT=$(cd -- "$REPO/.." && pwd)
PAYLOADS=$ROOT/device
IMG=${1:-$ROOT/pyra-trixie-t1.img}
TOP=$ROOT
# shellcheck source=pyra-vendor-image.sh
. "$REPO/pyra-vendor-image.sh"
WORK=$ROOT/pyra-trixie-t1-preptest.img
PREP=$REPO/pyra-trixie-prep.sh
OUT=${OUTDIR:-}
MNT=$(mktemp -d /tmp/pyraprep.XXXXXX)
BUILD_DIR=${PYRA_BUILD_DIR:-$(cd -- "$ROOT/.." && pwd)/dragonbox-pyra-build}
KTAR=${PYRA_KERNEL_TARBALL:-$BUILD_DIR/kernel/m4-kbdled-kernel.tar.gz}
KREL=5.6.19-m4-kbdled
KSLOT=l5
BDEB=${PYRA_BACKLIGHT_DEB:-}
SDEB=${PYRA_SETTINGS_DEB:-}
SODEB=${PYRA_SOUND_DEB:-}
PIDEB=${PYRA_PYRAINPUT_DEB:-}

PASS=0; FAIL=0; SKIP=0; ABORTED=0; BANNERED=0
SKIPPED=()
p() { printf '\e[32mPASS\e[0m  %s\n' "$*"; PASS=$((PASS+1)); }
f() { printf '\e[31mFAIL\e[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
i() { printf '\e[36m----\e[0m  %s\n' "$*"; }

# A silent exit must never read as a pass -- the verify-card-capacity.sh lesson.
# But exactly ONE banner may ever be printed, from the EXIT path, so a run can
# never emit two contradictory verdicts. The ERR trap only records the abort.
#
# An ERR trap fires whether or not errexit is set, so it must be DISARMED around
# any command whose failure is a legitimate outcome, not merely wrapped in
# `set +e`. arm/disarm below; five places need it.
#
# They flip a flag the trap reads rather than setting and clearing the trap:
# without errtrace, bash puts the ERR trap back when a function returns, so a
# `trap - ERR` inside disarm() was undone on the spot and disarm did nothing.
ERR_ARMED=0
trap '[[ $ERR_ARMED -eq 1 ]] && { ABORTED=1; printf "\e[31m!!!!\e[0m  unexpected error at line $LINENO\n" >&2; }; true' ERR
arm()    { ERR_ARMED=1; }
disarm() { ERR_ARMED=0; }
arm

LOOP=""
finish() {
    local rc=$?
    set +e; disarm
    for d in dev sys proc boot; do mountpoint -q "$MNT/$d" && umount "$MNT/$d"; done
    mountpoint -q "$MNT" && umount "$MNT"
    [[ -n $LOOP ]] && losetup -d "$LOOP"
    rmdir "$MNT" 2>/dev/null
    [[ $BANNERED -eq 1 ]] && return
    BANNERED=1
    echo
    [[ -n $OUT ]] && printf '\e[36m----\e[0m  logs, snapshots and diffs in %s\n' "$OUT"
    printf '\e[1m%d passed, %d failed, %d skipped\e[0m\n' "$PASS" "$FAIL" "$SKIP"
    for r in "${SKIPPED[@]}"; do printf '      skipped: %s\n' "$r"; done
    if [[ $ABORTED -eq 1 ]]; then
        echo "TEST COMPLETE: FAIL (harness aborted before finishing)"
    elif [[ $rc -ne 0 && $FAIL -eq 0 ]]; then
        echo "TEST COMPLETE: FAIL (exited $rc with no assertion failure -- treat as incomplete)"
    elif [[ $FAIL -gt 0 ]]; then
        echo "TEST COMPLETE: FAIL"
    elif [[ $SKIP -gt 0 ]]; then
        echo "TEST COMPLETE: PASS, WITH THE SKIPS ABOVE"
    else
        echo "TEST COMPLETE: PASS"
    fi
}
trap finish EXIT

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
if [[ ! -e $IMG && $# -eq 0 ]]; then
    i "no $IMG; unpacking it from $VENDOR_7Z"
    vendor_unpack "$IMG" || { rm -f "$IMG"; exit 1; }
    chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "$IMG"
    chmod a-w "$IMG"
fi
[[ -r $IMG ]] || { echo "no image at $IMG" >&2; exit 1; }
vendor_img_ok "$IMG" || { echo "$IMG is not the vendor image (SHA-256 differs from the pin in pyra-vendor-image.sh); rename it and rerun to unpack a fresh one" >&2; exit 1; }
i "$IMG matches the vendor image's pinned SHA-256"
[[ -x $PREP ]] || { echo "no pyra-trixie-prep.sh beside this script" >&2; exit 1; }
# Deferred until after the guards, so a refused run leaves no stray directory.
[[ -n $OUT ]] || OUT=$(mktemp -d /tmp/pyra-prep-selftest.XXXXXX)
mkdir -p "$OUT"
i "artefacts in $OUT"
if [[ ! -r $KTAR ]]; then
    KURL=$(sed -n 's/^KERNEL_URL=//p' "$PREP")
    KSHA=$(sed -n 's/^KERNEL_SHA256=//p' "$PREP")
    [[ -n $KURL && -n $KSHA ]] || { echo "no kernel tarball at $KTAR and none pinned in prep; set PYRA_KERNEL_TARBALL" >&2; exit 2; }
    i "fix 19: no tarball at $KTAR; downloading the pinned $KURL (network)"
    KTAR=$OUT/m4-kbdled-kernel.tar.gz
    curl -fsSL --proto '=https' --tlsv1.2 -o "$KTAR" "$KURL" ||
        { echo "the pinned kernel download failed; set PYRA_KERNEL_TARBALL" >&2; exit 2; }
    [[ $(sha256sum < "$KTAR" | cut -d' ' -f1) == "$KSHA" ]] ||
        { echo "the downloaded kernel does not match prep's pinned SHA-256" >&2; exit 2; }
fi
KARGS=(--kernel "$KTAR")
i "fix 19 installs $KTAR"
if [[ $BDEB == none ]]; then
    KARGS+=(--no-backlight)
    SKIP=$((SKIP+1)); SKIPPED+=("fix 22 installed no pyra-backlight (PYRA_BACKLIGHT_DEB=none)")
    printf '\e[33mSKIP\e[0m  fix22: PYRA_BACKLIGHT_DEB=none; prep runs with --no-backlight\n'
elif [[ -n $BDEB ]]; then
    [[ -r $BDEB ]] || { echo "PYRA_BACKLIGHT_DEB=$BDEB is not readable" >&2; exit 2; }
    KARGS+=(--backlight "$BDEB")
    i "fix 22 installs $BDEB"
else
    i "fix 22: prep downloads the pinned pyra-backlight release (network)"
fi
# SON: whether fix 26 installs pyra-settings in this run.
SON=no
if [[ $SDEB == none ]]; then
    KARGS+=(--no-settings)
    SKIP=$((SKIP+1)); SKIPPED+=("fix 26 installed no pyra-settings (PYRA_SETTINGS_DEB=none)")
    printf '\e[33mSKIP\e[0m  fix26: PYRA_SETTINGS_DEB=none; prep runs with --no-settings\n'
elif [[ -n $SDEB ]]; then
    [[ -r $SDEB ]] || { echo "PYRA_SETTINGS_DEB=$SDEB is not readable" >&2; exit 2; }
    [[ $BDEB != none ]] || { echo "PYRA_SETTINGS_DEB needs pyra-backlight; unset PYRA_BACKLIGHT_DEB=none" >&2; exit 2; }
    KARGS+=(--settings "$SDEB")
    SON=yes
    i "fix 26 installs $SDEB"
elif [[ -n $(sed -n 's/^SETTINGS_SHA256=//p' "$PREP") && $BDEB != none ]]; then
    SON=yes
    i "fix 26: prep downloads the pinned pyra-settings release (network)"
else
    SKIP=$((SKIP+1)); SKIPPED+=("fix 26 installed no pyra-settings (none pinned; set PYRA_SETTINGS_DEB to a .deb)")
    printf '\e[33mSKIP\e[0m  fix26: no pyra-settings release is pinned and PYRA_SETTINGS_DEB is unset\n'
fi
# SOON: whether fix 27 installs pyra-sound in this run.
SOON=yes
if [[ $SODEB == none ]]; then
    KARGS+=(--no-sound)
    SOON=no
    SKIP=$((SKIP+1)); SKIPPED+=("fix 27 installed no pyra-sound (PYRA_SOUND_DEB=none)")
    printf '\e[33mSKIP\e[0m  fix27: PYRA_SOUND_DEB=none; prep runs with --no-sound\n'
elif [[ -n $SODEB ]]; then
    [[ -r $SODEB ]] || { echo "PYRA_SOUND_DEB=$SODEB is not readable" >&2; exit 2; }
    KARGS+=(--sound "$SODEB")
    i "fix 27 installs $SODEB"
else
    i "fix 27: prep downloads the pinned pyra-sound release (network)"
fi
# PION: whether fix 29 installs the rebuilt funkeymonkey-pyrainput in this run.
PIVER=$(sed -n 's/^PYRAINPUT_TAG=pyrainput-//p' "$PREP")
PION=yes
if [[ $PIDEB == none ]]; then
    KARGS+=(--no-pyrainput)
    PION=no
    SKIP=$((SKIP+1)); SKIPPED+=("fix 29 installed no rebuilt funkeymonkey-pyrainput (PYRA_PYRAINPUT_DEB=none)")
    printf '\e[33mSKIP\e[0m  fix29: PYRA_PYRAINPUT_DEB=none; prep runs with --no-pyrainput\n'
else
    [[ -n $PIDEB || ! -r $BUILD_DIR/pyrainput/funkeymonkey-pyrainput_${PIVER}_armhf.deb ]] ||
        PIDEB=$BUILD_DIR/pyrainput/funkeymonkey-pyrainput_${PIVER}_armhf.deb
    if [[ -n $PIDEB ]]; then
        [[ -r $PIDEB ]] || { echo "PYRA_PYRAINPUT_DEB=$PIDEB is not readable" >&2; exit 2; }
        KARGS+=(--pyrainput "$PIDEB")
        i "fix 29 installs $PIDEB"
    else
        i "fix 29: prep downloads the pinned funkeymonkey-pyrainput release (network)"
    fi
fi

########################################################################
i "working copy"
########################################################################
# Reuse an existing copy only if it is byte-identical to the pristine image,
# otherwise a rerun would silently test a already-prepped leftover.
if [[ -e $WORK ]] && cmp -s "$IMG" "$WORK"; then
    i "reusing $WORK (identical to the image)"
else
    rm -f "$WORK"
    cp --sparse=always "$IMG" "$WORK"
    chmod 644 "$WORK"   # the pristine image is kept read-only; its copy must not be
    i "copied $IMG -> $WORK"
fi

modprobe f2fs
LOOP=$(losetup --find --partscan --show "$WORK")
i "loop device $LOOP"
# udev may still be handling the new partitions; mount can fail with "Can't
# lookup blockdev" until it is done.
udevadm settle 2>/dev/null || true
[[ -b ${LOOP}p2 ]] || { echo "no ${LOOP}p2 — partscan failed" >&2; exit 1; }

blkid "${LOOP}p1" "${LOOP}p2" || true
mount -t f2fs "${LOOP}p2" "$MNT"
i "mounted ${LOOP}p2 at $MNT"
# Fix 14 rebuilds the initrds, which live on p1, so prep needs it at /boot.
mount "${LOOP}p1" "$MNT/boot"
i "mounted ${LOOP}p1 at $MNT/boot"

snapshot() {
    # No pipeline: find's exit status must not decide the harness's fate, and
    # a downstream reader exiting early would SIGPIPE it under pipefail.
    local raw=$OUT/.snap.$$
    # -xdev keeps each walk on its own partition, so /boot is walked apart.
    find "$MNT" -xdev -printf '%y %m %U %G %s %P -> %l\n' > "$raw" 2>/dev/null || true
    find "$MNT/boot" -xdev -printf '%y %m %U %G %s boot/%P -> %l\n' >> "$raw" 2>/dev/null || true
    LC_ALL=C sort "$raw"
    rm -f "$raw"
}

########################################################################
i "snapshot before"
########################################################################
snapshot > "$OUT/rootfs-before.txt"
i "$(wc -l < "$OUT/rootfs-before.txt") entries"

########################################################################
i "run 1 of pyra-trixie-prep.sh"
########################################################################
# Run 1 also exercises fix 2's two options: --set-password on the image's
# existing pyra user, fed a test password on stdin, and --ssh-key with a key
# made for this run (its comment must not reach the card).
TESTPW=selftest-not-a-real-password
# Fix 23 removes the vendor's host keys; one public key is kept for its mixed test.
cp "$MNT/etc/ssh/ssh_host_rsa_key.pub" "$OUT/vendor-rsa.pub"
# Fix 28 appends to remap.inc; the vendor's lines must survive it.
cp "$MNT/etc/console-setup/remap.inc" "$OUT/remap.inc.vendor"
ssh-keygen -q -t ed25519 -N '' -C 'comment-that-must-not-land@example.invalid' -f "$OUT/testkey"
disarm; set +e
"$PREP" "${KARGS[@]}" --set-password --ssh-key "$OUT/testkey.pub" --grow-on-boot "$MNT" pyra \
    < <(printf '%s\n%s\n' "$TESTPW" "$TESTPW") 2>&1 | tee "$OUT/prep-run1.log"
RC=${PIPESTATUS[0]}
set -e; arm
[[ $RC -eq 0 ]] && p "run 1 exited 0" || f "run 1 exited $RC"

snapshot > "$OUT/rootfs-after1.txt"

########################################################################
i "what run 1 changed"
########################################################################
diff -u "$OUT/rootfs-before.txt" "$OUT/rootfs-after1.txt" > "$OUT/rootfs-diff1.txt" || true
if grep -E '^[+-][^+-]' "$OUT/rootfs-diff1.txt" > "$OUT/.d1" 2>/dev/null && [[ -s $OUT/.d1 ]]; then
    sed 's/^/      /' "$OUT/.d1"
else
    echo "      (no structural changes)"
fi
rm -f "$OUT/.d1"

########################################################################
i "assert fixes 1 to 8"
########################################################################
# fix 1 — the ineffective symlink must be gone
if [[ -e $MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so || -L $MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so ]]; then
    f "fix1: armsoc_dri.so still present"
else
    p "fix1: armsoc_dri.so absent"
fi

# fix 4 — GLX disabled, lightdm data dir owned by lightdm
GLXCONF=$MNT/etc/X11/xorg.conf.d/20-pyra-glx.conf
if grep -qi 'Option[[:space:]]*"GLX"[[:space:]]*"Disable"' "$GLXCONF" 2>/dev/null; then
    p "fix4: GLX disabled in $(basename "$GLXCONF") ($(stat -c %a "$GLXCONF"))"
else
    f "fix4: GLX not disabled"
fi
LDMUID=$(awk -F: '$1=="lightdm"{print $3}' "$MNT/etc/passwd")
if [[ -d $MNT/var/lib/lightdm/data ]]; then
    p "fix4: /var/lib/lightdm/data $(stat -c '%a %u:%g' "$MNT/var/lib/lightdm/data") (lightdm uid $LDMUID)"
else
    f "fix4: /var/lib/lightdm/data missing"
fi

# fix 2 — --set-password on the existing pyra user, and --ssh-key
HASH=$(awk -F: '$1=="pyra"{print $2}' "$MNT/etc/shadow")
SALT=$(cut -d'$' -f3 <<<"$HASH")
[[ $HASH == '$6$'* && $(openssl passwd -6 -salt "$SALT" "$TESTPW") == "$HASH" ]] \
    && p "fix2: --set-password gave the existing pyra user the test password" || f "fix2: pyra's shadow hash is not the test password"
PHOME=$(awk -F: '$1=="pyra"{print $6}' "$MNT/etc/passwd")
PIDS=$(awk -F: '$1=="pyra"{print $3":"$4}' "$MNT/etc/passwd")
AK=$MNT$PHOME/.ssh/authorized_keys
[[ $(cat "$AK" 2>/dev/null) == "$(awk '{print $1, $2}' "$OUT/testkey.pub")" ]] \
    && p "fix2: authorized_keys holds the key, type and key only" || f "fix2: authorized_keys is missing or not exactly the key"
grep -q 'example.invalid' "$AK" 2>/dev/null && f "fix2: the key's comment reached the card" || p "fix2: the key's comment did not reach the card"
[[ $(stat -c '%a %u:%g' "$AK" 2>/dev/null) == "600 $PIDS" && $(stat -c '%a %u:%g' "$MNT$PHOME/.ssh" 2>/dev/null) == "700 $PIDS" ]] \
    && p "fix2: .ssh 0700 and authorized_keys 0600, owned by pyra" || f "fix2: .ssh or authorized_keys has the wrong mode or owner"

# fix 2 — marker, user, groups
[[ -e $MNT/var/lib/pyra/first-run.done ]] && p "fix2: first-run marker present" || f "fix2: marker missing"
if grep -q '^pyra:' "$MNT/etc/passwd"; then
    p "fix2: user pyra $(grep '^pyra:' "$MNT/etc/passwd" | cut -d: -f3,4,6,7)"
else
    f "fix2: no pyra user"
fi
grep -q '^pyra:\$6\$' "$MNT/etc/shadow" && p "fix2: pyra has a \$6\$ hash" || f "fix2: pyra has no sha512 password"
# group/gshadow agreement is the corruption the hand-edited forum procedure causes
if diff <(cut -d: -f1,4 "$MNT/etc/group" | sort) <(cut -d: -f1,4 "$MNT/etc/gshadow" | sort) >/dev/null; then
    p "fix2: group and gshadow agree on every group"
else
    f "fix2: group and gshadow disagree"
    diff <(cut -d: -f1,4 "$MNT/etc/group" | sort) <(cut -d: -f1,4 "$MNT/etc/gshadow" | sort) > "$OUT/.g" || true
    sed -n '1,10p' "$OUT/.g" | sed 's/^/      /'
    rm -f "$OUT/.g"
fi

# fix 2 — root locked (the vendor's root password is 'root'), and sulogin let
# through to the emergency and rescue shells
RHASH=$(awk -F: '$1=="root"{print $2}' "$MNT/etc/shadow")
[[ $RHASH == '!'* ]] && p "fix2: root is locked (shadow '!...')" || f "fix2: root is not locked (shadow '${RHASH:0:3}...')"
grep -q 'fix2: locked root' "$OUT/prep-run1.log" && p "fix2: run 1 locked the vendor image's root" || f "fix2: run 1 did not report locking root"
for u in emergency rescue; do
    D=$MNT/etc/systemd/system/$u.service.d/pyra-sulogin-force.conf
    cmp -s "$PAYLOADS/etc/systemd/system/$u.service.d/pyra-sulogin-force.conf" "$D" && [[ $(stat -c '%a %u:%g' "$D") == "644 0:0" ]] \
        && p "fix2: $u.service.d/pyra-sulogin-force.conf matches repo, 0644 root:root" || f "fix2: $u.service.d/pyra-sulogin-force.conf missing, different or wrong mode"
    grep -qx 'Environment=SYSTEMD_SULOGIN_FORCE=1' "$D" 2>/dev/null && p "fix2: $u.service gets SYSTEMD_SULOGIN_FORCE=1" || f "fix2: $u.service's drop-in does not set SYSTEMD_SULOGIN_FORCE=1"
done

# fix 3 — config, unit, enabled
[[ -e $MNT/etc/pyrainput.cfg ]] && p "fix3: /etc/pyrainput.cfg present ($(stat -c %s "$MNT/etc/pyrainput.cfg") bytes)" || f "fix3: cfg missing"
PYRAUNIT=""
for c in "$MNT"/lib/systemd/system/pyrainput.service "$MNT"/usr/lib/systemd/system/pyrainput.service; do
    [[ -e $c ]] && { PYRAUNIT=$c; break; }
done
[[ -n $PYRAUNIT ]] && p "fix3: unit at ${PYRAUNIT#$MNT}" || f "fix3: no pyrainput.service"
[[ -L $MNT/etc/systemd/system/multi-user.target.wants/pyrainput.service ]] \
    && p "fix3: enabled -> $(readlink "$MNT/etc/systemd/system/multi-user.target.wants/pyrainput.service")" \
    || f "fix3: not enabled"

# fix 5 — the payloads must match the repository byte for byte
D=$MNT/usr/local/sbin/pyra-usb3503-rescue
U=$MNT/etc/systemd/system/pyra-usb3503-rescue.service
if [[ -e $D ]] && cmp -s "$PAYLOADS/pyra-usb3503-rescue" "$D"; then
    p "fix5: rescue script matches repo, mode $(stat -c '%a %u:%g' "$D")"
else
    f "fix5: rescue script missing or differs from repo"
fi
[[ $(stat -c '%a %u:%g' "$D" 2>/dev/null) == "755 0:0" ]] && p "fix5: script is 0755 root:root" || f "fix5: script mode is $(stat -c '%a %u:%g' "$D" 2>/dev/null)"
if [[ -e $U ]] && cmp -s "$PAYLOADS/pyra-usb3503-rescue.service" "$U"; then
    p "fix5: unit matches repo, mode $(stat -c '%a %u:%g' "$U")"
else
    f "fix5: unit missing or differs from repo"
fi
[[ $(stat -c '%a %u:%g' "$U" 2>/dev/null) == "644 0:0" ]] && p "fix5: unit is 0644 root:root" || f "fix5: unit mode is $(stat -c '%a %u:%g' "$U" 2>/dev/null)"
[[ -L $MNT/etc/systemd/system/multi-user.target.wants/pyra-usb3503-rescue.service ]] \
    && p "fix5: enabled -> $(readlink "$MNT/etc/systemd/system/multi-user.target.wants/pyra-usb3503-rescue.service")" \
    || f "fix5: not enabled"
# /usr/local/sbin must not have been re-moded
i "fix5: /usr/local/sbin is $(stat -c '%a %u:%g' "$MNT/usr/local/sbin")"

# fix 6 — the thermal daemon must apply its cap by writing sysfs, and the
# vendor's original must still be on the card beside it.
TH=$MNT/usr/share/pyra/scripts/pyra-thermal.sh
if [[ ! -f $TH ]]; then
    f "fix6: no pyra-thermal.sh on the card at all"
else
    if grep -qE '^[[:space:]]*cpufreq-set -u' "$TH"; then
        f "fix6: still calls cpufreq-set, which trixie cannot install"
    else
        p "fix6: no cpufreq-set call left"
    fi
    if grep -q 'scaling_max_freq' "$TH"; then
        p "fix6: applies the cap by writing scaling_max_freq"
    else
        f "fix6: nothing writes scaling_max_freq"
    fi
    # Two fixes now transform this one file, so the card must carry two
    # backups and the chain has to hold link by link:
    #
    #   .before-pyra-thermal-fix     the vendor's file, untouched
    #   .before-pyra-thermal-ladder  vendor + fix 6, which is fix 7's input
    #   pyra-thermal.sh              vendor + fix 6 + fix 7
    #
    # Checking each link separately is what keeps fix 6 verifiable now that
    # something else edits the same file after it.
    VENDOR_ORIG=$TH.before-pyra-thermal-fix
    AFTER_FIX6=$TH.before-pyra-thermal-ladder

    if [[ -e $VENDOR_ORIG ]]; then
        p "fix6: vendor original kept at ${VENDOR_ORIG#$MNT}"
    else
        f "fix6: no vendor original kept, so the card has no undo"
    fi
    if [[ -e $AFTER_FIX6 ]]; then
        p "fix7: fix 6's output kept at ${AFTER_FIX6#$MNT}, so the two undo independently"
    else
        f "fix7: no ${AFTER_FIX6#$MNT}, so fix 7 cannot be undone on its own"
    fi

    # fix 6 must not have touched the ladder. Its output is the SECOND backup,
    # not the final file, now that fix 7 runs after it.
    LADDER_BEFORE=$(grep -cE 'setMaxFreq|setMaxCharge' "$VENDOR_ORIG" 2>/dev/null || echo 0)
    LADDER_MID=$(grep -cE 'setMaxFreq|setMaxCharge' "$AFTER_FIX6" 2>/dev/null || echo 0)
    if [[ $LADDER_BEFORE -eq $LADDER_MID && $LADDER_BEFORE -gt 0 ]]; then
        p "fix6: thermal ladder untouched by fix 6 ($LADDER_MID decisions, as shipped)"
    else
        f "fix6: fix 6 changed the ladder, $LADDER_BEFORE decisions before and $LADDER_MID after"
    fi

    # It has to parse, or the card boots with a dead thermal daemon.
    if bash -n "$TH" 2>/dev/null; then
        p "fix7: final daemon is valid shell"
    else
        f "fix7: final daemon does not parse"
    fi
    if bash -n "$AFTER_FIX6" 2>/dev/null; then
        p "fix6: fix 6's output is valid shell"
    else
        f "fix6: fix 6's output does not parse"
    fi

    # Link one: vendor -> fix 6.
    if "$PAYLOADS/pyra-thermal-fix.sh" --emit-patched "$VENDOR_ORIG" 2>/dev/null | cmp -s - "$AFTER_FIX6"; then
        p "fix6: matches what pyra-thermal-fix.sh produces, byte for byte"
    else
        f "fix6: differs from what the device script would produce"
    fi
    # Link two: fix 6 -> fix 7. Fix 26 then replaces the file with the fork's,
    # which from 0.38+pyra5 adds the user ceiling (pyraReadCeiling, its comment
    # and its call) to exactly what fix 7 makes; that block is taken out before
    # comparing, so the fork may add it and nothing else.
    FIX7_OUT=$(mktemp)
    "$PAYLOADS/pyra-thermal-ladder.sh" --emit-patched "$AFTER_FIX6" > "$FIX7_OUT" 2>/dev/null || :
    TH_CMP=$(mktemp)
    if grep -q '^pyraReadCeiling()' "$TH"; then
        awk '/^# A ceiling the user sets/{skip=1} skip&&/^}$/{skip=2;next} skip==2&&/^$/{skip=0;next} skip{next} /^[[:space:]]*pyraReadCeiling$/{next} {print}' "$TH" > "$TH_CMP"
        TH_WHAT="the fork's daemon, less its ceiling block,"
    else
        cp "$TH" "$TH_CMP"; TH_WHAT="the final daemon"
    fi
    if [[ -s $FIX7_OUT ]] && cmp -s "$FIX7_OUT" "$TH_CMP"; then
        p "fix7: $TH_WHAT matches what pyra-thermal-ladder.sh produces, byte for byte"
    else
        f "fix7: $TH_WHAT differs from what the device script would produce"
    fi
    rm -f "$TH_CMP"

    # The point of fix 7, asserted directly rather than inferred from a diff.
    if grep -q 'gaugeHot1=' "$TH"; then
        p "fix7: board rungs present ($(grep -oE 'gaugeHot[1-5]=[0-9]+' "$TH" | tr '\n' ' '))"
    else
        f "fix7: no board rungs in the patched daemon"
    fi
    if grep -q 'pyraHyst=' "$TH"; then
        p "fix7: hysteresis present ($(grep -oE 'pyraHyst=[0-9]+' "$TH"))"
    else
        f "fix7: no hysteresis in the patched daemon"
    fi
    if grep -q 'pyraCap' "$TH"; then
        p "fix7: caps go through a helper that takes the lower of the two ladders"
    else
        f "fix7: setMaxFreq overwrite fault not fixed"
    fi
    # The poll has to be fast enough to matter. 20 s is slower than this
    # machine's thermal transient: two cores cross the trip in 16 s.
    POLL=$(grep -oE '^interval=[0-9]+' "$TH" | cut -d= -f2)
    if [[ -n $POLL && $POLL -le 5 ]]; then
        p "fix7: poll interval is ${POLL}s (vendor 20s, which cannot control this machine)"
    else
        f "fix7: poll interval is '${POLL:-absent}', too slow to catch a two-core ramp"
    fi
    # And it has to watch the sensor the passive trip is on.
    if grep -q 'pyraCpuDev' "$TH"; then
        p "fix7: ladder reads the hotter of core_thermal and cpu_thermal"
    else
        f "fix7: ladder still reads core_thermal alone, which lags the trip sensor"
    fi
    # The charging ladder must be byte-identical in its thresholds and currents.
    CHG_BEFORE=$(grep -oE 'setMaxCharge [0-9]+' "$VENDOR_ORIG" | sort | uniq -c | tr -s ' ')
    CHG_AFTER=$(grep -oE 'setMaxCharge [0-9]+' "$TH" | sort | uniq -c | tr -s ' ')
    if [[ $CHG_BEFORE == "$CHG_AFTER" ]]; then
        p "fix7: charging ladder unchanged, every threshold and current as shipped"
    else
        f "fix7: charging ladder changed; before [$CHG_BEFORE] after [$CHG_AFTER]"
    fi

    # Mode and owner must survive: this is a packaged file.
    i "fix6/7: $(stat -c '%a %u:%g' "$TH") $(basename "$TH")"
fi

# fix 6/7 — the guard that re-applies both after a pyra-hacks package run, and
# the two scripts it re-applies them with, byte for byte with the repository.
for spec in pyra-thermal-fix.sh:/usr/local/sbin:755 \
            pyra-thermal-ladder.sh:/usr/local/sbin:755 \
            pyra-thermal-guard:/usr/local/sbin:755 \
            etc/dpkg/dpkg.cfg.d/pyra-thermal-guard:/etc/dpkg/dpkg.cfg.d:644; do
    IFS=: read -r src dir mode <<<"$spec"
    D=$MNT$dir/$(basename "$src")
    if [[ -e $D ]] && cmp -s "$PAYLOADS/$src" "$D"; then
        p "fix6/7: ${D#$MNT} matches repo"
    else
        f "fix6/7: ${D#$MNT} missing or differs from repo"
    fi
    [[ $(stat -c '%a %u:%g' "$D" 2>/dev/null) == "$mode 0:0" ]] \
        || f "fix6/7: ${D#$MNT} mode is $(stat -c '%a %u:%g' "$D" 2>/dev/null), want $mode 0:0"
done
# Run the guard on a copy (it writes when it acts, and this test must not):
# as prep leaves the card it has nothing to do, and after a reinstall of the
# vendor file it must restore exactly what fixes 6 and 7 wrote (the fork's
# ceiling comes only with the fork, so it is not part of that).
if [[ -f $TH ]]; then
    GT=$(mktemp -d)
    cp -p "$TH" "$TH".before-pyra-thermal-* "$GT/" 2>/dev/null
    GUARD=(env PYRA_THERMAL_SCRIPT="$GT/pyra-thermal.sh" PYRA_THERMAL_HELPERS="$PAYLOADS" "$PAYLOADS/pyra-thermal-guard")
    if "${GUARD[@]}" 2>&1 | grep -q .; then
        f "fix6/7: pyra-thermal-guard would change or warn about the prepared card"
    else
        p "fix6/7: pyra-thermal-guard is silent on the prepared card"
    fi
    cp "$GT/pyra-thermal.sh.before-pyra-thermal-fix" "$GT/pyra-thermal.sh" 2>/dev/null
    "${GUARD[@]}" >/dev/null 2>&1
    if [[ -s $FIX7_OUT ]] && cmp -s "$GT/pyra-thermal.sh" "$FIX7_OUT"; then
        p "fix6/7: after a simulated pyra-hacks reinstall, the guard restores fixes 6 and 7 byte for byte"
    else
        f "fix6/7: after a simulated pyra-hacks reinstall, the guard does not restore fixes 6 and 7"
    fi
    rm -rf "$GT" "$FIX7_OUT"
fi

########################################################################
i "assert fix 8 — the card can charge while it runs"
########################################################################
# Fix 8 writes four new files rather than transforming a packaged one, so
# there is no vendor original to diff against. What matters is that what is on
# the card is exactly what the device script generates, that the rule names
# the charger this board actually has, and that the helper is valid /bin/sh —
# it runs from udev, where a syntax error is silent.

F8_CONF=$MNT/etc/default/pyra-charge-current
F8_HELPER=$MNT/usr/local/sbin/pyra-charge-current-apply
F8_RULE=$MNT/etc/udev/rules.d/60-pyra-charge-current.rules

F8_STAGE=$(mktemp -d /tmp/pyra-selftest-fix8.XXXXXX)
if "$PAYLOADS/pyra-charge-current.sh" --emit-into "$F8_STAGE" >/dev/null 2>&1; then
    p "fix8: pyra-charge-current.sh --emit-into produced a tree"
    for rel in /etc/default/pyra-charge-current \
               /usr/local/sbin/pyra-charge-current-apply \
               /etc/udev/rules.d/60-pyra-charge-current.rules \
               /etc/udev/rules.d/charging.rules; do
        if [[ ! -e $MNT$rel ]]; then
            f "fix8: $rel is not on the card"
        elif cmp -s "$F8_STAGE$rel" "$MNT$rel"; then
            p "fix8: $rel matches the device script byte for byte"
        else
            f "fix8: $rel differs from what the device script would produce"
        fi
    done
else
    f "fix8: pyra-charge-current.sh --emit-into failed"
fi
rm -rf "$F8_STAGE"

# The helper runs under dash from udev. A syntax error there fails silently.
if sh -n "$F8_HELPER" 2>/dev/null; then
    p "fix8: the helper parses as /bin/sh"
else
    f "fix8: the helper is not valid /bin/sh"
fi
if [[ -x $F8_HELPER ]]; then
    p "fix8: the helper is executable ($(stat -c '%a' "$F8_HELPER"))"
else
    f "fix8: the helper is not executable, so the udev rule cannot run it"
fi

# After a replug the chip's own D+/D- detection sets the limit about 0.1-0.6 s
# after the plug event that runs the helper (3 A on an adapter, 500 mA on the
# normal port; R74). The helper has to start its delayed re-check, and the
# image has to have the systemd-run it starts it with.
if grep -q -- '--settle' "$F8_HELPER" && grep -q 'systemd-run --no-block' "$F8_HELPER"; then
    p "fix8: the helper re-checks the limit after the chip's detection"
else
    f "fix8: the helper does not re-check after detection; a replug leaves the chip's limit"
fi
if [[ -x $MNT/usr/bin/systemd-run ]]; then
    p "fix8: systemd-run is on the image for the delayed re-check"
else
    f "fix8: no /usr/bin/systemd-run on the image; the re-check after a replug never runs"
fi

# The rule has to name this board's charger, not the twl4030 the stock rules
# were written for, and it has to fire on the events that reset the register.
if grep -q 'KERNEL=="bq24297"' "$F8_RULE"; then
    p "fix8: the rule matches bq24297, not twl4030"
else
    f "fix8: the rule does not match bq24297"
fi
if grep -qE 'ACTION==.*add.*change|ACTION==.*change.*add' "$F8_RULE"; then
    p "fix8: the rule fires on both add and change"
else
    f "fix8: the rule does not cover both add and change; the limit resets on plug"
fi
if grep -q "RUN+=\"/usr/local/sbin/pyra-charge-current-apply\"" "$F8_RULE"; then
    p "fix8: the rule runs the helper by its installed path"
else
    f "fix8: the rule does not invoke the installed helper"
fi

# The number itself, and the bound on it. 500000 would not be a fix: the
# machine draws about 620 mA at idle.
F8_UA=$(grep -oE '^PYRA_INPUT_CURRENT_UA=[0-9]+' "$F8_CONF" | cut -d= -f2)
if [[ -n $F8_UA && $F8_UA -gt 500000 && $F8_UA -le 3000000 ]]; then
    p "fix8: input limit is ${F8_UA} uA (above the 500 mA floor, within the chip's 3 A ceiling)"
else
    f "fix8: input limit is '${F8_UA:-absent}', which is not a working value"
fi

# The stock rules must be masked, or the thermal daemon's charge ladder can
# win a boot-order race and drive the input limit from the fuel gauge's die.
if grep -qs 'pyra-charge-current' "$MNT/etc/udev/rules.d/charging.rules"; then
    p "fix8: the stock charging.rules is masked from /etc/udev/rules.d"
else
    f "fix8: the stock charging.rules is not masked; the thermal daemon can reach the charger"
fi

# The stock rules must be left alone: this fix takes precedence by living in
# /etc, and reverting it should mean deleting files there, not restoring /lib.
if [[ -e $MNT/lib/udev/rules.d/charging.rules ]]; then
    if grep -q 'neither tested nor complete nor working' "$MNT/lib/udev/rules.d/charging.rules"; then
        p "fix8: the stock /lib/udev/rules.d/charging.rules is untouched"
    else
        f "fix8: the stock charging.rules was modified; this fix should not touch it"
    fi
else
    i "fix8: no stock charging.rules in this image to leave alone"
fi

########################################################################
i "assert fixes 9 to 12 — codec routes, greeter audio, SGX init rule, volume wheel"
########################################################################
# Each of these writes new files generated by its device script's --emit-into,
# like fix 8: what is on the card must be what the script generates, with the
# script's mode, owned by root.
#
#   emit_matches FIX SCRIPT  -- emits SCRIPT into a stage and compares each
#                               file with the card. Leaves the stage in F_STAGE.
emit_matches() {
    local fix=$1 script=$2 files rel
    F_STAGE=$(mktemp -d "/tmp/pyra-selftest-$fix.XXXXXX")
    if ! files=$("$script" --emit-into "$F_STAGE" 2>/dev/null) || [[ -z $files ]]; then
        f "$fix: ${script#$ROOT/} --emit-into failed"
        return 0
    fi
    while read -r rel; do
        [[ -n $rel ]] || continue
        rel=${rel#$F_STAGE}
        if [[ ! -e $MNT$rel ]]; then
            f "$fix: $rel is not on the card"
        elif ! cmp -s "$F_STAGE$rel" "$MNT$rel"; then
            f "$fix: $rel differs from what ${script#$ROOT/} would produce"
        elif [[ $(stat -c '%a %u:%g' "$MNT$rel") != "$(stat -c '%a' "$F_STAGE$rel") 0:0" ]]; then
            f "$fix: $rel is $(stat -c '%a %u:%g' "$MNT$rel"), not $(stat -c '%a' "$F_STAGE$rel") root:root"
        else
            p "$fix: $rel matches the device script ($(stat -c '%a' "$MNT$rel") root:root)"
        fi
    done <<<"$files"
}

# Fix 9: the udev rule, its helper, and R109's ExecStartPost drop-in, which
# re-applies the routes after PulseAudio's own open of the card resets them.
emit_matches fix9 "$PAYLOADS/pyra-audio-route.sh"; rm -rf "$F_STAGE"
F9_HELPER=$MNT/usr/local/sbin/pyra-audio-route-apply
F9_RULE=$MNT/etc/udev/rules.d/95-pyra-audio-route.rules
F9_DROPIN=$MNT/etc/systemd/user/pulseaudio.service.d/20-pyra-audio-route.conf
sh -n "$F9_HELPER" 2>/dev/null && p "fix9: the helper parses as /bin/sh" || f "fix9: the helper is not valid /bin/sh"
if grep -qx 'ExecStartPost=/usr/local/sbin/pyra-audio-route-apply' "$F9_DROPIN" 2>/dev/null &&
   grep -qx '\[Service\]' "$F9_DROPIN"; then
    p "fix9: the pulseaudio.service drop-in runs the helper as ExecStartPost"
else
    f "fix9: the pulseaudio.service drop-in does not run the helper; PulseAudio's open leaves the routes reset"
fi
if grep -q 'ATTRS{id}=="L15".*RUN+="/usr/local/sbin/pyra-audio-route-apply"' "$F9_RULE" 2>/dev/null; then
    p "fix9: the udev rule runs the helper for card L15"
else
    f "fix9: the udev rule does not run the helper for card L15"
fi
# 95- has to sort after the stock restore, or the shipped silent state wins.
if [[ -e $MNT/lib/udev/rules.d/90-alsa-restore.rules || -e $MNT/usr/lib/udev/rules.d/90-alsa-restore.rules ]]; then
    p "fix9: the stock rule it must follow is 90-alsa-restore, below 95-"
else
    f "fix9: no 90-alsa-restore.rules on the image; the 95- ordering argument no longer holds"
fi
F9_ROUTES=0
for pair in 'Handsfree Left Playback=HF DAC' 'Handsfree Right Playback=HF DAC' \
            'Headset Left Playback=HS DAC' 'Headset Right Playback=HS DAC'; do
    grep -qF "'$pair'" "$F9_HELPER" 2>/dev/null && F9_ROUTES=$((F9_ROUTES+1))
done
[[ $F9_ROUTES -eq 4 ]] && p "fix9: the helper sets all four output routes" || f "fix9: the helper sets $F9_ROUTES of the four output routes"
# Handsfree Playback Volume is the wheel's (pyra_volumed); the helper must not fight it.
if grep -q 'Handsfree Playback Volume' "$F9_HELPER" 2>/dev/null; then
    f "fix9: the helper writes Handsfree Playback Volume, which belongs to the wheel"
else
    p "fix9: the helper leaves Handsfree Playback Volume to the wheel"
fi
[[ -x $MNT/usr/bin/amixer ]] && p "fix9: /usr/bin/amixer is on the image for the helper" || f "fix9: no /usr/bin/amixer on the image; the helper sets nothing"

# Fix 10: drop-ins that skip PulseAudio for the greeter, beside the packaged units.
emit_matches fix10 "$PAYLOADS/pyra-greeter-audio.sh"; rm -rf "$F_STAGE"
for u in service socket; do
    D=$MNT/etc/systemd/user/pulseaudio.$u.d/10-no-greeter.conf
    if grep -qx 'ConditionUser=!lightdm' "$D" 2>/dev/null && grep -qx '\[Unit\]' "$D"; then
        p "fix10: pulseaudio.$u is skipped for the greeter (ConditionUser=!lightdm)"
    else
        f "fix10: pulseaudio.$u has no ConditionUser=!lightdm; the greeter can take the card"
    fi
    if [[ -e $MNT/usr/lib/systemd/user/pulseaudio.$u ]]; then
        p "fix10: the packaged pulseaudio.$u is still there for the drop-in to modify"
    else
        f "fix10: no packaged /usr/lib/systemd/user/pulseaudio.$u; the drop-in modifies nothing"
    fi
done

# Fix 11: the DDK's rule shadowed by name from /etc, started on the DRM card add.
emit_matches fix11 "$PAYLOADS/pyra-sgx-init.sh"; rm -rf "$F_STAGE"
F11_RULE=$MNT/etc/udev/rules.d/omap5-sgx-ddk-um-linux.rules
if grep -q 'ACTION=="add", SUBSYSTEM=="drm",.*DRIVERS=="pvrsrvkm".*pvrsrvctl --start' "$F11_RULE" 2>/dev/null; then
    p "fix11: the rule starts the SGX services on the pvr DRM card's add"
else
    f "fix11: the rule does not start the services on the DRM card's add"
fi
if grep 'SUBSYSTEM=="module"' "$F11_RULE" 2>/dev/null | grep -q 'ACTION=="add"'; then
    f "fix11: the rule still starts on the module add, which races the driver's probe"
else
    p "fix11: nothing starts on the module add event"
fi
F11_CTL=$(grep -o 'RUN+="[^ "]*pvrsrvctl' "$F11_RULE" 2>/dev/null | head -1 | sed 's/^RUN+="//' || true)
[[ -n $F11_CTL && -x $MNT$F11_CTL ]] && p "fix11: $F11_CTL is on the image" || f "fix11: the rule's pvrsrvctl ('${F11_CTL:-none}') is not on the image"
if [[ -e $MNT/lib/udev/rules.d/omap5-sgx-ddk-um-linux.rules ]]; then
    p "fix11: the DDK's own rule is still in /lib/udev/rules.d, shadowed by name"
else
    f "fix11: the DDK's rule is gone from /lib/udev/rules.d; the shadow no longer matches a packaged rule"
fi

# Fix 12: with fix 26 installing the pyra-hacks fork, it stands aside and
# leaves nothing; without it, it installs the calibrated daemon's source and runner.
if [[ $SON == yes ]]; then
    F12_LEFT=()
    for x in /etc/systemd/system/pyra_volumed.service.d/calibrated.conf /usr/local/sbin/pyra-volumed-run \
             /usr/local/bin/pyra_volumed /usr/local/src/pyra-volumed/pyra_volumed.c; do
        [[ -e $MNT$x ]] && F12_LEFT+=("$x")
    done
    if [[ ${#F12_LEFT[@]} -eq 0 ]]; then
        p "fix12: stood aside for fix 26's pyra-hacks fork; none of its files on the card"
    else
        f "fix12: fix 26 installs the fork, yet ${F12_LEFT[*]} remain and override its unit"
    fi
else
    emit_matches fix12 "$PAYLOADS/pyra-volumed/install.sh"; rm -rf "$F_STAGE"
    sh -n "$MNT/usr/local/sbin/pyra-volumed-run" 2>/dev/null && p "fix12: the runner parses as /bin/sh" ||
        f "fix12: the runner is not valid /bin/sh"
    if grep -qx 'ExecStart=/usr/local/sbin/pyra-volumed-run' "$MNT/etc/systemd/system/pyra_volumed.service.d/calibrated.conf" 2>/dev/null; then
        p "fix12: the pyra_volumed drop-in points the unit at the runner"
    else
        f "fix12: the pyra_volumed drop-in does not point the unit at the runner"
    fi
fi

########################################################################
i "assert fixes 13 and 14 — pyra-gles, and the init-top hooks in every initrd"
########################################################################
G=$MNT/usr/local/bin/pyra-gles
if [[ -e $G ]] && cmp -s "$PAYLOADS/pyra-gles" "$G"; then
    p "fix13: /usr/local/bin/pyra-gles matches repo"
else
    f "fix13: /usr/local/bin/pyra-gles missing or differs from repo"
fi
[[ $(stat -c '%a %u:%g' "$G" 2>/dev/null) == "755 0:0" ]] && p "fix13: pyra-gles is 0755 root:root" || f "fix13: pyra-gles mode is $(stat -c '%a %u:%g' "$G" 2>/dev/null)"
sh -n "$G" 2>/dev/null && p "fix13: pyra-gles parses as /bin/sh" || f "fix13: pyra-gles is not valid /bin/sh"

for h in pyra-fw-nofallback pyra-settle-nudge; do
    H=$MNT/etc/initramfs-tools/scripts/init-top/$h
    if [[ -e $H ]] && cmp -s "$PAYLOADS/etc/initramfs-tools/scripts/init-top/$h" "$H"; then
        p "fix14: ${H#$MNT} matches repo"
    else
        f "fix14: ${H#$MNT} missing or differs from repo"
    fi
    [[ $(stat -c '%a %u:%g' "$H" 2>/dev/null) == "755 0:0" ]] || f "fix14: ${H#$MNT} mode is $(stat -c '%a %u:%g' "$H" 2>/dev/null)"
done
for g in usr/local/sbin/pyra-grow-root:pyra-grow-root \
         etc/initramfs-tools/scripts/local-premount/pyra-grow-root:etc/initramfs-tools/scripts/local-premount/pyra-grow-root \
         etc/initramfs-tools/hooks/pyra-grow-root:etc/initramfs-tools/hooks/pyra-grow-root; do
    H=$MNT/${g%%:*}
    if [[ -e $H ]] && cmp -s "$PAYLOADS/${g#*:}" "$H"; then
        p "grow-on-boot: /${g%%:*} matches repo"
    else
        f "grow-on-boot: /${g%%:*} missing or differs from repo"
    fi
    [[ $(stat -c '%a %u:%g' "$H" 2>/dev/null) == "755 0:0" ]] || f "grow-on-boot: /${g%%:*} mode is $(stat -c '%a %u:%g' "$H" 2>/dev/null)"
done
# Read each initrd with the image's own lsinitramfs, as prep does, and require
# both hooks in the archive and in init-top/ORDER before udev, which is what
# makes them run before `udevadm settle`.
for d in proc sys dev; do mount --bind "/$d" "$MNT/$d"; done
# Clean environment and Debian's PATH, as prep uses.
in_chroot() {
    chroot "$MNT" /usr/bin/env -i HOME=/root LC_ALL=C \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
}
NINITRD=0
for initrd in "$MNT"/boot/initrd.img-*; do
    rel=${initrd#$MNT/boot/initrd.img-}
    [[ -d $MNT/lib/modules/$rel ]] || { i "fix14: initrd.img-$rel has no modules, prep skips it"; continue; }
    NINITRD=$((NINITRD+1))
    LIST=$(in_chroot lsinitramfs "/boot/initrd.img-$rel" 2>/dev/null || true)
    ORDER=$(in_chroot sh -c "unmkinitramfs /boot/initrd.img-$rel /tmp/pyra-selftest-x >/dev/null 2>&1 &&
        cat /tmp/pyra-selftest-x/main/scripts/init-top/ORDER 2>/dev/null ||
        cat /tmp/pyra-selftest-x/scripts/init-top/ORDER; rm -rf /tmp/pyra-selftest-x" 2>/dev/null || true)
    for h in pyra-fw-nofallback pyra-settle-nudge; do
        if grep -qx "scripts/init-top/$h" <<<"$LIST"; then
            p "fix14: initrd.img-$rel contains $h"
        else
            f "fix14: initrd.img-$rel lacks $h"
        fi
        hl=$(grep -n "init-top/$h " <<<"$ORDER" | cut -d: -f1 | head -1 || true)
        ul=$(grep -n 'init-top/udev ' <<<"$ORDER" | cut -d: -f1 | head -1 || true)
        if [[ -n $hl && -n $ul && $hl -lt $ul ]]; then
            p "fix14: initrd.img-$rel runs $h before udev"
        else
            f "fix14: initrd.img-$rel does not run $h before udev (ORDER line ${hl:-none}, udev ${ul:-none})"
        fi
    done
    # --grow-on-boot: the hook, the script it runs, and the tools the script
    # needs beyond busybox, all inside the archive.
    for x in scripts/local-premount/pyra-grow-root usr/sbin/pyra-grow-root \
             usr/sbin/sfdisk usr/bin/partx usr/sbin/fsck.f2fs usr/sbin/resize.f2fs; do
        if grep -qx "$x" <<<"$LIST"; then
            p "grow-on-boot: initrd.img-$rel contains $x"
        else
            f "grow-on-boot: initrd.img-$rel lacks $x"
        fi
    done
done
for d in dev sys proc; do umount "$MNT/$d"; done
[[ $NINITRD -gt 0 ]] && p "fix14: checked $NINITRD initrd(s)" || f "fix14: no initrd with modules on the image"

########################################################################
i "assert fix 15 — the Fn keyboard-brightness keys"
########################################################################
K=$MNT/usr/local/sbin/pyra-kbdlight.sh
if [[ -e $K ]] && cmp -s "$PAYLOADS/pyra-kbdlight.sh" "$K"; then
    p "fix15: /usr/local/sbin/pyra-kbdlight.sh matches repo"
else
    f "fix15: /usr/local/sbin/pyra-kbdlight.sh missing or differs from repo"
fi
[[ $(stat -c '%a %u:%g' "$K" 2>/dev/null) == "755 0:0" ]] && p "fix15: pyra-kbdlight.sh is 0755 root:root" || f "fix15: pyra-kbdlight.sh mode is $(stat -c '%a %u:%g' "$K" 2>/dev/null)"
for kv in "fn up" "fnshift down"; do
    if grep -qx "scripts.brightness.${kv% *} = /usr/local/sbin/pyra-kbdlight.sh ${kv#* }" "$MNT/etc/pyrainput.cfg"; then
        p "fix15: /etc/pyrainput.cfg sends ${kv% *} to pyra-kbdlight.sh ${kv#* }"
    else
        f "fix15: /etc/pyrainput.cfg has no ${kv% *} line for pyra-kbdlight.sh"
    fi
done
D=$MNT/etc/systemd/system/pyrainput.service.d/pyra-kbdlight.conf
if [[ -e $D ]] && cmp -s "$PAYLOADS/etc/systemd/system/pyrainput.service.d/pyra-kbdlight.conf" "$D"; then
    p "fix15: pyrainput.service.d/pyra-kbdlight.conf matches repo"
else
    f "fix15: pyrainput.service.d/pyra-kbdlight.conf missing or differs from repo"
fi
[[ $(stat -c '%a %u:%g' "$D" 2>/dev/null) == "644 0:0" ]] && p "fix15: the drop-in is 0644 root:root" || f "fix15: the drop-in mode is $(stat -c '%a %u:%g' "$D" 2>/dev/null)"
# It must reload through the script, ignoring failure, and the unit it extends must exist.
if grep -qx 'ExecStartPost=-/usr/local/sbin/pyra-kbdlight.sh --reload $MAINPID' "$D" 2>/dev/null && [[ -n ${PYRAUNIT:-} ]]; then
    p "fix15: pyrainput.service reloads through pyra-kbdlight.sh at start"
else
    f "fix15: the drop-in has no ExecStartPost reload, or there is no pyrainput.service"
fi
# The vendor script stays the package's own: nothing diverts or edits it.
if [[ -e $MNT/usr/share/pyra/scripts/pyra-brightkey.sh ]] &&
   ! grep -qs 'pyra-brightkey' "$MNT/var/lib/dpkg/diversions"; then
    p "fix15: the vendor pyra-brightkey.sh is in place and not diverted"
else
    f "fix15: the vendor pyra-brightkey.sh is missing or diverted"
fi

########################################################################
i "assert fix 16 — the governor setting"
########################################################################
for g in "pyra-governor-tune.sh /usr/local/sbin 755" "pyra-governor-tune.service /etc/systemd/system 644"; do
    read -r name dir mode <<<"$g"
    G=$MNT$dir/$name
    if [[ -e $G ]] && cmp -s "$PAYLOADS/$name" "$G"; then
        p "fix16: $dir/$name matches repo"
    else
        f "fix16: $dir/$name missing or differs from repo"
    fi
    [[ $(stat -c '%a %u:%g' "$G" 2>/dev/null) == "$mode 0:0" ]] && p "fix16: $name is $mode root:root" || f "fix16: $name mode is $(stat -c '%a %u:%g' "$G" 2>/dev/null)"
done
[[ $(readlink "$MNT/etc/systemd/system/multi-user.target.wants/pyra-governor-tune.service" 2>/dev/null) == /etc/systemd/system/pyra-governor-tune.service ]] \
    && p "fix16: enabled in multi-user.target" \
    || f "fix16: not enabled"

########################################################################
i "assert fix 17 — the PulseAudio script, chosen per boot"
########################################################################
while read -r src dir mode; do
    A=$MNT$dir/$(basename "$src")
    if [[ -e $A ]] && cmp -s "$PAYLOADS/$src" "$A"; then
        p "fix17: $dir/$(basename "$src") matches repo"
    else
        f "fix17: $dir/$(basename "$src") missing or differs from repo"
    fi
    [[ $(stat -c '%a %u:%g' "$A" 2>/dev/null) == "$mode 0:0" ]] && p "fix17: $(basename "$src") is $mode root:root" || f "fix17: $(basename "$src") mode is $(stat -c '%a %u:%g' "$A" 2>/dev/null)"
done <<'FILES'
pyra-audio-select.sh /usr/local/sbin 755
pyra-audio-select.service /etc/systemd/system 644
pulse/zz-pyra-aess.conf /usr/local/share/pyra-audio 644
pulse/pyra-aess.pa /etc/pulse 644
pulse/alsa-mixer/profile-sets/pyra-aess.conf /etc/pulse/pyra-alsa-mixer/profile-sets 644
pulse/alsa-mixer/paths/pyra-speaker.conf /usr/share/pulseaudio/alsa-mixer/paths 644
pulse/alsa-mixer/paths/pyra-headphones.conf /usr/share/pulseaudio/alsa-mixer/paths 644
FILES
# Dangling on the PC as on any boot until the unit fills /run, which is the
# point: until then the packaged pyra.conf and pyra.pa are what apply.
[[ $(readlink "$MNT/etc/pulse/daemon.conf.d/zz-pyra-aess.conf" 2>/dev/null) == /run/pyra-audio/zz-pyra-aess.conf ]] \
    && p "fix17: daemon.conf.d/zz-pyra-aess.conf links into /run/pyra-audio" \
    || f "fix17: daemon.conf.d/zz-pyra-aess.conf is not the link into /run"
[[ -e $MNT/etc/pulse/daemon.conf.d/pyra.conf && -e $MNT/etc/pulse/pyra.pa ]] \
    && p "fix17: the packaged pyra.conf and pyra.pa are still in place" \
    || f "fix17: the packaged pyra.conf or pyra.pa is missing"
[[ $(readlink "$MNT/etc/systemd/system/multi-user.target.wants/pyra-audio-select.service" 2>/dev/null) == /etc/systemd/system/pyra-audio-select.service ]] \
    && p "fix17: enabled in multi-user.target" \
    || f "fix17: not enabled"

########################################################################
i "assert fix 18 — pyra-keypad-rescue, a manual tool with no unit"
########################################################################
K=$MNT/usr/local/sbin/pyra-keypad-rescue
if [[ -e $K ]] && cmp -s "$PAYLOADS/pyra-keypad-rescue" "$K"; then
    p "fix18: /usr/local/sbin/pyra-keypad-rescue matches repo"
else
    f "fix18: /usr/local/sbin/pyra-keypad-rescue missing or differs from repo"
fi
[[ $(stat -c '%a %u:%g' "$K" 2>/dev/null) == "755 0:0" ]] && p "fix18: pyra-keypad-rescue is 0755 root:root" || f "fix18: pyra-keypad-rescue mode is $(stat -c '%a %u:%g' "$K" 2>/dev/null)"
sh -n "$K" 2>/dev/null && p "fix18: pyra-keypad-rescue parses as /bin/sh" || f "fix18: pyra-keypad-rescue is not valid /bin/sh"
# Prep installs no packages, so the tool works only if the image ships these.
for t in i2cget i2cset; do
    [[ -x $MNT/usr/sbin/$t ]] && p "fix18: the image ships /usr/sbin/$t" || f "fix18: the image has no /usr/sbin/$t"
done

########################################################################
i "assert fix 19 — the shipped kernel, and the two scripts that manage it"
########################################################################
for s in pyra-install-debug-kernel.sh pyra-boot-kernel.sh; do
    K=$MNT/usr/local/sbin/$s
    if [[ -e $K ]] && cmp -s "$PAYLOADS/$s" "$K"; then
        p "fix19: /usr/local/sbin/$s matches repo"
    else
        f "fix19: /usr/local/sbin/$s missing or differs from repo"
    fi
    [[ $(stat -c '%a %u:%g' "$K" 2>/dev/null) == "755 0:0" ]] && p "fix19: $s is 0755 root:root" || f "fix19: $s mode is $(stat -c '%a %u:%g' "$K" 2>/dev/null)"
done
EXT=$MNT/boot/extlinux
# One l5 entry, booting the kernel, its dtbs and its initrd, with the
# stock entry's append line copied verbatim.
ENTRY=$(awk -v want="label $KSLOT" '$0 == want {f=1; print; next} /^label /{f=0} f' "$EXT/user.cfg")
[[ $(grep -cx "label $KSLOT" "$EXT/user.cfg") -eq 1 ]] && p "fix19: user.cfg has one $KSLOT entry" || f "fix19: user.cfg has $(grep -cx "label $KSLOT" "$EXT/user.cfg") $KSLOT entries"
for want in "linux /vmlinuz-$KREL" "fdtdir /dtb/linux-image-$KREL" "initrd /initrd.img-$KREL"; do
    grep -qx "[[:space:]]*$want" <<<"$ENTRY" && p "fix19: $KSLOT has '$want'" || f "fix19: $KSLOT lacks '$want'"
done
A0=$(awk '/^label l0$/{f=1} f&&/^[[:space:]]*append /{print; exit}' "$EXT/linux.cfg")
A5=$(grep -m1 '^[[:space:]]*append ' <<<"$ENTRY" || true)
[[ -n $A0 && $(echo $A0) == "$(echo $A5)" ]] && p "fix19: $KSLOT's append line is l0's" || f "fix19: $KSLOT's append line differs from l0's"
tar xzOf "$KTAR" "./boot/vmlinuz-$KREL" | cmp -s - "$MNT/boot/vmlinuz-$KREL" \
    && p "fix19: /boot/vmlinuz-$KREL is the tarball's" || f "fix19: /boot/vmlinuz-$KREL missing or not the tarball's"
[[ -s $MNT/boot/initrd.img-$KREL ]] && p "fix19: /boot/initrd.img-$KREL was built" || f "fix19: no /boot/initrd.img-$KREL"
compgen -G "$MNT/boot/dtb/linux-image-$KREL/*.dtb" >/dev/null && p "fix19: its dtbs are in /boot/dtb" || f "fix19: no dtbs for $KREL"
[[ -s $MNT/usr/lib/modules/$KREL/modules.dep ]] && p "fix19: its modules are installed and depmod ran" || f "fix19: no modules.dep for $KREL"
[[ -L $MNT/lib ]] && p "fix19: /lib is still a symlink" || f "fix19: /lib is no longer a symlink"
# The M4 blacklist only the installer writes (R7). The shipped kernel has
# omap_remoteproc, so it must be there.
find "$MNT/usr/lib/modules/$KREL" -name 'omap_remoteproc.ko*' | grep -q . \
    && p "fix19: $KREL carries omap_remoteproc" || f "fix19: $KREL has no omap_remoteproc"
grep -qx 'blacklist omap_remoteproc' "$MNT/etc/modprobe.d/pyra-m4-noautoboot.conf" 2>/dev/null \
    && p "fix19: /etc/modprobe.d/pyra-m4-noautoboot.conf blacklists omap_remoteproc" || f "fix19: no M4 modprobe.d blacklist"
[[ $(tr -dc 'a-z0-9' < "$EXT/pyra-base-label" 2>/dev/null) == "$KSLOT" ]] && p "fix19: the base is $KSLOT" || f "fix19: the base is not $KSLOT"
[[ $(awk '/^default /{print $2; exit}' "$EXT/extlinux.conf") == "$KSLOT" ]] && p "fix19: extlinux.conf defaults to $KSLOT" || f "fix19: extlinux.conf does not default to $KSLOT"
# The fallback the docs promise: l0 untouched, the vendor's conf kept.
grep -qx 'label l0' "$EXT/linux.cfg" && grep -qx 'default l0' "$EXT/extlinux.conf.orig" 2>/dev/null \
    && p "fix19: l0 is still in linux.cfg and extlinux.conf.orig keeps 'default l0'" || f "fix19: the l0 fallback or extlinux.conf.orig is missing"
[[ ! -e $MNT/etc/systemd/system/sysinit.target.wants/pyra-boot-revert.service ]] \
    && p "fix19: no one-shot revert is armed" || f "fix19: the one-shot revert is armed"
[[ ! -e $MNT/var/tmp/pyra-prep-kernel.tar.gz ]] && p "fix19: no staged tarball left in /var/tmp" || f "fix19: the staged tarball is still in /var/tmp"

########################################################################
i "assert fix 20 — MATE leaves the keyboard light alone on battery"
########################################################################
SD=usr/share/glib-2.0/schemas
O=$MNT/$SD/99_pyra_kbdlight.gschema.override
if [[ -e $O ]] && cmp -s "$PAYLOADS/$SD/99_pyra_kbdlight.gschema.override" "$O"; then
    p "fix20: /$SD/99_pyra_kbdlight.gschema.override matches repo"
else
    f "fix20: /$SD/99_pyra_kbdlight.gschema.override missing or differs from repo"
fi
[[ $(stat -c '%a %u:%g' "$O" 2>/dev/null) == "644 0:0" ]] && p "fix20: the override is 0644 root:root" || f "fix20: the override mode is $(stat -c '%a %u:%g' "$O" 2>/dev/null)"
[[ $MNT/$SD/gschemas.compiled -nt $O ]] && p "fix20: gschemas.compiled is newer than the override" || f "fix20: gschemas.compiled was not rebuilt after the override"
# The compiled defaults, as a new user sees them: no dconf database involved.
for kv in "kbd-backlight-battery-reduce false" "idle-dim-ac false" "backlight-enable false"; do
    got=$(in_chroot env GSETTINGS_BACKEND=memory gsettings get org.mate.power-manager "${kv% *}" 2>/dev/null || true)
    [[ $got == "${kv#* }" ]] && p "fix20: ${kv% *} defaults to ${kv#* }" || f "fix20: ${kv% *} defaults to '$got', want ${kv#* }"
done

########################################################################
i "assert fix 21 — the SGX window system no longer closes a descriptor twice"
########################################################################
# The hashes are the device script's own, so test and fix can't disagree on them.
# The image is trixie, so its row is dri3wsegl-pyra 0.4's.
WSEGL=$PAYLOADS/pyra-wsegl-fdfix.sh
SHA_STOCK=$(awk '$1 == "0.4-trixie" {print $2}' "$WSEGL")
SHA_FIXED=$(awk '$1 == "0.4-trixie" {print $3}' "$WSEGL")
WL=$MNT/usr/lib/libpvrDRI3WSEGL.so
[[ $(sha256sum < "$WL" | cut -d' ' -f1) == "$SHA_FIXED" ]] && p "fix21: /usr/lib/libpvrDRI3WSEGL.so has the fixed SHA-256" || f "fix21: /usr/lib/libpvrDRI3WSEGL.so is not the fixed build"
[[ $(sha256sum < "$WL.stock" 2>/dev/null | cut -d' ' -f1) == "$SHA_STOCK" ]] && p "fix21: libpvrDRI3WSEGL.so.stock is the vendor's stock build" || f "fix21: libpvrDRI3WSEGL.so.stock is missing or not the stock build"
for x in "$WL" "$WL.stock"; do
    [[ $(stat -c '%a %u:%g' "$x" 2>/dev/null) == "644 0:0" ]] && p "fix21: $(basename "$x") is 0644 root:root" || f "fix21: $(basename "$x") mode is $(stat -c '%a %u:%g' "$x" 2>/dev/null)"
done
compgen -G "$WL.*.tmp" >/dev/null && f "fix21: a temporary file is left: $(ls "$WL".*.tmp)" || p "fix21: no temporary file left"
for spec in pyra-wsegl-fdfix.sh:/usr/local/sbin:755 \
            pyra-wsegl-guard:/usr/local/sbin:755 \
            etc/dpkg/dpkg.cfg.d/pyra-wsegl-guard:/etc/dpkg/dpkg.cfg.d:644; do
    IFS=: read -r src dir mode <<<"$spec"
    K=$MNT$dir/$(basename "$src")
    if [[ -e $K ]] && cmp -s "$PAYLOADS/$src" "$K"; then
        p "fix21: ${K#$MNT} matches repo"
    else
        f "fix21: ${K#$MNT} missing or differs from repo"
    fi
    [[ $(stat -c '%a %u:%g' "$K" 2>/dev/null) == "$mode 0:0" ]] && p "fix21: ${K#$MNT} is $mode root:root" || f "fix21: ${K#$MNT} mode is $(stat -c '%a %u:%g' "$K" 2>/dev/null), want $mode 0:0"
done
# The card's own copy, run by the image's /bin/sh, as a user would on the device.
WST=$(in_chroot /usr/local/sbin/pyra-wsegl-fdfix.sh status 2>&1 || true)
[[ $WST == $'/usr/lib/libpvrDRI3WSEGL.so: fixed\n/usr/lib/libpvrDRI3WSEGL.so.stock: stock' ]] \
    && p "fix21: on the card, pyra-wsegl-fdfix.sh status reads fixed, with the stock copy" || f "fix21: on the card, status says: ${WST//$'\n'/; }"

########################################################################
i "assert fix 22 — pyra-backlight, installed by the image's dpkg"
########################################################################
if [[ ${KARGS[*]} != *--no-backlight* ]]; then
    if [[ -n $BDEB ]]; then
        BVER=$(bsdtar -xOf "$BDEB" 'control.tar.*' | bsdtar -xOf - ./control | awk '/^Version:/{print $2}')
    else
        BVER=$(sed -n 's/^BACKLIGHT_TAG=v//p' "$PREP")
        grep -qF 'fix22: the download matches the pinned SHA-256' "$OUT/prep-run1.log" \
            && p "fix22: run 1 downloaded pyra-backlight $BVER and it matched the pin" || f "fix22: run 1 did not report a matching download"
    fi
    BST=$(in_chroot dpkg-query -W -f='${Version} ${db:Status-Abbrev}' pyra-backlight 2>/dev/null || true)
    [[ $BST == "$BVER ii"* ]] && p "fix22: dpkg has pyra-backlight $BVER installed and configured" || f "fix22: dpkg says '$BST', want $BVER ii"
    GST=$(in_chroot dpkg-query -W -f='${Version} ${db:Status-Abbrev}' gir1.2-matepanelapplet-4.0 2>/dev/null || true)
    [[ $GST == "1.27.1-4.1 ii"* ]] && p "fix22: the vendor image's missing gir1.2-matepanelapplet-4.0 1.27.1-4.1 is installed" || f "fix22: gir1.2-matepanelapplet-4.0 is '$GST'"
    for x in /usr/bin/pyra-idle-dim /usr/libexec/pyra-brightness-applet; do
        [[ -x $MNT$x ]] && p "fix22: $x is installed" || f "fix22: no executable $x"
    done
    for x in /usr/share/mate-panel/applets/org.pyra.BrightnessApplet.mate-panel-applet \
             /usr/share/dbus-1/services/org.mate.panel.applet.PyraBrightnessAppletFactory.service; do
        [[ -f $MNT$x ]] && p "fix22: $(basename "$x") is installed" || f "fix22: no $x"
    done
    [[ $(readlink "$MNT/etc/systemd/user/default.target.wants/pyra-idle-dim.service") == */pyra-idle-dim.service ]] \
        && p "fix22: pyra-idle-dim.service is enabled for every user" || f "fix22: pyra-idle-dim.service is not enabled in /etc/systemd/user"
    BAUDIT=$(in_chroot dpkg --audit pyra-backlight 2>&1 || true)
    [[ -z $BAUDIT ]] && p "fix22: dpkg --audit finds nothing wrong with pyra-backlight" || f "fix22: dpkg --audit: $(head -3 <<<"$BAUDIT" | tr '\n' ' ')"
    for x in usr/share/mate-panel/layouts/pyra-backlight.layout $SD/99_pyra_panel.gschema.override; do
        cmp -s "$PAYLOADS/$x" "$MNT/$x" && [[ $(stat -c '%a %u:%g' "$MNT/$x") == "644 0:0" ]] \
            && p "fix22: /$x matches repo, 0644 root:root" || f "fix22: /$x missing, differs from repo or has the wrong mode"
    done
    # Ours is the vendor's layout with one object appended; a vendor update to
    # pyra.layout would leave ours behind.
    VL=$MNT/usr/share/mate-panel/layouts/pyra.layout
    [[ -f $VL ]] && cmp -s "$VL" <(head -c "$(stat -c %s "$VL")" "$PAYLOADS/usr/share/mate-panel/layouts/pyra-backlight.layout") \
        && p "fix22: the layout is the image's pyra.layout plus the applet" || f "fix22: the image's pyra.layout is not the start of pyra-backlight.layout; the vendor's layout changed"
    got=$(in_chroot env GSETTINGS_BACKEND=memory gsettings get org.mate.panel default-layout 2>/dev/null || true)
    [[ $got == "'pyra-backlight'" ]] && p "fix22: org.mate.panel default-layout defaults to 'pyra-backlight'" || f "fix22: org.mate.panel default-layout defaults to $got"
else
    printf '\e[33mSKIP\e[0m  fix22: assertions (PYRA_BACKLIGHT_DEB=none)\n'
    in_chroot dpkg-query -W pyra-backlight >/dev/null 2>&1 \
        && f "fix22: --no-backlight installed pyra-backlight" || p "fix22: with --no-backlight pyra-backlight is not installed"
    [[ ! -e $MNT/$SD/99_pyra_panel.gschema.override && ! -e $MNT/usr/share/mate-panel/layouts/pyra-backlight.layout ]] \
        && p "fix22: and no default panel layout names the missing applet" || f "fix22: --no-backlight installed the panel layout or its override"
fi
compgen -G "$MNT/var/tmp/pyra-prep-*.deb" >/dev/null && f "fix22: a staged .deb is still in /var/tmp" || p "fix22: no staged .deb left in /var/tmp"

########################################################################
i "assert fix 23 — the vendor's shared host keys and machine-id"
########################################################################
HK=pyra-ssh-hostkeys.service
[[ $(grep -c ' etc/ssh/ssh_host_' "$OUT/rootfs-before.txt") -eq 6 ]] && p "fix23: the vendor image had six host key files" || f "fix23: the vendor image had $(grep -c ' etc/ssh/ssh_host_' "$OUT/rootfs-before.txt") host key files, not six"
grep -q "fix23: removed 6 ssh host key files (the vendor's" "$OUT/prep-run1.log" && p "fix23: run 1 recognised the vendor's six host key files and removed them" || f "fix23: run 1 did not report removing the vendor's host keys"
compgen -G "$MNT/etc/ssh/ssh_host_*" >/dev/null && f "fix23: ssh host keys left: $(cd "$MNT/etc/ssh" && ls ssh_host_* | tr '\n' ' ')" || p "fix23: no ssh host keys"
grep -q "fix23: emptied /etc/machine-id (the vendor's)" "$OUT/prep-run1.log" && p "fix23: run 1 recognised the vendor's machine-id" || f "fix23: run 1 did not report emptying the vendor's machine-id"
[[ -f $MNT/etc/machine-id && ! -s $MNT/etc/machine-id ]] && p "fix23: /etc/machine-id is an empty file" || f "fix23: /etc/machine-id is missing or not empty"
[[ $(readlink "$MNT/var/lib/dbus/machine-id") == /etc/machine-id ]] && p "fix23: /var/lib/dbus/machine-id is a link to /etc/machine-id" || f "fix23: /var/lib/dbus/machine-id is not a link to /etc/machine-id"
U=$MNT/etc/systemd/system/$HK
cmp -s "$PAYLOADS/$HK" "$U" && p "fix23: /etc/systemd/system/$HK matches repo" || f "fix23: $HK missing or differs from repo"
[[ $(stat -c '%a %u:%g' "$U" 2>/dev/null) == "644 0:0" ]] && p "fix23: $HK is 0644 root:root" || f "fix23: $HK mode is $(stat -c '%a %u:%g' "$U" 2>/dev/null)"
[[ $(readlink "$MNT/etc/systemd/system/multi-user.target.wants/$HK") == /etc/systemd/system/$HK ]] \
    && p "fix23: $HK enabled in multi-user.target" || f "fix23: $HK not enabled"
grep -qx 'Before=ssh.service ssh.socket' "$U" && grep -qx 'ExecStart=/usr/bin/ssh-keygen -A' "$U" \
    && p "fix23: $HK runs ssh-keygen -A before ssh" || f "fix23: $HK is not ordered before ssh or does not run ssh-keygen -A"
[[ $(readlink "$MNT/etc/systemd/system/systemd-firstboot.service") == /dev/null ]] \
    && p "fix23: systemd-firstboot.service masked" || f "fix23: systemd-firstboot.service not masked"

########################################################################
i "assert fix 24 — MATE shuts down at critical battery"
########################################################################
O=$MNT/$SD/99_pyra_power.gschema.override
cmp -s "$PAYLOADS/$SD/99_pyra_power.gschema.override" "$O" && p "fix24: /$SD/99_pyra_power.gschema.override matches repo" || f "fix24: /$SD/99_pyra_power.gschema.override missing or differs from repo"
[[ $(stat -c '%a %u:%g' "$O" 2>/dev/null) == "644 0:0" ]] && p "fix24: the override is 0644 root:root" || f "fix24: the override mode is $(stat -c '%a %u:%g' "$O" 2>/dev/null)"
[[ $MNT/$SD/gschemas.compiled -nt $O ]] && p "fix24: gschemas.compiled is newer than the override" || f "fix24: gschemas.compiled was not rebuilt after the override"
got=$(in_chroot env GSETTINGS_BACKEND=memory gsettings get org.mate.power-manager action-critical-battery 2>/dev/null || true)
[[ $got == "'shutdown'" ]] && p "fix24: action-critical-battery defaults to 'shutdown'" || f "fix24: action-critical-battery defaults to $got, want 'shutdown'"
for k in action-sleep-type-battery action-sleep-type-ac; do
    got=$(in_chroot env GSETTINGS_BACKEND=memory gsettings get org.mate.power-manager "$k" 2>/dev/null || true)
    [[ $got == "'suspend'" ]] && p "fix24: $k defaults to 'suspend'" || f "fix24: $k defaults to $got, want 'suspend'"
done

########################################################################
i "assert fix 25 — no 30 s polkit timeout or GL check at login"
########################################################################
for x in etc/xdg/pyra/autostart/polkit-ukui-authentication-agent-1.desktop etc/X11/Xsession.d/56pyra_mate-no-accel-check; do
    cmp -s "$PAYLOADS/$x" "$MNT/$x" && p "fix25: /$x matches repo" || f "fix25: /$x missing or differs from repo"
    [[ $(stat -c '%a %u:%g' "$MNT/$x" 2>/dev/null) == "644 0:0" ]] && p "fix25: $(basename "$x") is 0644 root:root" || f "fix25: $(basename "$x") mode is $(stat -c '%a %u:%g' "$MNT/$x" 2>/dev/null)"
done
# The image's own GLib parses the override: mate-session drops an entry it
# cannot load and falls back to the /etc/xdg copy, which is what fix 25 hides.
got=$(in_chroot python3 -c 'from gi.repository import GLib
k = GLib.KeyFile(); k.load_from_file("/etc/xdg/pyra/autostart/polkit-ukui-authentication-agent-1.desktop", 0)
print(k.get_boolean("Desktop Entry", "Hidden"), bool(k.get_string("Desktop Entry", "Exec")))' 2>&1 || true)
[[ $got == "True True" ]] && p "fix25: the ukui override loads, with Hidden and Exec" || f "fix25: the ukui override reads '$got', want Hidden and Exec"
[[ -r $MNT/etc/xdg/autostart/polkit-mate-authentication-agent-1.desktop ]] && p "fix25: mate-polkit's autostart entry is there to take over" || f "fix25: no mate-polkit autostart entry; no polkit agent would run"
got=$(in_chroot sh -c 'STARTUP=x-session-manager; . /etc/X11/Xsession.d/56pyra_mate-no-accel-check; echo "$STARTUP"' 2>&1 || true)
[[ $got == "x-session-manager --disable-acceleration-check" ]] && p "fix25: the image's session starts as '$got'" || f "fix25: the snippet makes STARTUP '$got'"
got=$(in_chroot sh -c 'STARTUP=/home/pyra/.xsession; . /etc/X11/Xsession.d/56pyra_mate-no-accel-check; echo "$STARTUP"' 2>&1 || true)
[[ $got == /home/pyra/.xsession ]] && p "fix25: a user's own ~/.xsession is left alone" || f "fix25: the snippet changed ~/.xsession to '$got'"

########################################################################
i "assert fix 26 — pyra-settings and the pyra-hacks fork, installed by the image's dpkg"
########################################################################
WHEEL12="etc/systemd/system/pyra_volumed.service.d/calibrated.conf usr/local/sbin/pyra-volumed-run usr/local/src/pyra-volumed/pyra_volumed.c"
if [[ $SON == yes ]]; then
    if [[ -n $SDEB ]]; then
        SVER=$(bsdtar -xOf "$SDEB" 'control.tar.*' | bsdtar -xOf - ./control | awk '/^Version:/{print $2}')
    else
        SVER=$(sed -n 's/^SETTINGS_TAG=v//p' "$PREP")
        grep -qF 'fix26: the download matches the pinned SHA-256' "$OUT/prep-run1.log" \
            && p "fix26: run 1 downloaded pyra-settings $SVER and it matched the pin" || f "fix26: run 1 did not report a matching download"
    fi
    HVER=$(sed -n 's/^HACKS_VER=//p' "$PREP")
    SST=$(in_chroot dpkg-query -W -f='${Version} ${db:Status-Abbrev}' pyra-settings 2>/dev/null || true)
    [[ $SST == "$SVER ii"* ]] && p "fix26: dpkg has pyra-settings $SVER installed and configured" || f "fix26: dpkg says '$SST', want $SVER ii"
    HST=$(in_chroot dpkg-query -W -f='${Version} ${db:Status-Abbrev}' pyra-hacks 2>/dev/null || true)
    [[ $HST == "$HVER ii"* ]] && p "fix26: dpkg has the pyra-hacks fork $HVER installed and configured" || f "fix26: pyra-hacks is '$HST', want $HVER ii"
    for x in /usr/bin/pyra-settings /usr/libexec/pyra-settings/pyra-settings-helper; do
        [[ -x $MNT$x ]] && p "fix26: $x is installed" || f "fix26: no executable $x"
    done
    [[ -f $MNT/usr/share/polkit-1/actions/org.pyra.settings.wake.policy ]] && p "fix26: its polkit action is installed" || f "fix26: no polkit action"
    [[ $(readlink "$MNT/etc/systemd/system/multi-user.target.wants/pyra-settings-apply.service") == */pyra-settings-apply.service ]] \
        && p "fix26: pyra-settings-apply.service is enabled" || f "fix26: pyra-settings-apply.service is not enabled"
    SAUDIT=$(in_chroot dpkg --audit 2>&1 || true)
    [[ -z $SAUDIT ]] && p "fix26: dpkg --audit finds nothing wrong" || f "fix26: dpkg --audit: $(head -3 <<<"$SAUDIT" | tr '\n' ' ')"
    # The fork carries fixes 6 and 7: both scripts must find its daemon fixed.
    TD=$MNT/usr/share/pyra/scripts/pyra-thermal.sh
    for fx in pyra-thermal-fix.sh pyra-thermal-ladder.sh; do
        "$PAYLOADS/$fx" --emit-patched "$TD" 2>/dev/null | cmp -s - "$TD" \
            && p "fix26: $fx finds the fork's thermal daemon already fixed" || f "fix26: $fx would change the fork's thermal daemon"
    done
    # The fork's daemon keeps a ceiling from /etc/default/pyra-thermal (0.38+pyra5).
    # Its reader runs under the image's own sh against test files: a valid value
    # lowers the top, anything else leaves 1500, and nothing in the file runs.
    [[ ! -e $MNT/etc/default/pyra-thermal ]] && p "fix26: no /etc/default/pyra-thermal, so no ceiling by default" \
        || f "fix26: prep left an /etc/default/pyra-thermal on the card"
    CT=$MNT/tmp/pyra-ceiling-test; rm -rf "$CT"; mkdir -p "$CT"
    sed -n '/^pyraCeilingConf=/,/^}/p' "$TD" | sed 's|^pyraCeilingConf=.*|pyraCeilingConf=/tmp/pyra-ceiling-test/conf|' > "$CT/reader.sh"
    if grep -q '^pyraReadCeiling()' "$CT/reader.sh" \
        && sed -n '/^doThermal()/,/current_maxFreq=\${maxFreq}/p' "$TD" | grep -q '^[[:space:]]*pyraReadCeiling$'; then
        p "fix26: the fork's daemon reads the ceiling at the start of every pass"
        for c in 'CPU_MAX_MHZ=1000|1000' 'CPU_MAX_MHZ = "875"  # quiet|875' 'CPU_MAX_MHZ=2000|1500' \
                 '#CPU_MAX_MHZ=500|1500' 'CPU_MAX_MHZ=0800|1500' 'CPU_MAX_MHZ=$(touch /tmp/pyra-ceiling-test/ran)|1500' \
                 'none|1500'; do
            IFS='|' read -r line want <<<"$c"
            rm -f "$CT/conf"; [[ $line == none ]] || printf '%s\n' "$line" > "$CT/conf"
            got=$(in_chroot sh -c 'maxFreq=1500; . /tmp/pyra-ceiling-test/reader.sh; pyraReadCeiling; echo $maxFreq' 2>&1)
            [[ $got == "$want" ]] && p "fix26: ceiling file '$line' gives a top of $want MHz" \
                || f "fix26: ceiling file '$line' gives '$got', want $want"
        done
        [[ ! -e $CT/ran ]] || f "fix26: the ceiling reader executed text from its file"
    else
        f "fix26: the fork's daemon has no ceiling reader called from doThermal (pyra-hacks older than 0.38+pyra5?)"
    fi
    rm -rf "$CT"
    W=0; for x in $WHEEL12; do [[ -e $MNT/$x ]] && W=1; done
    [[ $W -eq 0 ]] && p "fix26: fix 12 stood aside; the packaged unit runs the fork's pyra_volumed" || f "fix26: fix 12's files are on the card beside the fork"
    for spec in pyra-wheel-guard:/usr/local/sbin:755 \
                etc/dpkg/dpkg.cfg.d/pyra-wheel-guard:/etc/dpkg/dpkg.cfg.d:644; do
        IFS=: read -r src dir mode <<<"$spec"
        D=$MNT$dir/$(basename "$src")
        [[ -e $D ]] && cmp -s "$PAYLOADS/$src" "$D" && p "fix26: ${D#$MNT} matches repo" || f "fix26: ${D#$MNT} missing or differs from repo"
        [[ $(stat -c '%a %u:%g' "$D" 2>/dev/null) == "$mode 0:0" ]] \
            || f "fix26: ${D#$MNT} mode is $(stat -c '%a %u:%g' "$D" 2>/dev/null), want $mode 0:0"
    done
else
    printf '\e[33mSKIP\e[0m  fix26: assertions (no pyra-settings in this run)\n'
    in_chroot dpkg-query -W pyra-settings >/dev/null 2>&1 \
        && f "fix26: pyra-settings is installed though this run asked for none" || p "fix26: pyra-settings is not installed"
    W=1; for x in $WHEEL12; do [[ -e $MNT/$x ]] || W=0; done
    [[ $W -eq 1 ]] && p "fix26: without it, fix 12's calibrated wheel is in place" || f "fix26: without pyra-settings, fix 12's files are missing"
    [[ ! -e $MNT/usr/local/sbin/pyra-wheel-guard && ! -e $MNT/etc/dpkg/dpkg.cfg.d/pyra-wheel-guard ]] \
        && p "fix26: without the fork, no pyra-wheel-guard" || f "fix26: pyra-wheel-guard is on a card without the fork"
fi
# The wheel guard's judgement, from the payload, on versions it is handed: a
# +pyra version or fix 12's drop-in is a calibrated wheel, anything else warns.
WG=$PAYLOADS/pyra-wheel-guard
WDROP=$(mktemp)
for c in "0.38+pyra4|/nonexistent|silent" "0.39+pyra1|/nonexistent|silent" "0.38|/nonexistent|warn" \
         "0.39|/nonexistent|warn" "0.38|$WDROP|silent" "|/nonexistent|silent"; do
    IFS='|' read -r v d want <<<"$c"
    WGO=$(PYRA_HACKS_VERSION=$v PYRA_WHEEL_DROPIN=$d "$WG" 2>&1); WGRC=$?
    got=silent; grep -q 'THE VOLUME WHEEL IS NOT CALIBRATED' <<<"$WGO" && got=warn
    [[ -n $WGO && $got == silent ]] && got="'$WGO'"
    dl=absent; [[ $d == "$WDROP" ]] && dl=present
    [[ $got == "$want" && $WGRC -eq 0 ]] \
        && p "wheel guard: pyra-hacks '${v:-none}', drop-in $dl: $want" \
        || f "wheel guard: pyra-hacks '${v:-none}', drop-in $dl: got $got (exit $WGRC), want $want"
done
rm -f "$WDROP"

########################################################################
i "assert fix 27 — pyra-sound, installed by the image's dpkg, masks MATE's sound icon"
########################################################################
SOMASK=/etc/xdg/pyra/autostart/mate-volume-control-status-icon.desktop
if [[ $SOON == yes ]]; then
    if [[ -n $SODEB ]]; then
        SOVER=$(bsdtar -xOf "$SODEB" 'control.tar.*' | bsdtar -xOf - ./control | awk '/^Version:/{print $2}')
    else
        SOVER=$(sed -n 's/^SOUND_TAG=v//p' "$PREP")
        grep -qF 'fix27: the download matches the pinned SHA-256' "$OUT/prep-run1.log" \
            && p "fix27: run 1 downloaded pyra-sound $SOVER and it matched the pin" || f "fix27: run 1 did not report a matching download"
    fi
    SOST=$(in_chroot dpkg-query -W -f='${Version} ${db:Status-Abbrev}' pyra-sound 2>/dev/null || true)
    [[ $SOST == "$SOVER ii"* ]] && p "fix27: dpkg has pyra-sound $SOVER installed and configured" || f "fix27: dpkg says '$SOST', want $SOVER ii"
    [[ -x $MNT/usr/bin/pyra-sound ]] && p "fix27: /usr/bin/pyra-sound is installed" || f "fix27: no executable /usr/bin/pyra-sound"
    grep -qx 'Exec=pyra-sound' "$MNT/etc/xdg/autostart/pyra-sound.desktop" 2>/dev/null \
        && p "fix27: it starts at login (/etc/xdg/autostart/pyra-sound.desktop)" || f "fix27: no autostart entry for pyra-sound"
    in_chroot grep -qx 'Hidden=true' "$SOMASK" 2>/dev/null \
        && p "fix27: $SOMASK hides MATE's sound icon" || f "fix27: no Hidden=true mask at $SOMASK"
    grep -qs 'XDG_CONFIG_DIRS=/etc/xdg/pyra' "$MNT/etc/X11/Xsession.d/65pyra_xdg-config" \
        && p "fix27: the image puts /etc/xdg/pyra first in XDG_CONFIG_DIRS, so the mask applies" || f "fix27: nothing puts /etc/xdg/pyra in XDG_CONFIG_DIRS"
    SAUDIT=$(in_chroot dpkg --audit 2>&1 || true)
    [[ -z $SAUDIT ]] && p "fix27: dpkg --audit finds nothing wrong" || f "fix27: dpkg --audit: $(head -3 <<<"$SAUDIT" | tr '\n' ' ')"
else
    printf '\e[33mSKIP\e[0m  fix27: assertions (no pyra-sound in this run)\n'
    in_chroot dpkg-query -W pyra-sound >/dev/null 2>&1 \
        && f "fix27: pyra-sound is installed though this run asked for none" || p "fix27: pyra-sound is not installed"
    [[ ! -e $MNT$SOMASK ]] && p "fix27: and MATE's sound icon is not masked" || f "fix27: MATE's sound icon is masked without pyra-sound"
fi

########################################################################
i "assert fix 28 — the Fn symbols under X and on the console"
########################################################################
# The pins are prep's own, so test and fix can't disagree on them; the fixed
# file is also checked against the repository's patch applied here.
FN_XKB=/usr/share/X11/xkb/symbols/pyra
FN_STOCK=$(sed -n 's/^FN_XKB_STOCK_SHA256=\([0-9a-f]*\).*/\1/p' "$PREP")
FN_FIXED=$(sed -n 's/^FN_XKB_FIXED_SHA256=\([0-9a-f]*\).*/\1/p' "$PREP")
FN_PATCH=$ROOT/patches/userspace/pyra-config-xorg/0001-fn-d-and-fn-apostrophe-not-alt-r-t-accents.patch
FN_KMAP=$PAYLOADS/etc/console-setup/pyra-fn.kmap
FN_REMAP=$MNT/etc/console-setup/remap.inc
FN_CACHE=$MNT/etc/console-setup/cached_UTF-8_del.kmap.gz
got=$(in_chroot dpkg-divert --truename "$FN_XKB" 2>/dev/null || true)
pkg=$(in_chroot dpkg-divert --listpackage "$FN_XKB" 2>/dev/null || true)
[[ $got == "$FN_XKB.dist" && $pkg == LOCAL ]] && p "fix28: dpkg diverts $FN_XKB to pyra.dist (a local diversion)" || f "fix28: diversion of $FN_XKB is '$got' by '$pkg', want $FN_XKB.dist by LOCAL"
[[ $(sha256sum < "$MNT$FN_XKB.dist" 2>/dev/null | cut -d' ' -f1) == "$FN_STOCK" ]] && p "fix28: pyra.dist is pyra-config-xorg's stock keymap" || f "fix28: pyra.dist is missing or not the stock keymap"
[[ $(sha256sum < "$MNT$FN_XKB" 2>/dev/null | cut -d' ' -f1) == "$FN_FIXED" ]] && p "fix28: $FN_XKB has the fixed SHA-256" || f "fix28: $FN_XKB is not the fixed keymap"
FN_TMP=$OUT/pyra.fixed
if patch --no-backup-if-mismatch -s -o "$FN_TMP" "$MNT$FN_XKB.dist" <"$FN_PATCH" >/dev/null 2>&1 && cmp -s "$FN_TMP" "$MNT$FN_XKB"; then
    p "fix28: $FN_XKB is the repository's patch applied to the stock file"
else
    f "fix28: $FN_XKB differs from the repository's patch applied to pyra.dist"
fi
for x in "$FN_XKB" "$FN_XKB.dist" /etc/console-setup/remap.inc /etc/console-setup/cached_UTF-8_del.kmap.gz; do
    [[ $(stat -c '%a %u:%g' "$MNT$x" 2>/dev/null) == "644 0:0" ]] && p "fix28: $x is 0644 root:root" || f "fix28: $x mode is $(stat -c '%a %u:%g' "$MNT$x" 2>/dev/null)"
done
grep -qF 'fix28: X types _ and : with Fn+D and Fn+'"'"' (not Alt' "$OUT/prep-run1.log" \
    && p "fix28: run 1 compiled the keymap with the image's xkbcomp and read back the three keys" || f "fix28: run 1 did not report the compiled keymap's check"
# remap.inc: the vendor's lines, then one marked block that is the repo fragment.
FN_BEGIN='# >>> pyra-fn: the Pyra Fn layer (dragonbox-pyra prep, fix 28)'
FN_END='# <<< pyra-fn'
[[ $(grep -cxF "$FN_BEGIN" "$FN_REMAP") -eq 1 && $(grep -cxF "$FN_END" "$FN_REMAP") -eq 1 ]] \
    && p "fix28: remap.inc has one Fn block" || f "fix28: remap.inc has $(grep -cxF "$FN_BEGIN" "$FN_REMAP") begin and $(grep -cxF "$FN_END" "$FN_REMAP") end markers, want one each"
[[ $(awk -v b="$FN_BEGIN" -v e="$FN_END" '$0 == e {s = 0} s {print} $0 == b {s = 1}' "$FN_REMAP") == "$(cat "$FN_KMAP")" ]] \
    && p "fix28: the block matches device/etc/console-setup/pyra-fn.kmap" || f "fix28: the block in remap.inc differs from pyra-fn.kmap"
[[ $(awk -v b="$FN_BEGIN" '$0 == b {exit} {print}' "$FN_REMAP") == "$(cat "$OUT/remap.inc.vendor")" ]] \
    && p "fix28: the vendor's remap.inc lines are kept, unchanged, above the block" || f "fix28: the lines above the block differ from the vendor's remap.inc"
# The console loads the cached keymap at boot: every line of the fragment must be in it.
FN_MISSING=$(grep '^keycode' "$FN_KMAP" | grep -vxFf <(zcat "$FN_CACHE" 2>/dev/null) || true)
[[ -r $FN_CACHE && -z $FN_MISSING ]] && p "fix28: the cached console keymap has all $(grep -c '^keycode' "$FN_KMAP") Fn keycode lines" || f "fix28: the cached console keymap lacks: ${FN_MISSING//$'\n'/; }"
# setupcon makes its temporary files in /run, else /tmp, and removes them on exit.
FN_LEFT=$(compgen -G "$MNT/run/tmpkbd.*"; compgen -G "$MNT/tmp/tmpkbd.*") || true
[[ -z $FN_LEFT ]] && p "fix28: setupcon left no temporary file in the image" || f "fix28: setupcon left: ${FN_LEFT//$'\n'/ }"

########################################################################
i "assert fix 29 — the rebuilt funkeymonkey-pyrainput, its unit, and the input guard"
########################################################################
PIUNIT=/usr/lib/systemd/system/pyrainput.service
PIWANTS=/etc/systemd/system/multi-user.target.wants/pyrainput.service
PILIB=$MNT/usr/lib/funkeymonkey/libpyrainput.so
# The unit fix 3 writes, from prep itself: the package's must be the same.
FIX3UNIT=$OUT/fix3-pyrainput.service
awk '/^    cat > "\$UNIT" <<.EOF.$/ {s = 1; next} s && /^EOF$/ {exit} s' "$PREP" > "$FIX3UNIT"
[[ -s $FIX3UNIT ]] || f "fix29: could not read fix 3's unit out of prep"
if [[ $PION == yes ]]; then
    [[ -z $PIDEB ]] && { grep -qF 'fix29: the download matches the pinned SHA-256' "$OUT/prep-run1.log" \
        && p "fix29: run 1 downloaded funkeymonkey-pyrainput $PIVER and it matched the pin" || f "fix29: run 1 did not report a matching download"; }
    PST=$(in_chroot dpkg-query -W -f='${Version} ${db:Status-Abbrev}' funkeymonkey-pyrainput 2>/dev/null || true)
    [[ $PST == "$PIVER ii"* ]] && p "fix29: dpkg has funkeymonkey-pyrainput $PIVER installed and configured" || f "fix29: dpkg says '$PST', want $PIVER ii"
    [[ $(in_chroot dpkg-query -S "$PIUNIT" 2>/dev/null) == "funkeymonkey-pyrainput: $PIUNIT" ]] \
        && p "fix29: the package owns $PIUNIT" || f "fix29: $PIUNIT is not funkeymonkey-pyrainput's"
    cmp -s "$FIX3UNIT" "$MNT$PIUNIT" && p "fix29: its unit is byte-identical to fix 3's" || f "fix29: its unit differs from fix 3's"
    in_chroot test -e "$PIWANTS" && p "fix29: pyrainput.service is enabled ($PIWANTS resolves)" || f "fix29: $PIWANTS is missing or dangling"
    # 0003's names, as strings in the library: the vendor's has the bad ones.
    if ! grep -qaE 'PYRA_KEY_RIFHT|PYRA_KEY_PAUSE' "$PILIB" && grep -qa 'PYRA_KEY_FN_ESC' "$PILIB"; then
        p "fix29: libpyrainput.so has 0003's key names and none of the four bad ones"
    else
        f "fix29: libpyrainput.so still names PYRA_KEY_RIFHT or PYRA_KEY_PAUSE"
    fi
    SAUDIT=$(in_chroot dpkg --audit 2>&1 || true)
    [[ -z $SAUDIT ]] && p "fix29: dpkg --audit finds nothing wrong" || f "fix29: dpkg --audit: $(head -3 <<<"$SAUDIT" | tr '\n' ' ')"
    for spec in pyra-input-guard:/usr/local/sbin:755 \
                etc/dpkg/dpkg.cfg.d/pyra-input-guard:/etc/dpkg/dpkg.cfg.d:644; do
        IFS=: read -r src dir mode <<<"$spec"
        D=$MNT$dir/$(basename "$src")
        [[ -e $D ]] && cmp -s "$PAYLOADS/$src" "$D" && p "fix29: ${D#$MNT} matches repo" || f "fix29: ${D#$MNT} missing or differs from repo"
        [[ $(stat -c '%a %u:%g' "$D" 2>/dev/null) == "$mode 0:0" ]] && p "fix29: ${D#$MNT} is $mode root:root" \
            || f "fix29: ${D#$MNT} mode is $(stat -c '%a %u:%g' "$D" 2>/dev/null), want $mode 0:0"
    done
else
    printf '\e[33mSKIP\e[0m  fix29: assertions (no rebuilt funkeymonkey-pyrainput in this run)\n'
    PST=$(in_chroot dpkg-query -W -f='${Version}' funkeymonkey-pyrainput 2>/dev/null || true)
    [[ $PST != *+pyra* ]] && p "fix29: the vendor's funkeymonkey-pyrainput $PST stays" || f "fix29: $PST is installed though this run asked for none"
    [[ ! -e $MNT/usr/local/sbin/pyra-input-guard && ! -e $MNT/etc/dpkg/dpkg.cfg.d/pyra-input-guard ]] \
        && p "fix29: without it, no pyra-input-guard" || f "fix29: pyra-input-guard is on a card without the rebuilt package"
fi
# The input guard's judgement, from the payload, on versions it is handed, with
# the unit and its link in a scratch directory: a +pyra version or none is
# silent and writes nothing; anything else warns, and puts back a missing unit
# (fix 3's, byte for byte) and its link.
IG=$PAYLOADS/pyra-input-guard
for c in "0.1.19+pyra1|silent" "0.1.20+pyra1|silent" "|silent" "0.1.19|warn" "0.1.20|warn"; do
    IFS='|' read -r v want <<<"$c"
    IGD=$(mktemp -d)
    IGO=$(PYRA_PYRAINPUT_VERSION=$v PYRA_INPUT_UNIT=$IGD/pyrainput.service PYRA_INPUT_WANTS=$IGD/wants/pyrainput.service "$IG" 2>&1); IGRC=$?
    got=silent; grep -q 'THE INPUT DAEMON IS NOT THE FIXED BUILD' <<<"$IGO" && got=warn
    [[ -n $IGO && $got == silent ]] && got="'$IGO'"
    [[ $got == "$want" && $IGRC -eq 0 ]] \
        && p "input guard: funkeymonkey-pyrainput '${v:-none}': $want" \
        || f "input guard: funkeymonkey-pyrainput '${v:-none}': got $got (exit $IGRC), want $want"
    if [[ $want == warn ]]; then
        cmp -s "$FIX3UNIT" "$IGD/pyrainput.service" && [[ $(readlink "$IGD/wants/pyrainput.service") == "$IGD/pyrainput.service" ]] \
            && grep -q "put fix 3's back" <<<"$IGO" \
            && p "input guard: '$v' with no unit puts fix 3's unit and its link back, and says so" \
            || f "input guard: '$v' did not restore fix 3's unit and its link"
    else
        [[ -z $(ls -A "$IGD") ]] && p "input guard: '${v:-none}' writes nothing" || f "input guard: '${v:-none}' wrote $(ls -A "$IGD")"
    fi
    rm -rf "$IGD"
done

########################################################################
i "assert fix 30 — the touchscreen calibration tool, its menu entry, and the kernel fuzz"
########################################################################
TOUCH_FILES="pyra-touch-calibrate:/usr/local/bin:755
usr/local/share/applications/xinput_calibrator.desktop:/usr/local/share/applications:644
etc/udev/rules.d/91-pyra-touch-fuzz.rules:/etc/udev/rules.d:644"
for spec in $TOUCH_FILES; do
    IFS=: read -r src dir mode <<<"$spec"
    D=$MNT$dir/$(basename "$src")
    [[ -e $D ]] && cmp -s "$PAYLOADS/$src" "$D" && p "fix30: ${D#$MNT} matches repo" || f "fix30: ${D#$MNT} missing or differs from repo"
    [[ $(stat -c '%a %u:%g' "$D" 2>/dev/null) == "$mode 0:0" ]] && p "fix30: ${D#$MNT} is $mode root:root" \
        || f "fix30: ${D#$MNT} mode is $(stat -c '%a %u:%g' "$D" 2>/dev/null), want $mode 0:0"
done
[[ $(stat -c '%a %u:%g' "$MNT/usr/local/share/applications" 2>/dev/null) == "755 0:0" ]] \
    && p "fix30: /usr/local/share/applications is 755 root:root" || f "fix30: /usr/local/share/applications is $(stat -c '%a %u:%g' "$MNT/usr/local/share/applications" 2>/dev/null)"
# The image's python3 runs the tool (--help needs no display), and its ctypes
# finds every libXi and Xlib call the tool makes, so no xinput is needed.
got=$(in_chroot /usr/local/bin/pyra-touch-calibrate --help 2>&1 | head -1 || true)
[[ $got == "Calibrate the Pyra's touchscreen for the libinput X driver, and keep it." ]] \
    && p "fix30: the image's python3 runs pyra-touch-calibrate --help" || f "fix30: pyra-touch-calibrate --help printed '$got'"
got=$(in_chroot python3 -c 'import ctypes
xi, x11 = ctypes.CDLL("libXi.so.6"), ctypes.CDLL("libX11.so.6")
for n in ("XIQueryVersion", "XIQueryDevice", "XIFreeDeviceInfo", "XIGetProperty", "XIChangeProperty"): getattr(xi, n)
for n in ("XOpenDisplay", "XInternAtom", "XSync", "XFree"): getattr(x11, n)
import gi; gi.require_version("Gtk", "3.0"); gi.require_version("Gdk", "3.0"); print("ok")' 2>&1 || true)
[[ $got == ok ]] && p "fix30: the image's ctypes finds libXi's and Xlib's calls, and GTK 3 is there" || f "fix30: the tool's libraries: $got"
[[ ! -e $MNT/usr/bin/xinput ]] && i "fix30: the image has no xinput, as expected" || i "fix30: the image has /usr/bin/xinput"
# The entry loads with the image's GLib, runs the installed tool in a terminal,
# and wins over xinput-calibrator's with the session's XDG_DATA_DIRS (as read
# from mate-panel's environment on a running card).
got=$(in_chroot python3 -c 'from gi.repository import GLib
k = GLib.KeyFile(); k.load_from_file("/usr/local/share/applications/xinput_calibrator.desktop", 0)
print(k.get_boolean("Desktop Entry", "Terminal"), "/usr/local/bin/pyra-touch-calibrate;" in k.get_string("Desktop Entry", "Exec"))' 2>&1 || true)
[[ $got == "True True" ]] && p "fix30: the menu entry loads, runs the tool, in a terminal" || f "fix30: the menu entry reads '$got', want Terminal and the tool in Exec"
got=$(in_chroot env XDG_DATA_DIRS=/usr/share/mate:/usr/local/share/:/usr/share/ python3 -c 'from gi.repository import Gio
print(Gio.DesktopAppInfo.new("xinput_calibrator.desktop").get_filename())' 2>&1 || true)
[[ $got == /usr/local/share/applications/xinput_calibrator.desktop ]] \
    && p "fix30: the menu's xinput_calibrator.desktop is fix 30's" || f "fix30: xinput_calibrator.desktop resolves to '$got'"
[[ -e $MNT/usr/share/applications/xinput_calibrator.desktop ]] && p "fix30: xinput-calibrator's own entry is untouched" || f "fix30: xinput-calibrator's own entry is gone"
# The rule parses with the image's udevadm, and its RUN comes after the RUN of
# libinput's rule, which is what sets the fuzz to 0.
got=$(in_chroot udevadm verify --resolve-names=never /etc/udev/rules.d/91-pyra-touch-fuzz.rules 2>&1 || true)
grep -q 'Fail: *0' <<<"$got" && p "fix30: the image's udevadm verify passes the fuzz rule" || f "fix30: udevadm verify: $(tr '\n' ' ' <<<"$got")"
LI=$MNT/usr/lib/udev/rules.d/90-libinput-fuzz-override.rules
# udev reads the rule files of all its directories in one order, by name.
ORDER=$(find "$MNT/usr/lib/udev/rules.d" "$MNT/etc/udev/rules.d" -name '*.rules' -printf '%f\n' | LC_ALL=C sort -u)
grep -q 'RUN{program}+="libinput-fuzz-to-zero' "$LI" 2>/dev/null \
    && (( $(grep -nxF 90-libinput-fuzz-override.rules <<<"$ORDER" | cut -d: -f1) < $(grep -nxF 91-pyra-touch-fuzz.rules <<<"$ORDER" | cut -d: -f1) )) \
    && p "fix30: the rule sorts after libinput's, whose RUN zeroes the fuzz" || f "fix30: no libinput fuzz-to-zero rule before 91-pyra-touch-fuzz.rules"
R=$MNT/etc/udev/rules.d/91-pyra-touch-fuzz.rules
grep -qF 'ENV{EVDEV_ABS_00}=":::$env{LIBINPUT_FUZZ_00}"' "$R" && grep -qF 'ENV{EVDEV_ABS_01}=":::$env{LIBINPUT_FUZZ_01}"' "$R" \
    && grep -qF 'RUN{builtin}+="keyboard"' "$R" && p "fix30: the rule hands libinput's fuzz back to the kernel with RUN{builtin}" \
    || f "fix30: the rule does not set EVDEV_ABS_00/01 from LIBINPUT_FUZZ and RUN the keyboard builtin"

########################################################################
i "assert fix 31 — pyra-info and the prep marker"
########################################################################
D=$MNT/usr/local/bin/pyra-info
[[ -e $D ]] && cmp -s "$PAYLOADS/pyra-info" "$D" && p "fix31: /usr/local/bin/pyra-info matches repo" || f "fix31: /usr/local/bin/pyra-info missing or differs from repo"
[[ $(stat -c '%a %u:%g' "$D" 2>/dev/null) == "755 0:0" ]] && p "fix31: pyra-info is 755 root:root" || f "fix31: pyra-info is $(stat -c '%a %u:%g' "$D" 2>/dev/null)"
M=$MNT/etc/dragonbox-pyra-prep
[[ $(stat -c '%a %u:%g' "$M" 2>/dev/null) == "644 0:0" ]] && p "fix31: /etc/dragonbox-pyra-prep is 644 root:root" || f "fix31: /etc/dragonbox-pyra-prep is $(stat -c '%a %u:%g' "$M" 2>/dev/null)"
TOP=$(cd -- "$(dirname -- "$PREP")/.." && pwd)
WANT_COMMIT=$(git -c safe.directory="$TOP" -C "$TOP" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
[[ $WANT_COMMIT != unknown && -n $(git -c safe.directory="$TOP" -C "$TOP" status --porcelain --untracked-files=no 2>/dev/null) ]] && WANT_COMMIT+=-dirty
KPIN=$(sed -n 's/^KERNEL_SHA256=//p' "$PREP")
KSUM=$(sha256sum < "$KTAR" | cut -d' ' -f1)
if [[ -n $KPIN && $KSUM == "$KPIN" ]]; then WANT_KERNEL=$(sed -n 's/^KERNEL_TAG=//p' "$PREP"); else WANT_KERNEL="local build, sha256 $KSUM"; fi
grep -qx "prep=$WANT_COMMIT" "$M" && p "fix31: the marker names the checkout prep ran from ($WANT_COMMIT)" || f "fix31: marker prep= is '$(sed -n 's/^prep=//p' "$M")', want $WANT_COMMIT"
grep -qxF "kernel=$WANT_KERNEL" "$M" && p "fix31: the marker names the kernel fix 19 installed ($WANT_KERNEL)" || f "fix31: marker kernel= is '$(sed -n 's/^kernel=//p' "$M")', want $WANT_KERNEL"
grep -qxE 'date=[0-9]{4}-[0-9]{2}-[0-9]{2}' "$M" && grep -qx 'release=no' "$M" && p "fix31: the marker has a date and release=no" || f "fix31: the marker's date or release line is wrong"
# The image's own bash, dpkg-query and awk run it. The chroot has no
# /proc/device-tree, so only the lines that come from the image are checked.
set +e; got=$(in_chroot /usr/local/bin/pyra-info 2>/dev/null); rc=$?; set -e
[[ $rc -eq 0 ]] && p "fix31: the image runs pyra-info (exit 0)" || f "fix31: pyra-info exited $rc in the image"
grep -qxF "Prepared   : commit $WANT_COMMIT, $(sed -n 's/^date=//p' "$M"), $WANT_KERNEL" <<<"$got" \
    && p "fix31: pyra-info prints the marker" || f "fix31: pyra-info's Prepared line: '$(grep '^Prepared' <<<"$got")'"
grep -qx 'RAM        : not readable from Linux.*' <<<"$got" && ! grep -q MemTotal <<<"$got" \
    && p "fix31: pyra-info prints no RAM size" || f "fix31: pyra-info's RAM line: '$(grep '^RAM' <<<"$got")'"
UB=$(in_chroot dpkg-query -W -f='${Version}' u-boot-pyra 2>/dev/null || true)
grep -qE "^  u-boot-pyra +${UB//./\\.}\$" <<<"$got" && [[ -n $UB ]] \
    && p "fix31: pyra-info lists the image's u-boot-pyra ($UB)" || f "fix31: pyra-info's u-boot-pyra line: '$(grep 'u-boot-pyra' <<<"$got")'"
if [[ $SON == yes ]]; then
    SV=$(in_chroot dpkg-query -W -f='${Version}' pyra-settings 2>/dev/null || true)
    grep -qE "^  pyra-settings +${SV//./\\.}\$" <<<"$got" && [[ -n $SV ]] \
        && p "fix31: pyra-info lists fix 26's pyra-settings ($SV)" || f "fix31: pyra-info's pyra-settings line: '$(grep 'pyra-settings' <<<"$got")'"
fi
[[ $(grep -c '^  ' <<<"$got") -eq 7 ]] && p "fix31: pyra-info lists all seven packages" || f "fix31: pyra-info lists $(grep -c '^  ' <<<"$got") packages, want 7"

########################################################################
i "assert fix 32 — python3-apt and /dragonbox for the DBP Installer"
########################################################################
for pkg in python3-apt python-apt-common distro-info-data; do
    st=$(in_chroot dpkg-query -W -f='${db:Status-Abbrev} ${Version}' "$pkg" 2>/dev/null || true)
    [[ $st == ii* ]] && p "fix32: $pkg installed (${st##* })" || f "fix32: $pkg is '${st:-not installed}'"
done
# Not apt.Cache(): as root it writes /var/cache/apt, and run 2 must find nothing changed.
in_chroot python3 -B -c 'import apt, apt_pkg; apt_pkg.init()' >/dev/null 2>&1 \
    && p "fix32: the image's python3 imports apt and apt_pkg" || f "fix32: the image's python3 cannot use python3-apt"
compgen -G "$MNT/var/tmp/pyra-prep-*.deb" >/dev/null && f "fix32: staged .debs left in /var/tmp" || p "fix32: no staged .debs left in /var/tmp"
PU=$(awk -F: '$1=="pyra"{print $3":"$4}' "$MNT/etc/passwd")
for d in /dragonbox /dragonbox/packages /dragonbox/appdata; do
    [[ -d $MNT$d && ! -L $MNT$d && $(stat -c '%u:%g %a' "$MNT$d") == "$PU 755" ]] \
        && p "fix32: $d is a directory, 755 pyra's ($PU)" || f "fix32: $d is $(stat -c '%F %u:%g %a' "$MNT$d" 2>/dev/null || echo missing)"
done
PH=$(awk -F: '$1=="pyra"{print $6}' "$MNT/etc/passwd")
L=$MNT$PH/dragonbox
[[ -L $L && $(readlink "$L") == /dragonbox && $(stat -c '%u:%g' -- "$L") == "$PU" ]] \
    && p "fix32: $PH/dragonbox is pyra's link to /dragonbox" || f "fix32: $PH/dragonbox is $(stat -c '%F -> %N %u:%g' -- "$L" 2>/dev/null || echo missing)"

########################################################################
i "assert fix 33 — the first-boot password window, idle on a card with a password"
########################################################################
for spec in "pyra-first-boot:/usr/local/sbin/pyra-first-boot:755" "pyra-first-boot.service:/etc/systemd/system/pyra-first-boot.service:644"; do
    IFS=: read -r src dst mode <<<"$spec"
    cmp -s "$PAYLOADS/$src" "$MNT$dst" && p "fix33: $dst matches repo" || f "fix33: $dst missing or differs from repo"
    [[ $(stat -c '%a %u:%g' "$MNT$dst" 2>/dev/null) == "$mode 0:0" ]] && p "fix33: $dst is $mode root:root" \
        || f "fix33: $dst is $(stat -c '%a %u:%g' "$MNT$dst" 2>/dev/null), want $mode 0:0"
done
[[ $(readlink "$MNT/etc/systemd/system/graphical.target.wants/pyra-first-boot.service") == /etc/systemd/system/pyra-first-boot.service ]] \
    && p "fix33: pyra-first-boot.service enabled in graphical.target" || f "fix33: pyra-first-boot.service not enabled in graphical.target"
grep -qx 'Before=display-manager.service' "$MNT/etc/systemd/system/pyra-first-boot.service" \
    && grep -qx 'ConditionPathExists=/var/lib/dragonbox-pyra/first-boot-password' "$MNT/etc/systemd/system/pyra-first-boot.service" \
    && p "fix33: the unit runs before the greeter, only with the pending file" || f "fix33: the unit's ordering or condition changed"
[[ ! -e $MNT/var/lib/dragonbox-pyra/first-boot-password ]] && grep -q 'fix33: nothing pending' "$OUT/prep-run1.log" \
    && p "fix33: run 1 (with a password) left nothing pending" || f "fix33: run 1 left a pending file, or did not say nothing is pending"
got=$(in_chroot /usr/local/sbin/pyra-first-boot --help 2>&1 | head -1 || true)
[[ $got == "Ask for the user's password on a card's first boot, before the greeter." ]] \
    && p "fix33: the image's python3 runs pyra-first-boot --help" || f "fix33: pyra-first-boot --help printed '$got'"
# Without the pending file the tool exits at once, as root, touching nothing.
in_chroot /usr/local/sbin/pyra-first-boot >/dev/null 2>&1 && p "fix33: with nothing pending the tool exits 0" || f "fix33: with nothing pending the tool failed"
got=$(in_chroot python3 -B -c 'import importlib.machinery as m
fb = m.SourceFileLoader("fb", "/usr/local/sbin/pyra-first-boot").load_module()
print([fb.problem(*a) is None for a in (("", ""), ("ab", "ac"), ("pyra", "pyra"), ("a\nb", "a\nb"), ("a:b c|d", "a:b c|d"))])
import gi; gi.require_version("Gtk", "3.0"); gi.require_version("Gdk", "3.0"); from gi.repository import Gtk, Gdk' 2>&1 || true)
[[ $got == "[False, False, False, False, True]" ]] \
    && p "fix33: the window refuses empty, unequal, 'pyra' and line breaks, takes 'a:b c|d'; GTK 3 imports" || f "fix33: the checks or GTK 3: $got"

########################################################################
i "run 2 — idempotency"
########################################################################
disarm; set +e
"$PREP" "${KARGS[@]}" --ssh-key "$OUT/testkey.pub" --grow-on-boot "$MNT" pyra 2>&1 | tee "$OUT/prep-run2.log"
RC2=${PIPESTATUS[0]}
set -e; arm
[[ $RC2 -eq 0 ]] && p "run 2 exited 0" || f "run 2 exited $RC2"

snapshot > "$OUT/rootfs-after2.txt"
if diff -u "$OUT/rootfs-after1.txt" "$OUT/rootfs-after2.txt" > "$OUT/rootfs-diff2.txt"; then
    p "run 2 changed nothing on disk"
else
    f "run 2 changed the filesystem:"
    grep -E '^[+-][^+-]' "$OUT/rootfs-diff2.txt" > "$OUT/.d2" || true
    sed -n '1,20p' "$OUT/.d2" | sed 's/^/      /'
    rm -f "$OUT/.d2"
fi
# and it must say so, rather than silently rewriting
grep -qE "fix2: the key is already authorised" "$OUT/prep-run2.log" && p "run 2 reported the ssh key already authorised" || f "run 2 did not report the ssh key already authorised"
grep -qE "fix2: its password is unchanged" "$OUT/prep-run2.log" && p "run 2, without --set-password, left the password alone" || f "run 2 did not say it left the password alone"
grep -q 'fix2: root is already locked' "$OUT/prep-run2.log" && p "run 2 reported root already locked" || f "run 2 did not report root already locked"
grep -qE 'fix5: .*already up to date' "$OUT/prep-run2.log" && p "run 2 reported fix5 already up to date" || f "run 2 did not report fix5 up to date"
grep -qE 'fix5: already enabled' "$OUT/prep-run2.log" && p "run 2 reported fix5 already enabled" || f "run 2 did not report fix5 already enabled"
grep -qE 'fix6: .*already applies' "$OUT/prep-run2.log" && p "run 2 reported fix6 already applied" || f "run 2 did not report fix6 already applied"
grep -qE 'fix7: .*already has the corrected ladder' "$OUT/prep-run2.log" && p "run 2 reported fix7 already applied" || f "run 2 did not report fix7 already applied"
grep -qE 'fix8: .*already in place' "$OUT/prep-run2.log" && p "run 2 reported fix8 already applied" || f "run 2 did not report fix8 already in place"
grep -qE 'fix13: .*already in place' "$OUT/prep-run2.log" && p "run 2 reported fix13 already applied" || f "run 2 did not report fix13 already in place"
grep -qE 'fix14: .*already has both hooks' "$OUT/prep-run2.log" && p "run 2 reported fix14's initrds current" || f "run 2 did not report fix14's initrds current"
! grep -qE 'fix14: rebuilt' "$OUT/prep-run2.log" && p "run 2 rebuilt no initrd" || f "run 2 rebuilt an initrd"
grep -qE 'fix15: .*already up to date' "$OUT/prep-run2.log" && p "run 2 reported fix15's script up to date" || f "run 2 did not report fix15's script up to date"
[[ $(grep -cE 'fix15: .*already set' "$OUT/prep-run2.log") -eq 2 ]] && p "run 2 reported both fix15 keys already set" || f "run 2 did not report both fix15 keys already set"
grep -qE 'fix15: pyrainput.service.d/pyra-kbdlight.conf already up to date' "$OUT/prep-run2.log" && p "run 2 reported fix15's drop-in up to date" || f "run 2 did not report fix15's drop-in up to date"
[[ $(grep -cE 'fix16: .*already up to date' "$OUT/prep-run2.log") -eq 2 ]] && p "run 2 reported both fix16 files up to date" || f "run 2 did not report both fix16 files up to date"
grep -qE 'fix16: already enabled' "$OUT/prep-run2.log" && p "run 2 reported fix16 already enabled" || f "run 2 did not report fix16 already enabled"
[[ $(grep -cE 'fix17: .*already up to date' "$OUT/prep-run2.log") -eq 7 ]] && p "run 2 reported all seven fix17 files up to date" || f "run 2 did not report all seven fix17 files up to date"
grep -qE 'fix17: link already in place' "$OUT/prep-run2.log" && p "run 2 reported fix17's link in place" || f "run 2 did not report fix17's link in place"
grep -qE 'fix17: already enabled' "$OUT/prep-run2.log" && p "run 2 reported fix17 already enabled" || f "run 2 did not report fix17 already enabled"
grep -qE 'fix18: .*already up to date' "$OUT/prep-run2.log" && p "run 2 reported fix18 already up to date" || f "run 2 did not report fix18 already up to date"
[[ $(grep -cE 'fix19: .*already up to date' "$OUT/prep-run2.log") -eq 2 ]] && p "run 2 reported both fix19 scripts up to date" || f "run 2 did not report both fix19 scripts up to date"
grep -qE "fix19: $KREL is already installed" "$OUT/prep-run2.log" && p "run 2 reported the kernel already installed" || f "run 2 did not report the kernel already installed"
grep -qE 'fix19: .*already the base and the default' "$OUT/prep-run2.log" && p "run 2 reported l5 already the base and default" || f "run 2 did not report l5 already the base and default"
grep -qE 'fix20: .*already up to date' "$OUT/prep-run2.log" && p "run 2 reported fix20 already up to date" || f "run 2 did not report fix20 already up to date"
grep -qE 'fix21: .*libpvrDRI3WSEGL.so already patched' "$OUT/prep-run2.log" && p "run 2 reported the library already patched" || f "run 2 did not report the library already patched"
if [[ ${KARGS[*]} != *--no-backlight* ]]; then
    grep -qE 'fix22: pyra-backlight .* already installed' "$OUT/prep-run2.log" && p "run 2 reported pyra-backlight already installed" || f "run 2 did not report pyra-backlight already installed"
    grep -qF 'fix22: the default panel layout is already up to date' "$OUT/prep-run2.log" && p "run 2 reported the panel layout already up to date" || f "run 2 did not report the panel layout already up to date"
fi
for x in pyra-wsegl-fdfix.sh sbin/pyra-wsegl-guard dpkg.cfg.d/pyra-wsegl-guard; do
    grep -qE "fix21: .*$x already up to date" "$OUT/prep-run2.log" && p "run 2 reported fix21's $x up to date" || f "run 2 did not report fix21's $x up to date"
done
[[ $(grep -cE 'fix23: .*already (up to date|enabled|empty|masked)' "$OUT/prep-run2.log") -eq 4 ]] \
    && p "run 2 reported fix23's unit, its link, the machine-id and the mask already in place" || f "run 2 did not report fix23's unit, link, machine-id and mask in place"
if [[ $SON == yes ]]; then
    grep -qE 'fix26: pyra-settings .* already installed' "$OUT/prep-run2.log" && p "run 2 reported pyra-settings already installed" || f "run 2 did not report pyra-settings already installed"
    grep -qF 'fix26: the image already has pyra-hacks' "$OUT/prep-run2.log" && p "run 2 found the fork already installed" || f "run 2 did not find the fork already installed"
    grep -qF 'fix12: left to the pyra-hacks fork' "$OUT/prep-run2.log" && p "run 2 reported fix 12 left to the fork" || f "run 2 did not report fix 12 left to the fork"
fi
if [[ $SOON == yes ]]; then
    grep -qE 'fix27: pyra-sound .* already installed' "$OUT/prep-run2.log" && p "run 2 reported pyra-sound already installed" || f "run 2 did not report pyra-sound already installed"
fi
if [[ $PION == yes ]]; then
    grep -qE 'fix29: funkeymonkey-pyrainput .* already installed' "$OUT/prep-run2.log" && p "run 2 reported funkeymonkey-pyrainput already installed" || f "run 2 did not report funkeymonkey-pyrainput already installed"
    [[ $(grep -cE 'fix29: .*pyra-input-guard already up to date' "$OUT/prep-run2.log") -eq 2 ]] \
        && p "run 2 reported both of fix29's guard files already up to date" || f "run 2 did not report both of fix29's guard files up to date"
fi
grep -qE 'fix24: .*already up to date' "$OUT/prep-run2.log" && p "run 2 reported fix24 already up to date" || f "run 2 did not report fix24 already up to date"
[[ $(grep -cE 'fix25: .*already up to date' "$OUT/prep-run2.log") -eq 2 ]] && p "run 2 reported both of fix25's files already up to date" || f "run 2 did not report both of fix25's files up to date"
[[ $(grep -cE 'fix30: .*already up to date' "$OUT/prep-run2.log") -eq 3 ]] && p "run 2 reported fix30's three files already up to date" || f "run 2 did not report fix30's three files up to date"
[[ $(grep -cE 'fix31: .*already up to date' "$OUT/prep-run2.log") -eq 2 ]] && p "run 2 reported pyra-info and the marker already up to date" || f "run 2 did not report pyra-info and the marker up to date"
[[ $(grep -cE 'fix32: (the image already has|/dragonbox.* already there|.*already points at /dragonbox)' "$OUT/prep-run2.log") -eq 7 ]] \
    && p "run 2 found fix32's three packages, three directories and the link in place" || f "run 2 did not find all of fix32's packages, directories and link in place"
[[ $(grep -cE 'fix33: .*already (up to date|enabled)' "$OUT/prep-run2.log") -eq 3 ]] \
    && p "run 2 reported fix33's tool, unit and link already in place" || f "run 2 did not report fix33's tool, unit and link in place"
for m in 'is already diverted' 'already fixed' 'already carries the Fn fragment' 'already has the Fn keys'; do
    grep -F 'fix28: ' "$OUT/prep-run2.log" | grep -qF "$m" \
        && p "run 2 reported fix28's '$m'" || f "run 2 did not report fix28's '$m'"
done

# With no kernel option prep offers the published download. Until a release
# is pinned in prep there is none, and it must stop before writing anything.
if grep -qx 'KERNEL_URL=' "$PREP"; then
    disarm; set +e
    NOK=$("$PREP" "$MNT" pyra 2>&1 </dev/null); NRC=$?
    set -e; arm
    [[ $NRC -ne 0 ]] && grep -q 'no kernel to install; nothing has been written' <<<"$NOK" \
        && p "with no release pinned, a run with no kernel option stops" || f "a run with no kernel option and no release pinned did not stop as expected (exit $NRC)"
    snapshot > "$OUT/rootfs-after3.txt"
    cmp -s "$OUT/rootfs-after2.txt" "$OUT/rootfs-after3.txt" && p "and it wrote nothing" || f "a run that stopped for no kernel changed the filesystem"
else
    i "a release is pinned in prep; not testing the download here"
fi

########################################################################
i "fix 23 — a card's own host keys and machine-id are kept"
########################################################################
# As on a card that has booted since prep: keys made here, a machine-id of its
# own and D-Bus's copy as a file. A re-run must keep all of it. Then one of
# the vendor's public keys among them: that makes them the vendor's set again.
# The card's own identity is left in place for --release (run 3) to remove.
VENDOR_MID=$(sed -n 's/^VENDOR_MACHINE_ID=//p' "$PREP")
OWN_MID=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
ssh-keygen -q -t ed25519 -N '' -C '' -f "$MNT/etc/ssh/ssh_host_ed25519_key"
printf '%s\n' "$OWN_MID" > "$MNT/etc/machine-id"
rm -f "$MNT/var/lib/dbus/machine-id"; printf '%s\n' "$OWN_MID" > "$MNT/var/lib/dbus/machine-id"
OWN_PUB=$(cat "$MNT/etc/ssh/ssh_host_ed25519_key.pub")
snapshot > "$OUT/rootfs-own-before.txt"
disarm; set +e
"$PREP" "${KARGS[@]}" --grow-on-boot "$MNT" pyra </dev/null > "$OUT/prep-run-own.log" 2>&1; ORC=$?
set -e; arm
[[ $ORC -eq 0 ]] && p "fix23: the run on a card with its own identity exited 0" || f "fix23: the run on a card with its own identity exited $ORC"
snapshot > "$OUT/rootfs-own-after.txt"
cmp -s "$OUT/rootfs-own-before.txt" "$OUT/rootfs-own-after.txt" && p "fix23: and changed nothing on disk" || f "fix23: the run on a card with its own identity changed the filesystem"
[[ $(cat "$MNT/etc/ssh/ssh_host_ed25519_key.pub") == "$OWN_PUB" ]] && grep -q "fix23: the ssh host keys are this card's own" "$OUT/prep-run-own.log" \
    && p "fix23: the card's own host key is kept" || f "fix23: the card's own host key was not kept"
[[ $(cat "$MNT/etc/machine-id") == "$OWN_MID" && $(cat "$MNT/var/lib/dbus/machine-id") == "$OWN_MID" ]] && grep -q "fix23: /etc/machine-id is this card's own" "$OUT/prep-run-own.log" \
    && p "fix23: the card's own machine-id and D-Bus's copy are kept" || f "fix23: the card's own machine-id was not kept"
[[ -n $VENDOR_MID && $VENDOR_MID != "$OWN_MID" ]] || f "fix23: could not read VENDOR_MACHINE_ID from prep"
# One vendor public key (rsa, saved before run 1) beside the card's own.
cp "$MNT/etc/ssh/ssh_host_ed25519_key" "$OUT/own-hostkey"; cp "$MNT/etc/ssh/ssh_host_ed25519_key.pub" "$OUT/own-hostkey.pub"
cp "$OUT/vendor-rsa.pub" "$MNT/etc/ssh/ssh_host_rsa_key.pub"
disarm; set +e
"$PREP" "${KARGS[@]}" --grow-on-boot "$MNT" pyra </dev/null > "$OUT/prep-run-mixed.log" 2>&1; MRC=$?
set -e; arm
[[ $MRC -eq 0 ]] && ! compgen -G "$MNT/etc/ssh/ssh_host_*" >/dev/null && grep -q "fix23: removed 3 ssh host key files (the vendor's" "$OUT/prep-run-mixed.log" \
    && p "fix23: one vendor key among the card's own makes prep remove them all" || f "fix23: a vendor key among the card's own: exit $MRC, keys left: $(cd "$MNT/etc/ssh" && ls ssh_host_* 2>/dev/null | tr '\n' ' ')"
[[ $(cat "$MNT/etc/machine-id") == "$OWN_MID" ]] && p "fix23: the machine-id, the card's own, is still kept" || f "fix23: the machine-id changed with the host keys"
# Put the card's own key back for run 3.
install -m 0600 "$OUT/own-hostkey" "$MNT/etc/ssh/ssh_host_ed25519_key"
install -m 0644 "$OUT/own-hostkey.pub" "$MNT/etc/ssh/ssh_host_ed25519_key.pub"
rm -f "$OUT/own-hostkey" "$OUT/own-hostkey.pub"

########################################################################
i "missing-payload abort — must die before fix 1 writes"
########################################################################
# Re-create the symlink fix 1 removes, run a copy of the script with no
# payloads beside it, and assert the symlink survives.
STAGE=$(mktemp -d /tmp/pyraprep-nopayload.XXXXXX)
cp "$PREP" "$STAGE/"
ln -sf kms_swrast_dri.so "$MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so"
# This run is SUPPOSED to fail, so its failure must not read as a harness abort.
ARC=0
disarm
ABORT=$("$STAGE/$(basename "$PREP")" --kernel "$KTAR" "$MNT" pyra 2>&1) || ARC=$?
arm
[[ $ARC -ne 0 ]] && p "no-payload run exited $ARC" || f "no-payload run exited 0"
grep -q 'pyra-usb3503-rescue not found' <<<"$ABORT" \
    && p "no-payload run failed for the right reason" \
    || { f "no-payload run failed for the wrong reason:"; sed 's/^/      /' <<<"$ABORT"; }
if [[ -L $MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so ]]; then
    p "no-payload run aborted before fix 1 wrote anything"
else
    f "no-payload run removed armsoc_dri.so before aborting"
fi
rm -f "$MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so"
rm -rf "$STAGE"

# Every card gets the shipped kernel: there is no option to leave it out.
ARC=0
disarm
ABORT=$("$PREP" --no-kernel "$MNT" pyra 2>&1 </dev/null) || ARC=$?
arm
[[ $ARC -ne 0 ]] && grep -q 'unknown option: --no-kernel' <<<"$ABORT" \
    && p "fix19: prep refuses --no-kernel as an unknown option" || f "fix19: --no-kernel was not refused (exit $ARC)"

########################################################################
i "unknown driver library — fix 21 must stop prep before fix 1 writes"
########################################################################
# A library that is neither the stock nor the fixed build (one byte added),
# the same canary as above, then the real file put back.
mv "$WL" "$WL.selftest-keep"
{ cat "$WL.selftest-keep"; printf x; } > "$WL"
ln -sf kms_swrast_dri.so "$MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so"
ARC=0
disarm
ABORT=$("$PREP" --kernel "$KTAR" "$MNT" pyra 2>&1 </dev/null) || ARC=$?
arm
if [[ $ARC -ne 0 ]] && grep -q 'fix21: /usr/lib/libpvrDRI3WSEGL.so: unknown' <<<"$ABORT"; then
    p "an unknown libpvrDRI3WSEGL.so stops prep (exit $ARC) for the right reason"
else
    f "an unknown libpvrDRI3WSEGL.so: exit $ARC:"; tail -3 <<<"$ABORT" | sed 's/^/      /'
fi
[[ -L $MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so ]] && p "and it stopped before fix 1 wrote anything" || f "an unknown library let fix 1 run first"
rm -f "$MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so"
mv "$WL.selftest-keep" "$WL"

########################################################################
i "fix 22 — a wrong .deb and a missing dependency stop prep before fix 1 writes"
########################################################################
# Two minimal .debs, made with ar and tar: another package, and a pyra-backlight
# that depends on a package no image has. The same canary as above.
mkdeb() {   # OUT.deb PACKAGE DEPENDS
    local d; d=$(mktemp -d)
    printf 'Package: %s\nVersion: 0.0selftest\nArchitecture: all\nMaintainer: selftest <selftest@example.invalid>\nDepends: %s\nDescription: prep selftest\n' \
        "$2" "$3" > "$d/control"
    tar -czf "$d/control.tar.gz" -C "$d" ./control
    mkdir "$d/data"; tar -czf "$d/data.tar.gz" -C "$d/data" .
    printf '2.0\n' > "$d/debian-binary"
    rm -f "$1"; (cd "$d" && ar rc "$1" debian-binary control.tar.gz data.tar.gz)
    rm -rf "$d"
}
for c in "other-package|python3|is the package 'other-package', not pyra-backlight" \
         "pyra-backlight|python3, pyra-selftest-no-such-package (>= 1)|lacks what pyra-backlight 0.0selftest depends on"; do
    IFS='|' read -r bpkg bdeps bwant <<<"$c"
    mkdeb "$OUT/selftest-$bpkg.deb" "$bpkg" "$bdeps"
    ln -sf kms_swrast_dri.so "$MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so"
    ARC=0
    disarm
    ABORT=$("$PREP" --kernel "$KTAR" --backlight "$OUT/selftest-$bpkg.deb" "$MNT" pyra 2>&1 </dev/null) || ARC=$?
    arm
    if [[ $ARC -ne 0 ]] && grep -qF "$bwant" <<<"$ABORT"; then
        p "fix22: a .deb that $bwant stops prep (exit $ARC)"
    else
        f "fix22: a .deb that $bwant: exit $ARC:"; tail -3 <<<"$ABORT" | sed 's/^/      /'
    fi
    [[ $bpkg == pyra-backlight ]] && { grep -q 'pyra-selftest-no-such-package' <<<"$ABORT" && p "fix22: it names the missing dependency" || f "fix22: it did not name the missing dependency"; }
    [[ -L $MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so ]] && p "fix22: and it stopped before fix 1 wrote anything" || f "fix22: fix 1 ran before the .deb was refused"
    [[ ! -e $MNT/var/tmp/pyra-prep-backlight.deb ]] && p "fix22: and removed the staged .deb" || f "fix22: the staged .deb was left in /var/tmp"
    rm -f "$MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so"
done

########################################################################
i "fix 26 — a wrong .deb, and pyra-settings without pyra-backlight, stop prep before fix 1 writes"
########################################################################
mkdeb "$OUT/selftest-not-settings.deb" other-package python3
# The wrong .deb needs a real pyra-backlight beside it to reach fix 26's check:
# the run's own, or the pinned download.
BARGS=(); [[ -n $BDEB && $BDEB != none ]] && BARGS=(--backlight "$BDEB")
SCASES=("--no-backlight|needs pyra-backlight, which --no-backlight leaves out")
[[ $BDEB != none ]] && SCASES+=("${BARGS[*]}|is the package 'other-package', not pyra-settings")
for c in "${SCASES[@]}"; do
    IFS='|' read -r sargs swant <<<"$c"
    ln -sf kms_swrast_dri.so "$MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so"
    ARC=0
    disarm
    # shellcheck disable=SC2086  # the options split on purpose
    ABORT=$("$PREP" --kernel "$KTAR" $sargs --settings "$OUT/selftest-not-settings.deb" "$MNT" pyra 2>&1 </dev/null) || ARC=$?
    arm
    if [[ $ARC -ne 0 ]] && grep -qF "$swant" <<<"$ABORT"; then
        p "fix26: a run where pyra-settings $swant stops prep (exit $ARC)"
    else
        f "fix26: pyra-settings $swant: exit $ARC:"; tail -3 <<<"$ABORT" | sed 's/^/      /'
    fi
    [[ -L $MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so ]] && p "fix26: and it stopped before fix 1 wrote anything" || f "fix26: fix 1 ran before prep stopped"
    [[ ! -e $MNT/var/tmp/pyra-prep-settings.deb ]] && p "fix26: and left no staged .deb" || f "fix26: the staged .deb was left in /var/tmp"
    rm -f "$MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so"
done

########################################################################
i "fix 27 — a wrong .deb, a missing dependency and a wrong pin stop prep before fix 1 writes"
########################################################################
# --no-backlight and --no-settings get these runs past fixes 22 and 26 with no
# download. The pin case runs a copy of prep whose SOUND_SHA256 the release
# cannot match, beside links to device/ and patches/ (prep finds its payloads there); bash
# runs it, in case OUT is on a noexec /tmp.
mkdeb "$OUT/selftest-not-sound.deb" other-package python3
mkdeb "$OUT/selftest-sound-nodep.deb" pyra-sound "python3, pyra-selftest-no-such-package (>= 1)"
PINDIR=$OUT/pin
rm -rf "$PINDIR"; mkdir -p "$PINDIR/pc"; ln -s "$PAYLOADS" "$PINDIR/device"; ln -s "$ROOT/patches" "$PINDIR/patches"
sed 's/^SOUND_SHA256=.*/SOUND_SHA256=0000000000000000000000000000000000000000000000000000000000000000/' \
    "$PREP" > "$PINDIR/pc/pyra-trixie-prep.sh"
chmod 0755 "$PINDIR/pc/pyra-trixie-prep.sh"
SOCASES=("$PREP|--sound $OUT/selftest-not-sound.deb|is the package 'other-package', not pyra-sound"
         "$PREP|--sound $OUT/selftest-sound-nodep.deb|lacks what pyra-sound 0.0selftest depends on")
if [[ -z $SODEB ]]; then
    SOCASES+=("$PINDIR/pc/pyra-trixie-prep.sh||not the pinned 0000000000000000000000000000000000000000000000000000000000000000")
else
    SKIP=$((SKIP+1)); SKIPPED+=("fix 27's wrong-pin case (needs the network; PYRA_SOUND_DEB is set)")
    printf '\e[33mSKIP\e[0m  fix27: wrong-pin case (PYRA_SOUND_DEB is set, so this run stays off the network)\n'
fi
for c in "${SOCASES[@]}"; do
    IFS='|' read -r soprep soargs sowant <<<"$c"
    ln -sf kms_swrast_dri.so "$MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so"
    ARC=0
    disarm
    # shellcheck disable=SC2086  # the options split on purpose
    ABORT=$(bash "$soprep" --kernel "$KTAR" --no-backlight --no-settings $soargs "$MNT" pyra 2>&1 </dev/null) || ARC=$?
    arm
    if [[ $ARC -ne 0 ]] && grep -qF "$sowant" <<<"$ABORT"; then
        p "fix27: a run where pyra-sound $sowant stops prep (exit $ARC)"
    else
        f "fix27: pyra-sound $sowant: exit $ARC:"; tail -3 <<<"$ABORT" | sed 's/^/      /'
    fi
    [[ $sowant == lacks* ]] && { grep -q 'pyra-selftest-no-such-package' <<<"$ABORT" && p "fix27: it names the missing dependency" || f "fix27: it did not name the missing dependency"; }
    [[ -L $MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so ]] && p "fix27: and it stopped before fix 1 wrote anything" || f "fix27: fix 1 ran before prep stopped"
    [[ ! -e $MNT/var/tmp/pyra-prep-sound.deb ]] && p "fix27: and left no staged .deb" || f "fix27: the staged .deb was left in /var/tmp"
    rm -f "$MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so"
done
rm -rf "$PINDIR"

########################################################################
i "fix 29 — a wrong .deb and one that is not a +pyra build stop prep before fix 1 writes"
########################################################################
# --no-backlight, --no-settings and --no-sound get these runs to fix 29 with no
# download. mkdeb's version, 0.0selftest, is not a +pyra build.
mkdeb "$OUT/selftest-not-pyrainput.deb" other-package python3
mkdeb "$OUT/selftest-pyrainput-vendor.deb" funkeymonkey-pyrainput funkeymonkey
for c in "selftest-not-pyrainput|is the package 'other-package', not funkeymonkey-pyrainput" \
         "selftest-pyrainput-vendor|is funkeymonkey-pyrainput 0.0selftest, not a +pyra build"; do
    IFS='|' read -r pideb piwant <<<"$c"
    ln -sf kms_swrast_dri.so "$MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so"
    ARC=0
    disarm
    ABORT=$("$PREP" --kernel "$KTAR" --no-backlight --no-settings --no-sound --pyrainput "$OUT/$pideb.deb" "$MNT" pyra 2>&1 </dev/null) || ARC=$?
    arm
    if [[ $ARC -ne 0 ]] && grep -qF "$piwant" <<<"$ABORT"; then
        p "fix29: a .deb that $piwant stops prep (exit $ARC)"
    else
        f "fix29: a .deb that $piwant: exit $ARC:"; tail -3 <<<"$ABORT" | sed 's/^/      /'
    fi
    [[ -L $MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so ]] && p "fix29: and it stopped before fix 1 wrote anything" || f "fix29: fix 1 ran before prep stopped"
    [[ ! -e $MNT/var/tmp/pyra-prep-pyrainput.deb ]] && p "fix29: and left no staged .deb" || f "fix29: the staged .deb was left in /var/tmp"
    rm -f "$MNT/usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so"
done

########################################################################
i "fix 21's guard — a package run that puts the stock library back"
########################################################################
# The image's dpkg, in the chroot, fires the hook prep installed. The image
# carries no dri3wsegl-pyra deb, so the real reinstall needs the vendor's 0.4
# deb (PYRA_WSEGL_DEB, by default the package archive beside the repository),
# checked against its SHA-256. Without it, the stock build is written back the
# way dpkg writes it (by rename) and `dpkg --configure -a`, which has nothing
# to configure but still runs post-invoke hooks, fires the guard.
WDEB_SHA=1f7494f83b517c50b3602a6252c6250654a33c5538c4fe78df250ee0c36d10c4
WDEB=${PYRA_WSEGL_DEB:-$(cd -- "$ROOT/.." && pwd)/pyra-packages-archive/packages.pyra-handheld.com/trixie/dri3wsegl-pyra_0.4_armhf.deb}
WFIX=/usr/local/sbin/pyra-wsegl-fdfix.sh
WMARK=$MNT/var/lib/pyra-wsegl-fdfix
for d in proc sys dev; do mount --bind "/$d" "$MNT/$d"; done
wsha() { sha256sum < "$WL" | cut -d' ' -f1; }
stock_back() {      # put the stock build where the library is, as dpkg would
    cp -p "$WL.stock" "$WL.selftest-new" && mv "$WL.selftest-new" "$WL"
}
pkgrun() {          # pkgrun: a dpkg run in the image; its output in $WOUT, exit in $WRC
    disarm; set +e
    if [[ $WREAL == yes ]]; then
        WOUT=$(in_chroot dpkg -i /tmp/dri3wsegl-pyra_0.4_armhf.deb 2>&1 </dev/null)
    else
        stock_back
        WOUT=$(in_chroot dpkg --configure -a 2>&1 </dev/null)
    fi
    WRC=$?
    set -e; arm
}
WREAL=no
if [[ -r $WDEB ]] && [[ $(sha256sum < "$WDEB" | cut -d' ' -f1) == "$WDEB_SHA" ]]; then
    WREAL=yes; cp "$WDEB" "$MNT/tmp/"
    i "fix21 guard: reinstalling the vendor's dri3wsegl-pyra 0.4 deb with the image's dpkg"
else
    i "fix21 guard: no checked 0.4 deb at $WDEB; writing the stock build back by hand, dpkg --configure -a fires the hook"
fi
pkgrun
[[ $WRC -eq 0 ]] && p "fix21 guard: the package run exited 0" || f "fix21 guard: the package run exited $WRC: $(tail -2 <<<"$WOUT")"
[[ $(wsha) == "$SHA_FIXED" ]] && p "fix21 guard: after the package run the library is the fixed build again" || f "fix21 guard: after the package run the library is not the fixed build"
grep -q 'pyra-wsegl-guard: a package run put the stock' <<<"$WOUT" && p "fix21 guard: it said it re-applied the fix" || f "fix21 guard: no re-apply message: $(tail -3 <<<"$WOUT" | tr '\n' ' ')"
[[ $(stat -c '%a %u:%g' "$WL") == "644 0:0" ]] && p "fix21 guard: the re-patched library is 0644 root:root" || f "fix21 guard: re-patched library mode is $(stat -c '%a %u:%g' "$WL")"
compgen -G "$WL.*.tmp" >/dev/null && f "fix21 guard: a temporary file is left" || p "fix21 guard: no temporary file left"
# Nothing to do on a fixed library: silent.
disarm; WOUT=$(in_chroot /usr/local/sbin/pyra-wsegl-guard 2>&1 || true); arm
[[ -z $WOUT ]] && p "fix21 guard: silent when the library is already fixed" || f "fix21 guard: on a fixed library it said: $WOUT"

# A deliberate rollback must survive the next package run.
in_chroot "$WFIX" rollback >/dev/null 2>&1 || f "fix21 guard: rollback failed in the chroot"
pkgrun
if [[ $(wsha) == "$SHA_STOCK" ]] && ! grep -q pyra-wsegl-guard <<<"$WOUT"; then
    p "fix21 guard: a rolled-back card stays stock across a package run, silently"
else
    f "fix21 guard: after rollback and a package run: $(in_chroot "$WFIX" status 2>&1 | tr '\n' ' ')"
fi
in_chroot "$WFIX" install >/dev/null 2>&1 || f "fix21 guard: install after rollback failed"
[[ $(wsha) == "$SHA_FIXED" && ! -e $WMARK/rolled-back ]] && p "fix21 guard: install after rollback patches and clears the rollback marker" || f "fix21 guard: install after rollback left $(in_chroot "$WFIX" status 2>&1 | tr '\n' ' ')"
rmdir "$WMARK" 2>/dev/null || true

# A build the fix does not know: warn, change nothing, never fail dpkg.
cp -p "$WL" "$WL.selftest-keep"
{ cat "$WL.stock"; printf x; } > "$WL.selftest-new"; chmod 644 "$WL.selftest-new"; mv "$WL.selftest-new" "$WL"
UNK=$(wsha)
disarm; set +e
WOUT=$(in_chroot dpkg --configure -a 2>&1 </dev/null); WRC=$?
set -e; arm
[[ $WRC -eq 0 ]] && p "fix21 guard: an unknown build does not fail the package run" || f "fix21 guard: an unknown build made dpkg exit $WRC"
grep -q 'FIX 21 IS NOT APPLIED' <<<"$WOUT" && p "fix21 guard: an unknown build prints the warning" || f "fix21 guard: no warning for an unknown build: $(tail -3 <<<"$WOUT" | tr '\n' ' ')"
[[ $(wsha) == "$UNK" ]] && p "fix21 guard: an unknown build is left unchanged" || f "fix21 guard: the guard changed an unknown build"
mv "$WL.selftest-keep" "$WL"
rm -f "$MNT/tmp/dri3wsegl-pyra_0.4_armhf.deb"

# Fix 26's wheel guard, fired by a real downgrade to the vendor's pyra-hacks
# 0.38 and a return to the fork, both with the image's dpkg. It needs the
# vendor's deb (PYRA_HACKS_VENDOR_DEB, by default the package archive beside
# the repository) with its pinned SHA-256, and the fork's: the copy beside
# PYRA_SETTINGS_DEB, or the pinned release (network). The same downgrade fires
# fixes 6 and 7's guard, which must put both back.
if [[ $SON == yes ]]; then
    i "fix 26's wheel guard — a downgrade to the vendor's pyra-hacks and back"
    HVDEB_SHA=e7f29e4428fa03adbeb045bde4c1aadffa036d68bec07bbc65c9bc6475d12164
    HVDEB=${PYRA_HACKS_VENDOR_DEB:-$(cd -- "$ROOT/.." && pwd)/pyra-packages-archive/packages.pyra-handheld.com/trixie/pyra-hacks_0.38_armhf.deb}
    HFNAME=$(sed -n 's/^HACKS_DEB=//p' "$PREP")
    HFURL=$(sed -n 's/^HACKS_URL=//p' "$PREP")
    HFSHA=$(sed -n 's/^HACKS_SHA256=//p' "$PREP")
    HFDEB=$MNT/tmp/$HFNAME
    if [[ -n $SDEB && -r $(dirname -- "$SDEB")/$HFNAME ]]; then
        cp "$(dirname -- "$SDEB")/$HFNAME" "$HFDEB"
    elif ! curl -fsSL --proto '=https' --tlsv1.2 -o "$HFDEB" "$HFURL" \
         || [[ $(sha256sum < "$HFDEB" | cut -d' ' -f1) != "$HFSHA" ]]; then
        rm -f "$HFDEB"
    fi
    if [[ -r $HVDEB && $(sha256sum < "$HVDEB" | cut -d' ' -f1) == "$HVDEB_SHA" && -r $HFDEB ]]; then
        cp "$HVDEB" "$MNT/tmp/pyra-hacks-vendor.deb"
        disarm; GOUT=$(in_chroot /usr/local/sbin/pyra-wheel-guard 2>&1 || true); arm
        [[ -z $GOUT ]] && p "wheel guard: silent on the prepared card" || f "wheel guard: on the prepared card it said: $GOUT"
        disarm; set +e
        GOUT=$(in_chroot dpkg -i /tmp/pyra-hacks-vendor.deb 2>&1 </dev/null); GRC=$?
        set -e; arm
        [[ $GRC -eq 0 ]] && p "wheel guard: the downgrade to the vendor's 0.38 exited 0" || f "wheel guard: the downgrade exited $GRC: $(tail -2 <<<"$GOUT" | tr '\n' ' ')"
        grep -q 'THE VOLUME WHEEL IS NOT CALIBRATED' <<<"$GOUT" && p "wheel guard: the downgrade prints the warning" \
            || f "wheel guard: no warning after the downgrade: $(tail -3 <<<"$GOUT" | tr '\n' ' ')"
        grep -q 're-applied fixes 6 and 7' <<<"$GOUT" && p "fix6/7 guard: the same downgrade re-applied both fixes" \
            || f "fix6/7 guard: no re-apply after the downgrade: $(tail -3 <<<"$GOUT" | tr '\n' ' ')"
        disarm; set +e
        GOUT=$(in_chroot dpkg -i "/tmp/$HFNAME" 2>&1 </dev/null); GRC=$?
        set -e; arm
        [[ $GRC -eq 0 ]] && p "wheel guard: the return to the fork exited 0" || f "wheel guard: the return to the fork exited $GRC: $(tail -2 <<<"$GOUT" | tr '\n' ' ')"
        grep -q pyra-wheel-guard <<<"$GOUT" && f "wheel guard: it still warned with the fork back" || p "wheel guard: silent once the fork is back"
        HST=$(in_chroot dpkg-query -W -f='${Version} ${db:Status-Abbrev}' pyra-hacks 2>/dev/null || true)
        [[ $HST == "$HVER ii"* ]] && p "wheel guard: dpkg has the fork $HVER again" || f "wheel guard: pyra-hacks is '$HST' after the return, want $HVER ii"
        TD=$MNT/usr/share/pyra/scripts/pyra-thermal.sh
        for fx in pyra-thermal-fix.sh pyra-thermal-ladder.sh; do
            "$PAYLOADS/$fx" --emit-patched "$TD" 2>/dev/null | cmp -s - "$TD" \
                || f "wheel guard: after the return, $fx would change the thermal daemon"
        done
        rm -f "$MNT/tmp/pyra-hacks-vendor.deb"
    else
        SKIP=$((SKIP+1)); SKIPPED+=("wheel guard: no real downgrade (vendor 0.38 deb at $HVDEB or the fork's deb missing)")
        printf '\e[33mSKIP\e[0m  wheel guard: no checked vendor 0.38 deb at %s, or no fork deb\n' "$HVDEB"
    fi
    rm -f "$HFDEB"
fi
# Fix 29's input guard, the same way: a downgrade to the vendor's 0.1.19, whose
# package has no unit, so dpkg deletes the rebuilt package's; the guard must
# warn and put fix 3's unit back. Then the return, which must be silent. It
# needs the vendor's deb (PYRA_PYRAINPUT_VENDOR_DEB, by default the package
# archive beside the repository) with its pinned SHA-256, and the rebuilt one:
# the run's own, or the pinned release (network).
if [[ $PION == yes ]]; then
    i "fix 29's input guard — a downgrade to the vendor's funkeymonkey-pyrainput and back"
    PVDEB_SHA=f959dbbda1e4c39524f85a955c66f2af6275274ed687292de8fcd100f3aacea4
    PVDEB=${PYRA_PYRAINPUT_VENDOR_DEB:-$(cd -- "$ROOT/.." && pwd)/pyra-packages-archive/packages.pyra-handheld.com/trixie/funkeymonkey-pyrainput_0.1.19_armhf.deb}
    PFDEB=$MNT/tmp/pyrainput-fixed.deb
    if [[ -n $PIDEB ]]; then
        cp "$PIDEB" "$PFDEB"
    elif ! curl -fsSL --proto '=https' --tlsv1.2 -o "$PFDEB" "$(sed -n 's/^PYRAINPUT_URL=//p' "$PREP")" \
         || [[ $(sha256sum < "$PFDEB" | cut -d' ' -f1) != "$(sed -n 's/^PYRAINPUT_SHA256=//p' "$PREP")" ]]; then
        rm -f "$PFDEB"
    fi
    if [[ -r $PVDEB && $(sha256sum < "$PVDEB" | cut -d' ' -f1) == "$PVDEB_SHA" && -r $PFDEB ]]; then
        cp "$PVDEB" "$MNT/tmp/pyrainput-vendor.deb"
        disarm; GOUT=$(in_chroot /usr/local/sbin/pyra-input-guard 2>&1 || true); arm
        [[ -z $GOUT ]] && p "input guard: silent on the prepared card" || f "input guard: on the prepared card it said: $GOUT"
        disarm; set +e
        GOUT=$(in_chroot dpkg -i /tmp/pyrainput-vendor.deb 2>&1 </dev/null); GRC=$?
        set -e; arm
        [[ $GRC -eq 0 ]] && p "input guard: the downgrade to the vendor's 0.1.19 exited 0" || f "input guard: the downgrade exited $GRC: $(tail -2 <<<"$GOUT" | tr '\n' ' ')"
        grep -q 'THE INPUT DAEMON IS NOT THE FIXED BUILD' <<<"$GOUT" && p "input guard: the downgrade prints the warning" \
            || f "input guard: no warning after the downgrade: $(tail -3 <<<"$GOUT" | tr '\n' ' ')"
        grep -q "put fix 3's back" <<<"$GOUT" && in_chroot dpkg-query -S "$PIUNIT" >/dev/null 2>&1 && f "input guard: the vendor's package owns a unit after all"
        cmp -s "$FIX3UNIT" "$MNT$PIUNIT" && in_chroot test -e "$PIWANTS" \
            && p "input guard: after the downgrade, fix 3's unit is back and enabled" || f "input guard: after the downgrade, no enabled pyrainput.service"
        disarm; set +e
        GOUT=$(in_chroot dpkg -i /tmp/pyrainput-fixed.deb 2>&1 </dev/null); GRC=$?
        set -e; arm
        [[ $GRC -eq 0 ]] && p "input guard: the return to $PIVER exited 0" || f "input guard: the return exited $GRC: $(tail -2 <<<"$GOUT" | tr '\n' ' ')"
        grep -q pyra-input-guard <<<"$GOUT" && f "input guard: it still warned with $PIVER back" || p "input guard: silent once $PIVER is back"
        PST=$(in_chroot dpkg-query -W -f='${Version} ${db:Status-Abbrev}' funkeymonkey-pyrainput 2>/dev/null || true)
        [[ $PST == "$PIVER ii"* && $(in_chroot dpkg-query -S "$PIUNIT" 2>/dev/null) == "funkeymonkey-pyrainput: $PIUNIT" ]] \
            && p "input guard: dpkg has $PIVER again, owning the unit" || f "input guard: after the return, '$PST', unit $(in_chroot dpkg-query -S "$PIUNIT" 2>&1)"
        in_chroot test -e "$PIWANTS" && p "input guard: and pyrainput.service is still enabled" || f "input guard: pyrainput.service is not enabled after the return"
        rm -f "$MNT/tmp/pyrainput-vendor.deb"
    else
        SKIP=$((SKIP+1)); SKIPPED+=("input guard: no real downgrade (vendor 0.1.19 deb at $PVDEB or the rebuilt deb missing)")
        printf '\e[33mSKIP\e[0m  input guard: no checked vendor 0.1.19 deb at %s, or no rebuilt deb\n' "$PVDEB"
    fi
    rm -f "$PFDEB"
fi
for d in dev sys proc; do umount "$MNT/$d"; done
[[ $(wsha) == "$SHA_FIXED" ]] || f "fix21 guard: the fixed library was not put back after the test"

########################################################################
i "release mode — prep --release"
########################################################################
# On top of runs 1 and 2: the same image, which also lets it check the
# refusals, since run 1 left an authorised key, and fix 23's --release case,
# since the card now has its own host key and machine-id. Release mode changes
# fix 2's password, removes those whatever they are, and removes what its own
# section does, so on a vendor image the result is the same.
# What the vendor image had, from the first snapshot.
i "vendor image: $(grep -c ' etc/ssh/ssh_host_' "$OUT/rootfs-before.txt") ssh host key files, /etc/machine-id $(awk '$6=="etc/machine-id"{print $5" bytes"}' "$OUT/rootfs-before.txt"), random-seed $(grep -q ' var/lib/systemd/random-seed ' "$OUT/rootfs-before.txt" && echo present || echo absent), credential.secret $(grep -q ' var/lib/systemd/credential.secret ' "$OUT/rootfs-before.txt" && echo present || echo absent)"
for u in "$MNT"/usr/lib/systemd/system/ssh.service "$MNT"/lib/systemd/system/ssh.service; do
    [[ -e $u ]] && { i "image ssh.service: $(grep -E '^Exec' "$u" | tr '\n' ' ')"; break; }
done
i "ssh enabled by: $(cd "$MNT/etc/systemd/system" && ls -d -- */ssh.service */ssh.socket 2>/dev/null | tr '\n' ' ')"
i "systemd-firstboot.service: $(compgen -G "$MNT/usr/lib/systemd/system/systemd-firstboot.service" >/dev/null && echo present || echo absent)"

refused() {     # refused LABEL MESSAGE PREP-ARGS... : must fail, say MESSAGE, write nothing
    local label=$1 msg=$2 out rc; shift 2
    snapshot > "$OUT/.rb"
    disarm; set +e
    out=$("$PREP" "$@" 2>&1 </dev/null); rc=$?
    set -e; arm
    snapshot > "$OUT/.ra"
    if [[ $rc -ne 0 ]] && grep -qF -- "$msg" <<<"$out" && cmp -s "$OUT/.rb" "$OUT/.ra"; then
        p "release: refuses $label and writes nothing"
    else
        f "release: $label: exit $rc, $(grep -cF -- "$msg" <<<"$out") matching lines, filesystem $(cmp -s "$OUT/.rb" "$OUT/.ra" && echo unchanged || echo changed)"
        tail -3 <<<"$out" | sed 's/^/      /'
    fi
    rm -f "$OUT/.rb" "$OUT/.ra"
}
refused "--set-password" "--set-password conflicts with --release" "${KARGS[@]}" --release --set-password "$MNT" pyra
refused "--ssh-key" "--ssh-key conflicts with --release" "${KARGS[@]}" --release --ssh-key "$OUT/testkey.pub" "$MNT" pyra
refused "another username" "the release image's user is 'pyra'" "${KARGS[@]}" --release "$MNT" someone
refused "an image with an authorised key" "authorized_keys exists in the image" "${KARGS[@]}" --release "$MNT" pyra
rm -f "$AK"
printf 'pyra ALL=(ALL) NOPASSWD: ALL\n' > "$MNT/etc/sudoers.d/90-pyra-nopasswd"; chmod 0440 "$MNT/etc/sudoers.d/90-pyra-nopasswd"
refused "an image with 90-pyra-nopasswd" "90-pyra-nopasswd exists in the image" "${KARGS[@]}" --release "$MNT" pyra
mv "$MNT/etc/sudoers.d/90-pyra-nopasswd" "$MNT/etc/sudoers.d/50-selftest"
refused "an image with a NOPASSWD rule for all commands" "the image has a NOPASSWD sudo rule for all commands" "${KARGS[@]}" --release "$MNT" pyra
rm -f "$MNT/etc/sudoers.d/50-selftest"

# Run 3, stdin closed: a prompt would read EOF and stop the run.
disarm; set +e
"$PREP" "${KARGS[@]}" --release --grow-on-boot "$MNT" pyra </dev/null 2>&1 | tee "$OUT/prep-run3.log"
RC3=${PIPESTATUS[0]}
set -e; arm
[[ $RC3 -eq 0 ]] && p "release: run 3 exited 0 with stdin closed" || f "release: run 3 exited $RC3"
grep -qE 'Password for|\[Y/n\]' "$OUT/prep-run3.log" && f "release: run 3 prompted" || p "release: run 3 asked nothing"

HASH=$(awk -F: '$1=="pyra"{print $2}' "$MNT/etc/shadow")
[[ $HASH == '!' ]] && p "release: pyra has no password (shadow '!')" || f "release: pyra's shadow hash is '${HASH:0:3}...', not '!'"
LASTCHG=$(awk -F: '$1=="pyra"{print $3}' "$MNT/etc/shadow")
[[ $LASTCHG != 0 ]] && p "release: nothing expires the password chosen later (last change '$LASTCHG')" || f "release: pyra's last change is 0, which would expire the first-boot password"
PEND=$MNT/var/lib/dragonbox-pyra/first-boot-password
[[ -f $PEND && ! -L $PEND && $(<"$PEND") == pyra && $(stat -c '%a %u:%g' "$PEND") == "600 0:0" ]] \
    && p "release: the pending file names pyra, 600 root:root" || f "release: the pending file is $(stat -c '%F %a %u:%g' "$PEND" 2>/dev/null || echo missing)"
grep -q "fix33: the first boot asks for pyra's password" "$OUT/prep-run3.log" && p "release: fix 33 reports the first boot will ask" || f "release: fix 33 did not report the pending password"
compgen -G "$MNT/etc/ssh/ssh_host_*" >/dev/null && f "release: ssh host keys left: $(cd "$MNT/etc/ssh" && ls ssh_host_* | tr '\n' ' ')" || p "release: no ssh host keys"
grep -q 'fix23: removed 2 ssh host key files (--release)' "$OUT/prep-run3.log" && grep -q 'fix23: emptied /etc/machine-id (--release)' "$OUT/prep-run3.log" \
    && p "release: it removed the card's own host key and machine-id, which a plain run keeps" || f "release: run 3 did not report removing the card's own host key and machine-id"
[[ $(readlink "$MNT/etc/systemd/system/multi-user.target.wants/$HK") == /etc/systemd/system/$HK ]] \
    && p "release: $HK enabled in multi-user.target" || f "release: $HK not enabled"
[[ -f $MNT/etc/machine-id && ! -s $MNT/etc/machine-id ]] && p "release: /etc/machine-id is an empty file" || f "release: /etc/machine-id is missing or not empty"
DMID=$MNT/var/lib/dbus/machine-id
[[ ! -e $DMID && ! -L $DMID ]] || [[ $(readlink "$DMID") == /etc/machine-id ]] \
    && p "release: /var/lib/dbus/machine-id is absent or a link to /etc/machine-id" || f "release: /var/lib/dbus/machine-id is its own file"
for x in /var/lib/systemd/random-seed /var/lib/systemd/credential.secret; do
    [[ ! -e $MNT$x ]] && p "release: no $x" || f "release: $x is still there"
done
[[ ! -e $MNT/etc/sudoers.d/90-pyra-nopasswd ]] && p "release: no /etc/sudoers.d/90-pyra-nopasswd" || f "release: /etc/sudoers.d/90-pyra-nopasswd is there"
grep -sqE '^[^#]*NOPASSWD:.*\<ALL\>' "$MNT/etc/sudoers" "$MNT"/etc/sudoers.d/* && f "release: a NOPASSWD sudo rule for all commands is there" || p "release: no NOPASSWD sudo rule for all commands"
i "release: NOPASSWD rules left (the vendor's, one command each): $(grep -shE '^[^#]*NOPASSWD' "$MNT/etc/sudoers" "$MNT"/etc/sudoers.d/* | tr -s ' ' | tr '\n' ';')"
[[ $(readlink "$MNT/etc/systemd/system/systemd-firstboot.service") == /dev/null ]] \
    && p "release: systemd-firstboot.service masked" || f "release: systemd-firstboot.service not masked"
[[ ! -e $AK && ! -e $MNT/root/.ssh/authorized_keys ]] && p "release: no authorized_keys for pyra or root" || f "release: an authorized_keys file is there"
[[ $(awk -F: '$1=="root"{print $2}' "$MNT/etc/shadow") == '!'* ]] && p "release: root is locked" || f "release: root is not locked"
grep -qE 'fix21: .*already patched' "$OUT/prep-run3.log" && [[ $(sha256sum < "$WL" | cut -d' ' -f1) == "$SHA_FIXED" ]] \
    && p "release: the image carries the patched libpvrDRI3WSEGL.so" || f "release: the library is not the fixed build after run 3"
APTLEFT=$(find "$MNT/var/lib/apt/lists" "$MNT/var/cache/apt" -maxdepth 2 -type f \( -path '*/lists/*' ! -name lock -o -name '*pkgcache.bin' \) 2>/dev/null | wc -l)
[[ $APTLEFT -eq 0 && -e $MNT/var/lib/apt/lists/lock && -d $MNT/var/lib/apt/lists/partial ]] && grep -qE 'release: removed [1-9][0-9]* apt package list and cache files' "$OUT/prep-run3.log" \
    && p "release: the vendor's stale apt package lists are gone; the lock and partial/ stay" || f "release: $APTLEFT apt list or cache files left, or the lock or partial/ removed, or run 3 did not report removing them"

grep -qx 'release=yes' "$MNT/etc/dragonbox-pyra-prep" && grep -q 'fix31: updated /etc/dragonbox-pyra-prep' "$OUT/prep-run3.log" \
    && p "release: the marker says release=yes" || f "release: the marker's release line is '$(grep '^release=' "$MNT/etc/dragonbox-pyra-prep")'"
[[ -x $MNT/usr/local/bin/pyra-info ]] && p "release: pyra-info stays" || f "release: pyra-info is gone"

# Run 4: release mode is idempotent too.
snapshot > "$OUT/rootfs-after3.txt"
disarm; set +e
"$PREP" "${KARGS[@]}" --release --grow-on-boot "$MNT" pyra </dev/null 2>&1 | tee "$OUT/prep-run4.log"
RC4=${PIPESTATUS[0]}
set -e; arm
[[ $RC4 -eq 0 ]] && p "release: run 4 exited 0" || f "release: run 4 exited $RC4"
snapshot > "$OUT/rootfs-after4.txt"
if diff -u "$OUT/rootfs-after3.txt" "$OUT/rootfs-after4.txt" > "$OUT/rootfs-diff4.txt"; then
    p "release: run 4 changed nothing on disk"
else
    f "release: run 4 changed the filesystem:"
    { grep -E '^[+-][^+-]' "$OUT/rootfs-diff4.txt" || true; } | sed -n '1,20p' | sed 's/^/      /'
fi
grep -q "release: 'pyra' already has no password" "$OUT/prep-run4.log" \
    && p "release: run 4 left the locked password and the pending file alone" || f "release: run 4 did not report the password already locked"
grep -q 'release: no apt package lists in the image' "$OUT/prep-run4.log" \
    && p "release: run 4 found no apt package lists to remove" || f "release: run 4 did not report the apt package lists already gone"
[[ $(grep -cE 'fix23: .*already (up to date|enabled|empty|masked)' "$OUT/prep-run4.log") -eq 4 ]] \
    && p "release: run 4 reported the unit, its link, the machine-id and the mask already in place" || f "release: run 4 did not report the unit, link, machine-id and mask in place"

# The first boot, as far as a chroot shows it: without keys the image's own
# `sshd -t` (ssh.service's ExecStartPre) fails, and after the unit's command
# it passes. The keys are removed again afterwards.
for d in proc sys dev; do mount --bind "/$d" "$MNT/$d"; done
MADE_RUN=no
[[ -d $MNT/run/sshd ]] || { mkdir -p "$MNT/run/sshd"; MADE_RUN=yes; }
disarm; set +e
T0=$(in_chroot /usr/sbin/sshd -t 2>&1); T0RC=$?
G=$(in_chroot /usr/bin/ssh-keygen -A 2>&1); GRC=$?
T1=$(in_chroot /usr/sbin/sshd -t 2>&1); T1RC=$?
set -e; arm
# sshd ends its messages with a carriage return, which overprints the line.
T0=${T0//$'\r'/}; G=${G//$'\r'/}; T1=${T1//$'\r'/}
[[ $T0RC -ne 0 ]] && p "release: without host keys the image's sshd -t fails ($(head -1 <<<"$T0"))" || f "release: sshd -t passed with no host keys"
[[ $GRC -eq 0 && $T1RC -eq 0 ]] && p "release: after ssh-keygen -A ($(sed -n 's/.*generating new host keys: //p' <<<"$G")) sshd -t passes" \
    || { f "release: ssh-keygen -A exit $GRC, then sshd -t exit $T1RC"; printf '%s\n%s\n' "$G" "$T1" | sed 's/^/      /'; }
rm -f "$MNT"/etc/ssh/ssh_host_*
[[ $MADE_RUN == yes ]] && rm -rf "$MNT/run/sshd"
for d in dev sys proc; do umount "$MNT/$d"; done
snapshot > "$OUT/rootfs-after-keygen.txt"
cmp -s "$OUT/rootfs-after4.txt" "$OUT/rootfs-after-keygen.txt" && p "release: the chroot check left the image as run 4 did" \
    || { f "release: the chroot check changed the image:"; { diff "$OUT/rootfs-after4.txt" "$OUT/rootfs-after-keygen.txt" || true; } | sed -n '1,10p' | sed 's/^/      /'; }

# The first boot's password step, as far as a chroot shows it: the window's
# set_password with the image's chpasswd. Afterwards the hash opens with the
# chosen password (colon, space and bar included), the pending file is gone, so
# the unit's condition fails on the next boot. Shadow and file are put back.
# chpasswd also rewrites shadow's backup and may leave a lock file.
FB_SAVE=$OUT/.firstboot; rm -rf "$FB_SAVE"; mkdir -p "$FB_SAVE"
for x in /etc/shadow /etc/shadow- /etc/.pwd.lock "${PEND#$MNT}"; do
    [[ -e $MNT$x ]] && cp -a "$MNT$x" "$FB_SAVE/$(basename "$x")" || : > "$FB_SAVE/$(basename "$x").absent"
done
disarm; set +e
got=$(in_chroot python3 -B -c 'import importlib.machinery as m
fb = m.SourceFileLoader("fb", "/usr/local/sbin/pyra-first-boot").load_module()
print(fb.pending_user(), fb.set_password("pyra", "a:b c|d"))' 2>&1)
set -e; arm
HASH=$(awk -F: '$1=="pyra"{print $2}' "$MNT/etc/shadow")
[[ $got == "pyra None" ]] && p "release: the first-boot step ran the image's chpasswd for pyra" || f "release: pending_user, set_password printed '$got'"
# The image's crypt() checks the hash, whatever method its login.defs picked.
in_chroot perl -e 'exit(crypt($ARGV[0], $ARGV[1]) eq $ARGV[1] ? 0 : 1)' 'a:b c|d' "$HASH" \
    && p "release: pyra's new hash (${HASH:0:3}) opens with 'a:b c|d', checked by the image's crypt()" || f "release: pyra's hash '${HASH:0:4}...' does not open with 'a:b c|d'"
[[ ! -e $PEND ]] && p "release: the pending file is gone after the step" || f "release: the pending file is still there after the step"
for x in /etc/shadow /etc/shadow- /etc/.pwd.lock "${PEND#$MNT}"; do
    b=$FB_SAVE/$(basename "$x")
    if [[ -e $b.absent ]]; then rm -f -- "$MNT$x"; else cp -a "$b" "$MNT$x"; fi
done
rm -rf "$FB_SAVE"
snapshot > "$OUT/rootfs-after-firstboot.txt"
cmp -s "$OUT/rootfs-after4.txt" "$OUT/rootfs-after-firstboot.txt" && p "release: the first-boot check left the image as run 4 did" \
    || { f "release: the first-boot check changed the image:"; { diff "$OUT/rootfs-after4.txt" "$OUT/rootfs-after-firstboot.txt" || true; } | sed -n '1,10p' | sed 's/^/      /'; }

########################################################################
sync
i "unmounting"
umount "$MNT/boot"
umount "$MNT"; mountpoint -q "$MNT" || i "clean unmount"
fsck.f2fs -f --dry-run "${LOOP}p2" > "$OUT/fsck-after.log" 2>&1 && p "fsck.f2fs clean after prep" || f "fsck.f2fs reported problems (see $OUT/fsck-after.log)"
tail -5 "$OUT/fsck-after.log" | sed 's/^/      /'

# The banner is printed by finish() on the way out, once and only once.
exit $(( FAIL > 0 ))
