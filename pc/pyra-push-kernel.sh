#!/bin/sh
# Push a cross-built kernel to a Pyra, and optionally install and reboot it.
#
# This is the step between ./pyra-crossbuild.sh and the installer that runs on
# the device. On its own it copies the tarball and the repository's device/ and
# patches/ directories, which is everything the device side needs. With
# --install it runs pyra-install-debug-kernel.sh over ssh; with --reboot it
# reboots afterwards, waits for the machine to come back, and reports what is
# running.
#
# Every rebuild keeps the same release name, so installing one while the device
# is running it needs --replace-running, which this passes for you when the
# names match. That overwrites the live module tree, which is why --install
# without --reboot prints a warning rather than leaving you to find out.
#
#   ./pyra-push-kernel.sh pyra@192.168.0.10
#   ./pyra-push-kernel.sh --install --reboot pyra@192.168.0.10
#   PYRA_HOST=pyra@192.168.0.10 ./pyra-push-kernel.sh --install --reboot
#
# The tarball defaults to the fix build. Name another with --tarball, or point
# PYRA_BUILD_DIR somewhere else, exactly as the build script does.
#
# It copies and it reboots. It writes nothing to the card directly and makes no
# decision the installer would not make.

set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SELF_DIR/.." && pwd)
BUILD_DIR=${PYRA_BUILD_DIR:-$HOME/git/dragonbox-pyra-build}

TARBALL=$BUILD_DIR/kernel/fix-kernel.tar.gz
HOST=${PYRA_HOST:-}
DO_INSTALL=no
DO_REBOOT=no
REMOTE_DIR=dragonbox-pyra

say()  { echo; echo "== $*"; }
note() { echo "  $*"; }
die()  { echo "FAILED: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case $1 in
	--install)  DO_INSTALL=yes; shift ;;
	--reboot)   DO_REBOOT=yes; shift ;;
	--tarball)  [ $# -ge 2 ] || die "--tarball needs a path"
	            TARBALL=$2; shift 2 ;;
	-h|--help)  sed -n '2,25p' "$0" | sed 's/^# \?//'; exit 0 ;;
	-*)         die "unknown option: $1" ;;
	*)          [ -z "$HOST" ] || die "one host at a time"
	            HOST=$1; shift ;;
	esac
done

[ -n "$HOST" ] || die "no host. Pass one, or set PYRA_HOST.
  It is whatever you would give ssh, so pyra@<address>."
[ -r "$TARBALL" ] || die "no tarball at $TARBALL
  Build one first:  ./pc/pyra-crossbuild.sh kernel-fix"

case $HOST in *@*) ;; *) die "give the user too, as pyra@<address>" ;; esac

# The release name lives in the tarball, so the same rules apply here as in the
# installer: it is the tarball that decides, never the file name.
REL=$(tar tzf "$TARBALL" | sed -n 's|^\./boot/vmlinuz-||p' | head -1)
[ -n "$REL" ] || die "$TARBALL has no ./boot/vmlinuz-* in it. Is it a kernel tarball?"

say "what is going where"
note "tarball  $TARBALL"
note "release  $REL"
note "host     $HOST"

# Fail here rather than three commands later, and say the thing that is almost
# always wrong when it does fail.
ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" true 2>/dev/null || die \
"cannot reach $HOST without a password.
  If the key is in an agent other than the default one, that agent's socket has
  to be in SSH_AUTH_SOCK. Look in ~/.ssh/agent/ for it."

RUNNING=$(ssh -o ConnectTimeout=10 "$HOST" 'uname -r')
note "running  $RUNNING"

say "copying the kernel"
scp -q "$TARBALL" "$HOST:$(basename "$TARBALL")"
note "$(basename "$TARBALL") copied"

say "copying the device scripts and the patches"
rsync -a "$REPO_DIR/device" "$REPO_DIR/patches" "$HOST:$REMOTE_DIR/"
note "device/ and patches/ are current on the device"

if [ "$DO_INSTALL" = no ]; then
	say "not installing, because you did not ask"
	echo "  Finish it on the device with:"
	echo
	if [ "$REL" = "$RUNNING" ]; then
	echo "    sudo ./$REMOTE_DIR/device/pyra-install-debug-kernel.sh \\"
	echo "         --replace-running $(basename "$TARBALL")"
	echo
	echo "  --replace-running because $REL is what it is running now, so this"
	echo "  install replaces the module tree underneath it. Reboot straight after."
	else
	echo "    sudo ./$REMOTE_DIR/device/pyra-install-debug-kernel.sh $(basename "$TARBALL")"
	fi
	exit 0
fi

REPLACE=
if [ "$REL" = "$RUNNING" ]; then
	REPLACE=--replace-running
	say "installing over the running kernel"
	note "$REL is what it is running, so its module tree is replaced in place"
	[ "$DO_REBOOT" = yes ] || note "WARNING: you did not ask for a reboot. Do it yourself, soon."
else
	say "installing beside the running kernel"
fi

ssh -o ConnectTimeout=10 "$HOST" \
	"sudo ./$REMOTE_DIR/device/pyra-install-debug-kernel.sh $REPLACE $(basename "$TARBALL")"

if [ "$DO_REBOOT" = no ]; then
	say "installed, not rebooted"
	echo "  Reboot when you are ready. Check what will boot first:"
	echo
	echo "    sudo pyra-boot-kernel.sh status"
	exit 0
fi

say "rebooting"
ssh -o ConnectTimeout=10 "$HOST" 'sudo systemctl reboot' || true

# It goes away before it comes back, so do not believe the first few seconds.
sleep 10
n=0
while [ "$n" -lt 60 ]; do
	if back=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" 'uname -r' 2>/dev/null); then
		say "back up"
		note "running  $back"
		[ "$back" = "$REL" ] || die "it came back on $back, not $REL.
  Something else is the default. Look at: sudo pyra-boot-kernel.sh status"
		ssh -o ConnectTimeout=10 "$HOST" 'uptime -p; df -h /boot | tail -1'
		exit 0
	fi
	n=$((n + 1))
	sleep 5
done

die "it did not come back within five minutes.
  If it is on the serial console it may be sitting at the boot menu."
