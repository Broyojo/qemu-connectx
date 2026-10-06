#!/bin/sh
# Build the test guest: an Alpine linux-lts kernel plus an initramfs that
# carries mlx5_core, networking/PTP tools and the kernel's own NIC selftests.
#
# Runs the real work inside an arm64 Alpine container so it works from macOS.
# Outputs: guest/out/vmlinuz, guest/out/initramfs-base.cpio.gz
set -eu

here=$(cd "$(dirname "$0")" && pwd)
linux=${LINUX_SRC:-$here/../ref/linux}
linux_tag=${LINUX_TAG:-v6.18.55}
mkdir -p "$here/out"

# A sparse checkout of the kernel tree: selftests, the netlink library they
# use, and (for reference while developing the device) the mlx5 driver.
if [ ! -d "$linux/.git" ]; then
    git clone --depth 1 --filter=blob:none --sparse --branch "$linux_tag" \
        https://github.com/gregkh/linux.git "$linux"
fi
git -C "$linux" sparse-checkout set \
    drivers/net/ethernet/mellanox/mlx5/core include/linux/mlx5 \
    include/uapi/linux Documentation/netlink tools/net/ynl \
    tools/testing/selftests/net tools/testing/selftests/ptp \
    tools/testing/selftests/drivers/net

# Test tools first (static binaries in out/tools), then the root filesystem.
docker run --rm --platform linux/arm64 \
    -v "$here:/guest" -v "$linux:/linux:ro" \
    debian:sid-slim sh -eu /guest/build-tools-inner.sh
docker run --rm --platform linux/arm64 \
    -v "$here:/guest" -v "$linux:/linux:ro" \
    alpine:3.24 sh -eu /guest/build-guest-inner.sh
