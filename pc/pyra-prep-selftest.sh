#!/usr/bin/env bash
# Validate pyra-trixie-prep.sh against the real trixie image, loop-mounted.
#
#   sudo ./pc/pyra-prep-selftest.sh [/path/to/pyra-trixie-t1.img]
#
# Runs on a COPY, so the image itself stays the record of what was written to
# the card. Snapshots the whole rootfs before and after, so an unexpected write
# anywhere in the tree cannot go unnoticed. Then runs the prep script, asserts
# the end state of all eight fixes, runs it a second time and requires the
# filesystem to be unchanged, and finally checks that a missing fix 5 payload
# aborts before fix 1 writes anything.
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
WORK=$ROOT/pyra-trixie-t1-preptest.img
PREP=$REPO/pyra-trixie-prep.sh
OUT=${OUTDIR:-}
MNT=$(mktemp -d /tmp/pyraprep.XXXXXX)

PASS=0; FAIL=0; ABORTED=0; BANNERED=0
p() { printf '\e[32mPASS\e[0m  %s\n' "$*"; PASS=$((PASS+1)); }
f() { printf '\e[31mFAIL\e[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
i() { printf '\e[36m----\e[0m  %s\n' "$*"; }

# A silent exit must never read as a pass -- the verify-card-capacity.sh lesson.
# But exactly ONE banner may ever be printed, from the EXIT path, so a run can
# never emit two contradictory verdicts. The ERR trap only records the abort.
#
# An ERR trap fires whether or not errexit is set, so it must be DISARMED around
# any command whose failure is a legitimate outcome, not merely wrapped in
# `set +e`. arm/disarm below; three places need it.
ERRTRAP='ABORTED=1; printf "\e[31m!!!!\e[0m  unexpected error at line $LINENO\n" >&2'
arm()    { trap "$ERRTRAP" ERR; }
disarm() { trap - ERR; }
arm

LOOP=""
finish() {
    local rc=$?
    set +e; disarm
    mountpoint -q "$MNT" && umount "$MNT"
    [[ -n $LOOP ]] && losetup -d "$LOOP"
    rmdir "$MNT" 2>/dev/null
    [[ $BANNERED -eq 1 ]] && return
    BANNERED=1
    echo
    [[ -n $OUT ]] && printf '\e[36m----\e[0m  logs, snapshots and diffs in %s\n' "$OUT"
    printf '\e[1m%d passed, %d failed\e[0m\n' "$PASS" "$FAIL"
    if [[ $ABORTED -eq 1 ]]; then
        echo "TEST COMPLETE: FAIL (harness aborted before finishing)"
    elif [[ $rc -ne 0 && $FAIL -eq 0 ]]; then
        echo "TEST COMPLETE: FAIL (exited $rc with no assertion failure -- treat as incomplete)"
    elif [[ $FAIL -gt 0 ]]; then
        echo "TEST COMPLETE: FAIL"
    else
        echo "TEST COMPLETE: PASS"
    fi
}
trap finish EXIT

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ -r $IMG ]] || { echo "no image at $IMG" >&2; exit 1; }
[[ -x $PREP ]] || { echo "no pyra-trixie-prep.sh beside this script" >&2; exit 1; }
# Deferred until after the guards, so a refused run leaves no stray directory.
[[ -n $OUT ]] || OUT=$(mktemp -d /tmp/pyra-prep-selftest.XXXXXX)
mkdir -p "$OUT"
i "artefacts in $OUT"

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
    i "copied $IMG -> $WORK"
fi

modprobe f2fs
LOOP=$(losetup --find --partscan --show "$WORK")
i "loop device $LOOP"
[[ -b ${LOOP}p2 ]] || { echo "no ${LOOP}p2 — partscan failed" >&2; exit 1; }

blkid "${LOOP}p1" "${LOOP}p2" || true
mount -t f2fs "${LOOP}p2" "$MNT"
i "mounted ${LOOP}p2 at $MNT"

snapshot() {
    # No pipeline: find's exit status must not decide the harness's fate, and
    # a downstream reader exiting early would SIGPIPE it under pipefail.
    local raw=$OUT/.snap.$$
    find "$MNT" -xdev -printf '%y %m %U %G %s %P -> %l\n' > "$raw" 2>/dev/null || true
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
disarm; set +e
"$PREP" "$MNT" pyra 2>&1 | tee "$OUT/prep-run1.log"
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
i "assert the eight fixes"
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
i "run 2 — idempotency"
########################################################################
disarm; set +e
"$PREP" "$MNT" pyra 2>&1 | tee "$OUT/prep-run2.log"
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
grep -qE 'fix5: .*already up to date' "$OUT/prep-run2.log" && p "run 2 reported fix5 already up to date" || f "run 2 did not report fix5 up to date"
grep -qE 'fix5: already enabled' "$OUT/prep-run2.log" && p "run 2 reported fix5 already enabled" || f "run 2 did not report fix5 already enabled"
grep -qE 'fix6: .*already applies' "$OUT/prep-run2.log" && p "run 2 reported fix6 already applied" || f "run 2 did not report fix6 already applied"
grep -qE 'fix7: .*already has the corrected ladder' "$OUT/prep-run2.log" && p "run 2 reported fix7 already applied" || f "run 2 did not report fix7 already applied"
grep -qE 'fix8: .*already in place' "$OUT/prep-run2.log" && p "run 2 reported fix8 already applied" || f "run 2 did not report fix8 already in place"

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
ABORT=$("$STAGE/$(basename "$PREP")" "$MNT" pyra 2>&1) || ARC=$?
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
sync
i "unmounting"
umount "$MNT"; mountpoint -q "$MNT" || i "clean unmount"
fsck.f2fs -f --dry-run "${LOOP}p2" > "$OUT/fsck-after.log" 2>&1 && p "fsck.f2fs clean after prep" || f "fsck.f2fs reported problems (see $OUT/fsck-after.log)"
tail -5 "$OUT/fsck-after.log" | sed 's/^/      /'

# The banner is printed by finish() on the way out, once and only once.
exit $(( FAIL > 0 ))
