#!/usr/bin/env bash
# Apply the twelve known fixes to a freshly-written Debian 13 (trixie) Pyra SD card.
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

# Fix 7 transforms the same file, immediately after fix 6 and through the same
# --emit-patched door, for the same reason: one implementation of the change.
LADDER_FIX=$PAYLOADS/pyra-thermal-ladder.sh
[[ -x $LADDER_FIX ]] || die "fix7: pyra-thermal-ladder.sh not found or not executable (looked in $PAYLOADS)"

# Fix 8 does not transform anything: it writes three new files. It goes through
# the same kind of door for the same reason — one implementation, two callers.
CHARGE_FIX=$PAYLOADS/pyra-charge-current.sh
[[ -x $CHARGE_FIX ]] || die "fix8: pyra-charge-current.sh not found or not executable (looked in $PAYLOADS)"

AUDIO_FIX=$PAYLOADS/pyra-audio-route.sh
[[ -x $AUDIO_FIX ]] || die "fix9: pyra-audio-route.sh not found or not executable (looked in $PAYLOADS)"

GREETER_FIX=$PAYLOADS/pyra-greeter-audio.sh
[[ -x $GREETER_FIX ]] || die "fix10: pyra-greeter-audio.sh not found or not executable (looked in $PAYLOADS)"

SGX_FIX=$PAYLOADS/pyra-sgx-init.sh
[[ -x $SGX_FIX ]] || die "fix11: pyra-sgx-init.sh not found or not executable (looked in $PAYLOADS)"

WHEEL_FIX=$PAYLOADS/pyra-volumed/install.sh
[[ -x $WHEEL_FIX ]] || die "fix12: pyra-volumed/install.sh not found or not executable (looked in $PAYLOADS)"


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

########################################################################
# Fix 7 — the thermal ladder itself
########################################################################
# Fix 6 made the daemon able to apply a decision. This one is about the
# decision, and about when it makes it. Five faults, none of them observable
# before fix 6, because until then nothing was applied:
#
#   The sensor the daemon calls the battery is bq27421-0, the fuel gauge,
#   reporting its own die temperature — the board it is soldered to, not the
#   cell. Its ladder starts capping at 44 C, which one core of ordinary work
#   reaches in half a minute, while the sensor that IS watching the SoC gives
#   up nothing below 77 C. Measured on a V5.3: the gauge rose 2.0 C within ten
#   seconds of one core being loaded, the ceiling fell to 1250 MHz with the
#   core at 70.6 C, and the core never reached its own first rung at all.
#
#   Neither ladder had hysteresis. Same run: the ceiling changed twelve times,
#   six of them oscillating between 1250 and 1000 MHz inside 116 seconds while
#   the gauge sat between 44.8 and 45.5 C.
#
#   setMaxFreq compares against the constant maxFreq rather than against the
#   cap already chosen, so the ladder that runs last wins whether or not it is
#   the more restrictive. The battery ladder runs last. With the core at 98 C,
#   asking for 250 MHz, and the board at an ordinary 44.5 C, asking for 1250,
#   the daemon picks 1250. That one is a loss of thermal protection and is
#   why this is here rather than left as a tuning preference: a card without
#   it is throttled when it should not be and unprotected when it should be.
#
#   The poll is every 20 seconds, and two cores flat out take this machine
#   from a 63 C idle to its 100 C passive trip in SIXTEEN. The daemon's next
#   look arrives after the trip rather than before it.
#
#   It reads core_thermal, but the passive trip is on cpu_thermal, and during
#   a fast ramp cpu_thermal leads it by up to 12 C. Even an instantaneous
#   daemon on core_thermal would first act with cpu_thermal already at 91 C.
#
# The last two only matter once the first is fixed, and that is the single
# most important thing about this fix. The broken ladder left the machine
# PERMANENTLY PRE-CAPPED — measured at 750 MHz, where two cores flat out peak
# at a harmless 74 C — so the daemon never needed to be quick. Correcting the
# ladder alone, with the poll and the sensor left as they were, measured 102 C
# on two cores with the ceiling never moving once: worse than the code it
# replaced. All of it together measures 87 C with the load running to
# completion. Do not split this fix up.
#
# The charging thresholds and currents are NOT touched.

if ! "$LADDER_FIX" --emit-patched "$THERMAL_DST" > "$THERMAL_TMP" 2>/dev/null; then
    rm -f "$THERMAL_TMP"
    die "fix7: the ladder in ${THERMAL_DST#$ROOT} is not the one this was written
       for. Refusing to guess at a thermal daemon this was not written for."
fi

if ! bash -n "$THERMAL_TMP" 2>/dev/null; then
    rm -f "$THERMAL_TMP"
    die "fix7: the patched thermal daemon is not valid shell; nothing written"
fi

