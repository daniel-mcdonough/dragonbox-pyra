#!/usr/bin/env bash
# Apply the three known fixes to a freshly-written Debian 13 (trixie) Pyra SD card.
# Run against the MOUNTED rootfs partition, before the card's first boot.
#
#   sudo ./pyra-trixie-prep.sh /mnt [username]
#
# Idempotent: safe to re-run. Verifies its assumptions against the image
# instead of trusting them blindly.

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

echo

########################################################################
# Fix 1 — Xorg 21.1.16 segfaults when AIGLX fails to dlopen armsoc_dri.so
########################################################################
# Xorg 21.1.7 (bookworm) logs the failure and carries on; somewhere before
# 21.1.16 that path picked up a NULL deref. Give AIGLX *any* loadable DRI
# driver so it never reaches the broken branch. GLX then runs on swrast,
# which is what bookworm was silently doing all along — the SGX hardware
# path is GLES2 via the blob's EGL + libpvrDRI3WSEGL and is untouched.

if [[ -e $DRIDIR/armsoc_dri.so ]]; then
    ok "fix1: armsoc_dri.so already present ($(readlink -f "$DRIDIR/armsoc_dri.so" | sed "s|^$ROOT||"))"
else
    # Don't hardcode kms_swrast_dri.so — mesa has been shuffling these around.
    TARGET=""
    for cand in kms_swrast_dri.so swrast_dri.so; do
        [[ -e $DRIDIR/$cand ]] && { TARGET=$cand; break; }
    done
    if [[ -z $TARGET ]]; then
        TARGET=$(cd "$DRIDIR" && ls -1 ./*_dri.so 2>/dev/null | head -1 | sed 's|^\./||') || true
        [[ -n $TARGET ]] && warn "fix1: no swrast driver; falling back to $TARGET"
    fi
    [[ -n $TARGET ]] || die "fix1: no *_dri.so found in $DRIDIR — cannot create the symlink"
    ln -s "$TARGET" "$DRIDIR/armsoc_dri.so"
    ok "fix1: armsoc_dri.so -> $TARGET"
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

echo
sync
ok "done — unmount cleanly, then hold the power button until BOTH LEDs go green."
