#!/bin/bash
#
# pyra-install-debug-kernel.sh — install a test kernel beside the stock one,
# on the Pyra, and give it a boot entry.
#
#   sudo ./pyra-install-debug-kernel.sh [/path/to/something-kernel.tar.gz]
#
# Either of the tarballs `pyra-crossbuild.sh` produces will do:
# `softlockup-kernel.tar.gz` or `fix-kernel.tar.gz`. The release name is read
# out of the tarball rather than assumed, so there is nothing to keep in sync.
#
# Nothing here touches the stock kernel, its modules, its dtbs or its initrd,
# and `default l0` is left alone, so the stock kernel stays what you get by
# doing nothing. There is no boot menu on this machine — U-Boot has no display
# driver, so the menu only exists over the serial console — which is why
# `pyra-boot-kernel.sh` exists to choose between the two.
#
# There is one test slot, `l1`. Installing a second test kernel points that
# slot at the new one; the older kernel's files stay in /boot but drop out of
# the boot configuration.
#
# Run it again to reinstall; every step is idempotent. It will not install
# over the kernel you are currently running, to avoid replacing a live module
# tree; boot the stock kernel first if you need to redo one.
#
#   sudo ./pyra-install-debug-kernel.sh --replace-running fix-kernel.tar.gz
#
# overrides that, which is what you want while iterating on patches: a rebuilt
# kernel keeps the same release name, so every reinstall collides with the one
# you are running. The cost is that /lib/modules for the running release is
# replaced underneath you, so any module loaded between now and the reboot
# comes from the new tree. Reboot promptly, and do not use it to install a
# kernel built from different sources than the one running.
#
set -euo pipefail

TARBALL=
REPLACE_RUNNING=no

while [ $# -gt 0 ]; do
	case $1 in
	--replace-running) REPLACE_RUNNING=yes; shift ;;
	-h|--help)         sed -n '3,33p' "$0" | sed 's/^# \?//'; exit 0 ;;
	-*)                echo "unknown option: $1" >&2; exit 2 ;;
	*)                 [ -z "$TARBALL" ] || { echo "one tarball at a time" >&2; exit 2; }
	                   TARBALL=$1; shift ;;
	esac
done
CFG=/boot/extlinux/user.cfg
STOCK=/boot/extlinux/linux.cfg

[ "$(id -u)" = 0 ] || { echo "run this with sudo" >&2; exit 2; }

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

