#!/bin/bash
#
# pyra-m4-check.sh — check the state of the two Cortex-M4s and the DSP on
# the running Pyra.
#
#   ./pyra-m4-check.sh            report, change nothing
#   ./pyra-m4-check.sh --modprobe load omap_remoteproc first, if it is not in
#
# Safe on the stock kernel: it detects that the M4 kernel is not running and
# says so, rather than failing. That is deliberate, so it can be run before
# and after installing 5.6.19-m4 and the two outputs compared.
#
# It never writes to a remoteproc state file. Starting a processor needs
# firmware that does not exist yet, and once one does exist, note that
# rproc_alloc sets auto_boot = true and the omap driver never clears it --
# modprobe will start the core by itself, with no separate step to
# reconsider at. See docs/m4-ipu.md.
#
# Needs sudo only for the clock rates in debugfs; everything else is
# readable as an ordinary user, and the clock section is skipped rather
# than refused when it is not available.
#
set -uo pipefail

MODPROBE=0
case "${1:-}" in
--modprobe) MODPROBE=1 ;;
-h|--help)  sed -n '3,22p' "$0" | sed 's/^# \?//'; exit 0 ;;
"")         ;;
*)          echo "unknown argument: $1" >&2; exit 2 ;;
esac

pass=0 fail=0 skip=0
ok()   { echo "  ok    $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail+1)); }
warn() { echo "  skip  $*"; skip=$((skip+1)); }
note() { echo "        $*"; }

DT=/sys/firmware/devicetree/base   # NOT /proc/device-tree: it is a symlink
                                   # and find(1) will not descend it.

echo "== the machine =="
echo "  kernel  $(uname -r)"
echo "  model   $(tr -d '\0' < $DT/model 2>/dev/null)"
soc=$(cat /sys/bus/soc/devices/soc0/machine /sys/bus/soc/devices/soc0/revision \
        /sys/bus/soc/devices/soc0/type 2>/dev/null | tr '\n' ' ')
echo "  soc     ${soc:-unknown}"
case "$soc" in
*GP*) ok "GP part: firmware does not need TI signing" ;;
*HS*) bad "HS part: firmware would have to be signed, none of this works as written" ;;
*)    warn "could not read the SoC type" ;;
esac

echo
echo "== what the stock kernel already provides =="
# Both of these are true on the stock kernel too, and are the reason the
# backport is small. If either regresses, remoteproc cannot work at all.
for m in 55082000.mmu 4a066000.mmu; do
	[ -e "/sys/class/iommu/$m" ] && ok "iommu $m bound" || bad "iommu $m NOT bound"
done
if [ -e "$DT/ocp/interconnect@4a000000/segment@80000/target-module@74000/mailbox@0" ]; then
	ok "mailbox node present in the booted device tree"
	for c in mbox_ipu mbox_dsp; do
		[ -e "$DT/ocp/interconnect@4a000000/segment@80000/target-module@74000/mailbox@0/$c" ] \
			&& ok "  channel $c" || bad "  channel $c missing"
	done
else
	bad "no mailbox node in the booted device tree"
fi

echo
echo "== the device tree nodes the driver matches =="
ipu=$(find "$DT" -name compatible -exec grep -l "ti,omap5-ipu" {} + 2>/dev/null | head -1)
if [ -n "$ipu" ]; then
	ok "ipu node present (this is an M4 kernel)"
	M4KERNEL=1
else
	warn "no ipu node — this is not a 5.6.19-m4 kernel, so the rest is expected to be empty"
	M4KERNEL=0
fi

echo
echo "== the backlight still owns timer9 =="
# The timer trap. True on every kernel, and the check that matters most
# after installing a new device tree: if remoteproc were given timer9 the
# backlight would lose nothing, but starting the IPU would fail -EBUSY.
[ -e /sys/class/backlight/backlight ] \
	&& ok "display backlight present" || bad "display backlight MISSING"
[ -e /sys/class/backlight/keyboard-backlight ] \
	&& ok "keyboard backlight present" || bad "keyboard backlight MISSING"
b=$(cat /sys/class/backlight/backlight/actual_brightness 2>/dev/null)
[ -n "$b" ] && note "display brightness reads $b"

echo
echo "== remoteproc =="
if [ "$MODPROBE" = 1 ] && ! lsmod 2>/dev/null | grep -q '^omap_remoteproc'; then
	echo "  loading omap_remoteproc"
	sudo modprobe omap_remoteproc 2>&1 | sed 's/^/        /'
fi

if [ ! -d /sys/class/remoteproc ]; then
	if [ "$M4KERNEL" = 1 ]; then
		warn "no /sys/class/remoteproc — try --modprobe, or the module is missing"
	else
		ok "no /sys/class/remoteproc, as expected on this kernel"
	fi
else
	n=0
	for d in /sys/class/remoteproc/remoteproc*; do
		[ -d "$d" ] || continue
		n=$((n+1))
		nm=$(cat "$d/name" 2>/dev/null)
		st=$(cat "$d/state" 2>/dev/null)
		fw=$(cat "$d/firmware" 2>/dev/null)
		echo "  ${d##*/}: name=$nm state=$st firmware=$fw"
		case "$st" in
		offline) ok "  ${d##*/} is offline, which is correct with no firmware installed" ;;
		running) note "  ${d##*/} is RUNNING — something auto-booted it; see auto_boot in docs/m4-ipu.md" ;;
		*)       bad "  ${d##*/} is in state '$st'" ;;
		esac
	done
	[ "$n" -ge 2 ] && ok "$n remoteproc devices (expect 2: ipu and dsp)" \
	               || bad "$n remoteproc device(s), expected 2"
fi

echo
echo "== firmware =="
for f in /lib/firmware/omap5-ipu-fw.xem4 /lib/firmware/omap5-dsp-fw.xe64T; do
	[ -f "$f" ] && note "present: $f" || note "absent:  $f"
done
note "absent is expected today; nothing can be started until one exists"

echo
echo "== clocks (needs sudo) =="
cs=/sys/kernel/debug/clk/clk_summary
if sudo -n test -r $cs 2>/dev/null; then
	sudo -n grep -E "ipu_cm|dsp_cm" $cs 2>/dev/null | awk '{printf "        %-28s %s Hz\n", $1, $5}'
	pass=$((pass+1))
else
	warn "cannot read $cs without a password"
fi

echo
echo "$pass ok, $fail failed, $skip skipped"
exit $((fail>0))
