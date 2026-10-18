#!/bin/bash
#
# pyra-boot-kernel.sh — choose which kernel the Pyra boots next.
#
#   sudo pyra-boot-kernel.sh status
#   sudo pyra-boot-kernel.sh debug --once     # next boot only, then back to base
#   sudo pyra-boot-kernel.sh debug            # every boot until told otherwise
#   sudo pyra-boot-kernel.sh stock            # back to the base kernel
#   sudo pyra-boot-kernel.sh base             # which kernel is the base
#   sudo pyra-boot-kernel.sh base l3          # make that one the base
#
# THE BASE KERNEL
#
# "stock" used to mean l0 and nothing else, because l0 was the only kernel
# anyone wanted to come back to. That stopped being true: the distro kernel
# has a thermal problem that stops the battery charging much of the time, so
# the machine's everyday kernel is now the frequency one, and reverting to l0
# after a test boot would strand it on a kernel that will not charge.
#
# So the revert target is configurable. `base` sets it, the one-shot revert
# returns to it, and `stock` -- kept under its old name so existing habits and
# the systemd unit keep working -- means "back to the base". It is stored in
# /boot, beside extlinux.conf, because the revert service runs early and /boot
# is the one filesystem it is guaranteed to have.
#
# WHY THIS EXISTS
#
# The documented way to run a test kernel is to add a second extlinux entry,
# leave `default` on the stock kernel, and pick the test entry from the boot
# menu. On this machine there is no boot menu to pick from. U-Boot 2016.11 on
# the Pyra has no display driver at all — grep its image for "vidconsole" or
# "panel" and nothing comes back — so the menu is written to the serial console
# at ttyO2 and never reaches the LCD. There is no USB keyboard driver in it
# either. Without a serial cable the menu cannot be seen or answered, and
# `timeout 30` is thirty tenths of a second, so it is gone in three seconds.
#
# So the only way to boot a test kernel here is to make it the default, which
# removes the safety net the menu was providing. `--once` puts a different one
# in its place: it arms a service that sets the default back to the stock
# kernel early in the next boot, before the desktop comes up. A test kernel
# that boots therefore gets exactly one boot. A test kernel that does not reach
# userspace at all is the case nothing on the device can cover; recover it by
# putting the card in a PC and changing one word in
# /boot/extlinux/extlinux.conf.
#
# extlinux.conf says it is generated and must not be edited by hand. On this
# system it will not be: `extlinux-update` is not installed and there is no
# /etc/default/extlinux, so nothing regenerates it.
#
set -euo pipefail

CONF=/boot/extlinux/extlinux.conf
UNIT=/etc/systemd/system/pyra-boot-revert.service
SELF=/usr/local/sbin/pyra-boot-kernel.sh
BASE_FILE=/boot/extlinux/pyra-base-label
DEFAULT_BASE=l0
DEBUG_LABEL=l1

# Read on every run rather than cached at install time, so the revert service
# picks up a change without being rewritten.
read_base() {
        local b=""
        [ -r "$BASE_FILE" ] && b=$(tr -dc 'a-z0-9' < "$BASE_FILE")
        [ -n "$b" ] || b=$DEFAULT_BASE
        printf '%s' "$b"
}
STOCK_LABEL=$(read_base)

QUIET=0
ACTION=${1:-status}
ONCE=0
for a in "${@:2}"; do
        case "$a" in
        --once)  ONCE=1 ;;
        --quiet) QUIET=1 ;;
        # `base <label>` takes a positional argument; everything else does not.
        *) [ "$ACTION" = base ] || { echo "unknown option: $a" >&2; exit 2; } ;;
        esac
done

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
die() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run this with sudo"
[ -f "$CONF" ] || die "no $CONF"

current_label() { awk '/^default /{print $2; exit}' "$CONF"; }

label_exists() {
        grep -qx "label $1" /boot/extlinux/linux.cfg /boot/extlinux/user.cfg 2>/dev/null
}

describe() {
        local l=$1
        awk -v want="label $l" '
                $0 == want {f=1; next}
                f && /menu label /{sub(/^[[:space:]]*menu label /,""); print; exit}
        ' /boot/extlinux/linux.cfg /boot/extlinux/user.cfg 2>/dev/null
}

set_default() {
        local l=$1
        label_exists "$l" || die "there is no 'label $l' in linux.cfg or user.cfg"
        [ -f "$CONF.orig" ] || cp -a "$CONF" "$CONF.orig"
        sed -i "s/^default .*/default $l/" "$CONF"
        [ "$(current_label)" = "$l" ] || die "the default did not change"
        sync
}

