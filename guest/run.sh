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
#   QEMU      qemu-system-aarch64 binary (default: ../qemu/build)
#   NICS      "-netdev/-device" arguments (default: one mlx5 on user net)
#   SMP       number of guest CPUs (default 2)
#   APPEND    extra kernel command line
#   TIMEOUT   seconds before the guest is killed (default 120, 0 = none)
#   TRACE     comma-separated trace event patterns, e.g. "mlx5_cmd,mlx5_rx*"
#   QLOG      file for QEMU trace/log output (default: out/qemu.log)
#   OVERLAY   directory of extra files to lay over the guest root
set -eu

here=$(cd "$(dirname "$0")" && pwd)
qemu=${QEMU:-$here/../qemu/build/qemu-system-aarch64}
out=$here/out
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
"$qemu" -M virt,gic-version=3 -accel "${ACCEL:-hvf}" -cpu "${CPU:-host}" \
    -smp "${SMP:-2}" -m "${MEM:-2G}" -nographic -no-reboot \
    -kernel "$out/vmlinuz" -initrd "$ovl/initramfs" \
    -append "console=ttyAMA0 loglevel=${LOGLEVEL:-4} ${APPEND:-}" \
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
