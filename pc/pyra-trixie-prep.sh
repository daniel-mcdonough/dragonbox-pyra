#!/usr/bin/env bash
# Apply the six known fixes to a freshly-written Debian 13 (trixie) Pyra SD card.
# Run against the MOUNTED rootfs partition, before the card's first boot.
#
#   sudo ./pyra-trixie-prep.sh /mnt [username]
#
# Idempotent: safe to re-run. Verifies its assumptions against the image
# instead of trusting them blindly.
#
# Fixes 5 and 6 use files that live in device/ in the repository, so run this
# from a checkout rather than copying the script somewhere on its own.

set -euo pipefail

ROOT=${1:-}
USERNAME=${2:-pyra}
GROUPS_WANTED="sudo video audio netdev plugdev bluetooth dialout input render games cdrom floppy"

die()  { printf '\e[31mERROR\e[0m  %s\n' "$*" >&2; exit 1; }
warn() { printf '\e[33mWARN\e[0m   %s\n' "$*" >&2; }
ok()   { printf '\e[32mOK\e[0m     %s\n' "$*"; }
info() { printf '\e[36mINFO\e[0m   %s\n' "$*"; }

[[ -n $ROOT ]] || die "usage: $0 /path/to/mounted/rootfs [username]"
[[ $EUID -eq 0 ]] || die "must run as root (it writes into $ROOT and chowns files)"
[[ -d $ROOT/etc && -d $ROOT/usr && -d $ROOT/var ]] || die "$ROOT does not look like a rootfs"

# Sanity: is this actually a Debian trixie armhf Pyra image, and not, say, your own /?
[[ $(realpath "$ROOT") != "/" ]] || die "refusing to operate on the host root filesystem"
if [[ -r $ROOT/etc/os-release ]]; then
    . <(grep -E '^(ID|VERSION_CODENAME)=' "$ROOT/etc/os-release")
    info "target: ${ID:-?} ${VERSION_CODENAME:-?}"
    [[ ${VERSION_CODENAME:-} == trixie ]] || warn "codename is '${VERSION_CODENAME:-unknown}', not trixie — continuing anyway"
fi
DRIDIR=$ROOT/usr/lib/arm-linux-gnueabihf/dri
[[ -d $DRIDIR ]] || die "no $DRIDIR — is this an armhf rootfs?"

# Fix 5 copies these rather than embedding them, so the repository stays the
# single source of truth for the rescue logic. Check them here, before anything
# has been written, so a missing payload cannot leave a half-fixed card.
SCRIPTDIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Fix 5 installs two files onto the device. They live with the rest of the
# device payloads rather than beside this script, so that there is exactly one
# copy of each in the repository and no chance of the two drifting apart.
PAYLOADS=$SCRIPTDIR/../device
USB3503_SRC=$PAYLOADS/pyra-usb3503-rescue
USB3503_UNIT_SRC=$PAYLOADS/pyra-usb3503-rescue.service
for f in "$USB3503_SRC" "$USB3503_UNIT_SRC"; do
    [[ -r $f ]] || die "fix5: $(basename "$f") not found (looked in $PAYLOADS)"
done

# Fix 6 does not copy a file. It transforms one that is already on the card,
# and it calls the device script to do it so that the transformation has
# exactly one implementation in the repository rather than two that can drift.
THERMAL_FIX=$PAYLOADS/pyra-thermal-fix.sh
[[ -x $THERMAL_FIX ]] || die "fix6: pyra-thermal-fix.sh not found or not executable (looked in $PAYLOADS)"


echo

########################################################################
# Fix 1 — Xorg 21.1.16 segfaults during GLX init
########################################################################
# The forum fix symlinks armsoc_dri.so at a mesa driver. That does not work
# and cannot work. Xorg builds the symbol it looks up from the DRI2 driver
# name the DDX reports, which xf86-video-armsoc hardcodes to "armsoc", so it
# asks libdril_dri.so for __driDriverGetExtensions_armsoc. Mesa 25's stub
# exports one entry point per driver name it was built for and "armsoc" is
# not one of them, so the target of the symlink is irrelevant.
#
# The real bug is that 21.1.16's AIGLX probe NULL-derefs on every failure
# path instead of falling back to software GLX the way bookworm's 21.1.7
# does. So we stop the probe running at all — see fix 4 below.
#
# Remove any symlink an earlier run of this script created: it does nothing,
# and leaving it makes the Xorg log harder to read.

