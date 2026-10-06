#!/bin/sh
# Runs inside a Debian container; see build-guest.sh.
#
# Builds the C test tools as static glibc binaries (the kernel selftests and
# linuxptp do not build against musl): our own programs, the kernel's
# timestamping and PTP selftests, and linuxptp.
set -eu

apt-get update -qq >/dev/null
apt-get install -y -qq gcc make libc6-dev linux-libc-dev git ca-certificates \
    clang-19 libbpf-dev libelf-dev zlib1g-dev libzstd-dev libmnl-dev \
    pkg-config bison flex >/dev/null 2>&1

# tools/bin goes on the guest's PATH; tools/ksft mirrors the kernel's
# selftests directory for helpers the Python tests look up by location.
out=$OUT/tools
rm -rf "$out"
mkdir -p "$out/bin" "$out/ksft/net/lib" "$out/ksft/drivers/net"

for src in /guest/src/*.c; do
    gcc -O2 -Wall -static -o "$out/bin/$(basename "$src" .c)" "$src"
done

st=/linux/tools/testing/selftests
for t in net/txtimestamp net/timestamping net/hwtstamp_config \
         net/rxtimestamp net/udpgso_bench_tx net/udpgso_bench_rx \
         ptp/testptp; do
    gcc -O2 -static -I"$st" -o "$out/bin/$(basename "$t")" "$st/$t.c" \
        -lrt -lpthread
done
for t in net/lib/csum net/lib/xdp_helper drivers/net/napi_id_helper; do
    gcc -O2 -static -I"$st" -I"$st/net/lib" -o "$out/ksft/$t" "$st/$t.c"
done
# clang 19: programs built by newer releases are rejected by this kernel's
# BPF verifier.
for t in net/lib/xdp_dummy net/lib/xdp_native; do
    clang-19 -O2 -g -target bpf -I"/usr/include/$(uname -m)-linux-gnu" \
        -c "$st/$t.bpf.c" -o "$out/ksft/$t.bpf.o"
done

git clone -q --depth 1 -b "${LINUXPTP_TAG:-v4.4}" \
    https://github.com/richardcochran/linuxptp.git /tmp/linuxptp 2>/dev/null
make -C /tmp/linuxptp -j8 EXTRA_LDFLAGS=-static >/tmp/linuxptp.log 2>&1 ||
    { tail -20 /tmp/linuxptp.log; exit 1; }
for t in hwstamp_ctl ptp4l phc_ctl phc2sys pmc ts2phc; do
    cp "/tmp/linuxptp/$t" "$out/bin/"
done

# iproute2 with libbpf: the distribution's "ip" cannot load the selftests'
# XDP programs.  Also provides devlink.
git clone -q --depth 1 -b "${IPROUTE2_TAG:-v6.18.0}" \
    https://git.kernel.org/pub/scm/network/iproute2/iproute2.git \
    /tmp/iproute2 2>/dev/null
(cd /tmp/iproute2 && ./configure >/dev/null 2>&1 &&
 echo "LDLIBS += -lbpf -lelf -lz -lzstd -lmnl" >> config.mk &&
 make -j8 SHARED_LIBS=n LDFLAGS=-static SUBDIRS="lib ip devlink" \
     >/tmp/iproute2.log 2>&1) || { tail -20 /tmp/iproute2.log; exit 1; }
cp /tmp/iproute2/ip/ip /tmp/iproute2/devlink/devlink "$out/bin/"

find "$out" -type f | sort
