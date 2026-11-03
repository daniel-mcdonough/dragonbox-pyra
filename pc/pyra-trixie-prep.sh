#!/usr/bin/env bash
# Apply the twenty-two known fixes to a freshly-written Debian 13 (trixie) Pyra SD card.
# Run against the MOUNTED rootfs partition, with the boot partition mounted at
# its /boot, before the card's first boot.
#
#   sudo mount /dev/sdX2 /mnt && sudo mount /dev/sdX1 /mnt/boot
#   sudo ./pyra-trixie-prep.sh [--kernel FILE | --no-kernel]
#                              [--backlight FILE | --no-backlight] [--set-password]
#                              [--ssh-key FILE.pub] [--grow-on-boot] [--release]
#                              /mnt [username]
#
# Fix 2 creates the user and asks for its password. A user the image already
# has keeps its password unless --set-password is given: the vendor image ships
# a 'pyra' account whose password is not documented. --ssh-key authorises that
# public key for the user. Both are off unless asked for.
#
# Fix 19 installs the shipped kernel, 5.6.19-m4-kbdled, and makes it what the
# card boots. With no option it offers to download the published release asset
# and checks it against the SHA-256 pinned below; --kernel FILE uses a tarball
# you already have (a download, or ./pc/pyra-crossbuild.sh kernel-m4-kbdled);
# --no-kernel leaves the card on the stock 5.6.19-pyradef.
#
# Fix 22 installs pyra-backlight (a brightness applet for the screen and the
# keyboard light, and pyra-idle-dim) with the image's own dpkg. With no option
# it downloads the published .deb and checks it against the SHA-256 pinned
# below. --backlight FILE
# uses a .deb you have (pyra-backlight's ./build-deb.sh makes one);
# --no-backlight leaves it out.
#
# --grow-on-boot adds pyra-grow-root to fix 14's initrds: on its first boot
# the card checks its capacity and grows the rootfs to fill itself, so no PC
# grow is needed. Off by default. docs/grow-rootfs.md.
#
# --release makes an image to share rather than a card of your own, and asks
# nothing. The user 'pyra' gets the password 'pyra', which must be changed at
# the first login. The ssh host keys, the machine-id, systemd's random seed and
# credential secret are removed, so no two cards share them; a unit makes the
# host keys on the first boot, before sshd starts. It refuses --set-password,
# --ssh-key, another username, an authorised ssh key on the image or a
# NOPASSWD sudo rule for all commands: start from the vendor image instead.
# (The vendor's own rule for pyrainputctl alone stays.) It masks
# systemd-firstboot, which the empty machine-id would otherwise start.
#
# Fixes 14, 19, 20 and 22 run the image's own tools in a chroot, so a PC that is not
# armhf needs qemu-user with binfmt registered.
#
# Idempotent: safe to re-run. Verifies its assumptions against the image
# instead of trusting them blindly.
#
# Fix 21 patches the SGX driver's /usr/lib/libpvrDRI3WSEGL.so (a double close
# that corrupts game saves) and refuses an image whose copy is not the known
# stock build, before anything is written. A dpkg hook (pyra-wsegl-guard)
# re-applies it after a package run puts the stock build back.
#
# Fixes 5 and 6 use files that live in device/ in the repository, so run this
# from a checkout rather than copying the script somewhere on its own.

set -euo pipefail

die()  { printf '\e[31mERROR\e[0m  %s\n' "$*" >&2; exit 1; }
warn() { printf '\e[33mWARN\e[0m   %s\n' "$*" >&2; }
ok()   { printf '\e[32mOK\e[0m     %s\n' "$*"; }
info() { printf '\e[36mINFO\e[0m   %s\n' "$*"; }

KERNEL_MODE=ask         # ask: offer the download; file: --kernel; none: --no-kernel
KERNEL_FILE=
BACKLIGHT_MODE=auto     # auto: the pinned download if there is one; file: --backlight; none: --no-backlight
BACKLIGHT_FILE=
SET_PASSWORD=no
SSH_KEY=
GROW_ON_BOOT=no
RELEASE=no
ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
    --kernel)    [[ $# -ge 2 ]] || die "--kernel needs a tarball"
                 KERNEL_MODE=file; KERNEL_FILE=$2; shift 2 ;;
    --kernel=*)  KERNEL_MODE=file; KERNEL_FILE=${1#--kernel=}; shift ;;
    --no-kernel) KERNEL_MODE=none; shift ;;
    --backlight) [[ $# -ge 2 ]] || die "--backlight needs a .deb"
                 BACKLIGHT_MODE=file; BACKLIGHT_FILE=$2; shift 2 ;;
    --backlight=*) BACKLIGHT_MODE=file; BACKLIGHT_FILE=${1#--backlight=}; shift ;;
    --no-backlight) BACKLIGHT_MODE=none; shift ;;
    --set-password) SET_PASSWORD=yes; shift ;;
    --ssh-key)   [[ $# -ge 2 ]] || die "--ssh-key needs a public key file"
                 SSH_KEY=$2; shift 2 ;;
    --ssh-key=*) SSH_KEY=${1#--ssh-key=}; shift ;;
    --grow-on-boot) GROW_ON_BOOT=yes; shift ;;
    --release)   RELEASE=yes; shift ;;
    -*)          die "unknown option: $1" ;;
    *)           ARGS+=("$1"); shift ;;
    esac
done
ROOT=${ARGS[0]:-}
USERNAME=${ARGS[1]:-pyra}
GROUPS_WANTED="sudo video audio netdev plugdev bluetooth dialout input render games cdrom floppy"

[[ -n $ROOT ]] || die "usage: $0 [--kernel FILE | --no-kernel] [--backlight FILE | --no-backlight] [--set-password] [--ssh-key FILE.pub] [--grow-on-boot] [--release] /path/to/mounted/rootfs [username]"
[[ $EUID -eq 0 ]] || die "must run as root (it writes into $ROOT and chowns files)"
[[ -d $ROOT/etc && -d $ROOT/usr && -d $ROOT/var ]] || die "$ROOT does not look like a rootfs"

# --ssh-key takes one public key, checked before anything is written. A private
# key is refused: it must never be copied onto a card.
SSH_KEY_LINE=
if [[ -n $SSH_KEY ]]; then
    [[ -r $SSH_KEY ]] || die "fix2: no key file at $SSH_KEY"
    grep -q 'PRIVATE KEY' "$SSH_KEY" && die "fix2: $SSH_KEY is a private key; pass the .pub file"
    [[ $(grep -cv '^[[:space:]]*$' "$SSH_KEY") -eq 1 ]] || die "fix2: $SSH_KEY must hold exactly one public key"
    # Type and key only: the comment is often user@host or an email address,
    # which has no business on a card.
    SSH_KEY_LINE=$(grep -v '^[[:space:]]*$' "$SSH_KEY" | awk '{print $1, $2}')
    [[ $SSH_KEY_LINE == ssh-*\ * || $SSH_KEY_LINE == ecdsa-*\ * || $SSH_KEY_LINE == sk-*\ * ]] ||
        die "fix2: $SSH_KEY does not start with a key type (ssh-ed25519, ssh-rsa, ...)"
    if command -v ssh-keygen >/dev/null; then
        ssh-keygen -l -f "$SSH_KEY" >/dev/null 2>&1 || die "fix2: $SSH_KEY is not a public key ssh-keygen can read"
    fi
fi

# Sanity: is this actually a Debian trixie armhf Pyra image, and not, say, your own /?
[[ $(realpath "$ROOT") != "/" ]] || die "refusing to operate on the host root filesystem"
if [[ -r $ROOT/etc/os-release ]]; then
    . <(grep -E '^(ID|VERSION_CODENAME)=' "$ROOT/etc/os-release")
    info "target: ${ID:-?} ${VERSION_CODENAME:-?}"
    [[ ${VERSION_CODENAME:-} == trixie ]] || warn "codename is '${VERSION_CODENAME:-unknown}', not trixie — continuing anyway"
fi
DRIDIR=$ROOT/usr/lib/arm-linux-gnueabihf/dri
[[ -d $DRIDIR ]] || die "no $DRIDIR — is this an armhf rootfs?"