if [[ -L $DRIDIR/armsoc_dri.so || -e $DRIDIR/armsoc_dri.so ]]; then
    rm -f "$DRIDIR/armsoc_dri.so"
    ok "fix1: removed the ineffective armsoc_dri.so (superseded by fix 4)"
else
    ok "fix1: no armsoc_dri.so present, nothing to remove"
fi

########################################################################
# Fix 4 — disable the GLX extension so Xorg never runs the AIGLX probe
########################################################################
# Costs desktop GLX, which was always software rendered here anyway. Leaves
# DRI3 and Present alone, so GLES2 through the SGX blob is unaffected.

XCONFD=$ROOT/etc/X11/xorg.conf.d
GLXCONF=$XCONFD/20-pyra-glx.conf
if [[ ! -d $XCONFD ]]; then
    warn "fix4: $XCONFD does not exist — creating it"
    mkdir -p "$XCONFD"
fi
if [[ -f $GLXCONF ]] && grep -qi 'Option[[:space:]]*"GLX"[[:space:]]*"Disable"' "$GLXCONF"; then
    ok "fix4: GLX already disabled in ${GLXCONF#$ROOT}"
else
    cat > "$GLXCONF" <<'EOF'
# Xorg 21.1.16 segfaults in its AIGLX DRI2 probe on this hardware: the armsoc
# DDX asks for a DRI driver mesa 25 does not provide, and the server's error
# path NULL-derefs instead of falling back to software GLX. Disabling the GLX
# extension stops the probe running. DRI3 and Present are unaffected, so the
# SGX blob's GLES2 path still works. Revert when Xorg fixes the fallback.
Section "Extensions"
    Option "GLX" "Disable"
EndSection
EOF
    chmod 0644 "$GLXCONF"
    ok "fix4: wrote ${GLXCONF#$ROOT}"
fi

# lightdm warns on every start if this is missing. Cosmetic, but noisy.
LDMDATA=$ROOT/var/lib/lightdm/data
if [[ -d $LDMDATA ]]; then
    ok "fix4: ${LDMDATA#$ROOT} already exists"
else
    mkdir -p "$LDMDATA"
    # uid/gid resolved against the target rootfs, not the host
    LDMUID=$(awk -F: '$1=="lightdm"{print $3}' "$ROOT/etc/passwd" 2>/dev/null || true)
    LDMGID=$(awk -F: '$1=="lightdm"{print $3}' "$ROOT/etc/group" 2>/dev/null || true)
    if [[ -n ${LDMUID:-} && -n ${LDMGID:-} ]]; then
        # Non-fatal: this is cosmetic, and must not abort before fixes 2 and 3.
        if chown "$LDMUID:$LDMGID" "$LDMDATA" && chmod 0750 "$LDMDATA"; then
            ok "fix4: created ${LDMDATA#$ROOT} owned by lightdm ($LDMUID:$LDMGID)"
        else
            warn "fix4: created ${LDMDATA#$ROOT} but could not set ownership"
        fi
    else
        warn "fix4: created ${LDMDATA#$ROOT} but no lightdm user in the image; left root-owned"
    fi
fi

########################################################################
# Fix 2 — pyra-first-run.sh powers the unit off
########################################################################
# It shows a zenity question whose cancel button is "Shutdown". In the bare
# xinit session the dialog gets no usable input, the script takes the cancel
# branch and calls poweroff. Mark it done, and create the user it would have.

# Verify the marker path rather than trusting the forum post.
FIRSTRUN=$(grep -rls 'first-run' "$ROOT/usr/bin" "$ROOT/usr/local/bin" "$ROOT/etc" \
             "$ROOT/usr/share/pyra" "$ROOT/usr/lib/systemd/system" 2>/dev/null | head -5 || true)
