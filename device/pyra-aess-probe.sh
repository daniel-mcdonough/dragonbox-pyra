#!/bin/bash
#
# pyra-aess-probe.sh — is the OMAP5 AESS real silicon on this machine?
#
#   sudo ./pyra-aess-probe.sh [--verbose]
#
# The AESS (Audio Engine SubSystem) is the SoC's dedicated audio DSP. Its
# front-end DAIs accept 44100 and 48000 Hz S16_LE stereo, which is what every
# application produces; the TWL6040 behind it accepts only 88200/96000 S32_LE,
# which is why PulseAudio resamples and widens every stream in software and
# costs 15-18% of a core doing it (docs/improvements.md item 10).
#
# The driver is present and enabled (CONFIG_SND_SOC_OMAP_AESS=y), the node is
# in the device tree, and the firmware loads -- but the machine driver's
# omap_abe_add_aess_dai_links() is an empty stub, so nothing is ever wired to
# it. Before anyone spends a week filling that stub in, the cheap question is
# whether the hardware answers at all: the driver is TI's out-of-tree OMAP4
# AESS code, the firmware blob is OMAP4's, and as far as this repo can tell
# nobody has run it on an OMAP5.
#
# This script answers that and nothing else. It does not enable audio, load
# firmware, or change the audio path.
#
# What it does:
#   1. Refuses to read unless the L4 target module is runtime-active. Reading
#      a gated module on OMAP is an imprecise external abort, i.e. a panic,
#      not an error code. It forces the module active through ti-sysc's
#      power/control and restores the previous setting on exit.
#   2. Sanity-checks its own register-reading tool first. /usr/bin/devmem2 on
#      this image returns 0x0 for every address -- its read path is broken
#      while its write path works, which is the worst possible failure mode
#      for a liveness test. busybox devmem is used instead, and is verified
#      against CONTROL_ID_CODE before anything is concluded.
#   3. Reads the AESS register block and round-trips a word through each of
#      the three memories, restoring every value it writes.
#
# The decisive evidence is not the revision register -- a floating bus can
# produce a plausible-looking constant. It is SMEM: the ABE's sample memory is
# 24 bits wide, so writing 0xFFFFFFFF must read back 0x00FFFFFF. Nothing but
# real ABE silicon masks exactly the top byte.
#
set -uo pipefail

VERBOSE=no
case "${1:-}" in
--verbose|-v) VERBOSE=yes ;;
-h|--help)    sed -n '3,44p' "$0" | sed 's/^# \?//'; exit 0 ;;
"")           ;;
*)            echo "unknown option: $1" >&2; exit 2 ;;
esac

[ "$(id -u)" = 0 ] || { echo "run this with sudo" >&2; exit 2; }

TM=/sys/bus/platform/drivers/ti-sysc/401f1000.target-module
AESS_MPU=0x401f1000     # register block, MPU private access
AESS_DMEM=0x40180000    # 64 KiB data memory
AESS_SMEM=0x401c0000    # 64 KiB sample memory, 24-bit words
AESS_PMEM=0x401e0000    # program memory

say()  { printf '\n== %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }

# ------------------------------------------------------------------ tooling
# devmem2 is deliberately not used; see the header.
DEVMEM=
for c in /usr/bin/busybox /bin/busybox; do
	[ -x "$c" ] && { DEVMEM="$c devmem"; break; }
done
[ -n "$DEVMEM" ] || { echo "need busybox for devmem; devmem2 on this image reads 0x0 for everything" >&2; exit 2; }

rd() { $DEVMEM "$1" 32 2>/dev/null; }
wr() { $DEVMEM "$1" 32 "$2" >/dev/null 2>&1; }

say "checking the register-reading tool before trusting it"
# CONTROL_ID_CODE is in the always-on control module. It can never read 0x0,
# and on an OMAP5432 ES2.0 it reads 0x1B99802F.
IDCODE=$(rd 0x4a002204)
info "CONTROL_ID_CODE 0x4a002204 = ${IDCODE:-<no read>}"
case "$IDCODE" in
0x1B99802F) info "OMAP5432 ES2.0, and the tool reads real registers" ;;
0x0|"")     echo "  CONTROL_ID_CODE read as '${IDCODE:-nothing}'. The tool is not reading"
            echo "  registers, so nothing below would mean anything. Refusing to continue." >&2
            exit 1 ;;