# --release: everything it refuses is checked here, before anything is written.
# A shared image must carry nobody's access, so an image that already has some
# is refused rather than cleaned: what else it carries is unknown.
if [[ $RELEASE == yes ]]; then
    [[ $SET_PASSWORD == no ]] || die "release: --set-password conflicts with --release (the password is 'pyra')"
    [[ -z $SSH_KEY ]] || die "release: --ssh-key conflicts with --release (a shared image authorises no key)"
    [[ $USERNAME == pyra ]] || die "release: the release image's user is 'pyra', not '$USERNAME'"
    for h in "$(awk -F: '$1=="pyra"{print $6}' "$ROOT/etc/passwd")" /root; do
        [[ -n $h && -s $ROOT$h/.ssh/authorized_keys ]] &&
            die "release: $h/.ssh/authorized_keys exists in the image; start from the vendor image"
    done
    [[ -e $ROOT/etc/sudoers.d/90-pyra-nopasswd ]] &&
        die "release: /etc/sudoers.d/90-pyra-nopasswd exists in the image; start from the vendor image"
    # The vendor's /etc/sudoers.d/pyrainput allows one command without a
    # password and stays; a rule for every command is passwordless root.
    if NOPW=$(grep -sHnE '^[^#]*NOPASSWD:.*\<ALL\>' "$ROOT/etc/sudoers" "$ROOT"/etc/sudoers.d/*); then
        die "release: the image has a NOPASSWD sudo rule for all commands; start from the vendor image:
${NOPW//$ROOT/}"
    fi
    [[ -x $ROOT/usr/bin/ssh-keygen ]] || die "release: the image has no /usr/bin/ssh-keygen to make host keys on the first boot"
    command -v chage >/dev/null || die "release: no chage on this host; install shadow-utils"
    info "release: making an image to share; prep asks nothing"
fi

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

GLES_SRC=$PAYLOADS/pyra-gles
[[ -r $GLES_SRC ]] || die "fix13: pyra-gles not found (looked in $PAYLOADS)"

KBDLIGHT_SRC=$PAYLOADS/pyra-kbdlight.sh
[[ -x $KBDLIGHT_SRC ]] || die "fix15: pyra-kbdlight.sh not found or not executable (looked in $PAYLOADS)"
KBDLIGHT_DROPIN_SRC=$PAYLOADS/etc/systemd/system/pyrainput.service.d/pyra-kbdlight.conf
[[ -r $KBDLIGHT_DROPIN_SRC ]] || die "fix15: pyrainput.service.d/pyra-kbdlight.conf not found (looked in $PAYLOADS)"
# Fix 20's override, and the image's schema directory it compiles into.
SCHEMA_DIR=usr/share/glib-2.0/schemas
KBDMATE_SRC=$PAYLOADS/$SCHEMA_DIR/99_pyra_kbdlight.gschema.override
[[ -r $KBDMATE_SRC ]] || die "fix20: 99_pyra_kbdlight.gschema.override not found (looked in $PAYLOADS)"
[[ -e $ROOT/$SCHEMA_DIR/org.mate.power-manager.gschema.xml ]] ||
    die "fix20: the image has no org.mate.power-manager schema (mate-power-manager)"
# Fix 21 runs the device script on the image, so the patch has one
# implementation. A library it doesn't know stops prep here, before fix 1.
WSEGL_FIX=$PAYLOADS/pyra-wsegl-fdfix.sh
[[ -x $WSEGL_FIX ]] || die "fix21: pyra-wsegl-fdfix.sh not found or not executable (looked in $PAYLOADS)"
for f in pyra-wsegl-guard etc/dpkg/dpkg.cfg.d/pyra-wsegl-guard; do
    [[ -r $PAYLOADS/$f ]] || die "fix21: $f not found (looked in $PAYLOADS)"
done
WSEGL_STATE=$("$WSEGL_FIX" --root "$ROOT" status 2>&1 | head -1) || true
case ${WSEGL_STATE##*: } in
stock|fixed) ;;
*) die "fix21: $WSEGL_STATE
       Fix 21 patches only the known stock build of dri3wsegl-pyra 0.4; start from the vendor image" ;;
esac
# --release installs the unit that makes the host keys on the first boot.
HOSTKEYS_UNIT_SRC=$PAYLOADS/pyra-ssh-hostkeys.service
[[ $RELEASE == no || -r $HOSTKEYS_UNIT_SRC ]] ||
    die "release: pyra-ssh-hostkeys.service not found (looked in $PAYLOADS)"

GOVTUNE_SRC=$PAYLOADS/pyra-governor-tune.sh
GOVTUNE_UNIT_SRC=$PAYLOADS/pyra-governor-tune.service
[[ -x $GOVTUNE_SRC ]] || die "fix16: pyra-governor-tune.sh not found or not executable (looked in $PAYLOADS)"
[[ -r $GOVTUNE_UNIT_SRC ]] || die "fix16: pyra-governor-tune.service not found (looked in $PAYLOADS)"

# Fix 17 copies seven files and makes one link through the select script's
# --link door, which pyra-install-helpers.sh uses too. "name destination mode".
AUDIOSEL_SRC=$PAYLOADS/pyra-audio-select.sh
[[ -x $AUDIOSEL_SRC ]] || die "fix17: pyra-audio-select.sh not found or not executable (looked in $PAYLOADS)"
AUDIOSEL_FILES="pyra-audio-select.sh /usr/local/sbin 0755
pyra-audio-select.service /etc/systemd/system 0644
pulse/zz-pyra-aess.conf /usr/local/share/pyra-audio 0644
pulse/pyra-aess.pa /etc/pulse 0644
pulse/alsa-mixer/profile-sets/pyra-aess.conf /etc/pulse/pyra-alsa-mixer/profile-sets 0644
pulse/alsa-mixer/paths/pyra-speaker.conf /usr/share/pulseaudio/alsa-mixer/paths 0644
pulse/alsa-mixer/paths/pyra-headphones.conf /usr/share/pulseaudio/alsa-mixer/paths 0644"
while read -r src _ _; do
    [[ -r $PAYLOADS/$src ]] || die "fix17: $src not found (looked in $PAYLOADS)"
done <<<"$AUDIOSEL_FILES"

KEYPAD_SRC=$PAYLOADS/pyra-keypad-rescue
[[ -x $KEYPAD_SRC ]] || die "fix18: pyra-keypad-rescue not found or not executable (looked in $PAYLOADS)"

HOOK_SRC=$PAYLOADS/etc/initramfs-tools/scripts/init-top
HOOKS="pyra-fw-nofallback pyra-settle-nudge"
for h in $HOOKS; do
    [[ -r $HOOK_SRC/$h ]] || die "fix14: $h not found (looked in $HOOK_SRC)"
done
# --grow-on-boot: the grow script, the local-premount hook that runs it, and
# the initramfs-tools hook that copies it and its tools into the initrd.
# Destination (in the image) and source (in device/), mode 0755 each.
GROW_FILES=(
    usr/local/sbin/pyra-grow-root:pyra-grow-root
    etc/initramfs-tools/scripts/local-premount/pyra-grow-root:etc/initramfs-tools/scripts/local-premount/pyra-grow-root
    etc/initramfs-tools/hooks/pyra-grow-root:etc/initramfs-tools/hooks/pyra-grow-root
)
if [[ $GROW_ON_BOOT == yes ]]; then
    for g in "${GROW_FILES[@]}"; do
        [[ -r $PAYLOADS/${g#*:} ]] || die "grow-on-boot: ${g#*:} not found (looked in $PAYLOADS)"
    done
fi

# Fix 14 rebuilds each kernel's initrd with the image's own update-initramfs,
# run in a chroot, so two more things must hold before anything is written:
# the boot partition is mounted where the rootfs expects it, and this machine
# can run the image's armhf binaries (natively, or through qemu-user binfmt).
# Commands in the chroot get a clean environment with Debian's PATH: the
# caller's PATH may lack /usr/sbin (Arch's sudo does), where update-initramfs,
# depmod and ldconfig live, and its TMPDIR need not exist inside the image.
in_chroot() {
    chroot "$ROOT" /usr/bin/env -i HOME=/root LC_ALL=C \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
}
compgen -G "$ROOT/boot/initrd.img-*" >/dev/null ||
    die "fix14: no initrd in $ROOT/boot — mount the card's boot partition (p1) at $ROOT/boot"
in_chroot /bin/true 2>/dev/null ||
    die "fix14: cannot run the image's armhf binaries in a chroot. Install qemu-user with binfmt
       (Debian/Ubuntu: qemu-user-static binfmt-support; Arch: qemu-user-static qemu-user-static-binfmt)"
in_chroot sh -c 'command -v update-initramfs && command -v lsinitramfs' >/dev/null 2>&1 ||
    die "fix14: the image has no update-initramfs or lsinitramfs (initramfs-tools)"
in_chroot sh -c 'command -v glib-compile-schemas && command -v gsettings' >/dev/null 2>&1 ||
    die "fix20: the image has no glib-compile-schemas or gsettings (libglib2.0-bin)"
if [[ $GROW_ON_BOOT == yes ]]; then
    for t in /usr/sbin/sfdisk /usr/bin/partx /usr/sbin/fsck.f2fs /usr/sbin/resize.f2fs; do
        [[ -e $ROOT$t ]] || die "grow-on-boot: the image has no $t, which the initrd needs to grow the card"
    done
fi

# Fix 19 runs the two device scripts that own a kernel install and the boot
# choice, so both must be here; and the tarball is found, downloaded and
# checked now, so a bad one stops prep before fix 1 has written anything.
KINSTALL_SRC=$PAYLOADS/pyra-install-debug-kernel.sh
KBOOT_SRC=$PAYLOADS/pyra-boot-kernel.sh
for f in "$KINSTALL_SRC" "$KBOOT_SRC"; do
    [[ -x $f ]] || die "fix19: $(basename "$f") not found or not executable (looked in $PAYLOADS)"
done
KERNEL_REL=5.6.19-m4-kbdled
KERNEL_SLOT=l5
# The published release asset. Empty until the first kernel-* release exists
# (the public repository has no remote yet); a release fills in all three
# together. The hash is what makes a download trustworthy: the script comes
# from the repository, so the hash travels with the source that names it.
KERNEL_TAG=
KERNEL_URL=
KERNEL_SHA256=
KERNEL_TMP=
STAGED_KERNEL=$ROOT/var/tmp/pyra-prep-kernel.tar.gz
# Fix 22's published .deb, the same way: pyra-backlight's v0.2 release asset,
# the SHA-256 of the file as published. All three change together.
BACKLIGHT_TAG=v0.2
BACKLIGHT_URL=https://github.com/daniel-mcdonough/pyra-backlight/releases/download/v0.2/pyra-backlight_0.2_all.deb
BACKLIGHT_SHA256=d6e1ae62ce5ae1310e88c6719b6152ddc04c5241503933e535e79c9508999d10
BACKLIGHT_TMP=
STAGED_BACKLIGHT=$ROOT/var/tmp/pyra-prep-backlight.deb
# The one package pyra-backlight needs that the vendor image lacks: the MATE
# panel applet's GObject bindings, Debian trixie's build, pinned by SHA-256.
# The pool drops it if a point release replaces mate-panel; snapshot.debian.org
# keeps it by its SHA-1 for good. A copy beside the pyra-backlight .deb is used
# instead, so a run can be offline.
GIR_PKG=gir1.2-matepanelapplet-4.0
GIR_DEB=gir1.2-matepanelapplet-4.0_1.27.1-4.1_armhf.deb
GIR_SHA256=5c75b6aae0881990a2555c83502d93d22fd3700265ba9eebaa5841de05dd5684
GIR_URLS=(https://deb.debian.org/debian/pool/main/m/mate-panel/$GIR_DEB
          https://snapshot.debian.org/file/97d67626deac4562a3475a7abe61638c3d84f2a9)
STAGED_GIR=
cleanup() {
    [[ $(type -t chroot_unmount) == function ]] && chroot_unmount
    [[ -n $KERNEL_TMP ]] && rm -rf -- "$KERNEL_TMP"
    [[ -n $BACKLIGHT_TMP ]] && rm -rf -- "$BACKLIGHT_TMP"
    rm -f -- "$STAGED_KERNEL" "$STAGED_BACKLIGHT" ${STAGED_GIR:+"$STAGED_GIR"}
}
trap cleanup EXIT

if [[ $KERNEL_MODE == ask ]]; then
    if [[ -z $KERNEL_URL || -z $KERNEL_SHA256 ]]; then
        warn "fix19: no kernel release is published yet, so there is nothing to download.
       Pass --kernel FILE (./pc/pyra-crossbuild.sh kernel-m4-kbdled builds one),
       or --no-kernel to leave this card on the stock 5.6.19-pyradef."
        die "fix19: no kernel to install; nothing has been written"
    fi
    ans=y
    if [[ -t 0 && $RELEASE == no ]]; then
        printf 'Download the shipped kernel (%s, release %s) from\n  %s\nand install it? [Y/n] ' \
            "$KERNEL_REL" "$KERNEL_TAG" "$KERNEL_URL" >&2
        read -r ans || ans=n
    fi
    case ${ans:-y} in
    [Yy]*) command -v curl >/dev/null || die "fix19: the download needs curl on this PC"
           KERNEL_TMP=$(mktemp -d)
           KERNEL_FILE=$KERNEL_TMP/m4-kbdled-kernel.tar.gz
           info "fix19: downloading $KERNEL_URL"
           curl -fL --proto '=https' --tlsv1.2 -o "$KERNEL_FILE" "$KERNEL_URL" ||
               die "fix19: the download failed; nothing has been written"
           KERNEL_MODE=file ;;
    *)     KERNEL_MODE=none ;;
    esac
fi
if [[ $KERNEL_MODE == file ]]; then
    [[ -r $KERNEL_FILE ]] || die "fix19: no tarball at $KERNEL_FILE"
    sum=$(sha256sum "$KERNEL_FILE" | cut -d' ' -f1)
    if [[ -n $KERNEL_TMP ]]; then
        [[ $sum == "$KERNEL_SHA256" ]] ||
            die "fix19: the download's SHA-256 is $sum, not the pinned $KERNEL_SHA256. Not installing it."
        ok "fix19: the download matches the pinned SHA-256"
    fi
    LIST=$(tar tzf "$KERNEL_FILE") || die "fix19: $KERNEL_FILE is not a readable .tar.gz"
    grep -qx "./boot/vmlinuz-$KERNEL_REL" <<<"$LIST" ||
        die "fix19: $KERNEL_FILE does not carry ./boot/vmlinuz-$KERNEL_REL; prep installs only the shipped kernel"
    # The installer refuses this too, but by then fixes 1-18 are on the card.
    grep -qx './lib/' <<<"$LIST" &&
        die "fix19: $KERNEL_FILE has a ./lib/ entry, which would replace the image's /lib symlink"
    unset LIST
    if [[ -z $KERNEL_TMP ]]; then
        if [[ -n $KERNEL_SHA256 && $sum == "$KERNEL_SHA256" ]]; then
            ok "fix19: $KERNEL_FILE is the published release $KERNEL_TAG"
        else
            info "fix19: $KERNEL_FILE is not the published release (a local build?); installing it as given"
        fi
    fi
elif [[ $KERNEL_MODE == none ]]; then
    warn "fix19: no kernel will be installed; this card will boot the stock 5.6.19-pyradef"
fi

# Fix 22 installs a .deb with the image's dpkg, without apt: the vendor image
# has everything the package depends on except gir1.2-matepanelapplet-4.0,
# which is fetched pinned (GIR_* above) and installed with it. The .deb is
# found, downloaded and checked now,
# and its dependencies are looked up in the image, so a wrong file or a missing
# dependency stops prep before fix 1 has written anything. It is staged in the
# image's /var/tmp for the chroot's dpkg-deb, and removed on the way out.
# Prints each Depends entry of the .deb in $1 that the image does not satisfy.
# Packages named after it are being installed alongside, so they count as
# there. A virtual package counts when an installed package provides it.
# shellcheck disable=SC2016  # expanded by the chroot's sh, not here
BACKLIGHT_DEPCHECK='
deb=$1; shift
provided=$(dpkg-query -W -f="\${db:Status-Abbrev}|\${Provides}\n" | sed -n "s/^ii[^|]*|//p" |
    tr "," "\n" | sed "s/(.*//; s/[[:space:]]//g" | sort -u)
dpkg-deb -f "$deb" Depends | tr "," "\n" | while IFS= read -r dep; do
    dep=$(printf %s "$dep" | sed "s/^[[:space:]]*//; s/[[:space:]]*$//")
    [ -n "$dep" ] || continue
    met=no
    for alt in $(printf %s "$dep" | sed "s/[[:space:]]//g" | tr "|" " "); do
        name=${alt%%(*}; name=${name%%:*}
        for x in "$@"; do [ "$x" = "$name" ] && { met=yes; break; }; done
        [ "$met" = yes ] && break
        st=$(dpkg-query -W -f="\${db:Status-Abbrev}" "$name" 2>/dev/null) || st=
        case $st in
        ii*) ;;
        *) printf "%s\n" "$provided" | grep -qx "$name" && { met=yes; break; }; continue ;;
        esac
        c=$(printf %s "$alt" | sed -n "s/.*(\(.*\))$/\1/p")
        if [ -n "$c" ]; then
            op=$(printf %s "$c" | sed "s/[^<>=].*//"); ver=${c#"$op"}
            have=$(dpkg-query -W -f="\${Version}" "$name")
            dpkg --compare-versions "$have" "$op" "$ver" || continue
        fi
        met=yes; break
    done
    [ "$met" = yes ] || echo "  $dep"
done'
if [[ $BACKLIGHT_MODE == auto ]]; then
    if [[ -z $BACKLIGHT_URL || -z $BACKLIGHT_SHA256 ]]; then
        warn "fix22: no pyra-backlight release is pinned yet, so there is nothing to download, and
       the card gets no brightness applet or idle dimmer. Pass --backlight FILE
       (pyra-backlight's ./build-deb.sh builds one), or --no-backlight to leave it out."
        BACKLIGHT_MODE=none
    else
        command -v curl >/dev/null || die "fix22: the download needs curl on this PC"
        BACKLIGHT_TMP=$(mktemp -d)
        BACKLIGHT_FILE=$BACKLIGHT_TMP/pyra-backlight.deb
        info "fix22: downloading $BACKLIGHT_URL"
        curl -fL --proto '=https' --tlsv1.2 -o "$BACKLIGHT_FILE" "$BACKLIGHT_URL" ||
            die "fix22: the download failed; nothing has been written"
        sum=$(sha256sum "$BACKLIGHT_FILE" | cut -d' ' -f1)
        [[ $sum == "$BACKLIGHT_SHA256" ]] ||
            die "fix22: the download's SHA-256 is $sum, not the pinned $BACKLIGHT_SHA256. Not installing it."
        ok "fix22: the download matches the pinned SHA-256"
        BACKLIGHT_MODE=file
    fi
elif [[ $BACKLIGHT_MODE == none ]]; then
    warn "fix22: --no-backlight: pyra-backlight will not be installed"
fi
if [[ $BACKLIGHT_MODE == file ]]; then
    [[ -r $BACKLIGHT_FILE ]] || die "fix22: no .deb at $BACKLIGHT_FILE"
    if [[ -z $BACKLIGHT_TMP ]]; then
        sum=$(sha256sum "$BACKLIGHT_FILE" | cut -d' ' -f1)
        if [[ -n $BACKLIGHT_SHA256 && $sum == "$BACKLIGHT_SHA256" ]]; then
            ok "fix22: $BACKLIGHT_FILE is the published release $BACKLIGHT_TAG"
        else
            info "fix22: $BACKLIGHT_FILE is not the published release (a local build?); installing it as given"
        fi
    fi
    install -m 0644 -o 0 -g 0 "$BACKLIGHT_FILE" "$STAGED_BACKLIGHT"
    BL_DEB=${STAGED_BACKLIGHT#$ROOT}
    BL_PKG=$(in_chroot dpkg-deb -f "$BL_DEB" Package 2>/dev/null) ||
        die "fix22: $BACKLIGHT_FILE is not a .deb the image's dpkg-deb can read; nothing has been written"
    [[ $BL_PKG == pyra-backlight ]] ||
        die "fix22: $BACKLIGHT_FILE is the package '$BL_PKG', not pyra-backlight; nothing has been written"
    BL_VER=$(in_chroot dpkg-deb -f "$BL_DEB" Version)
    BL_WITH=()
    if [[ $(in_chroot dpkg-query -W -f='${db:Status-Abbrev}' "$GIR_PKG" 2>/dev/null) == ii* ]]; then
        ok "fix22: the image already has $GIR_PKG"
    else
        gir=$(dirname -- "$BACKLIGHT_FILE")/$GIR_DEB
        if [[ -r $gir ]]; then
            info "fix22: using $gir"
        else
            command -v curl >/dev/null || die "fix22: the image lacks $GIR_PKG, and fetching it needs curl on this PC"
            [[ -n $BACKLIGHT_TMP ]] || BACKLIGHT_TMP=$(mktemp -d)
            gir=$BACKLIGHT_TMP/$GIR_DEB
            for u in "${GIR_URLS[@]}"; do
                info "fix22: the image lacks $GIR_PKG; downloading $u"
                curl -fL --proto '=https' --tlsv1.2 -o "$gir" "$u" && break
                rm -f -- "$gir"
            done
            [[ -s $gir ]] || die "fix22: could not download $GIR_DEB; nothing has been written.
       Put it beside $BACKLIGHT_FILE to run without the network."
        fi
        sum=$(sha256sum "$gir" | cut -d' ' -f1)
        [[ $sum == "$GIR_SHA256" ]] ||
            die "fix22: $gir has SHA-256 $sum, not the pinned $GIR_SHA256. Not installing it."
        ok "fix22: $GIR_DEB matches the pinned SHA-256"
        STAGED_GIR=$ROOT/var/tmp/pyra-prep-$GIR_DEB
        install -m 0644 -o 0 -g 0 "$gir" "$STAGED_GIR"
        GIR_MISSING=$(in_chroot sh -c "$BACKLIGHT_DEPCHECK" sh "${STAGED_GIR#$ROOT}") ||
            die "fix22: could not read the dependencies of $GIR_DEB"
        [[ -z $GIR_MISSING ]] || die "fix22: the image lacks what $GIR_PKG depends on:
$GIR_MISSING
       Nothing has been written."
        BL_WITH=("${STAGED_GIR#$ROOT}")
    fi
    BL_MISSING=$(in_chroot sh -c "$BACKLIGHT_DEPCHECK" sh "$BL_DEB" "$GIR_PKG") ||
        die "fix22: could not read the dependencies of $BACKLIGHT_FILE"
    [[ -z $BL_MISSING ]] || die "fix22: the image lacks what pyra-backlight $BL_VER depends on, and prep adds only $GIR_PKG:
$BL_MISSING
       Nothing has been written."
    ok "fix22: pyra-backlight $BL_VER; the image has everything it depends on${BL_WITH:+, with $GIR_PKG added}"
fi


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
ask_password() {
    printf 'Password for %s (input hidden): ' "$USERNAME" >&2
    read -rs PW1; echo >&2
    printf 'Repeat: ' >&2
    read -rs PW2; echo >&2
    [[ $PW1 == "$PW2" && -n $PW1 ]] || die "fix2: passwords empty or did not match; $1"
    HASH=$(printf '%s' "$PW1" | openssl passwd -6 -stdin)
    unset PW1 PW2
    # chpasswd -e -R writes the hash without it ever hitting the process table.
    printf '%s:%s\n' "$USERNAME" "$HASH" | chpasswd -e -R "$ROOT"
    unset HASH
}
# --release: the documented password 'pyra', expired, so the first login (the
# greeter, a console or ssh) makes the user choose their own before going on.
# A hash that already is 'pyra' and already expired is left alone, so a rerun
# writes nothing.
release_password() {
    local hash salt
    hash=$(awk -F: -v u="$USERNAME" '$1==u{print $2}' "$ROOT/etc/shadow")
    salt=$(cut -d'$' -f3 <<<"$hash")
    if [[ $hash == '$6$'* && $(openssl passwd -6 -salt "$salt" pyra) == "$hash" &&
          $(awk -F: -v u="$USERNAME" '$1==u{print $3}' "$ROOT/etc/shadow") == 0 ]]; then
        ok "release: '$USERNAME' already has the password 'pyra', to be changed at the first login"
        return
    fi
    printf '%s:%s\n' "$USERNAME" "$(openssl passwd -6 pyra)" | chpasswd -e -R "$ROOT"
    chage -R "$ROOT" -d 0 "$USERNAME"
    ok "release: '$USERNAME' has the password 'pyra', to be changed at the first login"
}
if grep -q "^${USERNAME}:" "$ROOT/etc/passwd"; then
    ok "fix2: user '$USERNAME' already exists"
    if [[ $RELEASE == yes ]]; then
        release_password
    elif [[ $SET_PASSWORD == yes ]]; then
        ask_password "the password is unchanged"
        ok "fix2: password set for '$USERNAME'"
    else
        info "fix2: its password is unchanged (the image's own 'pyra' password is not documented; --set-password sets one)"
    fi
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

    if [[ $RELEASE == yes ]]; then
        release_password
    else
        ask_password "user has NO password set"
        ok "fix2: password set for '$USERNAME'"
    fi
fi

# --- an ssh key, if one was given -------------------------------------------
if [[ -n $SSH_KEY_LINE ]]; then
    IFS=: read -r _ _ KUID KGID _ KHOME _ < <(grep "^${USERNAME}:" "$ROOT/etc/passwd")
    [[ -n $KHOME && -d $ROOT$KHOME ]] || die "fix2: '$USERNAME' has no home directory in the image for authorized_keys"
    AUTH=$ROOT$KHOME/.ssh/authorized_keys
    install -d -m 0700 -o "$KUID" -g "$KGID" "$ROOT$KHOME/.ssh"
    if [[ -e $AUTH ]] && grep -qxF "$SSH_KEY_LINE" "$AUTH"; then
        ok "fix2: the key is already authorised for '$USERNAME'"
    else
        printf '%s\n' "$SSH_KEY_LINE" >> "$AUTH"
        ok "fix2: authorised $(awk '{print $1}' <<<"$SSH_KEY_LINE") key for '$USERNAME' in ${AUTH#$ROOT}"
    fi
    chown "$KUID:$KGID" "$AUTH"
    chmod 0600 "$AUTH"
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
# so a reinstall or upgrade of pyra-hacks reverts it. The dpkg hook installed
# after fix 7 puts it back, or says loudly that it cannot.

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

# Fixes 6 and 7 edit a file pyra-hacks owns, so any reinstall, upgrade or
# downgrade of that package puts the vendor's back. A dpkg post-invoke hook
# runs pyra-thermal-guard after every package run: it re-applies both fixes
# through the same two scripts, or warns on every run if they no longer
# recognise the new file. The two scripts go onto the card for it, which also
# gives the card the --check and --undo the docs point at.
for spec in pyra-thermal-fix.sh:/usr/local/sbin:0755 \
            pyra-thermal-ladder.sh:/usr/local/sbin:0755 \
            pyra-thermal-guard:/usr/local/sbin:0755 \
            etc/dpkg/dpkg.cfg.d/pyra-thermal-guard:/etc/dpkg/dpkg.cfg.d:0644; do
    IFS=: read -r src dir mode <<<"$spec"
    [[ -r $PAYLOADS/$src ]] || die "fix6/7: $src not found (looked in $PAYLOADS)"
    dst=$ROOT$dir/$(basename "$src")
    if [[ -e $dst ]] && cmp -s "$PAYLOADS/$src" "$dst"; then
        ok "fix6/7: ${dst#$ROOT} already up to date"
    else
        VERB=$([[ -e $dst ]] && echo updated || echo installed)
        [[ -d $ROOT$dir ]] || install -d -m 0755 "$ROOT$dir"
        install -m "$mode" -o 0 -g 0 "$PAYLOADS/$src" "$dst"
        ok "fix6/7: $VERB ${dst#$ROOT}"
    fi
done

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

# ---------------------------------------------------------------------- fix 13
#
# Every Qt5 program renders nothing on this image. The SGX blob ships its GLES2
# as libGLESv2.so.1; Qt links glvnd's libGLESv2.so.2, which has no vendor for
# the blob's EGL context, so every GL call is a stub and nothing logs an error.
# pyra-gles runs a program with a one-symlink shim in front of glvnd. It is per
# program on purpose: a system-wide shim would hand the blob GLES2 programs
# that need glvnd's fallback. Nothing in the image's menus links Qt, so there
# is no launcher to wrap; this puts the wrapper on the path. docs/qt-gles.md.

GLES_DST=$ROOT/usr/local/bin/pyra-gles
if [[ -e $GLES_DST ]] && cmp -s "$GLES_SRC" "$GLES_DST"; then
    ok "fix13: /usr/local/bin/pyra-gles already in place"
else
    mkdir -p "$ROOT/usr/local/bin"
    cat "$GLES_SRC" > "$GLES_DST"
    chmod 0755 "$GLES_DST"
    chown 0:0 "$GLES_DST"
    ok "fix13: wrote /usr/local/bin/pyra-gles"
fi

# ---------------------------------------------------------------------- fix 14
#
# Some boots sit in the initramfs for 70-126 s before mounting root, with
# nothing on screen (docs/troubleshooting.md, "Root mounts a minute or two
# late"). Two init-top hooks fix the two causes: pyra-fw-nofallback stops the
# USB ethernet adapter's 60 s wait for firmware that is not there, and
# pyra-settle-nudge wakes a `udevadm settle` that slept through the end of the
# queue (the cause patches/0048 fixes in our kernels, but not in the stock one
# this card boots). A hook only runs once it is in the initrd, so each kernel's
# initrd is rebuilt in a chroot by the image's own update-initramfs, exactly as
# pyra-install-helpers.sh does on the device. An initrd that already lists both
# hooks and is newer than both is left alone, so a second run changes nothing.

HOOK_DIR=$ROOT/etc/initramfs-tools/scripts/init-top
mkdir -p "$HOOK_DIR"
for h in $HOOKS; do
    if [[ -e $HOOK_DIR/$h ]] && cmp -s "$HOOK_SRC/$h" "$HOOK_DIR/$h"; then
        ok "fix14: /etc/initramfs-tools/scripts/init-top/$h already in place"
    else
        cat "$HOOK_SRC/$h" > "$HOOK_DIR/$h"
        chmod 0755 "$HOOK_DIR/$h"
        chown 0:0 "$HOOK_DIR/$h"
        ok "fix14: wrote /etc/initramfs-tools/scripts/init-top/$h"
    fi
done
if [[ $GROW_ON_BOOT == yes ]]; then
    for g in "${GROW_FILES[@]}"; do
        dst=$ROOT/${g%%:*}
        src=$PAYLOADS/${g#*:}
        if [[ -e $dst ]] && cmp -s "$src" "$dst"; then
            ok "grow-on-boot: /${g%%:*} already in place"
        else
            mkdir -p "$(dirname "$dst")"
            install -m 0755 -o 0 -g 0 "$src" "$dst"
            ok "grow-on-boot: wrote /${g%%:*}"
        fi
    done
fi
GROW_NOTE=
[[ $GROW_ON_BOOT == yes ]] && GROW_NOTE=" and pyra-grow-root"

initrd_has_hooks() {    # /boot/initrd.img-REL (chroot path) -> true when current
    local h list
    list=$(in_chroot lsinitramfs "$1" 2>/dev/null) || return 1
    for h in $HOOKS; do
        [[ $HOOK_DIR/$h -nt $ROOT$1 ]] && return 1
        grep -qx "scripts/init-top/$h" <<<"$list" || return 1
    done
    if [[ $GROW_ON_BOOT == yes ]]; then
        for g in "${GROW_FILES[@]}"; do
            [[ $ROOT/${g%%:*} -nt $ROOT$1 ]] && return 1
        done
        grep -qx "scripts/local-premount/pyra-grow-root" <<<"$list" || return 1
        grep -qx "usr/sbin/pyra-grow-root" <<<"$list" || return 1
        grep -qx "usr/sbin/sfdisk" <<<"$list" || return 1
    fi
    return 0
}

CHROOT_MOUNTS=()
chroot_unmount() {
    local m
    for m in "${CHROOT_MOUNTS[@]}"; do umount "$m" 2>/dev/null || umount -l "$m"; done
    CHROOT_MOUNTS=()
}
chroot_mount() {        # lsinitramfs and update-initramfs want /proc, /sys and /dev
    local d
    [[ ${#CHROOT_MOUNTS[@]} -eq 0 ]] || return 0
    for d in proc sys dev; do
        mountpoint -q "$ROOT/$d" && continue
        mount --bind "/$d" "$ROOT/$d"
        CHROOT_MOUNTS=("$ROOT/$d" "${CHROOT_MOUNTS[@]}")
    done
}

chroot_mount
for initrd in "$ROOT"/boot/initrd.img-*; do
    rel=${initrd#$ROOT/boot/initrd.img-}
    if [[ ! -d $ROOT/lib/modules/$rel ]]; then
        warn "fix14: skipped /boot/initrd.img-$rel (no /lib/modules/$rel to build it from)"
        continue
    fi
    if initrd_has_hooks "/boot/initrd.img-$rel"; then
        ok "fix14: /boot/initrd.img-$rel already has both hooks$GROW_NOTE"
        continue
    fi
    need=$(( $(stat -c %s "$initrd") / 1024 + 2048 ))
    free=$(df -Pk "$ROOT/boot" | awk 'NR==2{print $4}')
    [[ $free -ge $need ]] ||
        die "fix14: $ROOT/boot has ${free} KB free, rebuilding initrd.img-$rel needs about ${need} KB"
    info "fix14: rebuilding /boot/initrd.img-$rel in the chroot (under qemu, most of a minute)"
    if ! out=$(in_chroot update-initramfs -u -k "$rel" 2>&1); then
        rm -f -- "$initrd.new"
        die "fix14: update-initramfs -u -k $rel failed in the chroot:
$out"
    fi
    initrd_has_hooks "/boot/initrd.img-$rel" ||
        die "fix14: /boot/initrd.img-$rel was rebuilt but does not list both hooks$GROW_NOTE"
    ok "fix14: rebuilt /boot/initrd.img-$rel with both hooks$GROW_NOTE"
done
chroot_unmount

# ---------------------------------------------------------------------- fix 15
#
# The Fn keyboard-brightness keys do nothing on 5.6.19-m4-kbdled. That kernel
# declares the keyboard light as an LED (pyra::kbd_backlight), and the command
# funkeymonkey runs for the keys, pyra-scripts' pyra-brightkey.sh, only knows
# /sys/class/backlight/keyboard-backlight. pyra-kbdlight.sh drives the LED in the
# same nine steps, and hands the key to the vendor script when there is no LED,
# so it is right on the stock kernel too and needs no check of which kernel the
# card boots. The keys reach it through /etc/pyrainput.cfg (fix 3 makes it),
# which no package ships, so a pyra-scripts upgrade cannot undo this. The script
# writes the two lines itself, as pyra-install-helpers.sh has it do on a device.
# funkeymonkey-pyrainput 0.1.19 drops those lines at start and only applies them
# on a reload, so a drop-in for pyrainput.service reloads it once at each start
# (pyra-kbdlight.sh --reload says how it avoids killing the daemon).

KBDLIGHT_DST=$ROOT/usr/local/sbin/pyra-kbdlight.sh
if [[ -e $KBDLIGHT_DST ]] && cmp -s "$KBDLIGHT_SRC" "$KBDLIGHT_DST"; then
    ok "fix15: /usr/local/sbin/pyra-kbdlight.sh already up to date"
else
    VERB=$([[ -e $KBDLIGHT_DST ]] && echo updated || echo installed)
    install -m 0755 -o 0 -g 0 "$KBDLIGHT_SRC" "$KBDLIGHT_DST"
    ok "fix15: $VERB /usr/local/sbin/pyra-kbdlight.sh"
fi
while read -r line; do
    case $line in
    *"left alone"*) warn "fix15: ${line#pyra-kbdlight: }" ;;
    *)              ok "fix15: ${line#pyra-kbdlight: } in /etc/pyrainput.cfg" ;;
    esac
done < <("$KBDLIGHT_SRC" --configure "$ROOT/etc/pyrainput.cfg" 2>&1)
KBDLIGHT_DROPIN=$ROOT/etc/systemd/system/pyrainput.service.d/pyra-kbdlight.conf
if [[ -e $KBDLIGHT_DROPIN ]] && cmp -s "$KBDLIGHT_DROPIN_SRC" "$KBDLIGHT_DROPIN"; then
    ok "fix15: pyrainput.service.d/pyra-kbdlight.conf already up to date"
else
    VERB=$([[ -e $KBDLIGHT_DROPIN ]] && echo updated || echo installed)
    install -d -m 0755 -o 0 -g 0 "$(dirname "$KBDLIGHT_DROPIN")"
    install -m 0644 -o 0 -g 0 "$KBDLIGHT_DROPIN_SRC" "$KBDLIGHT_DROPIN"
    ok "fix15: $VERB pyrainput.service.d/pyra-kbdlight.conf (reload at start)"
fi

# ---------------------------------------------------------------------- fix 16
#
# ondemand's sampling_down_factor is 1, so the governor drops the clock at the
# first idle sample and work that arrives in bursts pays the ramp back up on
# every unit. 10 takes 23% off burst latency for 5.4% more idle frequency
# (measured 2026-09-13, experiments/governor/README.md; the script's header has
# the numbers and why it sets only this one value). A sysfs write does not
# survive a reboot, so the unit applies it at boot. It is a oneshot that stays
# active: leaving ondemand resets the tunable (pyra-cpu-pin's header), and
# `systemctl restart` puts it back. Every kernel here, the stock one included,
# boots on ondemand; on any other governor the unit's condition skips it and
# the script exits 0, so it cannot fail the boot. Same two files, same paths
# as pyra-install-helpers.sh, which enables it the same way online.

GOVTUNE_DST=$ROOT/usr/local/sbin/pyra-governor-tune.sh
GOVTUNE_UNIT=$ROOT/etc/systemd/system/pyra-governor-tune.service
if [[ -e $GOVTUNE_DST ]] && cmp -s "$GOVTUNE_SRC" "$GOVTUNE_DST"; then
    ok "fix16: ${GOVTUNE_DST#$ROOT} already up to date"
else
    VERB=$([[ -e $GOVTUNE_DST ]] && echo updated || echo installed)
    install -m 0755 -o 0 -g 0 "$GOVTUNE_SRC" "$GOVTUNE_DST"
    ok "fix16: $VERB ${GOVTUNE_DST#$ROOT}"
fi
if [[ -e $GOVTUNE_UNIT ]] && cmp -s "$GOVTUNE_UNIT_SRC" "$GOVTUNE_UNIT"; then
    ok "fix16: ${GOVTUNE_UNIT#$ROOT} already up to date"
else
    VERB=$([[ -e $GOVTUNE_UNIT ]] && echo updated || echo installed)
    install -m 0644 -o 0 -g 0 "$GOVTUNE_UNIT_SRC" "$GOVTUNE_UNIT"
    ok "fix16: $VERB ${GOVTUNE_UNIT#$ROOT}"
fi
if [[ -L $WANTS/pyra-governor-tune.service ]]; then
    ok "fix16: already enabled in multi-user.target"
else
    ln -sf /etc/systemd/system/pyra-governor-tune.service \
           "$WANTS/pyra-governor-tune.service"
    ok "fix16: enabled in multi-user.target"
fi

# ---------------------------------------------------------------------- fix 17
#
# The audio DSP (AESS) path needs its own PulseAudio script, and the packaged
# pyra.pa is right only for the direct McPDM link: load the wrong one and the
# session gets auto_null, the "dummy output". Which one is right depends on
# the kernel that booted, so a file in /etc cannot choose. The daemon.conf
# that selects pyra-aess.pa sits behind a link into /run, which starts empty;
# pyra-audio-select.service fills it before the display manager on an AESS
# kernel (5.6.19-m4-kbdled) and leaves it dangling on any other, where
# PulseAudio skips it and the packaged pyra.conf and pyra.pa apply untouched.
# So on the stock 5.6.19-pyradef this card boots, the stock audio is what
# plays. docs/audio.md, "Two paths, chosen by the kernel".
#
# Two of the files go in /usr/share/pulseaudio/alsa-mixer/paths, the only
# place PulseAudio 17 reads a profile set's paths from. The pulseaudio package
# owns that directory but not these files, and dpkg replaces or removes only
# files it owns, so an upgrade leaves them alone and they need no guard like
# fixes 6 and 7. Fix 9's helper sets the DSP mixers this path plays through;
# the paths carry no volume element, so the wheel (fix 12) is untouched.

while read -r src dir mode; do
    dst=$ROOT$dir/$(basename "$src")
    if [[ -e $dst ]] && cmp -s "$PAYLOADS/$src" "$dst"; then
        ok "fix17: ${dst#$ROOT} already up to date"
        continue
    fi
    VERB=$([[ -e $dst ]] && echo updated || echo installed)
    install -d -m 0755 "$ROOT$dir"
    install -m "$mode" -o 0 -g 0 "$PAYLOADS/$src" "$dst"
    ok "fix17: $VERB ${dst#$ROOT}"
done <<<"$AUDIOSEL_FILES"
LINKOUT=$("$AUDIOSEL_SRC" --link "$ROOT" 2>&1) ||
    die "fix17: could not make the daemon.conf.d link:
       $LINKOUT"
while read -r line; do
    case $line in
    same*) ok "fix17: link already in place: $(echo ${line#same})" ;;
    *)     ok "fix17: $(echo $line)" ;;
    esac
done <<<"$LINKOUT"
if [[ -L $WANTS/pyra-audio-select.service ]]; then
    ok "fix17: already enabled in multi-user.target"
else
    ln -sf /etc/systemd/system/pyra-audio-select.service \
           "$WANTS/pyra-audio-select.service"
    ok "fix17: enabled in multi-user.target"
fi

# ---------------------------------------------------------------------- fix 18
#
# The built-in keyboard can go dead with nothing logged. The TCA8418 holds its
# interrupt line asserted while it has events queued, the device tree calls
# the line edge triggered, and a key that lands between the driver's last
# FIFO read and its acknowledge leaves the line asserted with no new edge to
# come. patches/0006 fixes it in the kernel fix 19 installs; the stock
# 5.6.19-pyradef, which a --no-kernel card boots, does not carry it. pyra-keypad-rescue drains the queue and clears
# the status over i2c, run by hand from ssh or the touchscreen. A manual tool:
# no unit, nothing enabled. docs/troubleshooting.md, "Getting the keyboard
# back without that kernel".
#
# It needs i2cget and i2cset. The vendor image ships i2c-tools; prep installs
# no packages, so it only warns if an image lacks them.

KEYPAD_DST=$ROOT/usr/local/sbin/pyra-keypad-rescue
if [[ -e $KEYPAD_DST ]] && cmp -s "$KEYPAD_SRC" "$KEYPAD_DST"; then
    ok "fix18: ${KEYPAD_DST#$ROOT} already up to date"
else
    VERB=$([[ -e $KEYPAD_DST ]] && echo updated || echo installed)
    install -d -m 0755 "$ROOT/usr/local/sbin"
    install -m 0755 -o 0 -g 0 "$KEYPAD_SRC" "$KEYPAD_DST"
    ok "fix18: $VERB ${KEYPAD_DST#$ROOT}"
fi
for t in i2cget i2cset; do
    [[ -x $ROOT/usr/sbin/$t ]] ||
        warn "fix18: the image has no /usr/sbin/$t; pyra-keypad-rescue needs i2c-tools (apt install i2c-tools on the device)"
done

# ---------------------------------------------------------------------- fix 19
#
# The image boots the stock 5.6.19-pyradef, which has none of the kernel fixes:
# suspend, the nubs after resume, the keyboard (patches/0006), the jack, AESS
# audio, the keyboard light as an LED. The shipped kernel, 5.6.19-m4-kbdled,
# carries them (docs/building.md, "Which kernel ships"). Fix 19 installs it
# into user.cfg slot l5 and makes l5 the base, so the card boots it from the
# first boot; the distro kernel stays in linux.cfg as l0.
#
# The install is pyra-install-debug-kernel.sh, run in the chroot exactly as on
# the device, so there is one implementation of it: it guards /lib, depmod's
# the tree, writes the M4 modprobe.d blacklist before the initrd, builds the
# initrd (with fix 14's hooks, which are in place by now) and copies the stock
# append line into the entry. pyra-boot-kernel.sh then names l5 the base and
# makes it the default. Prep installs both scripts on every run, kernel or
# not: they are how a user changes kernels later.
#
# Fallback: a kernel that never reaches userspace can't be undone from the
# device. Put the card in a PC and change `default l5` to `default l0` in
# extlinux.conf on p1 (docs/troubleshooting.md, "The card does not boot
# after prep installed the kernel").

for s in "$KINSTALL_SRC" "$KBOOT_SRC"; do
    dst=$ROOT/usr/local/sbin/$(basename "$s")
    if [[ -e $dst ]] && cmp -s "$s" "$dst"; then
        ok "fix19: ${dst#$ROOT} already up to date"
    else
        VERB=$([[ -e $dst ]] && echo updated || echo installed)
        install -d -m 0755 "$ROOT/usr/local/sbin"
        install -m 0755 -o 0 -g 0 "$s" "$dst"
        ok "fix19: $VERB ${dst#$ROOT}"
    fi
done

if [[ $KERNEL_MODE == file ]]; then
    EXTDIR=$ROOT/boot/extlinux
    KMOD=$ROOT/usr/lib/modules/$KERNEL_REL
    M4_CONF=$ROOT/etc/modprobe.d/pyra-m4-noautoboot.conf
    slot_linux=$(awk -v want="label $KERNEL_SLOT" '$0 == want {f=1; next} /^label /{f=0}
        f && /^[[:space:]]*linux /{print $2; exit}' "$EXTDIR/user.cfg" 2>/dev/null || true)
    # Installed means: the entry boots it, its files are there, the image is
    # this tarball's, and a kernel with omap_remoteproc has the blacklist.
    current=no
    if [[ $slot_linux == "/vmlinuz-$KERNEL_REL" && -f $ROOT/boot/initrd.img-$KERNEL_REL && -d $KMOD ]] &&
       tar xzOf "$KERNEL_FILE" "./boot/vmlinuz-$KERNEL_REL" | cmp -s - "$ROOT/boot/vmlinuz-$KERNEL_REL"; then
        current=yes
        if find "$KMOD" -name 'omap_remoteproc.ko*' | grep -q . &&
           ! grep -qsx 'blacklist omap_remoteproc' "$M4_CONF"; then
            current=no
        fi
    fi
    if [[ $current == yes ]]; then
        ok "fix19: $KERNEL_REL is already installed in slot $KERNEL_SLOT"
    else
        cp -- "$KERNEL_FILE" "$STAGED_KERNEL"
        chroot_mount
        info "fix19: installing $KERNEL_REL in the chroot (under qemu, a few minutes)"
        if ! out=$(in_chroot /usr/local/sbin/pyra-install-debug-kernel.sh \
                --slot "$KERNEL_SLOT" "${STAGED_KERNEL#$ROOT}" 2>&1); then
            die "fix19: pyra-install-debug-kernel.sh failed in the chroot:
$out"
        fi
        rm -f -- "$STAGED_KERNEL"
        ok "fix19: installed $KERNEL_REL into slot $KERNEL_SLOT, with its initrd"
    fi
    if grep -qsx 'blacklist omap_remoteproc' "$M4_CONF"; then
        ok "fix19: ${M4_CONF#$ROOT} keeps the M4s from starting at boot"
    elif find "$KMOD" -name 'omap_remoteproc.ko*' | grep -q .; then
        die "fix19: $KERNEL_REL has omap_remoteproc but ${M4_CONF#$ROOT} was not written"
    fi

    base=$(tr -dc 'a-z0-9' < "$EXTDIR/pyra-base-label" 2>/dev/null || true)
    def=$(awk '/^[[:space:]]*default /{print $2; exit}' "$EXTDIR/extlinux.conf")
    if [[ $base == "$KERNEL_SLOT" && $def == "$KERNEL_SLOT" ]]; then
        ok "fix19: $KERNEL_SLOT is already the base and the default"
    else
        chroot_mount
        in_chroot /usr/local/sbin/pyra-boot-kernel.sh base "$KERNEL_SLOT" --quiet ||
            die "fix19: pyra-boot-kernel.sh could not make $KERNEL_SLOT the base"
        in_chroot /usr/local/sbin/pyra-boot-kernel.sh stock --quiet ||
            die "fix19: pyra-boot-kernel.sh could not make $KERNEL_SLOT the default"
        ok "fix19: the card boots $KERNEL_REL ($KERNEL_SLOT is the base and the default; l0 is the stock kernel)"
    fi
    chroot_unmount
else
    warn "fix19: no kernel installed; the card boots the stock 5.6.19-pyradef"
fi

# ---------------------------------------------------------------------- fix 20
#
# On battery, MATE's power manager takes the keyboard light over: at every
# power change it replaces the level with half of its own 100 %, dims that by
# 75 % when idle, and puts its 50 % back at the next touch, so a level set with
# the Fn keys (fix 15) or an applet lasts until the next idle period. All of it
# hangs on kbd-backlight-battery-reduce (true by default); on AC the same steps
# hang on idle-dim-ac, false by default and in the image. A system override
# sets it false, so a user's own gsettings value still wins (measured
# 2026-10-31, docs/verification-log.md). The override needs the schemas
# recompiled; dpkg's glib trigger recompiles them with it after any package
# change, so no package can undo it.

KBDMATE_DST=$ROOT/$SCHEMA_DIR/$(basename "$KBDMATE_SRC")
if [[ -e $KBDMATE_DST ]] && cmp -s "$KBDMATE_SRC" "$KBDMATE_DST" &&
   [[ $ROOT/$SCHEMA_DIR/gschemas.compiled -nt $KBDMATE_DST ]]; then
    ok "fix20: ${KBDMATE_DST#$ROOT} already up to date"
else
    VERB=$([[ -e $KBDMATE_DST ]] && echo updated || echo installed)
    install -m 0644 -o 0 -g 0 "$KBDMATE_SRC" "$KBDMATE_DST"
    in_chroot glib-compile-schemas --strict "/$SCHEMA_DIR" ||
        die "fix20: glib-compile-schemas rejected the schemas with the override in place"
    ok "fix20: $VERB ${KBDMATE_DST#$ROOT} and recompiled the schemas"
fi
# Read back through the compiled schemas, with no user database in the way.
KBDMATE_VAL=$(in_chroot env GSETTINGS_BACKEND=memory \
    gsettings get org.mate.power-manager kbd-backlight-battery-reduce 2>/dev/null || true)
[[ $KBDMATE_VAL == false ]] ||
    die "fix20: kbd-backlight-battery-reduce reads '$KBDMATE_VAL' after the override, not false"
ok "fix20: MATE leaves the keyboard light alone on battery (kbd-backlight-battery-reduce false)"

# ---------------------------------------------------------------------- fix 21
#
# The SGX driver's X11 window system closes each buffer's dma-buf descriptor
# twice: libxcb closes it after sending it to X, and buffer destruction closes
# the stored number again. Whatever file got that number in between loses its
# descriptor; in Ship of Harkinian that was the log in nearly every run and once
# a save file. pyra-wsegl-fdfix.sh turns the second close() into two Thumb NOPs,
# checked against the stock and fixed SHA-256s, keeps the stock file as
# libpvrDRI3WSEGL.so.stock and replaces the library by rename. It goes onto
# the card too, for its status and rollback. dri3wsegl-pyra owns the library,
# so a reinstall of that package puts the stock build back; a dpkg post-invoke
# hook runs pyra-wsegl-guard after every package run, which re-patches it, warns
# on every run about a build it doesn't know, and leaves a rolled-back card
# alone.

if out=$("$WSEGL_FIX" --root "$ROOT" install 2>&1); then
    case $out in
    already*) ok "fix21: /usr/lib/libpvrDRI3WSEGL.so already patched" ;;
    *)        ok "fix21: patched /usr/lib/libpvrDRI3WSEGL.so (no double close); stock kept as libpvrDRI3WSEGL.so.stock" ;;
    esac
else
    die "fix21: pyra-wsegl-fdfix.sh could not patch the library:
$out"
fi
for spec in pyra-wsegl-fdfix.sh:/usr/local/sbin:0755 \
            pyra-wsegl-guard:/usr/local/sbin:0755 \
            etc/dpkg/dpkg.cfg.d/pyra-wsegl-guard:/etc/dpkg/dpkg.cfg.d:0644; do
    IFS=: read -r src dir mode <<<"$spec"
    [[ -r $PAYLOADS/$src ]] || die "fix21: $src not found (looked in $PAYLOADS)"
    dst=$ROOT$dir/$(basename "$src")
    if [[ -e $dst ]] && cmp -s "$PAYLOADS/$src" "$dst"; then
        ok "fix21: ${dst#$ROOT} already up to date"
    else
        VERB=$([[ -e $dst ]] && echo updated || echo installed)
        [[ -d $ROOT$dir ]] || install -d -m 0755 "$ROOT$dir"
        install -m "$mode" -o 0 -g 0 "$PAYLOADS/$src" "$dst"
        ok "fix21: $VERB ${dst#$ROOT}"
    fi
done

# ---------------------------------------------------------------------- fix 22
#
# MATE's brightness applet and its idle dimming both find the keyboard light
# first on the stock kernel, so the image ships MATE's screen dimming off and
# no brightness slider (procedure.md section 8). pyra-backlight names each
# device: its applet (added from the panel's "Add to Panel...") sets the screen
# and keyboard light, and pyra-idle-dim, a user service its postinst enables
# for every user, dims the screen after org.mate.session idle-delay. The image's
# dpkg installs it in the chroot; that run fires the dpkg hooks of fixes 6, 7
# and 21, which find nothing to do. Installed means that version, configured.

if [[ $BACKLIGHT_MODE == file ]]; then
    have=$(in_chroot dpkg-query -W -f='${Version} ${db:Status-Abbrev}' pyra-backlight 2>/dev/null || true)
    if [[ $have == "$BL_VER ii"* ]]; then
        ok "fix22: pyra-backlight $BL_VER already installed"
    else
        chroot_mount
        info "fix22: installing pyra-backlight $BL_VER${BL_WITH:+ and $GIR_PKG} with the image's dpkg"
        if ! out=$(in_chroot dpkg -i "${BL_WITH[@]}" "$BL_DEB" 2>&1); then
            die "fix22: dpkg -i failed in the chroot:
$out"
        fi
        chroot_unmount
        ok "fix22: installed pyra-backlight $BL_VER (was: ${have:-not installed})"
    fi
    rm -f -- "$STAGED_BACKLIGHT" ${STAGED_GIR:+"$STAGED_GIR"}
    BL_WANTS=$ROOT/etc/systemd/user/default.target.wants/pyra-idle-dim.service
    [[ -L $BL_WANTS ]] || die "fix22: pyra-idle-dim.service is not enabled for users (no ${BL_WANTS#$ROOT})"
    ok "fix22: pyra-idle-dim.service is enabled for every user; the applet is in Add to Panel"
else
    warn "fix22: pyra-backlight not installed; no brightness applet or idle dimmer"
fi

# ------------------------------------------------------------------- release
#
# Last, so nothing after it can bring back what it removes. The vendor image
# ships its ssh host keys, the same on every card written from it, so anyone
# holding one can pose as any other. Debian's ssh.service does not make keys:
# its `sshd -t` fails with none. pyra-ssh-hostkeys.service runs ssh-keygen -A
# before sshd on a card with no host key. An empty /etc/machine-id makes
# systemd write a new one on the first boot (and treat that boot as the first:
# it applies unit presets, enable-only). That also starts the image's
# systemd-firstboot.service, which prompts on tty1 before sysinit.target for
# whatever of locale, keymap, timezone and root password it finds unset; a
# vendor card never runs it (its machine-id is set), so it is masked. The
# random seed and the credential secret would also be the same on every card;
# systemd makes them when missing.

if [[ $RELEASE == yes ]]; then
    HOSTKEYS_UNIT=$ROOT/etc/systemd/system/pyra-ssh-hostkeys.service
    if [[ -e $HOSTKEYS_UNIT ]] && cmp -s "$HOSTKEYS_UNIT_SRC" "$HOSTKEYS_UNIT"; then
        ok "release: ${HOSTKEYS_UNIT#$ROOT} already up to date"
    else
        install -m 0644 -o 0 -g 0 "$HOSTKEYS_UNIT_SRC" "$HOSTKEYS_UNIT"
        ok "release: installed ${HOSTKEYS_UNIT#$ROOT}"
    fi
    if [[ -L $WANTS/pyra-ssh-hostkeys.service ]]; then
        ok "release: pyra-ssh-hostkeys.service already enabled in multi-user.target"
    else
        ln -sf /etc/systemd/system/pyra-ssh-hostkeys.service "$WANTS/pyra-ssh-hostkeys.service"
        ok "release: enabled pyra-ssh-hostkeys.service in multi-user.target"
    fi

    KEYS=$(compgen -G "$ROOT/etc/ssh/ssh_host_*" || true)
    if [[ -n $KEYS ]]; then
        rm -f -- $KEYS
        ok "release: removed $(wc -l <<<"$KEYS") ssh host key files; the first boot makes new ones"
    else
        ok "release: no ssh host keys in the image"
    fi

    MID=$ROOT/etc/machine-id
    if [[ -f $MID && ! -s $MID ]]; then
        ok "release: /etc/machine-id already empty"
    else
        rm -f -- "$MID"
        install -m 0444 -o 0 -g 0 /dev/null "$MID"
        ok "release: emptied /etc/machine-id; the first boot writes a new one"
    fi
    # D-Bus reads its own copy if there is one; Debian makes it a link.
    DMID=$ROOT/var/lib/dbus/machine-id
    if [[ -e $DMID && ! -L $DMID ]]; then
        rm -f -- "$DMID"
        ln -s /etc/machine-id "$DMID"
        ok "release: /var/lib/dbus/machine-id is now a link to /etc/machine-id"
    else
        ok "release: /var/lib/dbus/machine-id is $([[ -L $DMID ]] && echo "a link to $(readlink "$DMID")" || echo absent)"
    fi

    FB=$ROOT/etc/systemd/system/systemd-firstboot.service
    if [[ $(readlink "$FB" 2>/dev/null) == /dev/null ]]; then
        ok "release: systemd-firstboot.service already masked"
    else
        rm -f -- "$FB"
        ln -s /dev/null "$FB"
        ok "release: masked systemd-firstboot.service, so the first boot asks nothing on the console"
    fi

    for f in /var/lib/systemd/random-seed /var/lib/systemd/credential.secret; do
        if [[ -e $ROOT$f ]]; then
            rm -f -- "$ROOT$f"
            ok "release: removed $f"
        else
            ok "release: no $f in the image"
        fi
    done
fi

echo
sync
ok "done — unmount cleanly, then hold the power button until BOTH LEDs go green."
