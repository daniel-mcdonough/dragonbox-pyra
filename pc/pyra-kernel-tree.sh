#!/usr/bin/env bash
# Turn the kernel patch sets into a git tree that reviewers can read.
#
#   ./pc/pyra-kernel-tree.sh [OUTPUT_DIR]
#
# OUTPUT_DIR defaults to ../linux-pyra-5.6.19 beside this repository.
#
# main is the stock linux-5.6.19-pyradef-10 source package, unpacked by
# dpkg-source exactly as pc/pyra-crossbuild.sh unpacks it. Each patch set is
# then one branch, stacked in the order the builds apply them:
#
#   pyra/fixes      patches/                         every kernel except stock
#   pyra/opp        + thermals-and-frequency/0007     intermediate OPPs
#   pyra/m4-ipu     + m4-ipu/                         the Cortex-M4s and the DSP
#   pyra/aess       + aess/                           the audio DSP
#   pyra/device     + gpu-power/0034 + kbd-led/       what 5.6.19-m4-kbdled carries
#                   + jack-detect/
#
#   pyra/overclock  pyra/opp + thermals-and-frequency/0008
#   pyra/c2-idle    pyra/fixes + c2-idle/0007
#   pyra/jack       pyra/fixes + jack-detect/         the headphone jack alone,
#                                                     without the AESS series
#
# so "git log main..pyra/fixes" is the fix series, "git log pyra/m4-ipu..pyra/aess"
# is the audio series, and "git format-patch -s A..B" makes sendable patches of
# either. The patch files in this repository stay the source of truth: the tree
# is generated from them and is rebuilt, not edited. Change a patch here, then
# rerun this.
#
# Needs docker (for dpkg-source) and git. Touches nothing outside OUTPUT_DIR and
# the build directory's kernel source cache.
set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$SELF_DIR/.." && pwd)
OUT=${1:-$(cd "$TOP/.." && pwd)/linux-pyra-5.6.19}
# Default: dragonbox-pyra-build beside this repository.
BUILD_DIR=${PYRA_BUILD_DIR:-$(cd "$SELF_DIR/../.." && pwd)/dragonbox-pyra-build}
KDIR=$BUILD_DIR/kernel
KERNEL_DSC=linux-5.6.19-pyradef_5.6.19-pyradef-10.dsc
EXP=$TOP/experiments

die() { echo "pyra-kernel-tree: $*" >&2; exit 1; }

[ -f "$KDIR/$KERNEL_DSC" ] || die "no $KDIR/$KERNEL_DSC; run pc/pyra-crossbuild.sh kernel once, or set PYRA_BUILD_DIR"
command -v docker >/dev/null || die "docker is not installed"

# Commits are made with fixed identities and dates so that the same patches
# always give the same hashes.
export GIT_COMMITTER_NAME="Pyra kernel tree" GIT_COMMITTER_EMAIL=noreply@example.invalid
DEFAULT_AUTHOR="Pyra kernel work <noreply@example.invalid>"

g() { git -C "$OUT" "$@"; }

# --- main: the stock source package -----------------------------------------
if [ ! -d "$OUT/.git" ]; then
	[ -e "$OUT" ] && die "$OUT exists and is not a git repository"
	tmp=$(mktemp -d "$KDIR/.tree-XXXXXX")
	trap 'rm -rf "$tmp"' EXIT
	cp "$KDIR/$KERNEL_DSC" "$KDIR"/linux-5.6.19-pyradef_5.6.19-pyradef*.{tar.gz,diff.gz} "$tmp/"
	docker run --rm -v "$tmp":/src -w /src debian:bookworm bash -euo pipefail -c "
		apt-get update -qq
		apt-get install -y --no-install-recommends dpkg-dev >/dev/null
		dpkg-source -x $KERNEL_DSC linux
		chown -R $(id -u):$(id -g) /src
	"
	mv "$tmp/linux" "$OUT"
	git init -q -b main "$OUT"
	# -f: the kernel's own .gitignore files would otherwise drop a few files
	# that the source package ships.
	g add -A -f
	GIT_AUTHOR_DATE="2025-01-11T00:04:20+0100" GIT_COMMITTER_DATE="2025-01-11T00:04:20+0100" \
	g commit -q --author="Pyra project <noreply@example.invalid>" \
		-m "linux-5.6.19-pyradef 5.6.19-pyradef-10, as published" \
		-m "Unpacked with dpkg-source -x from $KERNEL_DSC at