MARKER=""
if [[ -n $FIRSTRUN ]]; then
    info "fix2: first-run scripts found:"; sed "s|^$ROOT|  |" <<<"$FIRSTRUN"
    MARKER=$(grep -rhoE '/var/lib/pyra/[A-Za-z0-9._-]+' $FIRSTRUN 2>/dev/null | sort -u | head -1 || true)
    [[ -n $MARKER ]] && info "fix2: marker referenced by the script: $MARKER"
fi
if [[ -z $MARKER ]]; then
    MARKER=/var/lib/pyra/first-run.done
    warn "fix2: could not confirm the marker path from the image; using documented default $MARKER"
    warn "      if the wizard still runs, grep the real script for its guard condition"
fi
install -d -m 0755 "$ROOT$(dirname "$MARKER")"
: > "$ROOT$MARKER"
ok "fix2: touched $MARKER"

# --- create the user offline ------------------------------------------------
if grep -q "^${USERNAME}:" "$ROOT/etc/passwd"; then
    ok "fix2: user '$USERNAME' already exists"
else
    # Prefer shadow-utils' --root: it writes passwd/shadow/group/gshadow
    # consistently, honours the target's login.defs, and won't corrupt the
    # files the way appending lines by hand can.
    if command -v useradd >/dev/null && useradd --help 2>&1 | grep -q -- --root; then
        useradd --root "$ROOT" -m -s /bin/bash -c "" "$USERNAME"
        ok "fix2: created '$USERNAME' via useradd --root"
    else
        die "fix2: no useradd with --root support on this host; install shadow-utils"
    fi

    printf 'Password for %s (input hidden): ' "$USERNAME" >&2
    read -rs PW1; echo >&2
    printf 'Repeat: ' >&2
    read -rs PW2; echo >&2
    [[ $PW1 == "$PW2" && -n $PW1 ]] || die "fix2: passwords empty or did not match; user has NO password set"
    HASH=$(printf '%s' "$PW1" | openssl passwd -6 -stdin)
    unset PW1 PW2
    # chpasswd -e -R writes the hash without it ever hitting the process table.
    printf '%s:%s\n' "$USERNAME" "$HASH" | chpasswd -e -R "$ROOT"
    unset HASH
    ok "fix2: password set for '$USERNAME'"
fi

# --- group membership -------------------------------------------------------
ADDED=(); SKIPPED=()
for g in $GROUPS_WANTED; do
    if grep -q "^${g}:" "$ROOT/etc/group"; then
        if grep "^${g}:" "$ROOT/etc/group" | cut -d: -f4 | tr ',' '\n' | grep -qx "$USERNAME"; then
            continue
        fi
        usermod --root "$ROOT" -aG "$g" "$USERNAME"
        ADDED+=("$g")
    else
        SKIPPED+=("$g")
    fi
