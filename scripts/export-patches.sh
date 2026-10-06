#!/bin/sh
# Regenerate patches/ from the "mlx5" branch of the ./qemu checkout.
set -eu

top=$(cd "$(dirname "$0")/.." && pwd)
tag=${QEMU_TAG:-v11.1.2}

rm -f "$top"/patches/*.patch
git -C "$top/qemu" format-patch --quiet --zero-commit --no-signature \
    -o "$top/patches" "$tag..mlx5"
ls -l "$top/patches"
