#!/bin/bash
#
# pyra-install-debug-kernel.sh — install a test kernel beside the stock one,
# on the Pyra, and give it a boot entry.
#
#   sudo ./pyra-install-debug-kernel.sh [/path/to/something-kernel.tar.gz]
#   sudo ./pyra-install-debug-kernel.sh --slot l5 m4-kbdled-kernel.tar.gz
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
# By default it writes the test slot, `l1`. Installing a second test kernel
# points that slot at the new one; the older kernel's files stay in /boot but
# drop out of the boot configuration.
#
# `--slot LABEL` writes that entry of user.cfg instead, and leaves `l1` and
# every other entry alone. That is how a card gets a base kernel and a
# fallback from this script alone: install each into its own slot, then name
# the base with `pyra-boot-kernel.sh base LABEL`. A slot that already exists
# is replaced where it stands; a new one is added at the end. `l0` and any
# other label in linux.cfg cannot be a slot: that file is the distro's.
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
SLOT=l1

while [ $# -gt 0 ]; do
	case $1 in
	--replace-running) REPLACE_RUNNING=yes; shift ;;
	--slot)            [ $# -ge 2 ] || { echo "--slot needs a label" >&2; exit 2; }
	                   SLOT=$2; shift 2 ;;
	--slot=*)          SLOT=${1#--slot=}; shift ;;
	-h|--help)         sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \?//'; exit 0 ;;
	-*)                echo "unknown option: $1" >&2; exit 2 ;;
	*)                 [ -z "$TARBALL" ] || { echo "one tarball at a time" >&2; exit 2; }
	                   TARBALL=$1; shift ;;
	esac
done
CFG=/boot/extlinux/user.cfg
STOCK=/boot/extlinux/linux.cfg

[ "$(id -u)" = 0 ] || { echo "run this with sudo" >&2; exit 2; }
# The same characters pyra-boot-kernel.sh keeps when it reads the base label,
# so any slot written here can be named as the base.
case $SLOT in
''|*[!a-z0-9]*) echo "--slot '$SLOT': a label is lower-case letters and digits, like l5" >&2
                exit 2 ;;
esac

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
grep -qx "label $SLOT" "$STOCK" && die "$SLOT is an entry in $STOCK, the distro's file.
Pick a slot that is not there; 'grep ^label $STOCK $CFG' lists what is taken."
# Two defaults are expected here and no others. l0 is the stock kernel, which
# is how a machine that has never had a test kernel is set up. l1 is the test
# slot, which is what pyra-boot-kernel.sh selects and which this script is
# about to repoint at a different kernel. Anything else is a boot
# configuration this script did not write and should not edit.
# The machine's everyday kernel is no longer always l0: pyra-boot-kernel.sh
# can name another entry as the base, and does on this machine because the
# distro kernel's thermal behaviour stops the battery charging. So the
# acceptable defaults are the test slot and whatever the base currently is.
BASE=l0
[ -r /boot/extlinux/pyra-base-label ] &&
        BASE=$(tr -dc 'a-z0-9' < /boot/extlinux/pyra-base-label)
[ -n "$BASE" ] || BASE=l0

# With --slot, the slot being written is acceptable too: replacing what the
# default points at is the same thing the plain l1 case already does.
DEFAULT=$(awk '/^[[:space:]]*default /{print $2; exit}' /boot/extlinux/extlinux.conf)
case "$DEFAULT" in
"$SLOT") echo "  default is $SLOT, the slot this install repoints, so the next boot runs it" ;;
l1)     echo "  default is l1, the test slot; this install writes $SLOT and leaves l1 alone" ;;
"$BASE") echo "  default is $BASE, the base kernel; this install does not change what boots" ;;
*)      die "extlinux.conf defaults to '${DEFAULT:-nothing}', which is neither the test
slot l1 nor the base kernel $BASE. Refusing to guess. Put it back with
'pyra-boot-kernel.sh stock' and try again." ;;
esac
echo "  running $(uname -r), installing $REL beside it into slot $SLOT, from $TARBALL"
[ "$SLOT" = "$BASE" ] && echo "  $SLOT is the base kernel: the one-shot revert and 'pyra-boot-kernel.sh stock'
  will return to $REL from now on"

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
# A rebuild of an installed release overwrites that release's own files, so
# they are space this install gets back, not space it needs on top. The old
# initrd is not credited: it stays until the new one has been written.
# Without this, a same-name rebuild was refused with room to spare.
if [ -f "/boot/vmlinuz-$REL" ]; then
	boot_have=$(du -cm "/boot/vmlinuz-$REL" "/boot/System.map-$REL" \
		"/boot/config-$REL" "/boot/dtb/linux-image-$REL" 2>/dev/null |
		awk 'END{print $1}')
	echo "  $REL is already installed; its ${boot_have} MB in /boot is overwritten"
	boot_need=$(( boot_need - boot_have ))
