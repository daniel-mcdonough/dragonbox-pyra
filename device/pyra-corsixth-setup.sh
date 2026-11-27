#!/bin/sh
# pyra-corsixth-setup.sh — make CorsixTH 0.68.0-r1 (CorsixTH_maquis196) start on
# trixie, from files in its own appdata folder. Nothing is installed into the
# system.
#
#   ./pyra-corsixth-setup.sh           fetch, check and copy (the default)
#   ./pyra-corsixth-setup.sh --demo    the same, plus the free Theme Hospital demo
#   ./pyra-corsixth-setup.sh --check   whether the files are there and unchanged
#   ./pyra-corsixth-setup.sh --undo    remove what this script put there
#
# Run it as the desktop user, after corsixth_0.68.0-r1_maquis196.dbp is in
# dragonbox/packages/ and registered. It needs the network. It downloads about
# 30 MB of Debian package indices, 19 .debs and the CorsixTH source tarball.
#
# WHY
#
# The package holds only the binary and its launcher. It lacks three things.
# One is the Lua scripts that are most of the game. The binary looks for them
# only at an --interpreter= argument or in its builder's home directory.
# Another is bookworm libraries trixie doesn't have: FFmpeg 5 and libcurl-nss,
# and what they pull in. The last is liblua5.3, which trixie has but doesn't
# install. /etc/dbp/run_script sources package.user_prerun from the union
# root before the launcher runs. The union is the read-only image with
# <card>/dragonbox/appdata/CorsixTH/ as its writable branch, so a file there
# can set the library path and add the --interpreter argument. docs/dbp.md,
# "CorsixTH (Theme Hospital)".
#
# What goes into the appdata folder:
#   lib/                 19 libraries (17 from bookworm, liblua5.3 and libhwy
#                        from trixie), each under its soname
#   lua/5.3/             lpeg.so and lfs.so, from trixie
#   corsixth-0.68.0/     the Lua tree of the upstream v0.68.0 tag
#   package.user_prerun  sets LD_LIBRARY_PATH and LUA_CPATH, adds --interpreter
#   CorsixTH/            the game's config folder, from the package's defaults
#                        with check_for_updates = false (only when missing)
#   .pyra-corsixth-setup SHA-256 of every file above but CorsixTH/, for
#                        --check and --undo
#
# TRUST
#
# Each .deb is checked against the SHA-256 in a Packages index, whose own
# SHA-256 is in the suite's InRelease. InRelease must carry a good signature
# from a key in /usr/share/keyrings/debian-archive-keyring.gpg, which holds the
# bookworm and trixie archive keys. For each package the highest version across
# the suite, its -updates and its -security wins. The CorsixTH tarball is
# GitHub's archive of the v0.68.0 tag, checked against the SHA-256 below.
# That archive verifies against CorsixTH-0.68.0.tar.gz.sig, on the upstream
# release, made by the key that signed the tag
# (DB14 7D8C D673 7D34 210D 2023 5C25 1992 033D 3D7C). The demo is checked
# against a SHA-256 too.
set -eu

ID=CorsixTH_maquis196
DEBIAN=https://deb.debian.org/debian
SECURITY=https://security.debian.org/debian-security
KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg

TREE=corsixth-0.68.0
TREE_URL=https://github.com/CorsixTH/CorsixTH/archive/refs/tags/v0.68.0.tar.gz
TREE_SHA=54034b8434f5c583178405d2c84477f903fe2b15933b611f42230668e35d632e
TREE_PARTS="CorsixTH.lua Lua Bitmap Levels Campaigns Graphics"

DEMO_URL=https://th.corsix.org/Demo.zip
DEMO_SHA=d6b79b6f76e91413ecbf552a397e283e124a223263491cb08f803ae0b660f897

