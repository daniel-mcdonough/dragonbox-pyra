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
# the end state of fixes 1 to 8 and 13 to 22 (fix 2 with --set-password and
# --ssh-key, fix 14 with --grow-on-boot), runs it a second time and requires the
# filesystem to be unchanged, checks that a missing fix 5 payload and an
# unknown driver library (fix 21) each abort before fix 1 writes anything,
# fires fix 21's dpkg guard with the image's own dpkg (it must re-patch after a
# reinstall, leave a rolled-back card stock, and warn about an unknown build
# without touching it), and finally runs --release twice on the same
# image: what it refuses (writing nothing), the release end state (password
# 'pyra' expired, no host keys, empty machine-id, no prompts, no NOPASSWD
# rule for all commands, systemd-firstboot masked), idempotency, and the image's sshd -t before and after ssh-keygen -A.
#
# Fix 19 installs the shipped kernel from a tarball. The image carries only the
# stock kernel, so the test hands prep the cross-build's output
# (PYRA_BUILD_DIR/kernel/m4-kbdled-kernel.tar.gz, by default in
# dragonbox-pyra-build beside the repository; PYRA_KERNEL_TARBALL names another).
# Without one, it runs prep with --no-kernel and says so in the verdict: a SKIP
# is counted and printed, never a silent pass.
#
# Fix 22 installs pyra-backlight from a .deb: PYRA_BACKLIGHT_DEB, by default
# pyra-backlight/dist/pyra-backlight_0.2_all.deb beside the repository. Without
# one, prep runs with --no-backlight and that is a SKIP too. The image lacks
# gir1.2-matepanelapplet-4.0, which prep downloads (pinned) unless a copy sits
# beside that .deb. A .deb that is not
# pyra-backlight, and one whose dependency the image lacks, are made here and
# must each stop prep before fix 1 writes anything.
#
# Fix 21's guard is fired by a real reinstall of the vendor's dri3wsegl-pyra 0.4
# deb when PYRA_WSEGL_DEB (by default the package archive beside the
# repository) holds it with the pinned SHA-256. Without it, the stock library
# is written back by hand and an empty dpkg run fires the same hook; the log
# says which.
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
BDEB=${PYRA_BACKLIGHT_DEB:-$(cd -- "$ROOT/.." && pwd)/pyra-backlight/dist/pyra-backlight_0.2_all.deb}

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
# `set +e`. arm/disarm below; four places need it.
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
if [[ -r $KTAR ]]; then
    KARGS=(--kernel "$KTAR")
    i "fix 19 installs $KTAR"
else
    KARGS=(--no-kernel)
    SKIP=$((SKIP+1)); SKIPPED+=("fix 19 installed no kernel (no tarball at $KTAR)")
    printf '\e[33mSKIP\e[0m  fix19: no kernel tarball at %s; prep runs with --no-kernel\n' "$KTAR"
fi
if [[ -r $BDEB ]]; then
    KARGS+=(--backlight "$BDEB")
    i "fix 22 installs $BDEB"
else
    KARGS+=(--no-backlight)
    SKIP=$((SKIP+1)); SKIPPED+=("fix 22 installed no pyra-backlight (no .deb at $BDEB)")
    printf '\e[33mSKIP\e[0m  fix22: no pyra-backlight .deb at %s; prep runs with --no-backlight\n' "$BDEB"
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
    # Link two: fix 6 -> fix 7.
    if "$PAYLOADS/pyra-thermal-ladder.sh" --emit-patched "$AFTER_FIX6" 2>/dev/null | cmp -s - "$TH"; then
        p "fix7: matches what pyra-thermal-ladder.sh produces, byte for byte"
    else
        f "fix7: differs from what the device script would produce"
    fi

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
# vendor file it must restore exactly what prep wrote.
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
    if cmp -s "$GT/pyra-thermal.sh" "$TH"; then
        p "fix6/7: after a simulated pyra-hacks reinstall, the guard restores the prepared file byte for byte"
    else
        f "fix6/7: after a simulated pyra-hacks reinstall, the guard does not restore the prepared file"
    fi
    rm -rf "$GT"
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
if [[ ${KARGS[0]} == --kernel ]]; then
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
else
    printf '\e[33mSKIP\e[0m  fix19: kernel assertions (no tarball at %s)\n' "$KTAR"
    [[ $(awk '/^default /{print $2; exit}' "$EXT/extlinux.conf") == l0 && ! -e $EXT/pyra-base-label ]] \
        && p "fix19: with --no-kernel the card still boots l0" || f "fix19: --no-kernel changed the boot configuration"
