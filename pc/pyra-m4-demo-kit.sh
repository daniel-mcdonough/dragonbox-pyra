#!/bin/bash
#
# pyra-m4-demo-kit.sh — put together the M4 demo kit: everything somebody
# else needs to run the Pyra's two Cortex-M4s on their own unit, and the
# source for every binary in it.
#
#   ./pc/pyra-crossbuild.sh kernel-m4demo       first, once
#   ./pc/pyra-m4-demo-kit.sh                    then this
#
# Produces $PYRA_BUILD_DIR/m4-demo-kit/pyra-m4-demo-<date>.tar.gz, and the
# unpacked directory beside it. docs/m4-demo.md is its README.
#
# It ships a kernel binary, and that kernel is GPL-2.0-only, so it also
# ships what the binary was built from: every patch applied, the exact
# .config, and the name and sha256 of the upstream source package.
#
# It refuses to finish if anything it is about to package names the person
# who built it — a home directory, a login, a host name. Kernel build
# metadata is checked too: the container build gives root@<container id>,
# and that is the only thing allowed through.
#
set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF_DIR/.." && pwd)
BUILD_DIR=${PYRA_BUILD_DIR:-$HOME/git/dragonbox-pyra-build}
KDIR=$BUILD_DIR/kernel
OUT=$BUILD_DIR/m4-demo-kit
NAME=pyra-m4-demo-$(date +%Y%m%d)
KIT=$OUT/$NAME
RELEASE=5.6.19-m4demo

die() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
say() { printf '== %s\n' "$*"; }

TARBALL=$KDIR/m4demo-kernel.tar.gz
SRC=$KDIR/src-m4demo
[ -f "$TARBALL" ] || die "no $TARBALL; run ./pc/pyra-crossbuild.sh kernel-m4demo first"
[ -f "$SRC/.config" ] || die "no $SRC/.config; the kernel tree is not where the build left it"

say "checking the kernel tarball"
list=$(tar tzf "$TARBALL")
grep -q "boot/vmlinuz-$RELEASE\$" <<<"$list" || die "no vmlinuz-$RELEASE in the tarball"
grep -q "/modules/$RELEASE/.*omap_remoteproc.ko\$" <<<"$list" || die "no omap_remoteproc.ko"
grep -q "omap5-letux-cortex15-v5.3+pyra-v5.3.dtb\$" <<<"$list" || die "no Pyra V5.3 dtb"
for sym in REMOTEPROC OMAP2PLUS_MBOX RPMSG_VIRTIO; do
	grep -qx "CONFIG_$sym=y" "$SRC/.config" || die "CONFIG_$sym is not =y in $SRC/.config"
done
grep -qx "CONFIG_OMAP_REMOTEPROC=m" "$SRC/.config" || die "CONFIG_OMAP_REMOTEPROC is not =m"
# What makes this the demo kernel and not kernel-m4: no audio work, no OPPs.
applied=$SRC/.patches-applied
[ -f "$applied" ] || die "no $applied"
if grep -qE '^00(07|08|1[3-9]|2[0-9]|3[0-2])-' "$applied"; then
	die "the tree carries AESS or OPP patches; this is not a kernel-m4demo tree"
fi
for p in 0009 0010 0011 0012; do
	grep -q "^$p-" "$applied" || die "patch $p was not applied"
done
compile=$SRC/include/generated/compile.h
grep -q 'LINUX_COMPILE_BY "root"' "$compile" || die "$compile names a build user other than root"

say "building both firmwares"
make -s -C "$REPO/experiments/m4-ipu/firmware" clean
make -s -C "$REPO/experiments/m4-ipu/firmware" all demo >/dev/null

rm -rf "$KIT"
mkdir -p "$KIT"/{firmware,firmware-source,kernel-source/patches}

say "staging"
cp "$TARBALL" "$KIT/"
cp "$REPO/experiments/m4-ipu/firmware/pyra-m4-demo.xem4" \
   "$REPO/experiments/m4-ipu/firmware/omap5-ipu-fw.xem4" "$KIT/firmware/"
for s in pyra-m4-demo.sh pyra-m4-run.sh pyra-m4-check.sh \
	 pyra-install-debug-kernel.sh pyra-boot-kernel.sh; do
	install -m 0755 "$REPO/device/$s" "$KIT/$s"
done
# The demo script looks for its firmware beside itself.
ln -s firmware/pyra-m4-demo.xem4 "$KIT/pyra-m4-demo.xem4"

(cd "$REPO/experiments/m4-ipu/firmware" &&
	cp Makefile README.md m4.ld start.S main.c resource_table.c "$KIT/firmware-source/")

# Exactly the patches the build applied, in the order it applied them.
while read -r p; do
	src=""
	for d in "$REPO/patches" "$REPO/experiments/m4-ipu"; do
		[ -f "$d/$p" ] && { src=$d/$p; break; }
	done
	[ -n "$src" ] || die "applied patch $p is not in the repository any more"
	cp "$src" "$KIT/kernel-source/patches/"
done < "$applied"
cp "$applied" "$KIT/kernel-source/series"
cp "$SRC/.config" "$KIT/kernel-source/config-$RELEASE"
dsc=$(sed -n 's/^KERNEL_DSC=//p' "$SELF_DIR/pyra-crossbuild.sh")
sha=$(sed -n 's/^KERNEL_SHA=//p' "$SELF_DIR/pyra-crossbuild.sh")
cat > "$KIT/kernel-source/UPSTREAM" <<EOF
$RELEASE is built from the Pyra's own Debian kernel source package

    $dsc
    sha256 $sha

from https://packages.pyra-handheld.com/, with the patches in patches/
applied in the order listed in series, and config-$RELEASE as .config.
KERNELRELEASE=$RELEASE, cross-compiled with Debian bookworm's
crossbuild-essential-armhf (gcc 12.2).
EOF

cp "$REPO/docs/m4-demo.md" "$KIT/README.md"

say "checking for personal identifiers"
pat="$(id -un)|$(hostname -s)|$HOME"
if hits=$(grep -rIlE "$pat" "$KIT" 2>/dev/null); [ -n "$hits" ]; then
	echo "$hits" >&2
	die "the files above contain '$pat'; fix them before publishing"
fi
# Binaries, including inside the kernel tarball: strings, not grep -I.
for f in "$KIT"/firmware/*.xem4; do
	! strings "$f" | grep -qE "$pat" || die "$f contains '$pat' (debug info paths?)"
done
! tar xzOf "$TARBALL" 2>/dev/null | strings | grep -qE "$pat" \
	|| die "the kernel tarball contains '$pat'"

(cd "$KIT" && find . -type f ! -name SHA256SUMS -print0 | sort -z \
	| xargs -0 sha256sum > SHA256SUMS)
tar czf "$OUT/$NAME.tar.gz" -C "$OUT" --owner=0 --group=0 --numeric-owner "$NAME"
(cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")

say "done"
echo "  $OUT/$NAME.tar.gz  ($(du -h "$OUT/$NAME.tar.gz" | cut -f1))"
cat "$OUT/$NAME.tar.gz.sha256"
