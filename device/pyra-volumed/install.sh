#!/bin/sh
# install.sh -- put the calibrated pyra_volumed in place of pyra-hacks' one.
#
#   sudo ./install.sh          build, install, restart the service
#   sudo ./install.sh --undo   go back to the packaged daemon
#
# Runs on the Pyra. Builds pyra_volumed.c into /usr/local/bin and points the
# packaged pyra_volumed.service at it with a drop-in, so the pyra-hacks
# package is not modified and an upgrade of it cannot fight this. Needs gcc
# and libasound2-dev; not libiio.
set -eu
cd "$(dirname "$0")"
BIN=/usr/local/bin/pyra_volumed
DROPIN=/etc/systemd/system/pyra_volumed.service.d/calibrated.conf

if [ "${1:-}" = --undo ]; then
	rm -f "$DROPIN" "$BIN"
	rmdir "$(dirname "$DROPIN")" 2>/dev/null || true
	systemctl daemon-reload
	systemctl restart pyra_volumed
	echo "back to $(systemctl show -p ExecStart --value pyra_volumed | sed -n 's/.*path=\([^ ;]*\).*/\1/p')"
	exit 0
fi

cc -O2 -Wall -o "$BIN.new" pyra_volumed.c -lasound -lm
mv "$BIN.new" "$BIN"
mkdir -p "$(dirname "$DROPIN")"
cat > "$DROPIN" <<'UNIT'
# The volume wheel through its measured taper, not as a linear reading.
# From dragonbox-pyra device/pyra-volumed/. Delete this file (or run
# install.sh --undo) for the packaged /usr/bin/pyra_volumed.
[Service]
ExecStart=
ExecStart=/usr/local/bin/pyra_volumed
UNIT
systemctl daemon-reload
systemctl restart pyra_volumed
sleep 1
systemctl is-active pyra_volumed
pgrep -a pyra_volumed