# release package file... ; each file goes into lib/ under that name.
LIBS="
bookworm libavformat59   libavformat.so.59
bookworm libavcodec59    libavcodec.so.59
bookworm libavutil57     libavutil.so.57
bookworm libswscale6     libswscale.so.6
bookworm libswresample4  libswresample.so.4
bookworm libvpx7         libvpx.so.7
bookworm libdav1d6       libdav1d.so.6
bookworm libcodec2-1.0   libcodec2.so.1.0
bookworm libjxl0.7       libjxl.so.0.7 libjxl_threads.so.0.7
bookworm librav1e0       librav1e.so.0
bookworm libsvtav1enc1   libSvtAv1Enc.so.1
bookworm libx265-199     libx265.so.199
bookworm libssh-gcrypt-4 libssh-gcrypt.so.4
bookworm libcurl3-nss    libcurl-nss.so.4
bookworm libldap-2.5-0   libldap-2.5.so.0 liblber-2.5.so.0
trixie   liblua5.3-0     liblua5.3.so.0
trixie   libhwy1t64      libhwy.so.1
"
# The same, into lua/5.3/. Each package has a build for every Lua version, so
# these name the path that ends the file's.
LUAMODS="
trixie lua-lpeg       lua/5.3/lpeg.so
trixie lua-filesystem lua/5.3/lfs.so
"

MARK="# Written by pyra-corsixth-setup.sh"
MANIFEST=.pyra-corsixth-setup

die() { echo "pyra-corsixth-setup: $*" >&2; exit 1; }

sha_ok() { # file expected
	[ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]
}

# <card>/dragonbox/appdata/<Appdata=> of the registered package.
appdata_dir() {
	mnt=$(dbp-cmd getmount "$ID" 2>/dev/null) || mnt=
	[ -n "$mnt" ] || die "$ID: no mount point from dbp-cmd getmount; is the .dbp registered?"
	name=$(sed -n 's/^Appdata=//p' "/usr/share/applications/__dbp__${ID}_default.desktop" 2>/dev/null | head -n1)
	echo "${mnt%/}/dragonbox/appdata/${name:-$ID}"
}

# Fetch and check the index of one suite into $work/idx/<suite>.
# The mirror is in $work/idx/<suite>.base.
fetch_index() { # base suite
	base=$1 suite=$2 dir=$work/idx
	mkdir -p "$dir"
	wget -q -O "$dir/$suite.InRelease" "$base/dists/$suite/InRelease" ||
		die "download failed: $base/dists/$suite/InRelease"
	gpgv --quiet --keyring "$KEYRING" --output "$dir/$suite.Release" "$dir/$suite.InRelease" 2>/dev/null ||
		die "$suite: InRelease has no good signature from $KEYRING"
	# Only the signed text from here on.
	grep -qx "Suite: $suite\|Codename: $suite" "$dir/$suite.Release" ||
		die "$suite: the signed Release is for another suite"
	until=$(sed -n 's/^Valid-Until: //p' "$dir/$suite.Release")
	if [ -n "$until" ] && [ "$(date -d "$until" +%s)" -lt "$(date +%s)" ]; then
		die "$suite: Release expired at $until (is the clock right?)"
	fi
	want=$(awk '/^SHA256:/ { s = 1; next } /^[^ ]/ { s = 0 }
		s && $3 == "main/binary-armhf/Packages.xz" { print $1 }' "$dir/$suite.Release")
	[ -n "$want" ] || die "$suite: no main/binary-armhf/Packages.xz in Release"
	wget -q -O "$dir/$suite.xz" "$base/dists/$suite/main/binary-armhf/Packages.xz" ||
		die "download failed: $base/dists/$suite/main/binary-armhf/Packages.xz"
	sha_ok "$dir/$suite.xz" "$want" || die "$suite: Packages.xz doesn't match its signed Release"
	xz -dc "$dir/$suite.xz" >"$dir/$suite"
	rm "$dir/$suite.xz"
	echo "$base" >"$dir/$suite.base"
	echo "  $suite: signed index checked"
}

# "base filename sha256 version" of the highest version of a package across a
# release, its -updates and its -security.
pick() { # release package
	best='' bestv=''
	for suite in "$1" "$1-updates" "$1-security"; do
		idx=$work/idx/$suite
		awk -v p="$2" 'BEGIN { RS = ""; FS = "\n" }
		{
			n = v = f = s = ""
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^Package: /) n = substr($i, 10)
				else if ($i ~ /^Version: /) v = substr($i, 10)
				else if ($i ~ /^Filename: /) f = substr($i, 11)
				else if ($i ~ /^SHA256: /) s = substr($i, 9)
			}
			if (n == p) print v, f, s
		}' "$idx" >"$work/hits"
		while read -r v f s; do
			if [ -z "$bestv" ] || dpkg --compare-versions "$v" gt "$bestv"; then
				bestv=$v best="$(cat "$idx.base") $f $s $v"
			fi
		done <"$work/hits"
	done
	[ -n "$best" ] || die "$2 not found in $1, $1-updates or $1-security"
	echo "$best"
}

