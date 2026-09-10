#!/bin/bash
#
# pyra-crossbuild.sh — build Pyra armhf packages from source, on a PC.
#
#   ./pyra-crossbuild.sh ddx                 the omap5 X display driver
#   ./pyra-crossbuild.sh kernel              zImage, modules and dtbs
#   ./pyra-crossbuild.sh kernel bindeb-pkg   the same, as installable .debs
#   ./pyra-crossbuild.sh kernel-debug        a kernel that reports lockups
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

# A kernel that says where it is stuck, instead of sitting there silently.
#
# The stock config has no lockup detector of any kind, which is why two hangs
# that pinned a core for minutes produced no kernel message at all. This build
# turns that on, and nothing else: same source, same compiler, same everything.
#
# It installs BESIDE the stock kernel as 5.6.19-softlockup, so the stock one
# stays bootable and stays the default. See building.md.
build_kernel_debug() {
	local dir=$BUILD_DIR/kernel
	fetch "$KERNEL_DSC" "$KERNEL_SHA" "$dir"
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
		export KERNELRELEASE=5.6.19-softlockup KBUILD_BUILD_VERSION=10

		# Keep the untouched config recoverable.
		[ -f .config.stock ] || cp .config .config.stock

		# SOFTLOCKUP_DETECTOR depends on DEBUG_KERNEL, which the Pyra
		# config leaves off, and selects LOCKUP_DETECTOR itself.
		scripts/config --file .config \
			--enable  DEBUG_KERNEL \
			--enable  SOFTLOCKUP_DETECTOR \
			--disable BOOTPARAM_SOFTLOCKUP_PANIC \
			--enable  DETECT_HUNG_TASK \
			--disable BOOTPARAM_HUNG_TASK_PANIC \
			--set-val DEFAULT_HUNG_TASK_TIMEOUT 30 \
			--set-str LOCALVERSION "-softlockup" \
			--disable DEBUG_PREEMPT \
			--disable RCU_TRACE \
			--disable SCHED_DEBUG \
			--disable DEBUG_MISC
		make olddefconfig

		# DEBUG_KERNEL turns several other debug options on by default,
		# and DEBUG_PREEMPT in particular costs real time on every
		# preempt_disable. This kernel exists to catch a timing race, so
		# anything that perturbs timing is the last thing it wants. The
		# four disables above put those back; check they held.
		for opt in DEBUG_PREEMPT RCU_TRACE SCHED_DEBUG DEBUG_MISC; do
			grep -q "^CONFIG_${opt}=y" .config \
				&& { echo "  FAIL CONFIG_${opt} came back on"; exit 1; } \
				|| echo "  ok   CONFIG_${opt} off, no added overhead"
		done

		# olddefconfig silently drops anything whose dependencies are
		# unmet, so check rather than assume.
		fail=0
		for opt in DEBUG_KERNEL LOCKUP_DETECTOR SOFTLOCKUP_DETECTOR DETECT_HUNG_TASK; do
			if grep -q "^CONFIG_${opt}=y" .config; then
				echo "  ok   CONFIG_${opt}=y"
			else
				echo "  FAIL CONFIG_${opt} did not stick"; fail=1
			fi
		done
		for opt in BOOTPARAM_SOFTLOCKUP_PANIC BOOTPARAM_HUNG_TASK_PANIC; do
			grep -q "^CONFIG_${opt}=y" .config \
				&& { echo "  FAIL CONFIG_${opt} is on, it would panic"; fail=1; } \
				|| echo "  ok   CONFIG_${opt} off, it will warn not panic"
		done
		[ "$fail" = 0 ] || exit 1

		make -j$(nproc) zImage modules dtbs

		# Stage everything the Pyra needs, laid out so it unpacks
		# straight over / without disturbing the stock kernel. The
		# initrd is deliberately not here: it has to be generated on
		# the device, against the device'"'"'s own userspace.
		rm -rf ../staging
		mkdir -p ../staging/boot/dtb/linux-image-5.6.19-softlockup
		make INSTALL_MOD_PATH=../staging INSTALL_MOD_STRIP=1 modules_install
		cp arch/arm/boot/zImage ../staging/boot/vmlinuz-5.6.19-softlockup
		cp System.map ../staging/boot/System.map-5.6.19-softlockup
		cp .config ../staging/boot/config-5.6.19-softlockup
		cp arch/arm/boot/dts/*.dtb ../staging/boot/dtb/linux-image-5.6.19-softlockup/
		# The modules tree'"'"'s build/source symlinks point into this
		# container and would dangle on the Pyra.
		rm -f ../staging/lib/modules/5.6.19-softlockup/build \
		      ../staging/lib/modules/5.6.19-softlockup/source
		cd ..
		tar czf softlockup-kernel.tar.gz -C staging .
		echo "staged $(du -sh staging | cut -f1), tarball $(du -h softlockup-kernel.tar.gz | cut -f1)"
	'
	echo
	echo "built:   $dir/src/arch/arm/boot/zImage  (5.6.19-softlockup)"
	echo "install: $dir/softlockup-kernel.tar.gz"
	echo "symbols: $dir/src/vmlinux, for resolving addresses from a lockup report"
}

case "${1:-}" in
	ddx)          shift; build_ddx ;;
	kernel)       shift; build_kernel "$@" ;;
	kernel-debug) shift; build_kernel_debug ;;
	*)            die "usage: $0 ddx | kernel [make target...] | kernel-debug" ;;
esac
