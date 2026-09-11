#!/usr/bin/env bash
# pyra-devsetup.sh — the conveniences you want on a Pyra you are developing on:
# your SSH key installed, sudo without a password, and a desktop that comes up
# without a login prompt.
#
#   sudo ./pc/pyra-devsetup.sh /mnt                 card mounted on the PC
#   sudo ./pc/pyra-devsetup.sh /mnt --key ~/.ssh/id_ed25519.pub
#   sudo ./pc/pyra-devsetup.sh / --on-this-machine  running on the Pyra itself
#   sudo ./pc/pyra-devsetup.sh /mnt --undo          take it all back off
#
# **Prefer the offline mode.** Two of the three things here are what you need
# in order to get in at all, and a card that has just been rewritten has
# neither. Doing it with the card in a reader, before first boot, avoids
# needing the access it is meant to grant. That is not hypothetical: a reflash
# during this project cost network access to the device for exactly this
# reason.
#
# Idempotent. Re-running changes nothing that is already right, and re-running
# after adding a second key adds only the second key.
#
# WHAT THIS COSTS. Each of these trades a check for convenience, and they are
# reasonable on a development handheld on your own desk and unreasonable on
# anything else:
#
#   passwordless sudo  anything that reaches the account is root, including a
#                      program you ran by accident
#   autologin          anyone holding the device is one power button away from
#                      the desktop and the session keyring
#   authorised key     whoever holds the private key is in, without a password
#
# It does not touch password authentication, root login, or the firewall, so
# nothing here takes away a way in that you already had. `--undo` reverses the
# three things above; it deliberately leaves the SSH server running, because
# turning that off from here is how you lock yourself out.
#
set -euo pipefail

ROOT=""
USERNAME=pyra
KEYFILE=""
ALLOW_HOST_ROOT=0
DO_SUDO=1; DO_KEY=1; DO_AUTOLOGIN=1; DO_MDNS=1
UNDO=0; DRYRUN=0

die()  { printf '\e[31mERROR\e[0m  %s\n' "$*" >&2; exit 1; }
warn() { printf '\e[33mWARN\e[0m   %s\n' "$*" >&2; }
ok()   { printf '\e[32mOK\e[0m     %s\n' "$*"; }
info() { printf '\e[36mINFO\e[0m   %s\n' "$*"; }
act()  { if [[ $DRYRUN == 1 ]]; then printf '\e[35mWOULD\e[0m  %s\n' "$*"; return 1; fi; return 0; }

while [[ $# -gt 0 ]]; do
    case $1 in
    --user)            USERNAME=${2:?}; shift 2 ;;
    --key)             KEYFILE=${2:?}; shift 2 ;;
    --on-this-machine) ALLOW_HOST_ROOT=1; shift ;;
    --no-sudo)         DO_SUDO=0; shift ;;
    --no-key)          DO_KEY=0; shift ;;
    --no-autologin)    DO_AUTOLOGIN=0; shift ;;
    --no-mdns)         DO_MDNS=0; shift ;;
    --undo)            UNDO=1; shift ;;
    --dry-run)         DRYRUN=1; shift ;;
    -h|--help)         sed -n '2,37p' "$0" | sed 's/^# \?//'; exit 0 ;;
    -*)                die "unknown option: $1" ;;
    *)                 [[ -z $ROOT ]] || die "more than one rootfs given"; ROOT=$1; shift ;;
    esac
done

SUDOERS_REL=etc/sudoers.d/90-pyra-nopasswd
AUTOLOGIN_REL=etc/lightdm/lightdm.conf.d/99-autologin.conf
STAMP_REL=etc/pyra-devsetup.stamp

# ------------------------------------------------------------------ preflight
[[ -n $ROOT ]] || die "usage: $0 /path/to/mounted/rootfs [options].  --help for the rest."
[[ $EUID -eq 0 ]] || die "must run as root (it writes into $ROOT and chowns files)"
[[ -d $ROOT/etc && -d $ROOT/usr && -d $ROOT/home ]] || die "$ROOT does not look like a rootfs"

# Writing to the host's own root filesystem by mistake would be the worst
# possible outcome of a typo, so it takes a flag that says you meant it.
if [[ $(realpath "$ROOT") == "/" && $ALLOW_HOST_ROOT != 1 ]]; then
    die "that is this machine's root filesystem.