done
[[ ${#ADDED[@]}   -gt 0 ]] && ok   "fix2: added to groups: ${ADDED[*]}"
[[ ${#SKIPPED[@]} -gt 0 ]] && info "fix2: groups absent from image, skipped: ${SKIPPED[*]}"
info "fix2: $USERNAME now in: $(grep -E "^[^:]+:[^:]*:[^:]*:.*\b${USERNAME}\b" "$ROOT/etc/group" | cut -d: -f1 | tr '\n' ' ')"

########################################################################
# Fix 3 — funkeymonkey-pyrainput 0.1.19 (trixie) ships no systemd unit
########################################################################
# Packaging bug: the identical version in the bookworm repo has it. Without
# it the nubs (and the pyraInput keyboard/gamepad/mouse nodes) never appear.

UNIT=$ROOT/lib/systemd/system/pyrainput.service
[[ -d $ROOT/lib/systemd/system ]] || UNIT=$ROOT/usr/lib/systemd/system/pyrainput.service
[[ -d $(dirname "$UNIT") ]] || die "fix3: no systemd unit directory under $ROOT"

for f in /usr/sbin/funkeymonkey /usr/lib/funkeymonkey/libpyrainput.so; do
    [[ -e $ROOT$f ]] || warn "fix3: $f missing in the image — unit will fail until it exists"
done

# No package in the bookworm or trixie repo ships /etc/pyrainput.cfg, but
# libpyrainput logs "Could not open config file" without it and the unit is
# Restart=on-failure. An empty file is exactly what pyrainputctl creates on
# first use, and leaves the module on its built-in defaults.
if [[ -e $ROOT/etc/pyrainput.cfg ]]; then
    ok "fix3: /etc/pyrainput.cfg already present"
else
    : > "$ROOT/etc/pyrainput.cfg"
    chmod 0644 "$ROOT/etc/pyrainput.cfg"
    ok "fix3: created empty /etc/pyrainput.cfg"
fi

if [[ -e $UNIT ]]; then
    ok "fix3: $(sed "s|^$ROOT||" <<<"$UNIT") already present"
else
    cat > "$UNIT" <<'EOF'
[Unit]
Description=Pyra Input Deamon (funkeymonkey)
After=network.target
Documentation=https://dev.pyra-handheld.com/packages/funkeymonkey-pyrainput

[Service]
ExecStart=/usr/sbin/funkeymonkey -g -p /usr/lib/funkeymonkey/libpyrainput.so -r 0,1,2,3 -m nub0 -m nub1  -m "tca8418" -m "pyra-game-buttons" -X config=/etc/pyrainput.cfg
ExecReload=/bin/kill -USR1 $MAINPID
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
Alias=pyrainput.service
EOF
    chmod 0644 "$UNIT"
    ok "fix3: wrote $(sed "s|^$ROOT||" <<<"$UNIT")"
fi

# Enable it offline so you don't need a working session to do it by hand.
WANTS=$ROOT/etc/systemd/system/multi-user.target.wants
install -d -m 0755 "$WANTS"
if [[ -L $WANTS/pyrainput.service ]]; then
    ok "fix3: already enabled in multi-user.target"
else
    ln -s "$(sed "s|^$ROOT||" <<<"$UNIT")" "$WANTS/pyrainput.service"
    ok "fix3: enabled in multi-user.target"
fi

########################################################################
# Fix 5 — USB is dead after a warm reboot
########################################################################
# The on-board USB3503 hub is reset over i2c when its driver probes. After a
# warm reboot the reset GPIO is still deasserted from the previous boot, so
# the sequence is a no-op, the hub never connects, and everything behind it
# disappears — including the USB ethernet adapter, which is probably how you
# were talking to the machine. The EHCI controller and root hub come up
# normally, so it presents as dead hardware rather than an unreset hub.
#
# Rebinding the driver re-runs the reset from a known state. The rescue script
# checks the USB bus for the hub first, so on a cold boot it does nothing.
# This is a workaround: the real fix belongs in the driver or the device tree.

USB3503_DST=$ROOT/usr/local/sbin/pyra-usb3503-rescue
USB3503_UNIT=$ROOT/etc/systemd/system/pyra-usb3503-rescue.service

# Create only if absent: this image has /usr/local/sbin as 0755 root:root, but
# a Debian default of 2775 root:staff must not be silently re-moded.
[[ -d $ROOT/usr/local/sbin ]] || install -d -m 0755 "$ROOT/usr/local/sbin"
if [[ -e $USB3503_DST ]] && cmp -s "$USB3503_SRC" "$USB3503_DST"; then
    ok "fix5: ${USB3503_DST#$ROOT} already up to date"
else
    VERB=$([[ -e $USB3503_DST ]] && echo updated || echo installed)
    install -m 0755 -o 0 -g 0 "$USB3503_SRC" "$USB3503_DST"
    ok "fix5: $VERB ${USB3503_DST#$ROOT}"
fi

[[ -d $ROOT/etc/systemd/system ]] || install -d -m 0755 "$ROOT/etc/systemd/system"
if [[ -e $USB3503_UNIT ]] && cmp -s "$USB3503_UNIT_SRC" "$USB3503_UNIT"; then
    ok "fix5: ${USB3503_UNIT#$ROOT} already up to date"
else
    VERB=$([[ -e $USB3503_UNIT ]] && echo updated || echo installed)
    install -m 0644 -o 0 -g 0 "$USB3503_UNIT_SRC" "$USB3503_UNIT"
    ok "fix5: $VERB ${USB3503_UNIT#$ROOT}"
fi

# Enable it offline. The unit carries ConditionPathExists on the usb3503
# driver, so it is inert on anything that is not a Pyra. $WANTS was created by
# fix 3 above; set -u catches it if that ever stops being true.
if [[ -L $WANTS/pyra-usb3503-rescue.service ]]; then
    ok "fix5: already enabled in multi-user.target"
else
    ln -sf /etc/systemd/system/pyra-usb3503-rescue.service \
           "$WANTS/pyra-usb3503-rescue.service"
    ok "fix5: enabled in multi-user.target"
fi

########################################################################
# Fix 6 — the thermal daemon has never capped a frequency
########################################################################
# /usr/share/pyra/scripts/pyra-thermal.sh reads both temperature sensors every
# 20 seconds, decides a maximum CPU frequency, and applies it by calling
# cpufreq-set. That program is not installed and cannot be: it came from
# cpufrequtils, which is not in trixie and has no candidate version. So the
# call has failed on every cycle since the image's first boot, logging a line
# nobody reads, while the charging limit on the next line — a plain
# redirection, with no set -e to stop in between — has worked all along. The
# daemon has been managing the charger correctly and the CPU not at all.
#
# That leaves the kernel's step_wise governor as the only thing limiting
# frequency for heat, and on its own it is not enough: two cores of `7z b`
# take the machine seven degrees past its 100 C passive trip in under two
# minutes. With this fix the same load peaks at 84 C and the cap visibly moves.
#
# The replacement is a write to scaling_max_freq, which is all cpufreq-set -u
# ever did and needs nothing installed. The vendor's thermal ladder is left
# exactly as it is: the ladder is the vendor's policy, and only this one line
# was broken.
#
# This edits a file shipped by a package, in a location that is not a conffile,
# so a later upgrade of the Pyra scripts will silently revert it. On the device
# `pyra-thermal-fix.sh --check` says whether that has happened.

THERMAL_DST=$ROOT/usr/share/pyra/scripts/pyra-thermal.sh
[[ -f $THERMAL_DST ]] || die "fix6: no ${THERMAL_DST#$ROOT} on this card — is this a Pyra image?"

# --emit-patched writes the fixed form to stdout and changes nothing. An input
# that is already fixed comes back unchanged, so comparing decides whether
# there is anything to write and makes a re-run a no-op.
THERMAL_TMP=$(mktemp)
if ! "$THERMAL_FIX" --emit-patched "$THERMAL_DST" > "$THERMAL_TMP" 2>/dev/null; then
    rm -f "$THERMAL_TMP"
    die "fix6: ${THERMAL_DST#$ROOT} has no 'cpufreq-set -u' line to replace.
       Refusing to guess at a thermal daemon this was not written for."
fi

# Never leave a thermal daemon on the card that does not parse.
if ! bash -n "$THERMAL_TMP" 2>/dev/null; then
    rm -f "$THERMAL_TMP"
    die "fix6: the patched thermal daemon is not valid shell; nothing written"
fi

if cmp -s "$THERMAL_TMP" "$THERMAL_DST"; then
    ok "fix6: ${THERMAL_DST#$ROOT} already applies its frequency cap"
else
    # Keep the vendor's file alongside, once, so the card carries its own undo.
    [[ -e $THERMAL_DST.before-pyra-thermal-fix ]] \
        || cp -a "$THERMAL_DST" "$THERMAL_DST.before-pyra-thermal-fix"
    cat "$THERMAL_TMP" > "$THERMAL_DST"   # keep the vendor file's mode and owner
    ok "fix6: ${THERMAL_DST#$ROOT} now writes scaling_max_freq instead of calling cpufreq-set"
fi
rm -f "$THERMAL_TMP"

echo
sync
ok "done — unmount cleanly, then hold the power button until BOTH LEDs go green."
