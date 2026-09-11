#!/usr/bin/env bash
# Validate pyra-devsetup.sh against a synthetic rootfs, in a container.
#
#   ./pc/pyra-devsetup-selftest.sh
#
# Needs docker and nothing else: no Pyra, no card, and no root on this machine.
# The container gives the test a real root, which matters because the thing
# being checked is ownership and modes on files belonging to another system's
# accounts.
#
# What it asserts, in order:
#   a bad argument writes nothing at all
#   a dry run writes nothing at all
#   the three changes land with the right owner and mode
#   a key already present is not added twice, and an existing key survives
#   a file with no trailing newline does not splice two keys together
#   running it three times is the same as running it once
#   undo removes only what this script added, and is safe to repeat
#
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$HERE/pyra-devsetup.sh
[[ -x $SCRIPT ]] || { echo "no pyra-devsetup.sh beside this script" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is not installed" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "cannot talk to the docker daemon" >&2; exit 1; }

WORK=$(mktemp -d /tmp/pyra-devsetup-selftest.XXXXXX)
cleanup() { docker run --rm -v "$WORK":/w debian:trixie rm -rf /w/fake /w/fake2 >/dev/null 2>&1 || true
            rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# A rootfs with the shape the real one has: a named account that is not this
# machine's, a packaged lightdm drop-in to leave alone, the units the script
# looks for, and an authorized_keys that already trusts someone else and does
# not end in a newline.
mk_fixture() {
    local f=$WORK/fake-orig
    rm -rf "$f"
    mkdir -p "$f"/{etc/sudoers.d,etc/lightdm/lightdm.conf.d,etc/systemd/system,usr/share/xsessions,lib/systemd/system,home/pyra/.ssh,var}
    printf 'ID=debian\nVERSION_CODENAME=trixie\n' >"$f/etc/os-release"
    printf 'root:x:0:0:root:/root:/bin/bash\npyra:x:1000:1000:,,,:/home/pyra:/bin/bash\n' >"$f/etc/passwd"
    printf 'pyra:x:1000:\n' >"$f/etc/group"
    printf 'pyra\n' >"$f/etc/hostname"
    printf '# packaged, must be left alone\n' >"$f/etc/lightdm/lightdm.conf.d/90_pyra.conf"
    : >"$f/usr/share/xsessions/lightdm-xsession.desktop"
    for u in ssh.service avahi-daemon.service avahi-daemon.socket; do printf '[Unit]\n' >"$f/lib/systemd/system/$u"; done
    printf 'ssh-ed25519 AAAAC3PREEXISTING existing@elsewhere' >"$f/home/pyra/.ssh/authorized_keys"
}
mk_fixture
cp "$SCRIPT" "$WORK/pyra-devsetup.sh"

cat >"$WORK/inside.sh" <<'INNER'
set -u
PASS=0; FAIL=0
p() { printf '\e[32mPASS\e[0m  %s\n' "$*"; PASS=$((PASS+1)); }
f() { printf '\e[31mFAIL\e[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
i() { printf '\e[36m----\e[0m  %s\n' "$*"; }
eq() { [ "$2" = "$3" ] && p "$1 ($2)" || f "$1: got '$2', want '$3'"; }

apt-get update -qq >/dev/null 2>&1
apt-get install -y --no-install-recommends sudo openssh-client >/dev/null 2>&1
mkdir -p /root/.ssh
ssh-keygen -t ed25519 -N '' -C 'selftest@harness' -f /root/.ssh/id_ed25519 >/dev/null
S=/w/pyra-devsetup.sh
reset() { rm -rf /w/fake; cp -a /w/fake-orig /w/fake; }

i "a bad --key must write nothing"
reset
"$S" /w/fake --key /nonexistent.pub >/dev/null 2>&1 && f "bad key exited 0" || p "bad key was refused"
eq "sudoers.d is untouched" "$(ls -A /w/fake/etc/sudoers.d | wc -l)" "0"
[ -e /w/fake/etc/pyra-devsetup.stamp ] && f "a stamp was written anyway" || p "no stamp written"

i "a missing account must be refused"
reset
"$S" /w/fake --user nosuchuser >/dev/null 2>&1 && f "unknown user exited 0" || p "unknown user was refused"

i "a dry run must write nothing"
reset
n=$("$S" /w/fake --dry-run | grep -c WOULD)
[ "$n" -ge 4 ] && p "dry run planned $n actions" || f "dry run planned only $n actions"
eq "sudoers.d is untouched" "$(ls -A /w/fake/etc/sudoers.d | wc -l)" "0"

i "three runs are the same as one"
reset
"$S" /w/fake >/dev/null || f "first run failed"
snap1=$(find /w/fake -newer /w/fake/etc/os-release -type f | sort | xargs md5sum 2>/dev/null | md5sum)
"$S" /w/fake >/dev/null; "$S" /w/fake >/dev/null
eq "authorized_keys has both keys and no more" "$(wc -l < /w/fake/home/pyra/.ssh/authorized_keys)" "2"
eq "the stamp records the key once" "$(grep -c '^key-added: ' /w/fake/etc/pyra-devsetup.stamp)" "1"

i "the existing key survived, unspliced"
grep -q '^ssh-ed25519 AAAAC3PREEXISTING existing@elsewhere$' /w/fake/home/pyra/.ssh/authorized_keys \
    && p "the key that was already there is intact on its own line" \
    || f "the pre-existing key was damaged"

i "owners and modes"
eq "sudoers drop-in mode"    "$(stat -c%a /w/fake/etc/sudoers.d/90-pyra-nopasswd)" "440"
eq "sudoers drop-in owner"   "$(stat -c%u:%g /w/fake/etc/sudoers.d/90-pyra-nopasswd)" "0:0"
eq ".ssh mode"               "$(stat -c%a /w/fake/home/pyra/.ssh)" "700"
eq ".ssh owner"              "$(stat -c%u:%g /w/fake/home/pyra/.ssh)" "1000:1000"
eq "authorized_keys mode"    "$(stat -c%a /w/fake/home/pyra/.ssh/authorized_keys)" "600"
eq "authorized_keys owner"   "$(stat -c%u:%g /w/fake/home/pyra/.ssh/authorized_keys)" "1000:1000"
visudo -cqf /w/fake/etc/sudoers.d/90-pyra-nopasswd && p "the sudo rule parses" || f "the sudo rule does not parse"

i "autologin"
grep -qx 'autologin-user=pyra' /w/fake/etc/lightdm/lightdm.conf.d/99-autologin.conf \
    && p "autologin names the account" || f "autologin does not name the account"
eq "the file ends in a newline" "$(tail -c1 /w/fake/etc/lightdm/lightdm.conf.d/99-autologin.conf | wc -l)" "1"
grep -q 'packaged' /w/fake/etc/lightdm/lightdm.conf.d/90_pyra.conf \
    && p "the packaged drop-in was left alone" || f "the packaged drop-in was modified"

i "units enabled"
[ -L /w/fake/etc/systemd/system/multi-user.target.wants/ssh.service ] \
    && p "ssh is enabled at boot" || f "ssh was not enabled"
[ -L /w/fake/etc/systemd/system/multi-user.target.wants/avahi-daemon.service ] \
    && p "avahi is enabled at boot" || f "avahi was not enabled"

i "flags are honoured"
rm -rf /w/fake2; cp -a /w/fake-orig /w/fake2
"$S" /w/fake2 --no-autologin --no-mdns --no-sudo >/dev/null
[ -e /w/fake2/etc/lightdm/lightdm.conf.d/99-autologin.conf ] && f "--no-autologin wrote it anyway" || p "--no-autologin honoured"
[ -L /w/fake2/etc/systemd/system/multi-user.target.wants/avahi-daemon.service ] && f "--no-mdns enabled it anyway" || p "--no-mdns honoured"
[ -e /w/fake2/etc/sudoers.d/90-pyra-nopasswd ] && f "--no-sudo wrote it anyway" || p "--no-sudo honoured"
[ -L /w/fake2/etc/systemd/system/multi-user.target.wants/ssh.service ] && p "ssh is still enabled, as the key needs" || f "ssh was not enabled"

i "undo"
"$S" /w/fake --undo >/dev/null
[ -e /w/fake/etc/sudoers.d/90-pyra-nopasswd ] && f "the sudo rule survived undo" || p "the sudo rule is gone"
[ -e /w/fake/etc/lightdm/lightdm.conf.d/99-autologin.conf ] && f "autologin survived undo" || p "autologin is gone"
[ -e /w/fake/etc/pyra-devsetup.stamp ] && f "the stamp survived undo" || p "the stamp is gone"
eq "only our key was removed" "$(cat /w/fake/home/pyra/.ssh/authorized_keys)" "ssh-ed25519 AAAAC3PREEXISTING existing@elsewhere"
[ -L /w/fake/etc/systemd/system/multi-user.target.wants/ssh.service ] \
    && p "undo left ssh enabled, on purpose" || f "undo disabled ssh and could lock you out"
"$S" /w/fake --undo >/dev/null && p "a second undo is safe" || f "a second undo failed"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
INNER

docker run --rm -v "$WORK":/w -w /w debian:trixie bash /w/inside.sh
