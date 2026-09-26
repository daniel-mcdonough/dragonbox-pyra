#!/bin/sh
# Build pyra_undervolt.ko against a kernel variant's built tree (default
# 5.6.19-m4-kbdled, the Pyra's default boot kernel), out of tree: nothing in the
# kernel source changes.  The module is loaded by hand (insmod from a path) and is
# never installed.
#   ./build-module.sh                                -> pyra_undervolt.ko next to this script
#   PYRA_KERNEL_SUFFIX=m4 ./build-module.sh           the same, for 5.6.19-m4
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=${PYRA_BUILD_DIR:-$HOME/git/dragonbox-pyra-build}
SUFFIX=${PYRA_KERNEL_SUFFIX:-m4-kbdled}
SRC=src-$SUFFIX

[ -d "$BUILD_DIR/kernel/$SRC" ] || { echo "no $SRC; run pc/pyra-crossbuild.sh kernel-$SUFFIX first"; exit 1; }
docker run --rm -v "$BUILD_DIR/kernel/$SRC":/src:ro -v "$HERE":/mod -w /mod debian:bookworm bash -euo pipefail -c "
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
ls -l "$HERE/pyra_undervolt.ko"
