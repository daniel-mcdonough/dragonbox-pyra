#!/bin/bash
#
# pyra-install-debug-kernel.sh — install 5.6.19-softlockup beside the stock
# kernel, on the Pyra, and add a boot menu entry for it.
#
#   sudo ./pyra-install-debug-kernel.sh [/path/to/softlockup-kernel.tar.gz]
#
# Nothing here touches the stock kernel, its modules, its dtbs or its initrd,
# and `default l0` is left alone, so the stock kernel stays what you get by
# doing nothing. The debug kernel is chosen from the 30 second menu at each
# boot, which means a bad one is a power cycle away from gone.
#
# Run it again to reinstall; every step is idempotent.
#
set -euo pipefail

REL=5.6.19-softlockup
TARBALL=${1:-/home/pyra/softlockup-kernel.tar.gz}
CFG=/boot/extlinux/user.cfg
STOCK=/boot/extlinux/linux.cfg

[ "$(id -u)" = 0 ] || { echo "run this with sudo" >&2; exit 2; }

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
say "checking this is the right machine"
[ -f "$TARBALL" ]  || die "no tarball at $TARBALL"
[ -f "$STOCK" ]    || die "no $STOCK — this is not an extlinux Pyra card"
[ -L /lib ]        || die "/lib is not a symlink; this rootfs is already broken"
grep -q '^default l0' /boot/extlinux/extlinux.conf \
                   || die "extlinux.conf does not default to l0; refusing to guess"
echo "  running $(uname -r), installing $REL beside it"

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

say "checking there is room in /boot"
need=$(( $(gzip -l "$TARBALL" | awk 'NR==2{print $2}') / 1024 / 1024 + 30 ))
free=$(df -Pm /boot | awk 'NR==2{print $4}')
echo "  need about ${need} MB including the initrd, have ${free} MB"
[ "$free" -gt "$need" ] || die "not enough space in /boot"

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
	menu label trixie, kernel $REL (lockup detector)
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
grep -q "^default l0" /boot/extlinux/extlinux.conf \
        && echo "  ok   default is still l0, the stock kernel" || fail=1
[ -L /lib ] && echo "  ok   /lib -> $(readlink /lib)" || fail=1

echo
echo "--- $CFG now reads ---"
cat "$CFG"
echo "----------------------"
df -h /boot | tail -1

[ "$fail" = 0 ] || die "one of the checks above did not pass"

cat <<EOF

Done. Reboot and pick "trixie, kernel $REL (lockup detector)" from the
30 second menu. Doing nothing boots the stock kernel, as before.

Once it is up, confirm with:

    uname -r                                    # expect $REL
    cat /proc/sys/kernel/softlockup_panic        # expect 0
    cat /proc/sys/kernel/hung_task_timeout_secs  # expect 30

To undo it entirely:

    sudo rm -rf /boot/{vmlinuz,initrd.img,System.map,config}-$REL \\
                /boot/dtb/linux-image-$REL /usr/lib/modules/$REL
    sudo truncate -s 0 $CFG
EOF
