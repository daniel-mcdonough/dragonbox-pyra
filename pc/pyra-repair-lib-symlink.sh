#!/bin/bash
#
# pyra-repair-lib-symlink.sh — put back the /lib symlink that a tar extraction
# destroyed. Runs on the PC, with the Pyra's card mounted. The Pyra cannot fix
# itself: with /lib gone, no dynamically linked binary can start, which is
# every binary on the system.
#
#   sudo ./pyra-repair-lib-symlink.sh /mnt/pyra
#
# WHAT HAPPENED: Debian trixie is usr-merged, so /lib is a symlink to usr/lib.
# GNU tar, extracting an archive that contains a ./lib/ directory entry, deletes
# that symlink and creates a real directory in its place. Everything that lived
# under /lib then vanishes from view, including the ELF interpreter
# /lib/ld-linux-armhf.so.3 that every binary names in its header.
#
# The files themselves were never touched. They are all still in /usr/lib. Only
# the symlink pointing at them is missing, so this puts it back and moves the
# kernel modules that got written into the wrong place.
#
set -euo pipefail

ROOT=${1:-}
[ -n "$ROOT" ] || { echo "usage: $0 /path/to/mounted/rootfs" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
[ -d "$ROOT" ] || { echo "$ROOT is not a directory" >&2; exit 1; }

say() { echo "  $*"; }

# Refuse to touch anything that is not obviously the Pyra's rootfs, and in
# particular refuse to run against the PC's own /.
echo "checking $ROOT is the Pyra rootfs"
for marker in usr/lib/modules/5.6.19-pyradef etc/debian_version usr/lib/xorg/modules/drivers/omap5_drv.so; do
	[ -e "$ROOT/$marker" ] || { echo "missing $marker — refusing, this is not the Pyra rootfs" >&2; exit 1; }
done
[ "$(readlink -f "$ROOT")" != "/" ] || { echo "that is this PC's root — refusing" >&2; exit 1; }
say "ok"

echo "checking the damage"
if [ -L "$ROOT/lib" ]; then
	say "/lib is already a symlink to $(readlink "$ROOT/lib") — nothing to repair"
	exit 0
fi
[ -d "$ROOT/lib" ] || { echo "/lib is neither symlink nor directory — unexpected, stopping" >&2; exit 1; }
say "/lib is a real directory, as expected after the bad extraction"
say "it contains: $(ls -A "$ROOT/lib" | tr '\n' ' ')"

# Anything under the bogus /lib has to be moved into the real usr/lib before
# the directory can go. In practice that is only the modules just installed.
echo "moving anything under /lib into usr/lib"
shopt -s dotglob nullglob
for item in "$ROOT"/lib/*; do
	name=${item##*/}
	if [ -e "$ROOT/usr/lib/$name" ] && [ -d "$item" ]; then
		# Merge directory contents rather than clobbering, so an
		# existing usr/lib/modules keeps its other kernels.
		say "merging $name into usr/lib/$name"
		cp -a "$item"/. "$ROOT/usr/lib/$name"/
		rm -rf "$item"
	else
		say "moving $name to usr/lib/"
		mv "$item" "$ROOT/usr/lib/"
	fi
done
shopt -u dotglob nullglob

echo "restoring the symlink"
rmdir "$ROOT/lib"
ln -s usr/lib "$ROOT/lib"
say "/lib -> $(readlink "$ROOT/lib")"

echo "verifying"
fail=0
for f in lib/ld-linux-armhf.so.3 lib/arm-linux-gnueabihf/libc.so.6 lib/modules/5.6.19-pyradef/modules.dep; do
	if [ -e "$ROOT/$f" ]; then say "ok   $f"; else say "FAIL $f"; fail=1; fi
done
# The kernel that caused all this should still be installed, in the right place.
if [ -d "$ROOT/usr/lib/modules/5.6.19-softlockup" ]; then
	say "ok   usr/lib/modules/5.6.19-softlockup is in place"
else
	say "note usr/lib/modules/5.6.19-softlockup is absent"
fi
[ "$fail" = 0 ] || { echo "verification failed — do not boot this card yet" >&2; exit 1; }

sync
echo
echo "repaired. unmount, put the card back, and it will boot the stock kernel."