# Download, check and unpack one package into $work/x/<package>.
get_deb() { # release package
	p=$(pick "$1" "$2") || exit 1
	# shellcheck disable=SC2086 # split "base file sha version"
	set -- $p "$2"
	deb=$work/$5.deb
	wget -q -O "$deb" "$1/$2" || die "download failed: $1/$2"
	sha_ok "$deb" "$3" || die "$5: SHA-256 doesn't match the signed Packages; not using it"
	mkdir -p "$work/x/$5"
	dpkg-deb -x "$deb" "$work/x/$5"
	rm "$deb"
	echo "  $5 $4"
}

# Copy the file whose path ends in $tail from an unpacked package, following
# its symlinks, to destdir under its own name.
take() { # package tail destdir
	src=$(find "$work/x/$1" -path "*/$2" \( -type f -o -type l \) | head -n1)
	[ -n "$src" ] || die "$1 has no file */$2"
	mkdir -p "$3"
	cp -L "$src" "$3/${2##*/}"
}

install_set() { # list destsubdir
	echo "$1" | while read -r rel pkg names; do
		[ -n "$rel" ] || continue
		get_deb "$rel" "$pkg"
		for n in $names; do take "$pkg" "$n" "$stage/$2"; done
	done
}

apply() {
	demo=$1
	app=$(appdata_dir)
	for c in wget gpgv xz dpkg-deb tar; do
		command -v "$c" >/dev/null || die "$c not found"
	done
	[ -n "$demo" ] && { command -v unzip >/dev/null || die "unzip not found (needed for --demo)"; }
	[ -r "$KEYRING" ] || die "$KEYRING missing (package debian-archive-keyring)"
	if [ -f "$app/package.user_prerun" ] && ! grep -q "^$MARK" "$app/package.user_prerun"; then
		die "$app/package.user_prerun exists and isn't this script's; move it aside first"
	fi

	work=$(mktemp -d)
	trap 'rm -rf "$work"' EXIT INT TERM
	stage=$work/stage
	mkdir -p "$stage"

	echo "Debian indices:"
	for rel in bookworm trixie; do
		fetch_index "$DEBIAN" "$rel"
		fetch_index "$DEBIAN" "$rel-updates"
		fetch_index "$SECURITY" "$rel-security"
	done

	echo "Packages:"
	install_set "$LIBS" lib
	install_set "$LUAMODS" lua/5.3

	echo "CorsixTH v0.68.0 Lua tree:"
	wget -q -O "$work/tree.tar.gz" "$TREE_URL" || die "download failed: $TREE_URL"
	sha_ok "$work/tree.tar.gz" "$TREE_SHA" || die "CorsixTH tarball doesn't match the v0.68.0 SHA-256; not using it"
	tar -xzf "$work/tree.tar.gz" -C "$work"
	mkdir -p "$stage/$TREE"
	for p in $TREE_PARTS; do
		cp -R "$work/CorsixTH-0.68.0/CorsixTH/$p" "$stage/$TREE/"
	done
	echo "  $TREE_URL"

	cat >"$stage/package.user_prerun" <<EOF
$MARK; /etc/dbp/run_script sources it
# before CorsixTH.launch. lib/ has bookworm's FFmpeg 5 and libcurl-nss, which
# trixie lacks, and liblua5.3. $TREE/ is the upstream Lua tree the package
# doesn't ship. docs/dbp.md, "CorsixTH (Theme Hospital)".
export LD_LIBRARY_PATH="\$DBP_UNION_DIR/lib:\$LD_LIBRARY_PATH"
export LUA_CPATH="\$DBP_UNION_DIR/lua/5.3/?.so;;"
set -- "\$@" "--interpreter=\$DBP_UNION_DIR/$TREE/CorsixTH.lua"
EOF

	# Every library the binary and the copied libraries need must resolve
	# from lib/ plus the system.
	tok=$(dbp-cmd mount "$ID") || die "dbp-cmd mount $ID failed"
	union=/mnt/dbp/union/$ID
	missing=$( { LD_LIBRARY_PATH="$stage/lib" ldd "$union/corsix-th"
		for l in "$stage"/lib/*; do LD_LIBRARY_PATH="$stage/lib" ldd "$l"; done; } |
		grep 'not found' | sort -u) || true
	if [ ! -d "$app/CorsixTH" ]; then
		# The launcher makes this folder itself only at /dragonbox/appdata,
		# which is wrong when the package is on a second card.
		mkdir -p "$app/CorsixTH/Campaigns" "$app/CorsixTH/Levels" "$app/CorsixTH/Logs" \
			"$app/CorsixTH/Saves" "$app/CorsixTH/Screenshots"
		cp "$union/defaults/hotkeys.txt" "$app/CorsixTH/hotkeys.txt"
		# The update check would go through bookworm's libcurl.
		sed 's/^check_for_updates *= *true/check_for_updates = false/' \
			"$union/defaults/config.txt" >"$app/CorsixTH/config.txt"
		echo "CorsixTH/: config.txt and hotkeys.txt from the package (check_for_updates = false)"
	fi
	dbp-cmd umount "$tok" >/dev/null || true
	[ -z "$missing" ] || die "libraries still unresolved, nothing copied:
$missing"

	mkdir -p "$app"
	(cd "$stage" && find . -type f -exec sha256sum {} + | sort -k2) >"$work/manifest"
	mv "$work/manifest" "$stage/$MANIFEST"
	rm -rf "${app:?}/$TREE"
	cp -R "$stage/." "$app/"
	echo "In $app: lib/ ($(find "$stage/lib" -type f | wc -l) libraries), lua/5.3/, $TREE/, package.user_prerun"

	if [ -n "$demo" ]; then
		if [ -f "$app/HOSPITAL.EXE" ]; then
			echo "Demo: HOSPITAL.EXE is there already, skipped"
		else
			wget -q -O "$work/Demo.zip" "$DEMO_URL" || die "download failed: $DEMO_URL"
			sha_ok "$work/Demo.zip" "$DEMO_SHA" || die "Demo.zip doesn't match its SHA-256; not using it"
			unzip -q "$work/Demo.zip" -d "$work/demo"
			cp -R "$work/demo/HOSP/." "$app/"
			echo "Demo: unpacked into $app"
		fi
	elif [ ! -f "$app/HOSPITAL.EXE" ]; then
		echo "No game data yet: copy Theme Hospital's files (HOSPITAL.EXE, DATA/ ...) into $app, or run with --demo"
	fi
}

check() {
	app=$(appdata_dir)
	[ -f "$app/$MANIFEST" ] || { echo "not set up ($app/$MANIFEST missing)"; return 1; }
	if (cd "$app" && sha256sum -c --quiet "$MANIFEST"); then
		echo "ok: $(wc -l <"$app/$MANIFEST") files unchanged in $app"
	else
		echo "some files are missing or changed; run the script again"
		return 1
	fi
	[ -f "$app/HOSPITAL.EXE" ] || echo "no game data (HOSPITAL.EXE) in $app"
}

undo() {
	app=$(appdata_dir)
	[ -f "$app/$MANIFEST" ] || { echo "nothing to undo ($app/$MANIFEST missing)"; return 0; }
	# Remove only files that are still as this script wrote them.
	(cd "$app" && while read -r sum f; do
		[ -f "$f" ] || continue
		if sha_ok "$f" "$sum"; then rm "$f"; else echo "kept $app/$f (changed)"; fi
	done <"$MANIFEST")
	for d in "$TREE" lua lib; do
		[ -d "$app/$d" ] && find "$app/$d" -depth -type d -empty -delete
	done
	rm "$app/$MANIFEST"
	echo "removed the files from $app (CorsixTH/ and game data kept)"
}

[ "$(id -u)" -ne 0 ] || die "run this as the desktop user, not root (appdata belongs to the user)"
command -v dbp-cmd >/dev/null || die "dbp-cmd not found; is the dbp package installed?"
dbp-cmd path "$ID" >/dev/null 2>&1 ||
	die "$ID isn't registered; copy corsixth_0.68.0-r1_maquis196.dbp to dragonbox/packages/ first"

case "${1:-}" in
	"")      apply "" ;;
	--demo)  apply demo ;;
	--check) check ;;
	--undo)  undo ;;
	*)       sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
