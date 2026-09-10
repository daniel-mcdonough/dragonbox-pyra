#!/bin/bash
#
# pyra-crossbuild.sh — build Pyra armhf packages from source, on a PC.
#
#   ./pyra-crossbuild.sh ddx                 the omap5 X display driver
#   ./pyra-crossbuild.sh kernel              zImage, modules and dtbs
#   ./pyra-crossbuild.sh kernel bindeb-pkg   the same, as installable .debs
#
# PYRA_KERNELRELEASE=5.6.19-test builds a kernel that installs beside the stock
# one instead of over it. Set CONFIG_LOCALVERSION in the tree to match.
#
# Both are real cross-compiles inside a throwaway Debian container, not qemu
# emulation, so a full kernel takes minutes rather than the hours it costs to
# build natively on the Pyra's two Cortex-A15s. Nothing is installed on the
# host beyond the container image, and the Pyra's rootfs is never touched.
#
# The work tree defaults to ~/git/dragonbox-pyra-build and is deliberately
# outside this repository: the kernel source alone unpacks to about 1.5 GB.
# Override it with PYRA_BUILD_DIR.
#
# The container for the driver is trixie, matching the X server ABI on the
# card. The container for the kernel is bookworm, because 5.6 does not build
# with gcc 14 and bookworm's gcc 12 is what upstream used.
#
set -euo pipefail

REPO=https://packages.pyra-handheld.com/trixie
BUILD_DIR=${PYRA_BUILD_DIR:-$HOME/git/dragonbox-pyra-build}

# Only the .dsc hashes are pinned here. dpkg-source verifies the tarballs
# against the .dsc when it unpacks, so pinning the .dsc pins everything.
DDX_DSC=xserver-xorg-video-armsoc-omap5_0.6.dsc
DDX_SHA=d5b6586e54f24d73dca7415702a7c21113d90ca0f89d23556e8bad9aca6fa43b
KERNEL_DSC=linux-5.6.19-pyradef_5.6.19-pyradef-10.dsc
KERNEL_SHA=d42a933df6fa0836c836c6ba0c058cdebc260e8cc1812aba1645df3800774c6e

die() { echo "pyra-crossbuild: $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker is not installed"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon"

# Fetch a source package and its .dsc, and verify the .dsc against the hash
# above. Files already present are left alone, so a second run is cheap.
fetch() {
	local dsc=$1 want=$2 dir=$3 f got
	mkdir -p "$dir"
	cd "$dir"
	[ -f "$dsc" ] || curl -fsS --retry 3 -O "$REPO/$dsc" || die "cannot fetch $dsc"
	got=$(sha256sum "$dsc" | cut -d' ' -f1)
	[ "$got" = "$want" ] || die "$dsc has the wrong sha256: $got"
	# The .dsc lists its own tarballs; take the filenames off the end of the
	# Checksums-Sha256 stanza and fetch any that are missing.
	for f in $(awk '/^Checksums-Sha256:/{s=1;next} /^[^ ]/{s=0} s{print $3}' "$dsc"); do
		[ -f "$f" ] || curl -fsS --retry 3 -O "$REPO/$f" || die "cannot fetch $f"
	done
}

# Run a build inside a container, with this user owning whatever comes out.
run() {
	local image=$1 dir=$2 script=$3
	docker run --rm -v "$dir":/src -w /src "$image" bash -euo pipefail -c "
		export DEBIAN_FRONTEND=noninteractive
		$script
		chown -R $(id -u):$(id -g) /src
	"
}

build_ddx() {
	local dir=$BUILD_DIR/ddx
	fetch "$DDX_DSC" "$DDX_SHA" "$dir"
	run debian:trixie "$dir" '
		sed -i "s/^Types: deb$/Types: deb deb-src/" /etc/apt/sources.list.d/debian.sources
		dpkg --add-architecture armhf
		apt-get update -qq
		apt-get install -y --no-install-recommends \
			build-essential crossbuild-essential-armhf dpkg-dev devscripts
		rm -rf build
		dpkg-source -x '"$DDX_DSC"' build
		cd build
		apt-get build-dep -y -a armhf .
		dpkg-buildpackage -aarmhf -us -uc -b -j$(nproc)
	'
	echo
	ls -la "$dir"/*.deb
}

build_kernel() {
	local dir=$BUILD_DIR/kernel
	local target=${*:-zImage modules dtbs}
	# A test kernel should install alongside the stock one rather than over
	# it. Set PYRA_KERNELRELEASE, and set CONFIG_LOCALVERSION in the tree to
	# match, and the two live side by side in /boot and /lib/modules.
	local KRELEASE=${PYRA_KERNELRELEASE:-5.6.19-pyradef}
	fetch "$KERNEL_DSC" "$KERNEL_SHA" "$dir"
	# Unpack once. Later runs build the tree in place, so an edit to one
	# file costs one recompile and not a fresh 195 MB unpack.
	[ -d "$dir/src" ] || run debian:bookworm "$dir" '
		apt-get update -qq
		apt-get install -y --no-install-recommends dpkg-dev >/dev/null
		dpkg-source -x '"$KERNEL_DSC"' src
	'
	run debian:bookworm "$dir" '
		apt-get update -qq
		apt-get install -y --no-install-recommends \
			crossbuild-essential-armhf bc rsync kmod cpio bison flex \
			libssl-dev libyaml-dev openssl dpkg-dev debhelper >/dev/null
		cd src
		export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
		export KERNELRELEASE='"$KRELEASE"' KBUILD_BUILD_VERSION=10
		make olddefconfig
		make -j$(nproc) '"$target"'
	'
	echo
	ls -la "$dir"/src/arch/arm/boot/zImage "$dir"/*.deb 2>/dev/null || true
}

case "${1:-}" in
	ddx)    shift; build_ddx ;;
	kernel) shift; build_kernel "$@" ;;
	*)      die "usage: $0 ddx | kernel [make target...]" ;;
esac
