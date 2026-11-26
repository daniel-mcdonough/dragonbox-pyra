#!/bin/sh
# pyra-ptitseb-libs.sh — give ptitSeb's P* emulators (PSNes, PNes, PGen,
# PFBneo, build 03) the two buster libraries they need on trixie, inside each
# package's own appdata folder. Nothing is installed into the system.
#
#   ./pyra-ptitseb-libs.sh               fetch, check and copy (the default)
#   ./pyra-ptitseb-libs.sh --debs DIR    use the two .debs already in DIR
#   ./pyra-ptitseb-libs.sh --check       what each emulator has now
#   ./pyra-ptitseb-libs.sh --undo        remove the two files again
#
# Run it as the desktop user, after the .dbp files are in dragonbox/packages/
# and registered. It works on the emulators it finds registered and skips the
# others; run it again after adding one.
#
# WHY
#
# Build 03's binaries need libtinyxml2.so.6 and libfuse.so.2. Trixie has
# neither: tinyxml2 moved to .so.11, and libfuse2t64 has the right soname but
# a 64-bit time_t, which corrupts every file the emulators read through their
# FUSE romfs. Buster's two are the ABI the binaries were built for, and need
# only libc and libstdc++.
#
# Each emulator's launcher (psnes.sh etc.) puts <union>/lib first on
# LD_LIBRARY_PATH. The union is the read-only image with
# <card>/dragonbox/appdata/<id>/ as its writable branch, so files in
# appdata/<id>/lib/ show up in <union>/lib next to the image's own. Only that
# program loads them. docs/dbp.md, "ptitSeb's P* emulators".
#
# TRUST
#
# The .debs are checked against the SHA-256s below, which are the ones in
# buster's main/binary-armhf/Packages, signed through buster's InRelease by the
# "Debian Stable Release Key (10/buster)" (trixie keeps it in
# /usr/share/keyrings/debian-archive-removed-keys.gpg). docs/dbp.md shows how to
# check that chain yourself. The libraries taken out of them are checked too.
set -eu

ARCHIVE=https://archive.debian.org/debian
IDS="psnes pnes pgen pfbneo"

TX_DEB=libtinyxml2-6a_7.0.0+dfsg-1_armhf.deb
TX_URL=$ARCHIVE/pool/main/t/tinyxml2/$TX_DEB
TX_DEB_SHA=e6e812f6d5d8ada7c73534c805b357f73e6aa009099c14ea654cea32bc106e8e
TX_SO=usr/lib/arm-linux-gnueabihf/libtinyxml2.so.6.2.0
TX_NAME=libtinyxml2.so.6
TX_SO_SHA=8c41daedc60746b9859b99fc214f2ac830de261bc61666bb5c07ea402498bd69

FU_DEB=libfuse2_2.9.9-1+deb10u1_armhf.deb
FU_URL=$ARCHIVE/pool/main/f/fuse/$FU_DEB
FU_DEB_SHA=c0a8c4ab83d337bca5738da2a7df264962f4269778b93a2814923a4a3ebb303d
FU_SO=lib/arm-linux-gnueabihf/libfuse.so.2.9.9
FU_NAME=libfuse.so.2
FU_SO_SHA=eb638c364f53d0ee9e36e3290a6c4b4b5a0120dd1c8c3b613cd14edb3f8a08d3

die() { echo "pyra-ptitseb-libs: $*" >&2; exit 1; }

sha_ok() { # file expected
	[ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]
}

# The appdata folder of a registered id, or nothing. None of the four sets an
# Appdata= key, so the folder carries the id.
appdata_of() {
	mnt=$(dbp-cmd getmount "$1" 2>/dev/null) || return 0
	[ -n "$mnt" ] || return 0
	echo "${mnt%/}/dragonbox/appdata/$1"
}

registered() {
	for id in $IDS; do
		dbp-cmd path "$id" >/dev/null 2>&1 && echo "$id"
	done
	return 0
}

check() {
	for id in $IDS; do
		if ! dbp-cmd path "$id" >/dev/null 2>&1; then
			echo "$id: not registered"
			continue
		fi
		lib=$(appdata_of "$id")/lib
		state=ok
		for pair in "$TX_NAME $TX_SO_SHA" "$FU_NAME $FU_SO_SHA"; do
			# shellcheck disable=SC2086 # split "name sha"
			set -- $pair
			if [ ! -f "$lib/$1" ]; then state="missing $1"; break; fi
			sha_ok "$lib/$1" "$2" || { state="$1 differs from buster's"; break; }
		done
		echo "$id: $state ($lib)"
	done
}

undo() {
	for id in $(registered); do
		lib=$(appdata_of "$id")/lib
		[ "$lib" != /lib ] || { echo "$id: no mount point from dbp-cmd getmount, skipped"; continue; }
		for pair in "$TX_NAME $TX_SO_SHA" "$FU_NAME $FU_SO_SHA"; do
			# shellcheck disable=SC2086 # split "name sha"
			set -- $pair
			[ -f "$lib/$1" ] || continue
			# Leave a file this script didn't put there.
			if sha_ok "$lib/$1" "$2"; then
				rm "$lib/$1" && echo "$id: removed $1"
			else
				echo "$id: kept $lib/$1 (not buster's)"
			fi
		done
		rmdir "$lib" 2>/dev/null || true
	done
}

apply() {
	debs=$1
	ids=$(registered)
	[ -n "$ids" ] || die "none of $IDS is registered; copy the .dbp files to dragonbox/packages/ first"

	work=$(mktemp -d)
	trap 'rm -rf "$work"' EXIT INT TERM
	for spec in "$TX_DEB $TX_URL $TX_DEB_SHA" "$FU_DEB $FU_URL $FU_DEB_SHA"; do
		# shellcheck disable=SC2086 # split "deb url sha"
		set -- $spec
		if [ -n "$debs" ]; then
			[ -f "$debs/$1" ] || die "$debs/$1 not found"
			cp "$debs/$1" "$work/$1"
		else
			echo "fetching $2"
			wget -q -O "$work/$1" "$2" || die "download failed: $2"
		fi
		sha_ok "$work/$1" "$3" || die "$1: SHA-256 doesn't match buster's Packages; not using it"
		dpkg-deb -x "$work/$1" "$work/x"
	done
	sha_ok "$work/x/$TX_SO" "$TX_SO_SHA" || die "$TX_SO: unexpected contents"
	sha_ok "$work/x/$FU_SO" "$FU_SO_SHA" || die "$FU_SO: unexpected contents"

	for id in $ids; do
		lib=$(appdata_of "$id")/lib
		[ "$lib" != /lib ] || die "$id: no mount point from dbp-cmd getmount"
		mkdir -p "$lib"
		cp "$work/x/$TX_SO" "$lib/$TX_NAME"
		cp "$work/x/$FU_SO" "$lib/$FU_NAME"
		echo "$id: $TX_NAME and $FU_NAME in $lib"
	done
}

[ "$(id -u)" -ne 0 ] || die "run this as the desktop user, not root (appdata belongs to the user)"
command -v dbp-cmd >/dev/null || die "dbp-cmd not found; is the dbp package installed?"

case "${1:-}" in
	"")      apply "" ;;
	--debs)  [ -n "${2:-}" ] || die "--debs needs a directory"; apply "$2" ;;
	--check) check ;;
	--undo)  undo ;;
	*)       sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
