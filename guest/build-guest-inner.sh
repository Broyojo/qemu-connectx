#!/bin/sh
# Runs inside the Alpine container; see build-guest.sh.
set -eu

apk add --no-cache linux-lts kmod cpio gzip >/dev/null

kver=$(ls /lib/modules)
root=/tmp/rootfs
mkdir -p "$root"

# Userland: a tiny Alpine root with the networking/PTP tools we test with.
apk add --no-cache --root "$root" --initdb \
    --repositories-file /etc/apk/repositories --keys-dir /etc/apk/keys \
    busybox kmod ethtool iproute2 tcpdump pciutils iputils-ping socat \
    iperf3 python3 py3-yaml py3-jsonschema bash bpftool jq >/dev/null
"$root/bin/busybox" --install -s "$root/bin" 2>/dev/null || true

# Modules: mlx5_core, its dependency closure, and a few test helpers.
mods="mlx5_core af_packet veth ptp 8021q virtio_net virtio_pci"
for m in $mods; do
    modprobe -S "$kver" --show-depends "$m" 2>/dev/null |
        sed -n 's/^insmod \([^ ]*\).*/\1/p'
done | sort -u | while read -r ko; do
    mkdir -p "$root$(dirname "$ko")"
    cp "$ko" "$root$ko"
done
cp /lib/modules/"$kver"/modules.builtin* /lib/modules/"$kver"/modules.order \
    "$root/lib/modules/$kver/" 2>/dev/null || true
depmod -b "$root" "$kver"

# Test tools built by build-tools-inner.sh.
# /usr/local/bin is first on the guest's PATH: our "ip" shadows Alpine's.
mkdir -p "$root/usr/local/bin"
cp /guest/out/tools/bin/* "$root/usr/local/bin/"

# The kernel's Python driver tests, with the tree layout they expect (they
# find the netlink library and specs relative to their own location).
st=/linux/tools/testing/selftests
ksft=$root/ksft
mkdir -p "$ksft/tools/testing/selftests/net" \
    "$ksft/tools/testing/selftests/drivers" "$ksft/tools/net" \
    "$ksft/Documentation"
cp -r "$st/net/lib" "$ksft/tools/testing/selftests/net/"
cp -r "$st/drivers/net" "$ksft/tools/testing/selftests/drivers/"
cp -r /linux/tools/net/ynl "$ksft/tools/net/"
cp -r /linux/Documentation/netlink "$ksft/Documentation/"
cp -r /guest/out/tools/ksft/* "$ksft/tools/testing/selftests/"

cp /guest/init "$root/init"
chmod +x "$root/init"
mkdir -p "$root/proc" "$root/sys" "$root/dev" "$root/tmp" "$root/run" "$root/test"

(cd "$root" && find . | cpio -o -H newc 2>/dev/null | gzip -1) \
    > /guest/out/initramfs-base.cpio.gz
cp /boot/vmlinuz-lts /guest/out/vmlinuz
echo "$kver" > /guest/out/kver
ls -la /guest/out
echo "modules:"; find "$root/lib/modules" -name '*.ko*' | sed 's|.*/||' | tr '\n' ' '; echo
