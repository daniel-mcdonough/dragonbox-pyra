# shellcheck shell=bash
# The vendor trixie image: where it comes from, its pinned checksums, and how
# to unpack it. Sourced by pyra-image-build.sh, pyra-prep-selftest.sh and
# pyra-grow-root-selftest.sh, so the pins live in one place. Not run on its own.
#
# Needs TOP (the top of the repository) set before it is sourced.
# PYRA_VENDOR_7Z names another archive.

VENDOR_URL=https://packages.pyra-handheld.com/images/trixie/pyra-trixie-t1-brokenxorg.7z
VENDOR_7Z=${PYRA_VENDOR_7Z:-$TOP/pyra-trixie-t1-brokenxorg.7z}

# The archive as served since 2026-02-01 (862273362 bytes), and the one image
# inside it.
SHA_7Z=b2220b3f5ab9974d397d9fbac6c6190c8ff6690fdf977d0b52c4a6ade3fd28c7
SHA_IMG=d8e98ff644bb57472ad8585b2bb2c2c396c8de69c768f015f7dbbece2d3637ce
IMG_IN_7Z=pyra-trixie-t1.img

# vendor_img_ok FILE: true if FILE is the image exactly as the archive holds it.
vendor_img_ok() {
    [[ $(sha256sum < "$1" | cut -d' ' -f1) == "$SHA_IMG" ]]
}

# vendor_unpack DEST: check the archive, unpack its image to DEST (sparse),
# and check that. Prints why and returns 1 on any mismatch; DEST is then left
# for the caller to remove.
vendor_unpack() {
    local dest=$1
    if [[ ! -r $VENDOR_7Z ]]; then
        echo "no vendor archive at $VENDOR_7Z; download $VENDOR_URL" >&2
        return 1
    fi
    if [[ $(sha256sum < "$VENDOR_7Z" | cut -d' ' -f1) != "$SHA_7Z" ]]; then
        echo "$VENDOR_7Z is not the archive this script knows (SHA-256 differs); re-download it" >&2
        return 1
    fi
    local -a unpack
    if command -v bsdtar >/dev/null; then
        unpack=(bsdtar -xOf "$VENDOR_7Z" "$IMG_IN_7Z")
    elif command -v 7z >/dev/null; then
        unpack=(7z x -so "$VENDOR_7Z" "$IMG_IN_7Z")
    else
        echo "need bsdtar (libarchive) or 7z to unpack $VENDOR_7Z" >&2
        return 1
    fi
    # A failed or short unpack shows up as a checksum mismatch below.
    "${unpack[@]}" | dd of="$dest" bs=4M conv=sparse status=none || true
    if ! vendor_img_ok "$dest"; then
        echo "the unpacked image's SHA-256 differs from the pinned one" >&2
        return 1
    fi
}