If you are running this ON the Pyra, say so: $0 / --on-this-machine"
fi
ON_DEVICE=0; [[ $(realpath "$ROOT") == "/" ]] && ON_DEVICE=1

if [[ -r $ROOT/etc/os-release ]]; then
    . <(grep -E '^(ID|VERSION_CODENAME)=' "$ROOT/etc/os-release")
    info "target: ${ID:-?} ${VERSION_CODENAME:-?}  at $ROOT"
    [[ ${VERSION_CODENAME:-} == trixie ]] || warn "codename is '${VERSION_CODENAME:-unknown}', not trixie — continuing anyway"
fi

# Resolve the account against the TARGET's passwd file, not this machine's.
# Offline, the names and numbers here have nothing to do with the host.
PWENT=$(awk -F: -v u="$USERNAME" '$1==u{print; exit}' "$ROOT/etc/passwd" 2>/dev/null || true)
[[ -n $PWENT ]] || die "no account '$USERNAME' in $ROOT/etc/passwd.
The prep script creates it; run that first, or pass --user with the right name."
UID_T=$(cut -d: -f3 <<<"$PWENT")
GID_T=$(cut -d: -f4 <<<"$PWENT")
HOME_T=$(cut -d: -f6 <<<"$PWENT")
[[ -n $HOME_T && $HOME_T != "/" ]] || die "account '$USERNAME' has an implausible home: '$HOME_T'"
info "account: $USERNAME uid=$UID_T gid=$GID_T home=$HOME_T"

# --------------------------------------------------------------------- undo
if [[ $UNDO == 1 ]]; then
    info "undoing the development setup"
    for rel in "$SUDOERS_REL" "$AUTOLOGIN_REL"; do
        if [[ -e $ROOT/$rel ]]; then
            act "remove /$rel" && { rm -f "$ROOT/$rel"; ok "removed /$rel"; }
        else
            ok "/$rel was not there"
        fi
    done
    AK=$ROOT$HOME_T/.ssh/authorized_keys
    if [[ -r $ROOT/$STAMP_REL && -r $AK ]]; then
        n=0
        while read -r body; do
            [[ -n $body ]] || continue
            if grep -qF " $body " <<<" $(awk '{print $2}' "$AK" | tr '\n' ' ') "; then
                act "remove one authorised key" || continue
                tmp=$(mktemp); awk -v b="$body" '$2!=b' "$AK" >"$tmp"
                cat "$tmp" >"$AK"; rm -f "$tmp"; n=$((n+1))
            fi
        done < <(sed -n 's/^key-added: //p' "$ROOT/$STAMP_REL")
        [[ $n == 0 ]] && ok "no keys of ours left to remove" || ok "removed $n authorised key(s) this script had added"
        [[ ! -s $AK ]] && warn "$HOME_T/.ssh/authorized_keys is now empty"
    else
        ok "no record of keys added, leaving authorized_keys alone"
    fi
    act "remove /$STAMP_REL" && rm -f "$ROOT/$STAMP_REL"
    echo
    info "left alone on purpose: the SSH server, and mDNS if it was enabled."
    info "Disabling the way in from the same script that granted it is how you"
    info "end up with a handheld you cannot reach. Do that by hand if you mean it."
    exit 0
fi

