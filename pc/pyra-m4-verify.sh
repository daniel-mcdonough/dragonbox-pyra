#!/bin/bash
#
# pyra-m4-verify.sh — check that the M4 patch set still says what
# docs/m4-ipu.md claims it says.
#
#   ./pyra-m4-verify.sh              check the built tree
#   ./pyra-m4-verify.sh --patches    check only the patches, no build needed
#
# Every assertion here corresponds to a finding in docs/m4-ipu.md, and exists
# because that finding is easy to undo by accident. The two worth the file on
# their own:
#
#   - the ipu and dsp nodes must carry NO timer properties. Copying
#     omap5-uevm.dts wholesale reintroduces ti,watchdog-timers = <&timer9>,
#     and timer9 on a Pyra is the display backlight PWM. The failure is a
#     -EBUSY when starting the processor, with nothing to connect it to a
#     backlight, so it would cost somebody a bad afternoon.
#
#   - the ipu carveout must stay at least as big as the resource table the
#     firmware will carry. The canonical rsc_table_omap5_ipu.h wants 55 MB
#     against the 56 MB here, which is one megabyte of headroom and no more.
#     ex41_forwardmsg ships a table wanting 156 MB.
#
# It also checks the test firmware in experiments/m4-ipu/firmware, if it has
# been built. The assertion that matters there is that the trace buffer is
# NOT in the file: the whole test rests on .bss being zeroed by the loader,
# so that anything in the buffer afterwards must have been written by an M4.
# Build it into the file and the on-device test would pass against a dead
# processor.
#
# The device-side halves are device/pyra-m4-check.sh, which needs the kernel
# booted, and device/pyra-m4-run.sh, which needs it booted and actually loads
# the firmware. This one needs nothing but the repository, and the build tree
# only for the checks that read a compiled DTB.
#
set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF_DIR/.." && pwd)
PATCHES=$REPO/experiments/m4-ipu
BUILD_DIR=${PYRA_BUILD_DIR:-$HOME/git/dragonbox-pyra-build}
SRC=$BUILD_DIR/kernel/src-m4
DTB_NAME=omap5-letux-cortex15-v5.3+pyra-v5.3.dtb

# The TI clones, if they are present. Checked rather than assumed, because
# the carveout assertion is only meaningful when the table is readable.
TI=${PYRA_M4_TI_DIR:-$HOME/git/dragonbox-pyra-m4-work}

PATCHES_ONLY=0
case "${1:-}" in
--patches) PATCHES_ONLY=1 ;;
-h|--help) sed -n '3,26p' "$0" | sed 's/^# \?//'; exit 0 ;;
"")        ;;
*)         echo "unknown argument: $1" >&2; exit 2 ;;
esac

