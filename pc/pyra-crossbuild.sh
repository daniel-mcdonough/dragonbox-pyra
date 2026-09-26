#!/bin/bash
#
# pyra-crossbuild.sh — build Pyra armhf packages from source, on a PC.
#
#   ./pyra-crossbuild.sh ddx                 the omap5 X display driver
#   ./pyra-crossbuild.sh kernel              zImage, modules and dtbs
#   ./pyra-crossbuild.sh kernel bindeb-pkg   the same, as installable .debs
#   ./pyra-crossbuild.sh kernel-debug        a kernel that reports lockups
#   ./pyra-crossbuild.sh kernel-fix          the same, plus everything in patches/
#   ./pyra-crossbuild.sh kernel-c2           the fix kernel plus one experiment
#   ./pyra-crossbuild.sh kernel-freq         the fix kernel plus finer cpu steps
#   ./pyra-crossbuild.sh kernel-oc           the same, overclocked to 2 GHz
#   ./pyra-crossbuild.sh kernel-m4           the fix kernel plus the M4 stack
#   ./pyra-crossbuild.sh kernel-m4-uprobe    the same, plus user-space probes
#   ./pyra-crossbuild.sh kernel-m4-uprobe-kprobe  the same, first with 0033, plus PM debug
#   ./pyra-crossbuild.sh kernel-m4-kbdled    the same, with the keyboard light as an LED
#
# PYRA_KERNELRELEASE=5.6.19-test builds a kernel that installs beside the stock
# one instead of over it. Set CONFIG_LOCALVERSION in the tree to match.
#
# These are real cross-compiles inside a throwaway Debian container, not qemu
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

# Resolved rather than assumed, because the patch set lives at the top of
# the repository and this script does not.
SELF_DIR=$(cd "$(dirname "$0")" && pwd)

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