fi
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
WSEGL=$PAYLOADS/pyra-wsegl-fdfix.sh
SHA_STOCK=$(sed -n 's/^SHA_STOCK=//p' "$WSEGL")
SHA_FIXED=$(sed -n 's/^SHA_FIXED=//p' "$WSEGL")
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
if [[ ${KARGS[*]} == *--backlight\ * ]]; then
    BVER=$(bsdtar -xOf "$BDEB" 'control.tar.*' | bsdtar -xOf - ./control | awk '/^Version:/{print $2}')
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
else
    printf '\e[33mSKIP\e[0m  fix22: assertions (no .deb at %s)\n' "$BDEB"
    in_chroot dpkg-query -W pyra-backlight >/dev/null 2>&1 \
        && f "fix22: --no-backlight installed pyra-backlight" || p "fix22: with --no-backlight pyra-backlight is not installed"
fi
compgen -G "$MNT/var/tmp/pyra-prep-*.deb" >/dev/null && f "fix22: a staged .deb is still in /var/tmp" || p "fix22: no staged .deb left in /var/tmp"

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
if [[ ${KARGS[0]} == --kernel ]]; then
    grep -qE "fix19: $KREL is already installed" "$OUT/prep-run2.log" && p "run 2 reported the kernel already installed" || f "run 2 did not report the kernel already installed"
    grep -qE 'fix19: .*already the base and the default' "$OUT/prep-run2.log" && p "run 2 reported l5 already the base and default" || f "run 2 did not report l5 already the base and default"
fi
grep -qE 'fix20: .*already up to date' "$OUT/prep-run2.log" && p "run 2 reported fix20 already up to date" || f "run 2 did not report fix20 already up to date"
grep -qE 'fix21: .*libpvrDRI3WSEGL.so already patched' "$OUT/prep-run2.log" && p "run 2 reported the library already patched" || f "run 2 did not report the library already patched"
if [[ ${KARGS[*]} == *--backlight\ * ]]; then
    grep -qE 'fix22: pyra-backlight .* already installed' "$OUT/prep-run2.log" && p "run 2 reported pyra-backlight already installed" || f "run 2 did not report pyra-backlight already installed"
fi
for x in pyra-wsegl-fdfix.sh sbin/pyra-wsegl-guard dpkg.cfg.d/pyra-wsegl-guard; do
    grep -qE "fix21: .*$x already up to date" "$OUT/prep-run2.log" && p "run 2 reported fix21's $x up to date" || f "run 2 did not report fix21's $x up to date"
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
ABORT=$("$STAGE/$(basename "$PREP")" --no-kernel "$MNT" pyra 2>&1) || ARC=$?
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
ABORT=$("$PREP" --no-kernel "$MNT" pyra 2>&1 </dev/null) || ARC=$?
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
    ABORT=$("$PREP" --no-kernel --backlight "$OUT/selftest-$bpkg.deb" "$MNT" pyra 2>&1 </dev/null) || ARC=$?
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
for d in dev sys proc; do umount "$MNT/$d"; done
[[ $(wsha) == "$SHA_FIXED" ]] || f "fix21 guard: the fixed library was not put back after the test"

########################################################################
i "release mode — prep --release"
########################################################################
# On top of runs 1 and 2: the same image, which also lets it check the
# refusals, since run 1 left an authorised key. Release mode changes only
# fix 2's password and what its own section removes, so on a vendor image the
# result is the same.
HK=pyra-ssh-hostkeys.service
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
SALT=$(cut -d'$' -f3 <<<"$HASH")
[[ $HASH == '$6$'* && $(openssl passwd -6 -salt "$SALT" pyra) == "$HASH" ]] \
    && p "release: pyra's password is 'pyra'" || f "release: pyra's shadow hash is not 'pyra'"