pass=0 fail=0 skip=0
ok()   { echo "  ok    $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail+1)); }
warn() { echo "  skip  $*"; skip=$((skip+1)); }

echo "== the patch set =="

for p in 0009-remoteproc-omap-backport-the-device-tree-driver.patch \
         0010-arm-dts-omap5-add-the-ipu-and-dsp-nodes.patch \
         0011-arm-dts-pyra-enable-the-ipu-and-dsp.patch \
         0012-iommu-omap-do-not-sleep-while-holding-the-iommu-spinlocks.patch; do
	[ -f "$PATCHES/$p" ] && ok "$p present" || bad "$p missing"
done

# The three compat fixes are the whole reason 0009 is not just a copy of
# upstream. If any of them is lost the module stops compiling against 5.6,
# so assert each one individually rather than trusting the build.
grep -q 'set_load(timer->odt, 0, 0)' "$PATCHES"/0009-*.patch \
	&& ok "0009 keeps the three-argument set_load" \
	|| bad "0009 lost the three-argument set_load (5.6 dmtimer needs autoreload)"
grep -q 'u64 da, int len' "$PATCHES"/0009-*.patch \
	&& ok "0009 keeps da_to_va taking int len" \
	|| bad "0009 lost the int len in da_to_va (5.6 rproc_ops uses int)"
grep -q 'invalid boot address 0x%x' "$PATCHES"/0009-*.patch \
	&& ok "0009 keeps %x for the u32 bootaddr" \
	|| bad "0009 lost the %x for bootaddr (5.6 bootaddr is u32)"

# The finding this file mostly exists for. Match an actual property
# assignment, anchored and followed by '=', so that the patch's own comment
# explaining why the property is absent does not trip it.
if grep -qE '^\+[[:space:]]*ti,(watchdog-)?timers[[:space:]]*=' "$PATCHES"/0011-*.patch; then
	bad "0011 ADDS a timer property — timer9 is the backlight PWM, see docs/m4-ipu.md"
else
	ok "0011 adds no timer property to ipu or dsp"
fi

grep -q 'ipu-memory@95800000' "$PATCHES"/0011-*.patch \
	&& ok "0011 puts the ipu carveout at 0x95800000" \
	|| bad "0011 moved the ipu carveout off 0x95800000 (rsc table hard-codes it)"

echo
echo "== the test firmware =="
FW_DIR=$PATCHES/firmware
FW=$FW_DIR/omap5-ipu-fw.xem4

for f in start.S main.c resource_table.c m4.ld Makefile; do
	[ -f "$FW_DIR/$f" ] && ok "firmware/$f present" || bad "firmware/$f missing"
done

# 0012 is the fix for the two BUG: scheduling while atomic splats that
# starting the IPU produces. Assert it still says what it claims rather than
# just that the file exists.
P12=$PATCHES/0012-iommu-omap-do-not-sleep-while-holding-the-iommu-spinlocks.patch
if [ -f "$P12" ]; then
	if grep -q '^+	struct mutex	iommu_lock;' "$P12" && \
	   grep -q '^+	struct mutex lock;' "$P12"; then
		ok "0012 converts both omap-iommu locks to mutexes"
	else
		bad "0012 no longer converts both locks — see its header"
	fi
	grep -q '^+#include <linux/mutex.h>' "$P12" \
		&& ok "0012 adds mutex.h to omap-iommu.h" \
		|| bad "0012 dropped the mutex.h include the struct now needs"
fi

READELF=$(command -v arm-none-eabi-readelf || command -v readelf || true)
OBJCOPY=$(command -v arm-none-eabi-objcopy || command -v objcopy || true)

if [ ! -f "$FW" ]; then
	warn "no $FW — run 'make' in experiments/m4-ipu/firmware to check it"
elif [ -z "$READELF" ] || [ -z "$OBJCOPY" ]; then
	warn "no readelf/objcopy — cannot check the built firmware"
else
	# One PT_LOAD at device address 0, because the IPU has no ti,bootreg
	# and boots from the vector table there.
	load=$($READELF -lW "$FW" | awk '$1 == "LOAD" { print; n++ } END { if (n != 1) print "COUNT", n }')
	if grep -q '^COUNT' <<<"$load"; then
		bad "expected exactly one PT_LOAD segment, got $(awk '/^COUNT/{print $2}' <<<"$load")"
	else
		vaddr=$(awk '{print $3}' <<<"$load")
		filesz=$(awk '{print $5}' <<<"$load")
		memsz=$(awk '{print $6}' <<<"$load")
		[ "$vaddr" = "0x000000" ] || [ "$vaddr" = "0x00000000" ] || [ $((vaddr)) -eq 0 ] \
			&& ok "the segment loads at device address 0" \
			|| bad "the segment loads at $vaddr, not 0 — the M4 fetches its vectors from 0"

		# memsz > filesz is necessary but NOT sufficient, and saying so
		# is the point: the first version of this check stopped here,
		# and a deliberately broken build that moved the trace buffer
		# into the file still passed it, because .bss merely shrank
		# rather than disappearing. What has to be true is that the
		# TRACE BUFFER ITSELF sits past filesz, in the tail the loader
		# zeroes. That is asserted below, once the resource table has
		# been decoded and the buffer's address is known.
		if [ $((memsz)) -gt $((filesz)) ]; then
			ok "memsz $memsz > filesz $filesz (necessary, not sufficient)"
		else
			bad "memsz is not larger than filesz: nothing is zero-filled at all"
		fi
		[ $((memsz)) -le $((0x100000)) ] \
			&& ok "the image fits the 1 MiB carveout" \
			|| bad "the image is larger than the carveout it asks for"
	fi

	$READELF -SW "$FW" | grep -q '\.bss *NOBITS' \
		&& ok ".bss is NOBITS, so it costs nothing in the file" \
		|| bad ".bss is not NOBITS — the trace buffer is being shipped in the firmware"

	$READELF -SW "$FW" | grep -q '\.resource_table' \
		&& ok ".resource_table section present (remoteproc finds it by name)" \
		|| bad "no .resource_table section — remoteproc has nothing to parse"

	# Decode the table rather than trusting the source: ver, num, and the
	# carveout the device tree has to be able to satisfy.
	rt=$($OBJCOPY -O binary --only-section=.resource_table "$FW" /dev/stdout 2>/dev/null | od -An -tx4 -v | tr -s ' ' '\n' | grep -v '^$')
	ver=$(sed -n 1p <<<"$rt"); num=$(sed -n 2p <<<"$rt")
	cda=$(sed -n 8p <<<"$rt"); clen=$(sed -n 10p <<<"$rt")
	tda=$(sed -n 22p <<<"$rt"); tlen=$(sed -n 23p <<<"$rt")
	[ "$ver" = "00000001" ] && ok "resource table version 1" || bad "resource table version is 0x$ver"
	[ "$num" = "00000002" ] && ok "two resources (carveout + trace)" || bad "resource count is 0x$num"
	[ "$cda" = "00000000" ] && ok "carveout device address is 0" || bad "carveout device address is 0x$cda"
	if [ "0x$clen" = "0x00100000" ]; then
		ok "carveout asks for 1 MiB, well inside the 56 MiB the board reserves"
	else
		bad "carveout asks for 0x$clen, check it against ipu-memory@95800000 in 0011"
	fi

	# THE assertion. The trace buffer must lie entirely in the part of the
	# segment that has no bytes in the file, because "the M4 wrote this"
	# is the same statement as "the loader could only have zeroed this".
	# The segment loads at 0, so an address is an offset.
	if [ -n "${filesz:-}" ] && [[ "$tda" =~ ^[0-9a-f]+$ ]] && [[ "$tlen" =~ ^[0-9a-f]+$ ]]; then
		if [ $((0x$tda)) -ge $((filesz)) ]; then
			ok "the trace buffer (0x$tda) is past filesz ($filesz): it is zero-filled, never loaded"
		else
			bad "the trace buffer (0x$tda) is INSIDE the file image: its contents would come from the firmware, and the on-device test would pass against a dead core"
		fi
		[ $((0x$tda + 0x$tlen)) -le $((memsz)) ] \
			&& ok "the trace buffer is inside the loaded segment, so the loader reaches it" \
			|| bad "the trace buffer runs past the segment: the loader will not zero all of it"
	else
		warn "could not read the trace buffer address out of the resource table"
	fi
fi

echo
echo "== the build target =="
grep -q 'kernel-m4)' "$SELF_DIR/pyra-crossbuild.sh" \
	&& ok "pyra-crossbuild.sh has a kernel-m4 target" \
	|| bad "pyra-crossbuild.sh lost its kernel-m4 target"
# Built in, the driver probes during boot with no way to intervene. That is
# the wrong default on a SoC where a bad IOMMU setup wedges the L3.
grep -q 'OMAP_REMOTEPROC=m' "$SELF_DIR/pyra-crossbuild.sh" \
	&& ok "OMAP_REMOTEPROC is a module, not built in" \
	|| bad "OMAP_REMOTEPROC is no longer =m — it would probe during boot"

echo
echo "== the carveout against the resource table =="
RSC=$TI/ipcdev/packages/ti/ipc/remoteproc/rsc_table_omap5_ipu.h
if [ -f "$RSC" ]; then
	# Pull the three TYPE_CARVEOUT sizes out by name, not by position.
	# Sizes appear either as 'SZ_1M' or as '(SZ_1M * 48)'. Take the last
	# integer on the define's line, and default to 1 when there is none.
	mb() {
		local line n
		line=$(grep -E "^#define[[:space:]]+$1[[:space:]]" "$RSC" | tail -1)
		[ -n "$line" ] || { echo ""; return; }
		n=$(grep -oE '\*[[:space:]]*[0-9]+' <<<"$line" | grep -oE '[0-9]+' | tail -1)
		echo "${n:-1}"
	}
	t=$(mb IPU_MEM_TEXT_SIZE); d=$(mb IPU_MEM_DATA_SIZE); i=$(mb IPU_MEM_IPC_DATA_SIZE)
	if [ -z "$t$d$i" ]; then
		warn "could not parse the carveout sizes out of $RSC"
		t=0; d=0; i=0
	fi
	t=${t:-0}; d=${d:-0}; i=${i:-0}
	need=$((t + d + i))
	# 0011's carveout size, read out of the patch: the fourth cell of the
	# ipu region's reg. Guarded, because an unparseable side must show up as
	# a skip rather than vanish -- this assertion silently not running is
	# exactly the failure it exists to prevent.
	hex=$(grep -oE '^\+[[:space:]]*reg = <0 0x95800000 0 0x[0-9a-fA-F]+' "$PATCHES"/0011-*.patch \
		| grep -oE '0x[0-9a-fA-F]+$' | tail -1)
	if [[ "${hex:-}" =~ ^0x[0-9a-fA-F]+$ ]]; then
		have=$(( hex / 1024 / 1024 ))
	else
		have=0
	fi
	echo "  (table wants ${need} MB: text ${t}, data ${d}, ipc ${i}; carveout is ${have} MB)"
	if [ "$need" = 0 ] || [ "$have" = 0 ]; then
		warn "carveout comparison skipped, one side did not parse"
	elif [ "$have" -ge "$need" ]; then
		ok "carveout ${have} MB covers the ${need} MB the table asks for"
	else
		bad "carveout ${have} MB is SMALLER than the ${need} MB the table asks for"
	fi
else
	warn "no rsc_table_omap5_ipu.h under $TI — clone TI's ipcdev to check the carveout"
fi

[ "$PATCHES_ONLY" = 1 ] && { echo; echo "$pass ok, $fail failed, $skip skipped"; exit $((fail>0)); }

echo
echo "== the built kernel tree =="
if [ ! -d "$SRC" ]; then
	warn "no $SRC — run ./pc/pyra-crossbuild.sh kernel-m4 first"
	echo; echo "$pass ok, $fail failed, $skip skipped"; exit $((fail>0))
fi

for f in "$SRC/arch/arm/boot/zImage" \
         "$SRC/drivers/remoteproc/omap_remoteproc.ko" \
         "$SRC/arch/arm/boot/dts/$DTB_NAME"; do
	[ -f "$f" ] && ok "built: ${f#$SRC/}" || bad "missing: ${f#$SRC/}"
done

for opt in REMOTEPROC=y OMAP_REMOTEPROC=m OMAP2PLUS_MBOX=y RPMSG=y \
           RPMSG_VIRTIO=y RPMSG_CHAR=m VIRTIO=y; do
	grep -qx "CONFIG_$opt" "$SRC/.config" \
		&& ok "CONFIG_$opt" \
		|| bad "CONFIG_$opt not set in the built config"
done

echo
echo "== the compiled device tree =="
DTB=$SRC/arch/arm/boot/dts/$DTB_NAME
if [ ! -f "$DTB" ]; then
	warn "no $DTB_NAME to decompile"
else
	# These are the most valuable assertions in the file, so fall back to a
	# container rather than skipping them when the PC has no dtc. The build
	# already needs docker, so this adds no new dependency.
	if command -v dtc >/dev/null; then
		dts=$(dtc -I dtb -O dts "$DTB" 2>/dev/null || true)
	elif docker info >/dev/null 2>&1; then
		dts=$(docker run --rm -v "$(dirname "$DTB")":/d:ro debian:bookworm \
			bash -c 'apt-get update -qq >/dev/null 2>&1
			         apt-get install -y --no-install-recommends device-tree-compiler >/dev/null 2>&1
			         dtc -I dtb -O dts "/d/'"$DTB_NAME"'" 2>/dev/null' || true)
	else
		dts=""
	fi
fi
if [ -f "$DTB" ] && [ -z "${dts:-}" ]; then
	warn "no dtc and no docker; skipping the device tree assertions"
elif [ -n "${dts:-}" ]; then
	grep -q 'ti,omap5-ipu'  <<<"$dts" && ok "ipu node in the blob" || bad "no ipu node in the blob"
	grep -q 'ti,omap5-dsp'  <<<"$dts" && ok "dsp node in the blob" || bad "no dsp node in the blob"
	grep -q 'omap5-ipu-fw.xem4' <<<"$dts" \
		&& ok "ipu firmware-name is omap5-ipu-fw.xem4" \
		|| bad "ipu firmware-name is not what the build produces"
	# Both must be okay, or the driver matches nothing.
	[ "$(grep -c 'status = "okay"' <<<"$(awk '/ti,omap5-(ipu|dsp)/,/};/' <<<"$dts")")" = 2 ] \
		&& ok "both processors are status okay" \
		|| bad "ipu or dsp is not status okay — the driver will match nothing"
	# The assertion this file exists for: the ONLY ti,timers in the whole
	# tree must be the two backlight PWMs.
	n=$(grep -c 'ti,timers' <<<"$dts" || true)
	if [ "$n" = 2 ] && grep -q 'dmtimer-pwm@9' <<<"$dts" && grep -q 'dmtimer-pwm@8' <<<"$dts"; then
		ok "the only two ti,timers are the backlight PWMs (pwm8, pwm9)"
	else
		bad "expected exactly 2 ti,timers (pwm8, pwm9), found $n — a timer was given away"
	fi
	grep -q 'ipu-memory@95800000' <<<"$dts" && ok "ipu carveout in the blob" || bad "no ipu carveout in the blob"
	grep -q 'dsp-memory@95000000' <<<"$dts" && ok "dsp carveout in the blob" || bad "no dsp carveout in the blob"
fi

echo
echo "$pass ok, $fail failed, $skip skipped"
exit $((fail>0))
