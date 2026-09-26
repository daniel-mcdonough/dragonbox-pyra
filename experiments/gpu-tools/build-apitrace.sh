#!/usr/bin/env bash
# Cross-build apitrace's EGL/GLES tracer and CLI for the Pyra, in Shipwright's
# soh-pyra-cross container (scripts/pyra/build.sh image). The desktop side is
# Arch's apitrace package; keep APITRACE_TAG equal to its version so the trace
# format matches.
#
#   ./build-apitrace.sh            configure + build into $SRC/build-pyra
#   ./build-apitrace.sh install    stage into ./out/apitrace (rsync that to the Pyra)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${APITRACE_SRC:-$HOME/git/dragonbox-pyra-supporing-repos/apitrace}"
APITRACE_TAG=14.0
IMAGE=soh-pyra-cross

[[ -d "$SRC/.git" ]] || git clone --branch "$APITRACE_TAG" --depth 1 --recurse-submodules \
    --shallow-submodules https://github.com/apitrace/apitrace.git "$SRC"

# The DDK's DRI3 WSEGL aborts in eglWaitNative, which eglretrace's X11 code calls.
git -C "$SRC" apply --check "$HERE/apitrace-pyra-waitnative.patch" 2>/dev/null &&
    git -C "$SRC" apply "$HERE/apitrace-pyra-waitnative.patch"

run() {
  docker run --rm -i --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$SRC:/apitrace" -v "$HERE:/tools" -w /apitrace "$IMAGE" "$@"
}

case "${1:-build}" in
  build)
    run cmake -S /apitrace -B /apitrace/build-pyra -GNinja \
        -DCMAKE_TOOLCHAIN_FILE=/tools/armhf.cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DENABLE_GUI=OFF -DBUILD_TESTING=OFF -DENABLE_X11=ON -DENABLE_EGL=ON
    run cmake --build /apitrace/build-pyra
    ;;
  install)
    rm -rf "$HERE/out/apitrace"
    run cmake --install /apitrace/build-pyra --prefix /tools/out/apitrace
    ;;
  *) echo "usage: $0 {build|install}" >&2; exit 1 ;;
esac