LASTCHG=$(awk -F: '$1=="pyra"{print $3}' "$MNT/etc/shadow")
[[ $LASTCHG == 0 ]] && p "release: pyra must change it at the first login (last change 0)" || f "release: pyra's last change is '$LASTCHG', not 0"
compgen -G "$MNT/etc/ssh/ssh_host_*" >/dev/null && f "release: ssh host keys left: $(cd "$MNT/etc/ssh" && ls ssh_host_* | tr '\n' ' ')" || p "release: no ssh host keys"
U=$MNT/etc/systemd/system/$HK
cmp -s "$PAYLOADS/$HK" "$U" && p "release: /etc/systemd/system/$HK matches repo" || f "release: $HK missing or differs from repo"
[[ $(stat -c '%a %u:%g' "$U" 2>/dev/null) == "644 0:0" ]] && p "release: $HK is 0644 root:root" || f "release: $HK mode is $(stat -c '%a %u:%g' "$U" 2>/dev/null)"
[[ $(readlink "$MNT/etc/systemd/system/multi-user.target.wants/$HK") == /etc/systemd/system/$HK ]] \
    && p "release: $HK enabled in multi-user.target" || f "release: $HK not enabled"
grep -qx 'Before=ssh.service ssh.socket' "$U" && grep -qx 'ExecStart=/usr/bin/ssh-keygen -A' "$U" \
    && p "release: $HK runs ssh-keygen -A before ssh" || f "release: $HK is not ordered before ssh or does not run ssh-keygen -A"
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
grep -qE 'fix21: .*already patched' "$OUT/prep-run3.log" && [[ $(sha256sum < "$WL" | cut -d' ' -f1) == "$SHA_FIXED" ]] \
    && p "release: the image carries the patched libpvrDRI3WSEGL.so" || f "release: the library is not the fixed build after run 3"

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
grep -q "release: 'pyra' already has the password 'pyra'" "$OUT/prep-run4.log" \
    && p "release: run 4 left the expired password alone" || f "release: run 4 did not report the password already set"
[[ $(grep -cE 'release: .*already (up to date|enabled|empty|masked)' "$OUT/prep-run4.log") -eq 4 ]] \
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
[[ $T0RC -ne 0 ]] && p "release: without host keys the image's sshd -t fails ($(head -1 <<<"$T0"))" || f "release: sshd -t passed with no host keys"
[[ $GRC -eq 0 && $T1RC -eq 0 ]] && p "release: after ssh-keygen -A ($(sed -n 's/.*generating new host keys: //p' <<<"$G")) sshd -t passes" \
    || { f "release: ssh-keygen -A exit $GRC, then sshd -t exit $T1RC"; printf '%s\n%s\n' "$G" "$T1" | sed 's/^/      /'; }
rm -f "$MNT"/etc/ssh/ssh_host_*
[[ $MADE_RUN == yes ]] && rm -rf "$MNT/run/sshd"
for d in dev sys proc; do umount "$MNT/$d"; done
snapshot > "$OUT/rootfs-after-keygen.txt"
cmp -s "$OUT/rootfs-after4.txt" "$OUT/rootfs-after-keygen.txt" && p "release: the chroot check left the image as run 4 did" \
    || { f "release: the chroot check changed the image:"; { diff "$OUT/rootfs-after4.txt" "$OUT/rootfs-after-keygen.txt" || true; } | sed -n '1,10p' | sed 's/^/      /'; }

########################################################################
sync
i "unmounting"
umount "$MNT/boot"
umount "$MNT"; mountpoint -q "$MNT" || i "clean unmount"
fsck.f2fs -f --dry-run "${LOOP}p2" > "$OUT/fsck-after.log" 2>&1 && p "fsck.f2fs clean after prep" || f "fsck.f2fs reported problems (see $OUT/fsck-after.log)"
tail -5 "$OUT/fsck-after.log" | sed 's/^/      /'

# The banner is printed by finish() on the way out, once and only once.
exit $(( FAIL > 0 ))
