#!/bin/sh
# Put every device-side helper in this repository onto a Pyra, in one command.
#
#   ./pyra-push-helpers.sh pyra@192.168.0.10
#   ./pyra-push-helpers.sh --dry-run pyra@192.168.0.10
#   PYRA_HOST=pyra@192.168.0.10 ./pyra-push-helpers.sh
#
# This is the workstation half. It copies device/ to the Pyra and then runs
# device/pyra-install-helpers.sh there, which is the thing that decides where
# each file goes. That split is deliberate: there is one install map, it lives
# next to the files it installs, and this script is a caller of it rather than
# a second opinion about /usr/local. Change where something goes by editing
# the map in the installer, and both paths follow.
#
# It existed as a side effect before this: pyra-push-kernel.sh rsyncs device/
# on its way to installing a kernel. But that one needs a built tarball and
# refuses to run without one, so there was no way to refresh the helpers alone
# after a `git pull`. This is that way.
#
#   --dry-run   copy nothing, and ask the installer what it would change
#   --list      ask the installer where each file goes, and copy nothing
#   --no-install  copy device/, but stop before running the installer
#
# Everything it touches on the device is under /usr/local, /etc/sysctl.d or the
# calling user's own systemd directory. It installs no kernel and applies none
# of the six card fixes; those are pyra-push-kernel.sh and pc/pyra-trixie-prep.sh.

set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SELF_DIR/.." && pwd)
REMOTE_DIR=dragonbox-pyra

# PYRA_HOST is the default, not the answer: an argument has to be able to
# override it, exactly as in pyra-push-kernel.sh.
HOST_ENV=${PYRA_HOST:-}
HOST=
MODE=install

say()  { echo; echo "== $*"; }
note() { echo "  $*"; }
die()  { echo "FAILED: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case $1 in
	--dry-run)    MODE=dry-run; shift ;;
	--list)       MODE=list; shift ;;
	--no-install) MODE=copy-only; shift ;;
	-h|--help)    sed -n '2,28p' "$0" | sed 's/^# \?//'; exit 0 ;;
	-*)           die "unknown option: $1" ;;
	*)            [ -z "$HOST" ] || die "one host at a time"
	              HOST=$1; shift ;;
	esac
done

[ -n "$HOST" ] || HOST=$HOST_ENV
[ -n "$HOST" ] || die "no host. Pass one, or set PYRA_HOST.
  It is whatever you would give ssh, so pyra@<address>."
case $HOST in *@*) ;; *) die "give the user too, as pyra@<address>" ;; esac

[ -d "$REPO_DIR/device" ] || die "no device/ directory in $REPO_DIR.
  Run this from the pc/ directory of a complete checkout."
[ -r "$REPO_DIR/device/pyra-install-helpers.sh" ] || die \
	"device/pyra-install-helpers.sh is missing from the checkout.
  It is the half that knows where each file goes; this script only carries it."

# --list answers from the checkout. It describes the map, and the map is the
# same file that would be copied, so there is nothing to copy first and no
# reason to need the device switched on.
if [ "$MODE" = list ]; then
	exec sh "$REPO_DIR/device/pyra-install-helpers.sh" --list
fi

# Fail here rather than three commands later, and say the thing that is almost
# always wrong when it does fail.
say "reaching the device"
ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" true 2>/dev/null || die \
"cannot reach $HOST without a password.
  If the key is in an agent other than the default one, that agent's socket has
  to be in SSH_AUTH_SOCK. Look in ~/.ssh/agent/ for it."
note "host     $HOST"
note "running  $(ssh -o ConnectTimeout=10 "$HOST" 'uname -r')"

say "copying device/"
rsync -a --delete-excluded \
	--exclude '*.o' --exclude '__pycache__' \
	"$REPO_DIR/device" "$HOST:$REMOTE_DIR/"
note "device/ is current at $HOST:$REMOTE_DIR/device"

if [ "$MODE" = copy-only ]; then
	say "copied, not installed, because you said --no-install"
	echo "  Finish it on the device with:"
	echo
	echo "    sudo ./$REMOTE_DIR/device/pyra-install-helpers.sh"
	exit 0
fi

if [ "$MODE" = dry-run ]; then
	say "asking the installer what it would change"
	ssh -o ConnectTimeout=10 "$HOST" \
		"sudo ./$REMOTE_DIR/device/pyra-install-helpers.sh --dry-run"
	exit 0
fi

say "installing on the device"
# The installer verifies every file against the checkout before it reports
# success, so there is nothing to check again from this side.
ssh -o ConnectTimeout=10 "$HOST" \
	"sudo ./$REMOTE_DIR/device/pyra-install-helpers.sh"
