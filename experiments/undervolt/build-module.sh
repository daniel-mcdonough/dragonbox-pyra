#!/bin/sh
# Build pyra_undervolt.ko against a kernel variant's built tree (default
# 5.6.19-m4-kbdled, the Pyra's default boot kernel), out of tree: nothing in the
# kernel source changes.  undervolt.sh loads it from this directory for experiments;
# a build for the default kernel is also copied to device/lib/, which
# pyra-install-helpers.sh installs for pyra-undervolt.service.
#   ./build-module.sh                                -> pyra_undervolt.ko next to this script
#   PYRA_KERNEL_SUFFIX=m4-kbdled-sched ./build-module.sh
#       another kernel: built in the build tree (undervolt-<suffix>/), so the default
#       kernel's module here is left alone, and copied to device/lib/5.6.19-<suffix>/,
#       which pyra-install-helpers.sh installs where pyra-undervolt looks for that release
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
# Default: dragonbox-pyra-build beside this repository.
BUILD_DIR=${PYRA_BUILD_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)/dragonbox-pyra-build}
SUFFIX=${PYRA_KERNEL_SUFFIX:-m4-kbdled}
SRC=src-$SUFFIX

[ -d "$BUILD_DIR/kernel/$SRC" ] || { echo "no $SRC; run pc/pyra-crossbuild.sh kernel-$SUFFIX first"; exit 1; }
OUT=$HERE
if [ "$SUFFIX" != m4-kbdled ]; then
	OUT=$BUILD_DIR/kernel/undervolt-$SUFFIX
	mkdir -p "$OUT"
	cp "$HERE/Kbuild" "$HERE/pyra_undervolt.c" "$OUT/"
fi
docker run --rm -v "$BUILD_DIR/kernel/$SRC":/src:ro -v "$OUT":/mod -w /mod debian:bookworm bash -euo pipefail -c "
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y --no-install-recommends build-essential crossbuild-essential-armhf bc kmod bison flex libssl-dev >/dev/null
	export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
	trap 'rm -rf /mod/.tmp_* /mod/*.o /mod/*.mod /mod/*.mod.c /mod/.*.cmd /mod/modules.order /mod/Module.symvers; chown -R $(id -u):$(id -g) /mod' EXIT
	make -C /src M=/mod KERNELRELEASE=5.6.19-$SUFFIX modules
	arm-linux-gnueabihf-strip --strip-debug pyra_undervolt.ko
	/src/scripts/sign-file sha1 /src/certs/signing_key.pem /src/certs/signing_key.x509 pyra_undervolt.ko
	modinfo pyra_undervolt.ko | grep -E '^(name|vermagic|sig_key|parm)'
"
ls -l "$OUT/pyra_undervolt.ko"
if [ "$SUFFIX" = m4-kbdled ]; then
	cp "$HERE/pyra_undervolt.ko" "$HERE/../../device/lib/" && echo "copied to device/lib/"
else
	mkdir -p "$HERE/../../device/lib/5.6.19-$SUFFIX"
	cp "$OUT/pyra_undervolt.ko" "$HERE/../../device/lib/5.6.19-$SUFFIX/" && echo "copied to device/lib/5.6.19-$SUFFIX/"
fi
