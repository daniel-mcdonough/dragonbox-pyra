#!/bin/sh
# install.sh -- the calibrated pyra_volumed in place of pyra-hacks' one.
#
#   sudo ./install.sh                  install on this Pyra and restart it
#   sudo ./install.sh --undo           go back to the packaged daemon
#        ./install.sh --emit-into ROOT write the files under ROOT, nothing else
#
# The pyra-hacks package is not modified. The packaged unit is pointed at
# pyra-volumed-run by a drop-in, and that builds pyra_volumed.c with the
# card's own gcc the first time it starts (and whenever the source is newer
# than the binary). It needs only libc6-dev, which the image ships.
#
# --emit-into is the door pc/pyra-trixie-prep.sh (fix 12) goes through to put
# this on a card offline. It prints the paths it wrote, one per line, and
# does not care whether it is running on a Pyra.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=/usr/local/src/pyra-volumed/pyra_volumed.c
RUN=/usr/local/sbin/pyra-volumed-run
DROPIN=/etc/systemd/system/pyra_volumed.service.d/calibrated.conf
BIN=/usr/local/bin/pyra_volumed

emit() {
	root=$1
	install -D -m 0644 "$HERE/pyra_volumed.c" "$root$SRC"
	install -D -m 0755 "$HERE/pyra-volumed-run" "$root$RUN"
	install -D -m 0644 "$HERE/calibrated.conf" "$root$DROPIN"
	printf '%s\n' "$root$SRC" "$root$RUN" "$root$DROPIN"
}

case "${1:-}" in
--emit-into)
	emit "${2:?--emit-into needs a ROOT}"
	;;
--undo)
	rm -f "$DROPIN" "$RUN" "$BIN" "$SRC"
	rmdir "$(dirname "$DROPIN")" "$(dirname "$SRC")" 2>/dev/null || true
	systemctl daemon-reload
	systemctl restart pyra_volumed
	echo "back to the packaged /usr/bin/pyra_volumed"
	;;
"")
	emit "" >/dev/null
	rm -f "$BIN"     # force a build from the source just installed
	systemctl daemon-reload
	systemctl restart pyra_volumed
	sleep 3
	systemctl is-active pyra_volumed
	pgrep -a pyra_volumed
	;;
*)
	sed -n '2,7p' "$0" >&2
	exit 1
	;;
esac