if cmp -s "$THERMAL_TMP" "$THERMAL_DST"; then
    ok "fix7: ${THERMAL_DST#$ROOT} already has the corrected ladder"
else
    # A second backup, under its own name, so the two fixes undo independently
    # and in the order they were applied.
    [[ -e $THERMAL_DST.before-pyra-thermal-ladder ]] \
        || cp -a "$THERMAL_DST" "$THERMAL_DST.before-pyra-thermal-ladder"
    cat "$THERMAL_TMP" > "$THERMAL_DST"   # keep the vendor file's mode and owner
    ok "fix7: ${THERMAL_DST#$ROOT} no longer throttles on the fuel gauge, and takes the lower of its two ladders"
fi
rm -f "$THERMAL_TMP"

########################################################################
# Fix 8 — the machine cannot charge while it runs
########################################################################
# A Pyra plugged into a charger loses charge. The bq24297's input current
# limit is never set by anything, so it stays at the 500 mA USB floor the chip
# powers up with. This machine draws about 620 mA at idle, so the battery
# covers the difference and drains with the cable in. Measured: -617 mA out of
# the battery at online=1 with power-good set, down to 21% before anyone
# looked at the right register. One write to max_current, and it charges at
# +476 mA mean over 899 seconds on the same supply and the same cable.
#
# Three things were supposed to set that limit and none of them do.
#
#   /lib/udev/rules.d/charging.rules names twl4030 in every rule that works —
#   the OMAP3/GTA04 charger, not the bq24297 this board has. The rules for the
#   right chip sit beneath them under the vendor's own comment, "this is
#   preparation for the Pyra but neither tested nor complete nor working".
#
#   Because those rules never ran, /dev/usb_max_current is not the symlink
#   they were meant to create. It is an ordinary file, made by the first thing
#   to write it as root — the thermal daemon, which puts its charge-current
#   decision there every poll. Nothing reads it. That half of the daemon has
#   never had an effect on any image.
#
#   The driver parses usb_input_current and adp_input_current out of the
#   device tree at probe and does not apply either.
#
# This writes a rule in /etc/udev/rules.d, and a charging.rules there that
# masks the stock one of the same name in /lib without editing it. Unlike
# fixes 6 and 7 it edits no packaged file, so an upgrade will not silently
# revert it.
#
# It asserts a current rather than detecting one, because nothing here can:
# real BC1.2 detection means driving FORCE_DPDM in the charger's REG07 and
# belongs in the driver. The hardware backstop is VINDPM at 4.36 V. The
# default is 2000000, which is what this board's device tree already calls
# adp_input_current.
#
# It deliberately keeps the thermal daemon's charge ladder away from the
# working knob. That ladder reads the fuel gauge's die and caps at 500 mA
# above 44 C, and a Pyra idles with that sensor at 46-47 C. The stock rules'
# symlink is what would connect them, and it is a boot-order race: on
# 2026-10-22 the rule won, and the ladder flapped the limit between 1, 2 and
# 3 A while charging. The mask is what stops that. The pack is protected by
# the charger's TS pin, in hardware, either way.

# Emit into a staging root first and install only what differs, so a second
# run of this script writes nothing at all rather than rewriting four
# identical files with new timestamps.
CHARGE_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pyra-fix8.XXXXXX")
if ! CHARGE_FILES=$("$CHARGE_FIX" --emit-into "$CHARGE_STAGE" 2>&1); then
    rm -rf "$CHARGE_STAGE"
    die "fix8: could not generate the charge-current files:
       $CHARGE_FILES"
fi

# The helper runs under /bin/sh on the device. Check it parses as one here,
# before it goes on the card, rather than at the first plug event.
if ! sh -n "$CHARGE_STAGE/usr/local/sbin/pyra-charge-current-apply" 2>/dev/null; then
    rm -rf "$CHARGE_STAGE"
    die "fix8: the generated charge helper is not valid shell; nothing written"
fi

