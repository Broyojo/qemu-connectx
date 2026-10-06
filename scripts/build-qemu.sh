#!/bin/sh
# Fetch QEMU, apply the ConnectX device patches and build it.
#
# usage: scripts/build-qemu.sh [extra configure args...]
#
# Environment:
#   QEMU_TAG   upstream release the patches apply to (default v11.1.2)
#   TARGETS    QEMU system targets (default: the host architecture)
#
# The checkout lands in ./qemu on a branch named "mlx5"; the binary is
# ./qemu/build/qemu-system-<arch>.  If ./qemu already exists it is rebuilt
# as it is, so local changes to the device are kept.
set -eu

top=$(cd "$(dirname "$0")/.." && pwd)
tag=${QEMU_TAG:-v11.1.2}

case $(uname -m) in
arm64 | aarch64) host=aarch64 ;;
*) host=x86_64 ;;
esac
targets=${TARGETS:-$host-softmmu}

if [ ! -d "$top/qemu/.git" ]; then
    git clone --depth 1 --branch "$tag" \
        https://gitlab.com/qemu-project/qemu.git "$top/qemu"
    git -C "$top/qemu" checkout -q -b mlx5
    git -C "$top/qemu" am "$top"/patches/*.patch
fi

mkdir -p "$top/qemu/build"
cd "$top/qemu/build"
if [ ! -f build.ninja ]; then
    # Apple's ParavirtualizedGraphics, which one unrelated device uses, no
    # longer builds against the macOS 27 SDK.
    [ "$(uname -s)" = Darwin ] && set -- --disable-pvg "$@"
    ../configure --target-list="$targets" --disable-docs "$@"
fi
ninja
