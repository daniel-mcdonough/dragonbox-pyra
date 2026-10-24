#!/bin/sh
# Build pvrsrvkm with 0034 for a kernel variant (default 5.6.19-m4-uprobe-kprobe; set
# PYRA_KERNEL_SUFFIX=m4-kbdled for the default boot kernel), without touching that
# kernel's source for good: the patch goes on, the module builds, the patch comes off.
# The result is loaded by hand (insmod from a path) and is never installed, so a reboot or
# `modprobe -r` + `modprobe` puts the stock module back.
#   ./build-module.sh            -> pvrsrvkm-apm.ko next to this script
#   PYRA_KERNEL_SUFFIX=m4-kbdled ./build-module.sh   the same, for 5.6.19-m4-kbdled
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
# Default: dragonbox-pyra-build beside this repository.
BUILD_DIR=${PYRA_BUILD_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)/dragonbox-pyra-build}
SUFFIX=${PYRA_KERNEL_SUFFIX:-m4-uprobe-kprobe}
SRC=src-$SUFFIX
PATCH=0034-pvrsgx-let-the-sgx-power-domain-go-off-at-idle.patch
KO=drivers/gpu/drm/pvrsgx/1.14.3699939/eurasia_km/pvrsrvkm_omap5_sgx544_116.ko

[ -d "$BUILD_DIR/kernel/$SRC" ] || { echo "no $SRC; run pc/pyra-crossbuild.sh kernel-$SUFFIX first"; exit 1; }
cp "$HERE/$PATCH" "$BUILD_DIR/kernel/$PATCH"
docker run --rm -v "$BUILD_DIR/kernel":/src -w /src/$SRC debian:bookworm bash -euo pipefail -c "
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y --no-install-recommends build-essential crossbuild-essential-armhf bc kmod bison flex libssl-dev patch >/dev/null
	export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
	export KERNELRELEASE=5.6.19-$SUFFIX KBUILD_BUILD_VERSION=10
	patch -p1 --forward < ../$PATCH
	trap 'patch -p1 --reverse --silent < ../$PATCH; chown -R $(id -u):$(id -g) /src/$SRC' EXIT
	make -j\$(nproc) modules >/dev/null
	arm-linux-gnueabihf-strip --strip-debug -o ../pvrsrvkm-apm.ko $KO
	modinfo ../pvrsrvkm-apm.ko | grep -E '^(name|vermagic)'
	chown $(id -u):$(id -g) ../pvrsrvkm-apm.ko
"
rm -f "$BUILD_DIR/kernel/$PATCH"
mv "$BUILD_DIR/kernel/pvrsrvkm-apm.ko" "$HERE/pvrsrvkm-apm.ko"
ls -l "$HERE/pvrsrvkm-apm.ko"