# Two more kernels are built beside the stock one. They share everything but
# what they carry:
#
#   kernel-debug   5.6.19-softlockup   stock source, plus a lockup detector
#   kernel-fix     5.6.19-fix          the same, plus everything in patches/
#   kernel-c2      5.6.19-c2           the fix set plus experiments/c2-idle
#   kernel-freq    5.6.19-freq         the fix set plus the intermediate OPPs
#   kernel-oc      5.6.19-oc           kernel-freq plus the overclock OPPs
#   kernel-m4      5.6.19-m4           the fix set plus remoteproc for the M4s,
#                                      the AESS series and the intermediate OPPs
#   kernel-m4-uprobe  5.6.19-m4-uprobe     kernel-m4 plus UPROBE_EVENTS, so that
#                                      `perf probe -x <lib> <fn>` can count calls
#                                      into user-space code. The m4 config has
#                                      FTRACE and KPROBE_EVENTS but not this.
#
# kernel-m4 carries 0007 as well, so that the thermal daemon's frequency cap
# has the same eleven steps to land on that kernel-freq gave it. It takes 0007
# alone and never the directory: 0008 raises the ceiling to 2 GHz on voltages
# measured on a unit with soldered heatsink and replaced thermal interface, and
# that is the last thing to put under a kernel that also runs the IPU.
#
# The last four are experiments and are meant to be bootable beside the fix
# kernel rather than instead of it, which is why each has its own release name
# and its own source tree. See improvements.md item 12 for c2,
# experiments/thermals-and-frequency/README.md for freq and oc, and
# docs/m4-ipu.md for m4.
#
# kernel-freq and kernel-oc are deliberately separate. The first adds five
# frequency steps below the part's 1.5 GHz rating at the voltages the board
# already uses either side of them, and changes no ceiling. The second raises
# the ceiling to 2 GHz on voltages measured on somebody else's unit. Only one
# of those is worth building to answer a question about the governor.
#
# The stock config has no lockup detector of any kind, which is why two hangs
# that pinned a core for minutes produced no kernel message at all. Both of
# these turn that on: same source, same compiler, same everything else.
#
# Each installs BESIDE the stock kernel under its own release name, so the
# stock one stays bootable and stays the default. See building.md.
#
#   $1  release suffix, also the tarball name
#   $2  directories of patches to apply, space separated, empty for none.
#       They are gathered into one directory and applied in name order, so a
#       patch meant to go last has to sort last.
#   $3  source directory under the work tree, one per variant so that a
#       patched tree never leaks into an unpatched build
#   $4  extra config symbols to enable, space separated, empty for none.
#       NAME builds it in, NAME=m builds it as a module. Each is checked
#       afterwards, because olddefconfig silently drops anything whose
#       dependencies are unmet.
build_kernel_variant() {
	local suffix=$1 patchdirs=$2 srcdir=$3 extracfg=${4:-} pd
	local dir=$BUILD_DIR/kernel
	fetch "$KERNEL_DSC" "$KERNEL_SHA" "$dir"
	rm -rf "$dir/patches"
	if [ -n "$patchdirs" ]; then
		mkdir -p "$dir/patches"
		for pd in $patchdirs; do
			if [ -f "$pd" ]; then
				# A single patch, for an experiment that ships
				# more than one and is meant to be taken in
				# parts rather than whole.
				cp "$pd" "$dir/patches/"
			elif [ -d "$pd" ]; then
				ls "$pd"/*.patch >/dev/null 2>&1 || die "no patches in $pd"
				cp "$pd"/*.patch "$dir/patches/"
			else
				die "no such patch or directory: $pd"
			fi
		done
	fi
	[ -d "$dir/$srcdir" ] || run debian:bookworm "$dir" '
		apt-get update -qq
		apt-get install -y --no-install-recommends dpkg-dev >/dev/null
		dpkg-source -x '"$KERNEL_DSC"' '"$srcdir"'
	'
	run debian:bookworm "$dir" '
		export SUFFIX='"$suffix"'
		export EXTRACFG='"'$extracfg'"'
		apt-get update -qq
		apt-get install -y --no-install-recommends \
			crossbuild-essential-armhf bc rsync kmod cpio bison flex \
			libssl-dev libyaml-dev openssl dpkg-dev debhelper patch >/dev/null
		cd '"$srcdir"'
		export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
		export KERNELRELEASE=5.6.19-$SUFFIX KBUILD_BUILD_VERSION=10

		# Apply the patch set, if there is one. A rebuild must not fail
		# just because the tree is already patched, so record what has
		# been applied and skip those.
		#
		# The obvious test -- "does it reverse cleanly?" -- is wrong
		# for a series. 0013 edits omap-abe-twl6040.c and 0016 edits
		# it again; once both are in, 0013 no longer applies forward
		# OR reverse, because its context has moved. That is a correct
		# tree failing the check, and it is what a stamp file avoids.
		stamp=.patches-applied
		touch $stamp
		for p in ../patches/*.patch; do
			[ -e "$p" ] || break
			b=$(basename $p)
			if grep -qxF "$b" $stamp; then
				echo "  already  $b"
			elif patch -p1 --dry-run --forward --silent <"$p" >/dev/null 2>&1; then
				patch -p1 --forward --silent <"$p"
				echo "$b" >> $stamp
				echo "  applied  $b"
			elif patch -p1 --dry-run --reverse --silent <"$p" >/dev/null 2>&1; then
				# An already-patched tree from before the stamp
				# existed. Record it so this costs one pass.
				echo "$b" >> $stamp
				echo "  already  $b (stamped)"
			else
				echo "  FAIL     $b does not apply"; exit 1
			fi
		done

		# Keep the untouched config recoverable.
		[ -f .config.stock ] || cp .config .config.stock

		# SOFTLOCKUP_DETECTOR depends on DEBUG_KERNEL, which the Pyra
		# config leaves off, and selects LOCKUP_DETECTOR itself.
		# GENERIC_IRQ_DEBUGFS costs nothing at runtime and is the only
		# way to read the enable depth of an interrupt, which is what
		# separates a driver that stopped talking from one switched off
		# by an unbalanced disable_irq.
		scripts/config --file .config \
			--enable  DEBUG_KERNEL \
			--enable  SOFTLOCKUP_DETECTOR \
			--disable BOOTPARAM_SOFTLOCKUP_PANIC \
			--enable  DETECT_HUNG_TASK \
			--disable BOOTPARAM_HUNG_TASK_PANIC \
			--enable  GENERIC_IRQ_DEBUGFS \
			--set-val DEFAULT_HUNG_TASK_TIMEOUT 30 \
			--set-str LOCALVERSION "-$SUFFIX" \
			--disable DEBUG_PREEMPT \
			--disable RCU_TRACE \
			--disable SCHED_DEBUG \
			--disable DEBUG_MISC
		for opt in $EXTRACFG; do
			case "$opt" in
			*=m) scripts/config --file .config --module "${opt%=m}" ;;
			*)   scripts/config --file .config --enable "$opt" ;;
			esac
		done
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
		for opt in DEBUG_KERNEL LOCKUP_DETECTOR SOFTLOCKUP_DETECTOR DETECT_HUNG_TASK \
			   GENERIC_IRQ_DEBUGFS ${EXTRACFG//=m/}; do
			if grep -qE "^CONFIG_${opt}=(y|m)" .config; then
				echo "  ok   $(grep -E "^CONFIG_${opt}=" .config)"
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
		mkdir -p ../staging/boot/dtb/linux-image-5.6.19-$SUFFIX
		make INSTALL_MOD_PATH=../staging INSTALL_MOD_STRIP=1 modules_install
		# modules_install writes to staging/lib/modules. Debian trixie is
		# usr-merged, where /lib is a symlink to usr/lib, and GNU tar
		# extracting an archive that contains a ./lib/ DIRECTORY entry
		# deletes that symlink and creates a real directory in its place.
		# Every binary on the system then loses its interpreter at
		# /lib/ld-linux-armhf.so.3 and nothing can start, including the
		# shell you would need to fix it. So stage under usr/lib, which
		# is where the files actually live, and never ship a ./lib/
		# entry at all.
		mkdir -p ../staging/usr
		mv ../staging/lib ../staging/usr/lib
		cp arch/arm/boot/zImage ../staging/boot/vmlinuz-5.6.19-$SUFFIX
		cp System.map ../staging/boot/System.map-5.6.19-$SUFFIX
		cp .config ../staging/boot/config-5.6.19-$SUFFIX
		cp arch/arm/boot/dts/*.dtb ../staging/boot/dtb/linux-image-5.6.19-$SUFFIX/
		# The modules tree'"'"'s build/source symlinks point into this
		# container and would dangle on the Pyra.
		rm -f ../staging/usr/lib/modules/5.6.19-$SUFFIX/build \
		      ../staging/usr/lib/modules/5.6.19-$SUFFIX/source
		cd ..
		tar czf $SUFFIX-kernel.tar.gz -C staging .
		if tar tzf $SUFFIX-kernel.tar.gz | grep -qx "./lib/"; then
			echo "REFUSING: the tarball contains a ./lib/ entry, which"
			echo "would destroy the usr-merge symlink on extraction."
			exit 1
		fi
		echo "staged $(du -sh staging | cut -f1), tarball $(du -h $SUFFIX-kernel.tar.gz | cut -f1)"
	'
	echo
	echo "built:   $dir/$srcdir/arch/arm/boot/zImage  (5.6.19-$suffix)"
	echo "install: $dir/$suffix-kernel.tar.gz"
	echo "symbols: $dir/$srcdir/vmlinux, for resolving addresses from a lockup report"
}

OPP_DIR=$SELF_DIR/../experiments/thermals-and-frequency

build_kernel_debug() { build_kernel_variant softlockup "" src; }
build_kernel_fix()   { build_kernel_variant fix "$SELF_DIR/../patches" src-fix; }
build_kernel_c2()    { build_kernel_variant c2 \
	"$SELF_DIR/../patches $SELF_DIR/../experiments/c2-idle" src-c2; }
build_kernel_freq()  { build_kernel_variant freq \
	"$SELF_DIR/../patches $OPP_DIR/0007-arm-dts-omap5-add-the-intermediate-opps.patch" src-freq; }
build_kernel_oc()    { build_kernel_variant oc \
	"$SELF_DIR/../patches $OPP_DIR" src-oc; }
# The AESS series rides along with the M4 kernel because l1 is the only test
# slot on the device and both are wanted in the same boot. Without the aess
# directory here a clean tree would build an "audio kernel" with none of the
# audio work in it, which is exactly what it did until now -- 0013..0023 had
# only ever been hand-applied in src-m4.
M4_PATCHES="$SELF_DIR/../patches $OPP_DIR/0007-arm-dts-omap5-add-the-intermediate-opps.patch \
	 $SELF_DIR/../experiments/m4-ipu $SELF_DIR/../experiments/aess"
M4_CONFIG="REMOTEPROC OMAP_REMOTEPROC=m OMAP2PLUS_MBOX RPMSG RPMSG_VIRTIO RPMSG_CHAR=m VIRTIO"
build_kernel_m4()    { build_kernel_variant m4 "$M4_PATCHES" src-m4 \
	"$M4_CONFIG"; }
# The m4 kernel with user-space probes, for profiling a game: glibc malloc and
# similar hot library calls cannot be counted without them, and user-space
# unwinding does not work on this stack. Nothing else differs from kernel-m4.
build_kernel_m4_uprobe() { build_kernel_variant m4-uprobe \
	"$M4_PATCHES" src-m4-uprobe "$M4_CONFIG UPROBE_EVENTS UPROBES"; }
# kernel-m4-uprobe, first built after patches/0033 existed, so kprobes cannot
# BUG() in the optprobe code (docs/building.md, patch 7). PM_ADVANCED_DEBUG
# (which needs PM_DEBUG; on this board that only turns enable_off_mode from a
# gta04 check into a variable, both 0, and adds pm-debug.c)
# adds power/runtime_usage to sysfs, the runtime-PM reference count, which is
# what the GPU idle-power work needs to read (docs/handoff/gpu-power-*.md).
# Its own name and tree so the m4-uprobe build stays what it was.
build_kernel_m4_uprobe_kprobe() { build_kernel_variant m4-uprobe-kprobe \
	"$M4_PATCHES" src-m4-uprobe-kprobe \
	"$M4_CONFIG UPROBE_EVENTS UPROBES PM_DEBUG PM_ADVANCED_DEBUG"; }

# kernel-m4-uprobe-kprobe with the keyboard light declared as an LED
# (pyra::kbd_backlight) instead of a second backlight, so that desktop
# software finds only the panel in /sys/class/backlight
# (experiments/kbd-led, reports/pyra-kernel-kbd-backlight.md). It moves the
# keyboard light's sysfs path, so userspace that hard-codes
# /sys/class/backlight/keyboard-backlight stops reaching it on this kernel.
build_kernel_m4_kbdled() { build_kernel_variant m4-kbdled \
	"$M4_PATCHES $SELF_DIR/../experiments/kbd-led" src-m4-kbdled \
	"$M4_CONFIG UPROBE_EVENTS UPROBES PM_DEBUG PM_ADVANCED_DEBUG"; }

case "${1:-}" in
	ddx)          shift; build_ddx ;;
	kernel)       shift; build_kernel "$@" ;;
	kernel-debug) shift; build_kernel_debug ;;
	kernel-fix)   shift; build_kernel_fix ;;
	kernel-c2)    shift; build_kernel_c2 ;;
	kernel-freq)  shift; build_kernel_freq ;;
	kernel-oc)    shift; build_kernel_oc ;;
	kernel-m4)    shift; build_kernel_m4 ;;
	kernel-m4-uprobe) shift; build_kernel_m4_uprobe ;;
	kernel-m4-uprobe-kprobe) shift; build_kernel_m4_uprobe_kprobe ;;
	kernel-m4-kbdled) shift; build_kernel_m4_kbdled ;;
	*)            die "usage: $0 ddx | kernel [make target...] | kernel-debug | kernel-fix | kernel-c2 | kernel-freq | kernel-oc | kernel-m4 | kernel-m4-uprobe | kernel-m4-uprobe-kprobe | kernel-m4-kbdled" ;;
esac