fi
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

# A kernel with the M4 work carries omap_remoteproc as a module, and udev loads
# it at boot from the device tree modalias. remoteproc sets auto_boot and the
# omap driver never clears it, so the day omap5-ipu-fw.xem4 is in /lib/firmware
# both M4s start on every boot with nothing typed. The blacklist stops only that
# autoload; an explicit `modprobe omap_remoteproc`, which the M4 scripts do,
# still works. Written before the initrd so the initrd's copy of modprobe.d
# agrees. Kernels without the module need nothing, so nothing is written.
M4_CONF=/etc/modprobe.d/pyra-m4-noautoboot.conf
if find "/usr/lib/modules/$REL" -name 'omap_remoteproc.ko*' | grep -q .; then
	say "keeping the M4s from starting at boot"
	cat > "$M4_CONF" <<'EOF'
# Written by pyra-install-debug-kernel.sh. Stops udev loading omap_remoteproc
# at boot, which with auto_boot would start both Cortex-M4s whenever
# /lib/firmware/omap5-ipu-fw.xem4 exists. `modprobe omap_remoteproc` still
# loads it on request; the M4 scripts do that themselves.
blacklist omap_remoteproc
EOF
	echo "  wrote $M4_CONF"
fi

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

if [ -s "$CFG" ] && ! grep -qx "label $SLOT" "$CFG"; then
        cp -a "$CFG" "$CFG.before-$REL"
        echo "  kept your existing $CFG as $CFG.before-$REL"
fi

# The kernel this slot booted until now. If no other entry boots it, it is
# about to lose its last entry; say so, since its files stay in /boot.
slot_kernel() {  # slot_kernel <label>: the linux line of that entry in $CFG
	awk -v want="label $1" '$0 == want {f=1; next} /^label /{f=0}
		f && /^[[:space:]]*linux /{print $2; exit}' "$CFG" 2>/dev/null
}
# other_entries <label> <kernel>: the entries other than <label>, in either
# file, whose linux line is <kernel>, space-separated.
other_entries() {
	awk -v want="label $1" -v k="$2" 'FNR == 1 {l = ""} /^label /{l=$0}
		l != want && /^[[:space:]]*linux / && $2 == k {print substr(l, 7)}' \
		"$CFG" "$STOCK" 2>/dev/null | sort -u | tr '\n' ' '
}
OLD=$(slot_kernel "$SLOT")
if [ -n "$OLD" ] && [ "$OLD" != "/vmlinuz-$REL" ]; then
	others=$(other_entries "$SLOT" "$OLD")
	if [ -n "$others" ]; then
		echo "  $SLOT booted $OLD; ${others% } still boots it"
	else
		echo "  $SLOT booted $OLD, and no other entry does: its files stay in /boot"
		echo "  without a boot entry"
	fi
fi

# Rewrite rather than append, so running this twice does not stack entries.
# The slot's old block is replaced where it stood, so the other entries keep
# their order; a slot that was not there yet goes at the end.
# The card's own release name, so a bookworm card does not say trixie.
CODENAME=$( . /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-debian}")
entry=$(mktemp)
cat > "$entry" <<EOF
label $SLOT
	menu label $CODENAME, kernel $REL
	linux /vmlinuz-$REL
	append $APPEND
	fdtdir /dtb/linux-image-$REL
	initrd /initrd.img-$REL