CHARGE_CHANGED=0
while read -r staged; do
    [[ -n $staged ]] || continue
    rel=${staged#$CHARGE_STAGE}
    dst=$ROOT$rel
    if [[ -e $dst ]] && cmp -s "$staged" "$dst"; then
        ok "fix8: ${rel} already in place"
        continue
    fi
    mkdir -p "$(dirname "$dst")"
    cat "$staged" > "$dst"
    chmod --reference="$staged" "$dst"
    ok "fix8: wrote ${rel}"
    CHARGE_CHANGED=1
done <<<"$CHARGE_FILES"
rm -rf "$CHARGE_STAGE"

if [[ $CHARGE_CHANGED -eq 1 ]]; then
    ok "fix8: the card will charge while running instead of draining on the cable"
fi

# ----------------------------------------------------------------------- fix 9
#
# The machine has no sound and never has. Nothing is broken: the TWL6040's four
# output routing controls ship reading Off, and Headset Playback Volume ships
# at its 0,0 floor, so the DACs are not connected to the amplifiers.
#
#   Handsfree Left/Right Playback   Off   -> speakers
#   Headset   Left/Right Playback   Off   -> headphones
#   Headset Playback Volume         0,0
#
# Everything upstream is healthy and always was — the card enumerates, the PCM
# reaches RUNNING with a moving hw_ptr, pactl shows three unmuted sinks at
# 0.00 dB. The samples were arriving on time at a disconnected DAC.
#
# The source is /var/lib/alsa/asound.state, which shipped holding that silence
# and is replayed on every boot. There is no UCM profile for this card to
# override it, and alsa-state.service is inactive, so nothing ever re-captured
# it; one bad snapshot has survived every boot since the image was built.
#
# This installs a udev rule numbered 95-, above the stock 90-alsa-restore, so
# it has the last word over that state file rather than depending on it.
#
# It sets the four routes but deliberately does NOT set Handsfree Playback
# Volume: that control belongs to pyra_volumed, which reads the encoder wheel
# on palmas-gpadc and writes Handsfree only. It sets a volume and never sets a
# route, which is why the wheel appeared dead — it was moving the speaker level
# behind a switched-off amplifier. Headset Playback Volume has no daemon behind
# it (the wheel does not reach the headphones at all) and is lifted only when
# found at zero, so a value the user chose survives.

AUDIO_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pyra-fix9.XXXXXX")
if ! AUDIO_FILES=$("$AUDIO_FIX" --emit-into "$AUDIO_STAGE" 2>&1); then
    rm -rf "$AUDIO_STAGE"
    die "fix9: could not generate the audio routing files:
       $AUDIO_FILES"
fi

# The helper runs under /bin/sh on the device, from udev. Check it parses as
# one here, before it goes on the card.
if ! sh -n "$AUDIO_STAGE/usr/local/sbin/pyra-audio-route-apply" 2>/dev/null; then
    rm -rf "$AUDIO_STAGE"
    die "fix9: the generated audio helper is not valid shell; nothing written"
fi

AUDIO_CHANGED=0
while read -r staged; do
    [[ -n $staged ]] || continue
    rel=${staged#$AUDIO_STAGE}
    dst=$ROOT$rel
    if [[ -e $dst ]] && cmp -s "$staged" "$dst"; then
        ok "fix9: ${rel} already in place"
        continue
    fi
    mkdir -p "$(dirname "$dst")"
    cat "$staged" > "$dst"
    chmod --reference="$staged" "$dst"
    ok "fix9: wrote ${rel}"
    AUDIO_CHANGED=1
done <<<"$AUDIO_FILES"
rm -rf "$AUDIO_STAGE"

if [[ $AUDIO_CHANGED -eq 1 ]]; then
    ok "fix9: the card will have sound on speakers and headphones from first boot"
fi

# ---------------------------------------------------------------------- fix 10
#
# On some boots the desktop comes up silent even with fix 9 applied, and stays
# silent for the whole session. Measured on the hardware it hit 2 of the 6
# boots on record:
#
#   15:59:38  card (L15) registers
#   15:59:45  user@105 — the lightdm greeter — starts
#   15:59:52  greeter pulseaudio STARTED, holding hw:CARD=L15
#   15:59:59  user@1000 starts
#   16:00:00  session pulseaudio FAILS: device busy
#   16:00:14  greeter pulseaudio stops — fourteen seconds too late
#
# The greeter runs a PulseAudio of its own, and pyra.pa opens the codec as a
# raw ALSA device with module-alsa-sink, which is an exclusive open. Whichever
# instance arrives first owns the card. When the greeter wins, the session
# daemon fails to load the sink, both remap sinks fail behind it, and the
# session is left on the silent auto_null fallback. PulseAudio never retries.
#
# The card cannot be shared instead: module-udev-detect would arbitrate it
# properly but cannot give the 4-channel open the Speakers/Headphones split
# depends on. So the second claimant is removed rather than taught to share.
# A login greeter on a handheld has no use for audio; the only usual consumer
# is an accessibility reader at the login prompt, which this image does not
# run. pyra-greeter-audio.sh --undo puts it back.
#
# ConditionUser=!lightdm is evaluated by each user's own systemd instance
# against the user it runs as, so one file in /etc/systemd/user skips the unit
# for the greeter and leaves every other user alone. It shadows the packaged
# unit in /usr/lib rather than editing it, so an upgrade will not revert it.

GREETER_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pyra-fix10.XXXXXX")
if ! GREETER_FILES=$("$GREETER_FIX" --emit-into "$GREETER_STAGE" 2>&1); then
    rm -rf "$GREETER_STAGE"
    die "fix10: could not generate the greeter drop-ins:
       $GREETER_FILES"
fi

GREETER_CHANGED=0
while read -r staged; do
    [[ -n $staged ]] || continue
    rel=${staged#$GREETER_STAGE}
    dst=$ROOT$rel
    if [[ -e $dst ]] && cmp -s "$staged" "$dst"; then
        ok "fix10: ${rel} already in place"
        continue
    fi
    mkdir -p "$(dirname "$dst")"
    cat "$staged" > "$dst"
    chmod --reference="$staged" "$dst"
    ok "fix10: wrote ${rel}"
    GREETER_CHANGED=1
done <<<"$GREETER_FILES"
rm -rf "$GREETER_STAGE"

if [[ $GREETER_CHANGED -eq 1 ]]; then
    ok "fix10: the greeter will not take the sound card from the session"
fi

# ---------------------------------------------------------------------- fix 11
#
# The DDK's udev rule runs `pvrsrvctl --start` on the pvrsrvkm *module* add
# event, which the kernel sends before the driver probes, so it races the
# creation of /dev/dri/card2. Measured: 4 of 10 loads came up with the SGX
# services initialised; the rest left every GL program failing with "Couldn't
# connect to services" until pvrsrvctl was run by hand. The fix starts them on
# the add event of the pvr DRM card instead, which comes after the services
# core is up, with the node already created. 20 of 20 loads, and the boot path,
# came up initialised. It shadows the DDK's rule by name from /etc/udev/rules.d
# rather than editing it.

SGX_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pyra-fix11.XXXXXX")
if ! SGX_FILES=$("$SGX_FIX" --emit-into "$SGX_STAGE" 2>&1); then
    rm -rf "$SGX_STAGE"
    die "fix11: could not generate the SGX init rule:
       $SGX_FILES"
fi

SGX_CHANGED=0
while read -r staged; do
    [[ -n $staged ]] || continue
    rel=${staged#$SGX_STAGE}
    dst=$ROOT$rel
    if [[ -e $dst ]] && cmp -s "$staged" "$dst"; then
        ok "fix11: ${rel} already in place"
        continue
    fi
    mkdir -p "$(dirname "$dst")"
    cat "$staged" > "$dst"
    chmod --reference="$staged" "$dst"
    ok "fix11: wrote ${rel}"
    SGX_CHANGED=1
done <<<"$SGX_FILES"
rm -rf "$SGX_STAGE"

if [[ $SGX_CHANGED -eq 1 ]]; then
    ok "fix11: GL will find the SGX services up on every boot, not about half of them"
fi

# ---------------------------------------------------------------------- fix 12
#
# The volume wheel is a tapered pot, and pyra-hacks' pyra_volumed reads it as
# a linear one into a control that is already in dB, so the lower half of the
# wheel is silent and the rest is too steep. This installs a replacement that
# maps the wheel through its measured taper. It is C, and this script builds
# nothing, so it goes on the card as source: on its first start the unit's
# runner compiles it with the image's own gcc (it needs only libc6-dev), and
# falls back to the packaged daemon if that fails. The package is untouched;
# a drop-in points its unit at the runner.

WHEEL_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pyra-fix12.XXXXXX")
if ! WHEEL_FILES=$("$WHEEL_FIX" --emit-into "$WHEEL_STAGE" 2>&1); then
    rm -rf "$WHEEL_STAGE"
    die "fix12: could not generate the volume-wheel files:
       $WHEEL_FILES"
fi
[[ -x $ROOT/usr/bin/cc || -x $ROOT/usr/bin/gcc ]] ||
    warn "fix12: no gcc on the card; the packaged pyra_volumed will run until it is installed"
[[ -r $ROOT/usr/include/sound/asound.h ]] ||
    warn "fix12: no <sound/asound.h> on the card (libc6-dev / linux-libc-dev); the build will fail and fall back"

WHEEL_CHANGED=0
while read -r staged; do
    [[ -n $staged ]] || continue
    rel=${staged#$WHEEL_STAGE}
    dst=$ROOT$rel
    if [[ -e $dst ]] && cmp -s "$staged" "$dst"; then
        ok "fix12: ${rel} already in place"
        continue
    fi
    mkdir -p "$(dirname "$dst")"
    cat "$staged" > "$dst"
    chmod --reference="$staged" "$dst"
    ok "fix12: wrote ${rel}"
    WHEEL_CHANGED=1
done <<<"$WHEEL_FILES"
rm -rf "$WHEEL_STAGE"

if [[ $WHEEL_CHANGED -eq 1 ]]; then
    ok "fix12: the volume wheel will be built on first boot and map evenly in dB"
fi

echo
sync
ok "done — unmount cleanly, then hold the power button until BOTH LEDs go green."