https://packages.pyra-handheld.com/trixie/, the source pc/pyra-crossbuild.sh
builds every kernel variant from. Not edited."
	g tag -f stock-5.6.19-pyradef-10 >/dev/null
fi

# Apply one patch file as one commit. The patches come in three shapes (a
# format-patch mbox, a mail header without the mbox line, and a bare subject
# line), so read the message out of whichever it is, and apply the diff with
# patch(1) as the build does, so a patch that needs fuzz here needs it there.
apply() {
	local p=$1 msgf author date
	msgf=$(mktemp)
	author=$(python3 - "$p" "$msgf" "$DEFAULT_AUTHOR" <<'EOF'
import re, sys
path, out, default = sys.argv[1:]
lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
i, author, subject = 0, default, None
if lines[0].startswith('From ') and not lines[0].startswith('From: '):
    i = 1
if lines[i].startswith('From: '):
    hdr = None
    while i < len(lines) and lines[i] != '':
        l = lines[i]
        if l[:1] in ' \t' and hdr == 'subject':
            subject += ' ' + l.strip()
        elif l.startswith('From: '):
            author, hdr = l[6:].strip(), 'from'
        elif l.startswith('Subject: '):
            subject, hdr = l[9:].strip(), 'subject'
        else:
            hdr = None
        i += 1
    i += 1
else:
    subject = lines[0].strip(); i = 1
subject = re.sub(r'^\[PATCH[^\]]*\]\s*', '', subject)
body = []
for l in lines[i:]:
    if l == '---' or l.startswith('diff ') or l.startswith('--- a/') or l.startswith('Index: '):
        break
    body.append(l)
open(out, 'w').write(subject + '\n\n' + '\n'.join(body).strip('\n') + '\n')
print(author)
EOF
)
	date=$(git -C "$TOP" log -1 --format=%aI -- "$p")
	[ -n "$date" ] || date=$(date -r "$p" -Iseconds)
	(cd "$OUT" && patch -p1 --forward --silent --no-backup-if-mismatch <"$p") \
		|| die "$(basename "$p") does not apply on $(g rev-parse --abbrev-ref HEAD)"
	g add -A -f
	GIT_AUTHOR_DATE=$date GIT_COMMITTER_DATE=$date \
	g commit -q --author="$author" -F "$msgf"
	rm -f "$msgf"
	printf '  %-12s %s\n' "$(g rev-parse --short HEAD)" "$(basename "$p")"
}

# branch NAME BASE PATCH... : rebuild NAME from BASE with the patches on top.
branch() {
	local name=$1 base=$2 p; shift 2
	echo "$name (on $base)"
	g checkout -q -B "$name" "$base"
	for p in "$@"; do apply "$p"; done
}

[ -z "$(g status --porcelain)" ] || die "$OUT has uncommitted changes; it is generated, so commit nothing there"

branch pyra/fixes     main          "$TOP"/patches/*.patch
branch pyra/opp       pyra/fixes    "$EXP"/thermals-and-frequency/0007-*.patch
branch pyra/m4-ipu    pyra/opp      "$EXP"/m4-ipu/*.patch
branch pyra/aess      pyra/m4-ipu   "$EXP"/aess/*.patch
branch pyra/device    pyra/aess     "$EXP"/gpu-power/0034-*.patch "$EXP"/kbd-led/*.patch \
                                    "$EXP"/jack-detect/*.patch
branch pyra/overclock pyra/opp      "$EXP"/thermals-and-frequency/0008-*.patch
branch pyra/c2-idle   pyra/fixes    "$EXP"/c2-idle/*.patch
branch pyra/jack      pyra/fixes    "$EXP"/jack-detect/*.patch
g checkout -q pyra/device

echo
echo "done: $OUT"
echo "  git -C $OUT log --oneline main..pyra/fixes"