write_unit() {
        cat > "$UNIT" <<EOF
[Unit]
Description=Return the extlinux default to the base kernel
Documentation=man:pyra-boot-kernel.sh
DefaultDependencies=no
RequiresMountsFor=/boot
After=local-fs.target
Before=sysinit.target
ConditionPathExists=$SELF

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF stock --quiet

[Install]
WantedBy=sysinit.target
EOF
        systemctl daemon-reload
}

status() {
        local cur armed
        cur=$(current_label)
        # Three things can come back here and only one of them is an exit
        # status of 0. "enabled" means armed. "disabled" is what the unit
        # reports after it has fired and turned itself off, and "not-found"
        # is a machine that never armed it; both exit 1, and under
        # `set -e` with pipefail that used to kill this function before it
        # printed anything at all.
        armed=$(systemctl is-enabled pyra-boot-revert.service 2>/dev/null | head -1) || true
        [ "$armed" = enabled ] || armed=disarmed
        echo "running now      : $(uname -r)"
        echo "next boot        : $cur — $(describe "$cur")"
        echo "base kernel      : $STOCK_LABEL — $(describe "$STOCK_LABEL")"
        echo "one-shot revert  : $armed"
        if [ "$cur" = "$DEBUG_LABEL" ] && [ "$armed" = enabled ]; then
                echo
                echo "So the next boot uses the test kernel, and the boot after that"
                echo "is back on $(describe "$STOCK_LABEL") without you doing anything."
        elif [ "$cur" = "$DEBUG_LABEL" ]; then
                echo
                echo "So every boot uses the test kernel until you run: $0 stock"
        fi
}

case "$ACTION" in
debug)
        # The revert unit runs $SELF, and is conditional on it existing. Run
        # from anywhere else -- an unpacked kit, a checkout -- and the unit
        # would arm, report itself enabled, and then silently skip at boot,
        # leaving the test kernel as the default with nobody told. Refuse
        # before anything is changed.
        if [ "$ONCE" = 1 ] && [ ! -x "$SELF" ]; then
                die "--once needs this script installed where the revert service runs it:
    sudo install -m 0755 '$0' $SELF
and then: sudo $SELF debug --once"
        fi
        set_default "$DEBUG_LABEL"
        if [ "$ONCE" = 1 ]; then
                write_unit
                systemctl enable pyra-boot-revert.service >/dev/null 2>&1
                say "armed: the next boot uses $(describe "$DEBUG_LABEL")"
                say "and the one after it is back on $(describe "$STOCK_LABEL") automatically."
        else
                systemctl disable pyra-boot-revert.service >/dev/null 2>&1 || true
                say "set: every boot uses $(describe "$DEBUG_LABEL") until you run '$0 stock'."
        fi
        ;;
stock)
        set_default "$STOCK_LABEL"
        # When the revert service itself is the caller, early in boot, leave the
        # unit alone. It is idempotent: on a stock boot it sets l0 to l0. Only a
        # person running this by hand disarms it.
        if [ "$QUIET" = 0 ]; then
                systemctl disable pyra-boot-revert.service >/dev/null 2>&1 || true
        fi
        say "set: booting $(describe "$STOCK_LABEL")"
        ;;
base)
        # `base` with no label reports; with one, sets it.
        want=${2:-}
        case "$want" in ""|--*) want="" ;; esac
        if [ -z "$want" ]; then
                echo "base kernel: $STOCK_LABEL — $(describe "$STOCK_LABEL")"
                exit 0
        fi
        label_exists "$want" || die "there is no 'label $want' in linux.cfg or user.cfg"
        [ "$want" = "$DEBUG_LABEL" ] && die "$DEBUG_LABEL is the test slot; installing a
test kernel would silently change what the machine falls back to. Put the
kernel you want as a base in its own entry first."
        printf '%s\n' "$want" > "$BASE_FILE"
        sync
        STOCK_LABEL=$(read_base)
        say "base kernel is now $STOCK_LABEL — $(describe "$STOCK_LABEL")"
        say "the one-shot revert and '$0 stock' will return here from now on."
        ;;
status)
        status
        ;;
*)
        echo "usage: $0 {status|debug [--once]|stock|base [label]}" >&2
        exit 2
        ;;
esac

[ "$QUIET" = 1 ] || [ "$ACTION" = status ] || { echo; status; }