EOF
tmp=$(mktemp)
[ -e "$CFG" ] || : > "$CFG"
awk -v want="label $SLOT" -v entry="$entry" '
	function emit(  line) { while ((getline line < entry) > 0) print line; done = 1 }
	$0 == want { skip = 1; emit(); next }
	/^label / { skip = 0 }
	!skip
	END { if (!done) emit() }' "$CFG" > "$tmp"
[ "$(grep -cx "label $SLOT" "$tmp")" = 1 ] || die "the rewritten $CFG does not have exactly one $SLOT entry; $CFG is unchanged"
cat "$tmp" > "$CFG"
rm -f "$tmp" "$entry"

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
"$SLOT") echo "  ok   default is $SLOT, which now points at $REL" ;;
l1)      echo "  ok   default is l1, the test slot, which this install left alone" ;;
"$BASE") echo "  ok   default is $BASE, the base kernel; nothing about the next boot changed" ;;
*)       echo "  BAD  default is now '$now'"; fail=1 ;;
esac
[ -L /lib ] && echo "  ok   /lib -> $(readlink /lib)" || fail=1
if [ -f "$M4_CONF" ]; then
	grep -qx 'blacklist omap_remoteproc' "$M4_CONF" &&
		echo "  ok   $M4_CONF: omap_remoteproc loads only on request" || fail=1
fi

echo
echo "--- $CFG now reads ---"
cat "$CFG"
echo "----------------------"
df -h /boot | tail -1

[ "$fail" = 0 ] || die "one of the checks above did not pass"

# Branch on the slot, not on l0: the base is not always l0 any more, and
# treating every other default as l1 told the user a base-kernel install would
# reboot into the new one when it would not.
if [ "$SLOT" != l1 ] && [ "$now" != "$SLOT" ]; then
        NEXT="$SLOT now boots $REL. The default is still $now, so rebooting gets you
that kernel. Try $SLOT for one boot, or make it the base every boot uses:

    sudo pyra-boot-kernel.sh debug $SLOT --once  # one boot, then back to the base
    sudo pyra-boot-kernel.sh base $SLOT && sudo pyra-boot-kernel.sh stock

Falling back is the same two commands with the other kernel's slot."
elif [ "$now" != "$SLOT" ]; then
        NEXT="The default is still $now, so rebooting now gets you that kernel.
Choose the new one with

    sudo pyra-boot-kernel.sh debug --once        # one boot, then back to stock
    sudo pyra-boot-kernel.sh debug               # until you say otherwise"
else
        NEXT="The default is $SLOT, the slot this install just repointed, so the next
reboot runs $REL. Change your mind with

    sudo pyra-boot-kernel.sh stock               # back to the stock kernel
    sudo pyra-boot-kernel.sh status              # check before rebooting"
fi

UNBASE=
[ "$SLOT" != "$BASE" ] || UNBASE="    sudo pyra-boot-kernel.sh base <another label>  # $SLOT is the base now
"

cat <<EOF

Done. $NEXT

Once it is up, confirm with:

    uname -r                                    # expect $REL
    cat /proc/sys/kernel/softlockup_panic        # expect 0
    cat /proc/sys/kernel/hung_task_timeout_secs  # expect 30

To undo it entirely: boot away from $SLOT, drop only the $SLOT entry (the other
labels in $CFG, the default among them, stay), then remove the files:

${UNBASE}    sudo pyra-boot-kernel.sh stock
    sudo sed -i '/^label $SLOT\$/,/^label /{/^label $SLOT\$/d;/^label /!d}' $CFG
EOF
# Another entry booting the same release shares these files; removing them
# would leave that entry pointing at nothing.
shared=$(other_entries "$SLOT" "/vmlinuz-$REL")
if [ -n "$shared" ]; then
	cat <<EOF

but do not remove the files while ${shared% } boots $REL too.
EOF
else
	cat <<EOF
    sudo rm -rf /boot/{vmlinuz,initrd.img,System.map,config}-$REL \\
                /boot/dtb/linux-image-$REL /usr/lib/modules/$REL
EOF
fi