# With no argument, find the tarball, but only if there is exactly one. Two
# candidates is a question for the operator, not something to guess at.
if [ -z "$TARBALL" ]; then
        found=$(ls -1 /home/pyra/*-kernel.tar.gz 2>/dev/null || true)
        case $(printf '%s' "$found" | grep -c .) in
        1) TARBALL=$found ;;
        0) die "no *-kernel.tar.gz in /home/pyra; name one on the command line" ;;
        *) die "more than one tarball in /home/pyra; name the one you want:
$found" ;;
        esac
fi

# ---------------------------------------------------------------- preflight
say "checking this is the right machine"
[ -f "$TARBALL" ]  || die "no tarball at $TARBALL"

# The release name is whatever the tarball's kernel image is called.
REL=$(tar tzf "$TARBALL" | sed -n 's|^\./boot/vmlinuz-||p' | head -1)
[ -n "$REL" ] || die "$TARBALL has no ./boot/vmlinuz-* in it; is it a kernel tarball?"
if [ "$REL" = "$(uname -r)" ]; then
	[ "$REPLACE_RUNNING" = yes ] || die "$REL is already the running kernel.
  Boot the stock kernel first, or pass --replace-running if this is a rebuild
  of the same sources and you intend to reboot straight afterwards."
	say "replacing the running kernel's own files, as asked"
	echo "  /lib/modules/$REL is about to be overwritten while you are running from it."
	echo "  Reboot as soon as this finishes."
fi
[ -f "$STOCK" ]    || die "no $STOCK — this is not an extlinux Pyra card"
[ -L /lib ]        || die "/lib is not a symlink; this rootfs is already broken"
# Two defaults are expected here and no others. l0 is the stock kernel, which
# is how a machine that has never had a test kernel is set up. l1 is the test
# slot, which is what pyra-boot-kernel.sh selects and which this script is
# about to repoint at a different kernel. Anything else is a boot
# configuration this script did not write and should not edit.
DEFAULT=$(awk '/^[[:space:]]*default /{print $2; exit}' /boot/extlinux/extlinux.conf)
case "$DEFAULT" in
l0)     echo "  default is l0, the stock kernel; this install does not change what boots" ;;
l1)     echo "  default is l1, the test slot, and this install repoints it." ;;
*)      die "extlinux.conf defaults to '${DEFAULT:-nothing}', which is neither the stock
entry l0 nor the test slot l1. Refusing to guess. Put it back with
'pyra-boot-kernel.sh stock' and try again." ;;
esac
echo "  running $(uname -r), installing $REL beside it, from $TARBALL"

# The tarball must not carry a ./lib/ entry. trixie is usr-merged, /lib is a
# symlink to usr/lib, and GNU tar extracting a ./lib/ DIRECTORY entry deletes
# that symlink and puts a real directory there. Every binary then loses its
# ELF interpreter and nothing on the system can start, including the shell you
# would need to repair it. This happened once already, on 2026-09-10.
say "checking the tarball cannot destroy /lib"
if tar tzf "$TARBALL" | grep -qx "./lib/"; then
        die "the tarball contains a ./lib/ entry. Do not extract it."
fi
echo "  no ./lib/ entry; top level is: $(tar tzf "$TARBALL" | awk -F/ 'NF>2{print $2}' | sort -u | tr '\n' ' ')"

say "checking there is room"
# Measured per destination, because the two halves of the tarball land on
# different filesystems: ./boot/ on the /boot partition, ./usr/lib/modules on
# the root one. This used to charge /boot for the whole uncompressed tarball,
# which on a machine with 74 MB free in /boot refused an install that needed
# 17 MB there -- the other 36 MB were modules that were never going to /boot
# at all. Undersized by design in the other direction, too: nothing checked
# that the root filesystem could hold the modules.
tarsize() {  # tarsize <top-level dir>
	tar tzvf "$TARBALL" | awk -v d="$1" '
		{ n = $NF; sub(/^\.\//, "", n)
		  if (index(n, d "/") == 1) s += $3 }
		END { printf "%d", (s + 0) / 1024 / 1024 }'
}
boot_need=$(( $(tarsize boot) + 30 ))   # +30 for the initrd this builds
root_need=$(( $(tarsize usr) + 5 ))
boot_free=$(df -Pm /boot | awk 'NR==2{print $4}')
root_free=$(df -Pm /usr/lib/modules | awk 'NR==2{print $4}')
echo "  /boot           need about ${boot_need} MB including the initrd, have ${boot_free} MB"
echo "  /usr/lib/modules need about ${root_need} MB, have ${root_free} MB"
[ "$boot_free" -gt "$boot_need" ] || die "not enough space in /boot.
Kernels that have dropped out of the boot configuration still keep their
files here; 'ls /boot' and compare against
'grep linux /boot/extlinux/extlinux.conf /boot/extlinux/user.cfg'."
[ "$root_free" -gt "$root_need" ] || die "not enough space for the modules"

# ---------------------------------------------------------------- install
say "extracting"
tar xzf "$TARBALL" -C / --keep-directory-symlink
[ -L /lib ] || die "/lib stopped being a symlink during extraction. Do not reboot.
Repair it from another machine before doing anything else."
[ -f "/boot/vmlinuz-$REL" ]            || die "no /boot/vmlinuz-$REL after extraction"
[ -d "/usr/lib/modules/$REL" ]         || die "no modules for $REL after extraction"
[ -d "/boot/dtb/linux-image-$REL" ]    || die "no dtbs for $REL after extraction"
echo "  /lib is still a symlink to $(readlink /lib)"

say "building the module dependency tables"
depmod -a "$REL"

say "building the initrd against this machine's userspace"
update-initramfs -c -k "$REL"
[ -f "/boot/initrd.img-$REL" ] || die "no initrd was produced"

# ---------------------------------------------------------------- boot entry
# The append line is copied verbatim from the stock l0 entry rather than
# retyped, so the debug kernel gets exactly the arguments the working kernel
# gets. Only the three paths differ.
say "adding the boot menu entry"
APPEND=$(awk '/^label l0$/{f=1} f&&/^[[:space:]]*append /{sub(/^[[:space:]]*append /,""); print; exit}' "$STOCK")
[ -n "$APPEND" ] || die "could not read the stock append line from $STOCK"

if [ -s "$CFG" ] && ! grep -q "^label l1$" "$CFG"; then
        cp -a "$CFG" "$CFG.before-$REL"
        echo "  kept your existing $CFG as $CFG.before-$REL"
fi

# Rewrite rather than append, so running this twice does not stack entries.
tmp=$(mktemp)
if [ -s "$CFG" ]; then
        awk '/^label l1$/{skip=1} /^label /&&!/^label l1$/{skip=0} !skip' "$CFG" > "$tmp"
fi
{
        cat <<EOF
label l1
	menu label trixie, kernel $REL
	linux /vmlinuz-$REL
	append $APPEND
	fdtdir /dtb/linux-image-$REL
	initrd /initrd.img-$REL
EOF
} >> "$tmp"
cat "$tmp" > "$CFG"
rm -f "$tmp"

# ---------------------------------------------------------------- verify
say "verifying"
fail=0
for f in "/boot/vmlinuz-$REL" "/boot/initrd.img-$REL"; do
        if [ -f "$f" ]; then echo "  ok   $f ($(du -h "$f" | cut -f1))"
        else echo "  MISSING $f"; fail=1; fi
done
n=$(ls "/boot/dtb/linux-image-$REL"/*.dtb 2>/dev/null | wc -l)
echo "  ok   /boot/dtb/linux-image-$REL ($n dtbs)"
[ "$n" -gt 0 ] || fail=1
echo "  ok   /usr/lib/modules/$REL ($(find "/usr/lib/modules/$REL" -name '*.ko' | wc -l) modules)"
now=$(awk '/^[[:space:]]*default /{print $2; exit}' /boot/extlinux/extlinux.conf)
case "$now" in
l0)     echo "  ok   default is l0, the stock kernel; nothing about the next boot changed" ;;
l1)     echo "  ok   default is l1, the test slot, which now points at $REL" ;;
*)      echo "  BAD  default is now '$now'"; fail=1 ;;
esac
[ -L /lib ] && echo "  ok   /lib -> $(readlink /lib)" || fail=1

echo
echo "--- $CFG now reads ---"
cat "$CFG"
echo "----------------------"
df -h /boot | tail -1

[ "$fail" = 0 ] || die "one of the checks above did not pass"

if [ "$now" = l0 ]; then
        NEXT="The default is still l0, so rebooting now gets you the stock kernel.
Choose the new one with

    sudo pyra-boot-kernel.sh debug --once        # one boot, then back to stock
    sudo pyra-boot-kernel.sh debug               # until you say otherwise"
else
        NEXT="The default is l1, the slot this install just repointed, so the next
reboot runs $REL. Change your mind with

    sudo pyra-boot-kernel.sh stock               # back to the stock kernel
    sudo pyra-boot-kernel.sh status              # check before rebooting"
fi

cat <<EOF

Done. $NEXT

Once it is up, confirm with:

    uname -r                                    # expect $REL
    cat /proc/sys/kernel/softlockup_panic        # expect 0
    cat /proc/sys/kernel/hung_task_timeout_secs  # expect 30

To undo it entirely:

    sudo rm -rf /boot/{vmlinuz,initrd.img,System.map,config}-$REL \\
                /boot/dtb/linux-image-$REL /usr/lib/modules/$REL
    sudo truncate -s 0 $CFG
EOF
