#!/bin/sh
# pyra-sgx-init.sh — fix 11: start the SGX user-space services when the GPU is
# actually there, not when its module merely appears.
#
#   sudo ./pyra-sgx-init.sh             apply (the default)
#   sudo ./pyra-sgx-init.sh --check     which rule is in force, and did init run
#   sudo ./pyra-sgx-init.sh --undo      back to the DDK's own rule
#   ./pyra-sgx-init.sh --emit-into ROOT write the file under ROOT, print its path
#
# THE FAULT
#
# The DDK ships /lib/udev/rules.d/omap5-sgx-ddk-um-linux.rules, which runs
# `pvrsrvctl --start --no-module` on the *module* add event. The kernel sends
# that event before the module's init function runs, so before the driver has
# probed and before /dev/dri/card2 exists. pvrsrvctl finds the GPU by scanning
# /dev/dri, so whether it succeeds is a race with the probe. Measured on
# 2026-09-26 it lost about half the time, with the stock module and the patched
# one alike:
#
#   (udev-worker): pvrsrvkm_omap5_sgx544_116: Process '.../pvrsrvctl --start
#                  --no-module' failed with exit code 1.
#   [drm] Initialized pvr 1.14.3699939 20110701 for 56000000.gpu on minor 2
#
# and after a lost race every GL program fails with "Couldn't connect to
# services" (the kernel logs "BridgedDispatchKM: Driver initialisation not
# completed yet") until someone runs pvrsrvctl by hand.
#
# THE FIX
#
# Run it on the add event of the DRM card that belongs to pvrsrvkm instead.
# That event is sent from drm_dev_register, which pvr_probe calls after the
# services core has initialised, and udev creates /dev/dri/cardN before it runs
# anything a rule asks for. Nothing the driver does after registering is
# reached through the card node, so there is no window left.
#
# The file has the same name as the DDK's, in /etc/udev/rules.d, which shadows
# the packaged one entirely without editing it. The stop rule stays on the
# module remove event, as the DDK had it.
set -eu

RULE_PATH=/etc/udev/rules.d/omap5-sgx-ddk-um-linux.rules
STOCK_RULE=/lib/udev/rules.d/omap5-sgx-ddk-um-linux.rules
PVRSRVCTL=/opt/omap5-sgx-ddk-um-linux/bin/pvrsrvctl

emit_rule() {
	cat <<EOF
# fix 11 — shadows $STOCK_RULE.
#
# The DDK started the services on the module add event, which the kernel
# sends before the driver probes, so pvrsrvctl raced the creation of
# /dev/dri/card2 and lost about half the time. The DRM card's add event comes
# after the services core is up, and its node exists before RUN.
# device/pyra-sgx-init.sh in the dragonbox-pyra repository has the details.
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", DRIVERS=="pvrsrvkm", RUN+="$PVRSRVCTL --start --no-module"
SUBSYSTEM=="module", ACTION=="remove", DEVPATH=="/module/pvrsrvkm_omap5_sgx544_116", RUN+="$PVRSRVCTL --stop --no-module"
EOF
}

install_files() {
	root="$1"
	install -d -m 0755 "$root/etc/udev/rules.d"
	emit_rule > "$root$RULE_PATH"
	chmod 0644 "$root$RULE_PATH"
}

say_state() {
	if [ -e "$RULE_PATH" ]; then
		echo "rule: $RULE_PATH (fix 11, starts on the pvr DRM card)"
	elif [ -e "$STOCK_RULE" ]; then
		echo "rule: $STOCK_RULE (the DDK's, races the probe)"
	else
		echo "rule: none; nothing starts the SGX services"
	fi
	# Initialised if the services have reported since the driver last registered.
	# Both lines are the kernel's own, so this works on any boot of any kernel.
	if ! dmesg >/dev/null 2>&1; then
		echo "services: unknown; the kernel log needs root (run --check with sudo)"
		return 0
	fi
	last_load=$(dmesg | grep "Initialized pvr " | tail -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/')
	last_init=$(dmesg | grep "KM DDK-.*match" | tail -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/')
	if [ -z "$last_load" ]; then
		echo "driver: not loaded since the kernel log began"
	elif [ -n "$last_init" ] && awk "BEGIN{exit !($last_init >= $last_load)}"; then
		echo "services: initialised (driver at ${last_load}s, services at ${last_init}s)"
	else
		echo "services: NOT initialised since the driver loaded at ${last_load}s"
		echo "  start them by hand: sudo $PVRSRVCTL --start --no-module"
	fi
}

case "${1:---apply}" in
--emit-into)
	root="${2:?--emit-into needs a ROOT}"
	install_files "$root"
	# bare paths, one per line: the contract pc/pyra-trixie-prep.sh consumes.
	printf '%s\n' "$root$RULE_PATH"
	;;
--check)
	say_state
	;;
--undo)
	[ "$(id -u)" = 0 ] || { echo "needs root" >&2; exit 1; }
	rm -f "$RULE_PATH"
	udevadm control --reload 2>/dev/null || true
	echo "removed; $STOCK_RULE is in force again from the next module load."
	;;
--apply)
	[ "$(id -u)" = 0 ] || { echo "needs root" >&2; exit 1; }
	install_files ""
	udevadm control --reload 2>/dev/null || true
	echo "applied; it takes effect from the next time the GPU driver loads."
	say_state
	;;
*)
	sed -n '2,8p' "$0" >&2
	exit 1
	;;
esac