*)          info "unexpected id code -- not a 5432 ES2.0? continuing, but treat results with care" ;;
esac

# ------------------------------------------------------------------ preflight
say "checking the AESS is claimed by a driver"
[ -e "$TM" ] || { echo "no $TM -- this kernel has no ti-sysc node for the AESS" >&2; exit 1; }
if [ -d "$TM/401f1000.aess" ]; then
	info "401f1000.aess is bound to the aess driver"
else
	info "401f1000.aess is NOT bound -- the probe can still run, the module just has no driver"
fi

say "power domain, before touching anything"
PWRSTST=$(rd 0x4ae06504)
info "PM_ABE_PWRSTST      0x4ae06504 = $PWRSTST"
info "PM_ABE_PWRSTCTRL    0x4ae06500 = $(rd 0x4ae06500)"
info "CM_ABE_CLKSTCTRL    0x4a004500 = $(rd 0x4a004500)"
info "CM_ABE_AESS_CLKCTRL 0x4a004528 = $(rd 0x4a004528)"
if [ "$PWRSTST" = 0x0 ]; then
	echo "  abe_pwrdm reads 0x0, which is impossible for a live PRM. Refusing to continue." >&2
	exit 1
fi

# ------------------------------------------------------------------ power on
ORIG_CONTROL=$(cat "$TM/power/control")
restore() {
	[ -n "${ORIG_CONTROL:-}" ] || return 0
	echo "$ORIG_CONTROL" > "$TM/power/control" 2>/dev/null
	printf '\n== restored power/control to %s (now %s)\n' \
		"$ORIG_CONTROL" "$(cat "$TM/power/control" 2>/dev/null)"
}
trap restore EXIT

say "forcing the target module active"
info "was: runtime_status=$(cat "$TM/power/runtime_status"), control=$ORIG_CONTROL"
echo on > "$TM/power/control"
sleep 1
ST=$(cat "$TM/power/runtime_status")
info "now: runtime_status=$ST"
if [ "$ST" != active ]; then
	echo "  module did not come active. NOT reading it -- a read of a gated"
	echo "  OMAP module is an external abort, not an error code." >&2
	exit 1
fi

# ------------------------------------------------------------------ registers
say "AESS register block at $AESS_MPU"
reg() {  # reg <offset-hex> <name>
	printf '  +0x%-4s %-26s = %s\n' "$1" "$2" "$(rd "$(printf '0x%x' $((AESS_MPU + 0x$1)))")"
}
reg 00 REVISION
reg 10 SYSCONFIG
reg 68 EVENT_GENERATOR_COUNTER
reg 70 EVENT_SOURCE_SELECTION
reg 74 AUDIO_ENGINE_SCHEDULER
reg 7C AUTO_GATING_ENABLE
if [ "$VERBOSE" = yes ]; then
	reg 24 MCU_IRQSTATUS_RAW
	reg 28 MCU_IRQSTATUS
	reg 3C MCU_IRQENABLE_SET
	reg 60 DMAENABLE_SET
	reg 6C EVENT_GENERATOR_START
	reg 84 DMASTATUS_RAW
fi

REVISION=$(rd "$AESS_MPU")
SCHED=$(rd "$(printf '0x%x' $((AESS_MPU + 0x74)))")

# Do not poke memory out from under a running engine. Nothing in this tree
# starts it today, but that is exactly the assumption that stops being true.
if [ "$SCHED" != 0x00000000 ]; then
	echo
	echo "  AUDIO_ENGINE_SCHEDULER is $SCHED -- the engine looks like it is running."
	echo "  Not writing to its memory. Register evidence above still stands." >&2
	exit 1
fi