# Resolve and check the key BEFORE anything is written. A bad --key that is
# only noticed halfway through leaves a card with passwordless sudo and no way
# to log in, which is the worst of both.
if [[ $DO_KEY == 1 ]]; then
    if [[ -z $KEYFILE ]]; then
        # Under sudo the interesting keys belong to the person who typed it.
        caller_home=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
        mapfile -t cands < <(ls -1 "$caller_home"/.ssh/*.pub 2>/dev/null | grep -v -- '-cert.pub$' || true)
        case ${#cands[@]} in
        0) die "no public key found in $caller_home/.ssh — pass one with --key" ;;
        1) KEYFILE=${cands[0]} ;;
        *) # Prefer a modern one rather than asking, but say which.
           for pref in id_ed25519.pub id_ecdsa.pub id_rsa.pub; do
               [[ -r $caller_home/.ssh/$pref ]] && { KEYFILE=$caller_home/.ssh/$pref; break; }
           done
           [[ -n $KEYFILE ]] || die "several keys in $caller_home/.ssh and none of the usual names.
Pass the one you want with --key." ;;
        esac
    fi
    [[ -r $KEYFILE ]] || die "cannot read key file: $KEYFILE"
    read -r KTYPE KBODY _ <"$KEYFILE" || true
    [[ $KTYPE == ssh-* || $KTYPE == ecdsa-* || $KTYPE == sk-* ]] \
        || die "$KEYFILE does not look like an OpenSSH public key (first field: '${KTYPE:-empty}')"
    [[ -n $KBODY ]] || die "$KEYFILE has no key body"
    info "key: $KEYFILE ($KTYPE)"
fi

STAMP_TMP=$(mktemp)
{ echo "# Written by pyra-devsetup.sh. Delete this and you lose the record"
  echo "# of which authorised keys --undo may remove."
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "user: $USERNAME"
} >"$STAMP_TMP"
[[ -r $ROOT/$STAMP_REL ]] && sed -n 's/^key-added: /key-added: /p' "$ROOT/$STAMP_REL" >>"$STAMP_TMP"

# ------------------------------------------------------------ passwordless sudo
if [[ $DO_SUDO == 1 ]]; then
    want="$USERNAME ALL=(ALL) NOPASSWD: ALL"
    if [[ -r $ROOT/$SUDOERS_REL ]] && grep -qxF "$want" "$ROOT/$SUDOERS_REL"; then
        ok "sudo: /$SUDOERS_REL already grants $USERNAME NOPASSWD"
    elif act "write /$SUDOERS_REL granting $USERNAME NOPASSWD: ALL"; then
        tmp=$(mktemp)
        printf '# Development convenience. Remove with pyra-devsetup.sh --undo.\n%s\n' "$want" >"$tmp"
        # A malformed file here breaks sudo for every account at once, so check
        # it before it is in place rather than after.
        if command -v visudo >/dev/null && ! visudo -cqf "$tmp"; then
            rm -f "$tmp"; die "sudo: the rule I was about to write does not parse"
        fi
        install -D -m 0440 -o 0 -g 0 "$tmp" "$ROOT/$SUDOERS_REL"
        rm -f "$tmp"
        ok "sudo: $USERNAME may now sudo without a password"
    fi
else
    info "sudo: skipped"
fi

# ------------------------------------------------------------------- ssh key
if [[ $DO_KEY == 1 ]]; then
    AKDIR=$ROOT$HOME_T/.ssh
    AK=$AKDIR/authorized_keys
    if [[ -r $AK ]] && awk -v b="$KBODY" '$2==b{found=1} END{exit !found}' "$AK"; then
        ok "key: already authorised for $USERNAME"
    elif act "authorise this key for $USERNAME in $HOME_T/.ssh/authorized_keys"; then
        install -d -m 0700 -o "$UID_T" -g "$GID_T" "$AKDIR"
        # Append, never replace: this account may already trust other keys.
        [[ -e $AK ]] || : >"$AK"
        # A file that does not end in a newline would splice two keys together.
        [[ -s $AK && $(tail -c1 "$AK" | wc -l) == 0 ]] && echo >>"$AK"
        cat "$KEYFILE" >>"$AK"
        chown "$UID_T:$GID_T" "$AK"; chmod 0600 "$AK"
        ok "key: authorised for $USERNAME"
    fi
    echo "key-added: $KBODY" >>"$STAMP_TMP"

    # An authorised key is useless if nothing is listening.
    SSHUNIT=""
    for d in lib/systemd/system usr/lib/systemd/system etc/systemd/system; do
        [[ -e $ROOT/$d/ssh.service ]] && { SSHUNIT=/$d/ssh.service; break; }
    done
    if [[ -z $SSHUNIT ]]; then
        warn "ssh: no ssh.service found in $ROOT — install openssh-server on the device"
    elif [[ -L $ROOT/etc/systemd/system/multi-user.target.wants/ssh.service ]]; then
        ok "ssh: the server is already enabled at boot"
    elif act "enable ssh.service at boot"; then
        install -d -m 0755 "$ROOT/etc/systemd/system/multi-user.target.wants"
        ln -sf "$SSHUNIT" "$ROOT/etc/systemd/system/multi-user.target.wants/ssh.service"
        ok "ssh: enabled at boot"
    fi
else
    info "key: skipped"
fi

# ------------------------------------------------------------------ autologin
# The mechanism, and why it is a drop-in rather than an edit of the packaged
# file, is documented in docs/procedure.md section 7.
if [[ $DO_AUTOLOGIN == 1 ]]; then
    if [[ ! -d $ROOT/etc/lightdm ]]; then
        warn "autologin: no /etc/lightdm in $ROOT, skipping"
    else
        session=lightdm-xsession
        [[ -e $ROOT/usr/share/xsessions/$session.desktop ]] \
            || warn "autologin: no $session in /usr/share/xsessions, using it anyway"
        want=$(printf '[Seat:*]\nautologin-user=%s\nautologin-user-timeout=0\nautologin-session=%s\n' \
               "$USERNAME" "$session")
        if [[ -r $ROOT/$AUTOLOGIN_REL ]] && [[ $(cat "$ROOT/$AUTOLOGIN_REL") == "$want" ]]; then
            ok "autologin: already set for $USERNAME"
        elif act "write /$AUTOLOGIN_REL for $USERNAME"; then
            install -d -m 0755 "$ROOT/etc/lightdm/lightdm.conf.d"
            printf '%s\n' "$want" >"$ROOT/$AUTOLOGIN_REL"
            chmod 0644 "$ROOT/$AUTOLOGIN_REL"
            ok "autologin: $USERNAME will get the desktop with no prompt"
        fi
    fi
else
    info "autologin: skipped"
fi

# ----------------------------------------------------------------------- mdns
# Finding the device again after a reflash cost real time in this project. If
# avahi is already installed, turning it on means `<hostname>.local` works and
# you stop chasing DHCP leases.
if [[ $DO_MDNS == 1 ]]; then
    AVUNIT=""
    for d in lib/systemd/system usr/lib/systemd/system; do
        [[ -e $ROOT/$d/avahi-daemon.service ]] && { AVUNIT=/$d/avahi-daemon.service; break; }
    done
    HOSTN=$(tr -d '[:space:]' <"$ROOT/etc/hostname" 2>/dev/null || echo "")
    if [[ -z $AVUNIT ]]; then
        info "mdns: avahi is not installed, skipping (apt install avahi-daemon to get ${HOSTN:-pyra}.local)"
    elif [[ -L $ROOT/etc/systemd/system/multi-user.target.wants/avahi-daemon.service ]]; then
        ok "mdns: already enabled; the device answers to ${HOSTN:-?}.local"
    elif act "enable avahi-daemon at boot"; then
        install -d -m 0755 "$ROOT/etc/systemd/system/multi-user.target.wants"
        ln -sf "$AVUNIT" "$ROOT/etc/systemd/system/multi-user.target.wants/avahi-daemon.service"
        for d in lib/systemd/system usr/lib/systemd/system; do
            if [[ -e $ROOT/$d/avahi-daemon.socket ]]; then
                install -d -m 0755 "$ROOT/etc/systemd/system/sockets.target.wants"
                ln -sf "/$d/avahi-daemon.socket" "$ROOT/etc/systemd/system/sockets.target.wants/avahi-daemon.socket"
                break
            fi
        done
        ok "mdns: enabled; the device will answer to ${HOSTN:-?}.local"
    fi
else
    info "mdns: skipped"
fi

# ---------------------------------------------------------------------- stamp
# Re-running must not grow the file. Keep the header, then one line per
# distinct key, in the order they were first added.
if act "record what was done in /$STAMP_REL"; then
    dedup=$(mktemp)
    grep -v '^key-added: ' "$STAMP_TMP" >"$dedup"
    grep '^key-added: ' "$STAMP_TMP" | awk '!seen[$0]++' >>"$dedup"
    install -m 0644 -o 0 -g 0 "$dedup" "$ROOT/$STAMP_REL"
    rm -f "$dedup"
fi
rm -f "$STAMP_TMP"

# -------------------------------------------------------------------- summary
echo
if [[ $DRYRUN == 1 ]]; then
    info "dry run, nothing was changed."
    exit 0
fi
cat <<EOF
This machine is now set up for development, which means:

  $USERNAME can run any command as root without being asked for a password
  the desktop comes up without a login prompt
  whoever holds the private key for the authorised key can log in

Undo all three with:  $0 $ROOT --undo

EOF
if [[ $ON_DEVICE == 1 ]]; then
    cat <<'EOF'
Files are written but nothing has been restarted. To apply them now:

    sudo systemctl enable --now ssh
    sudo systemctl restart lightdm      # ends the current desktop session
EOF
else
    echo "Unmount the card and boot it."
fi
