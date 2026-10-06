#!/bin/sh
# Boot the test guest with an emulated ConnectX-5 and run a test script in it.
#
# usage: run.sh [test-script] [extra qemu args...]
#
# The script is copied into the guest as /test/run.sh and run by /init after
# mlx5_core has loaded; the guest powers off when it returns.  Without a
# script the guest drops to a shell on the serial console.
#
# Environment:
#   ARCH      guest architecture, aarch64 or x86_64 (default: the host's);
#             a foreign architecture runs under TCG emulation
#   QEMU      qemu-system-<arch> binary (default: ../qemu/build)
#   NICS      "-netdev/-device" arguments (default: one mlx5 on user net)
#   SMP       number of guest CPUs (default 2)
#   APPEND    extra kernel command line
#   TIMEOUT   seconds before the guest is killed (default 120, 0 = none)
#   TRACE     comma-separated trace event patterns, e.g. "mlx5_cmd,mlx5_rx*"
#   QLOG      file for QEMU trace/log output (default: out/qemu.log)
#   OVERLAY   directory of extra files to lay over the guest root
set -eu

here=$(cd "$(dirname "$0")" && pwd)

case $(uname -m) in
arm64 | aarch64) host=aarch64 ;;
*) host=x86_64 ;;
esac
case ${ARCH:-$host} in
arm64 | aarch64) arch=aarch64 machine=virt,gic-version=3 console=ttyAMA0 ;;
x86_64 | amd64) arch=x86_64 machine=q35 console=ttyS0 ;;
*) echo "unsupported ARCH" >&2; exit 1 ;;
esac
# Hardware virtualisation when the guest matches the host, else emulation.
accel=tcg cpu=max
if [ "$arch" = "$host" ]; then
    if [ "$(uname -s)" = Darwin ]; then
        accel=hvf cpu=host
    elif [ -w /dev/kvm ]; then
        accel=kvm cpu=host
    fi
fi

qemu=${QEMU:-$here/../qemu/build/qemu-system-$arch}
out=$here/out/$arch
script=${1:-}
[ $# -gt 0 ] && shift

# The initramfs is the base image plus an overlay holding the test script.
ovl=$(mktemp -d)
trap 'rm -rf "$ovl"' EXIT
mkdir -p "$ovl/root/test"
if [ -n "$script" ]; then
    cp "$script" "$ovl/root/test/run.sh"
    chmod +x "$ovl/root/test/run.sh"
fi
cp "$here"/tests/lib.sh "$ovl/root/test/" 2>/dev/null || true
if [ -n "${OVERLAY:-}" ]; then
    cp -R "$OVERLAY"/. "$ovl/root/"
fi
(cd "$ovl/root" && find . | cpio -o -H newc 2>/dev/null | gzip -1) \
    > "$ovl/overlay.cpio.gz"
cat "$out/initramfs-base.cpio.gz" "$ovl/overlay.cpio.gz" > "$ovl/initramfs"

# PCIe devices sit behind root ports, as on a real machine.
nics=${NICS:--device pcie-root-port,id=rp0,chassis=1 -netdev user,id=n0 -device mlx5,netdev=n0,bus=rp0}
trace=
for t in $(echo "${TRACE:-}" | tr ',' ' '); do
    trace="$trace -trace $t"
done

# shellcheck disable=SC2086
"$qemu" -M "$machine" -accel "${ACCEL:-$accel}" -cpu "${CPU:-$cpu}" \
    -smp "${SMP:-2}" -m "${MEM:-2G}" -nographic -no-reboot \
    -kernel "$out/vmlinuz" -initrd "$ovl/initramfs" \
    -append "console=$console loglevel=${LOGLEVEL:-4} ${APPEND:-}" \
    -d unimp,guest_errors -D "${QLOG:-$out/qemu.log}" $trace $nics "$@" &
pid=$!

timeout=${TIMEOUT:-120}
if [ "$timeout" -gt 0 ]; then
    # Detached from our stdout so a pipeline reading it ends with QEMU.
    (sleep "$timeout" && kill "$pid" && touch "$ovl/timedout") \
        >/dev/null 2>&1 &
    watchdog=$!
fi
wait "$pid" || true
if [ "$timeout" -gt 0 ]; then
    pkill -P "$watchdog" 2>/dev/null || true
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    if [ -e "$ovl/timedout" ]; then
        echo "TEST-TIMEOUT"
    fi
fi