# ------------------------------------------------------------------ memories
# Each word is read, written twice with different patterns, and put back.
# Sets GOT rather than echoing it, so the human-readable line still reaches
# the terminal instead of being eaten by a command substitution.
GOT=
roundtrip() {  # roundtrip <label> <addr> <pattern>
	local label=$1 addr=$2 pat=$3 orig
	orig=$(rd "$addr")
	wr "$addr" "$pat"
	GOT=$(rd "$addr")
	wr "$addr" "$orig"
	printf '  %-5s %s  wrote %s  read %s  restored %s\n' \
		"$label" "$addr" "$pat" "$GOT" "$(rd "$addr")"
}

say "memory round-trip (every value written is restored)"
roundtrip DMEM "$AESS_DMEM" 0xA5A5F00D; DMEM_GOT=$GOT
roundtrip PMEM "$AESS_PMEM" 0xDEADBEEF; PMEM_GOT=$GOT
roundtrip SMEM "$AESS_SMEM" 0xFFFFFFFF; SMEM_GOT=$GOT
# The last word of DMEM, to show the whole 64 KiB bank is decoded and not just
# the first page.
roundtrip DMEM "$(printf '0x%x' $((AESS_DMEM + 0xfffc)))" 0xA5A5F00D; DEND_GOT=$GOT

# ------------------------------------------------------------------ verdict
say "verdict"
fail=0
check() {  # check <what> <got> <want> <why>
	if [ "$2" = "$3" ]; then printf '  ok    %-34s %s\n' "$1" "$2"
	else printf '  FAIL  %-34s got %s, expected %s\n     %s\n' "$1" "$2" "$3" "$4"; fail=1; fi
}
check "DMEM holds a 32-bit pattern"  "$DMEM_GOT" 0xA5A5F00D "data memory is not backing writes"
check "DMEM decodes to +0xfffc"      "$DEND_GOT" 0xA5A5F00D "only the first page responds; bank may be aliased"
check "PMEM holds a 32-bit pattern"  "$PMEM_GOT" 0xDEADBEEF "program memory is not writable; firmware could not be loaded"
check "SMEM masks to 24 bits"        "$SMEM_GOT" 0x00FFFFFF "sample memory is not 24 bits wide -- this is the test that a floating bus fails"

if [ "$REVISION" = 0x00000000 ] || [ "$REVISION" = 0xFFFFFFFF ]; then
	printf '  FAIL  %-34s %s\n' "REVISION is a bus artefact" "$REVISION"; fail=1
else
	printf '  ok    %-34s %s\n' "REVISION reads plausibly" "$REVISION"
fi

echo
if [ "$fail" = 0 ]; then
	cat <<'EOF'
The AESS is real, powered and addressable on this machine. Its three memories
read and write, and SMEM has the 24-bit width the ABE architecture specifies,
which a floating or aliased bus cannot fake.

That settles the hardware question only. Two software blockers remain, both
found while writing this:

  1. sound/soc/ti/omap-abe-twl6040.c:451, omap_abe_add_aess_dai_links() is an
     empty stub -- it declares four locals, uses none, and returns 0. The
     firmware loads and the front-end DAIs (MultiMedia1, MultiMedia1 LP, ...)
     register, then nothing connects them to the card, so probe falls through
     to the direct McPDM link.

  2. The aess device's runtime PM reads "unsupported" -- the driver never
     calls pm_runtime_enable(), so omap_aess_pm_get() returns -EACCES and does
     nothing. This script had to force the module on through ti-sysc to read
     it at all. Even with DAI links in place, nothing would power the engine.

Also worth a look, though it is not biting today: abe_54xx_pwrdm in
arch/arm/mach-omap2/powerdomains54xx_data.c sets pwrsts_mem_on to PWRSTS_OFF_RET
for both banks, where OMAP4's abe_44xx_pwrdm sets PWRSTS_ON. PM_ABE_PWRSTCTRL
currently has both ONSTATE fields at ON, so the reset default is doing the
right thing and the table has never been applied -- but if anything ever calls
into the pwrdm memory-state code for this domain, it would program the AESS
memory down to retention while the domain is on.
EOF
else
	cat <<'EOF'
The AESS did not pass. Read the failures above before concluding the silicon
is dead -- an unbound driver, a gated power domain, or a broken devmem will
all produce failures here and none of them mean the hardware is absent.
EOF
fi

exit "$fail"
