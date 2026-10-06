#!/bin/sh
# The Linux kernel's NIC driver selftests (tools/testing/selftests/drivers/net)
# in "HW mode": eth0 is the device under test, eth1 in netns "peer" is the
# remote endpoint.
#
# NICS="$(guest/tests/pair-nics)" guest/run.sh guest/tests/ksft.sh
. /test/lib.sh
setup_pair

# Variables can be overridden from the kernel command line (APPEND=...).
for v in $(cat /proc/cmdline); do
    case $v in KSFT_*=*) export "$v" ;; esac
done
KSFT_TESTS=$(echo "${KSFT_TESTS:-}" | tr ',' ' ')

export NETIF=eth0 REMOTE_TYPE=netns REMOTE_ARGS=peer
export LOCAL_V4=10.9.0.1 REMOTE_V4=10.9.0.2
export LOCAL_V6=fd00:9::1 REMOTE_V6=fd00:9::2

# The RSS context tests steer flows with ntuple rules, off by default.
ethtool -K eth0 ntuple on

cd /ksft/tools/testing/selftests/drivers/net || exit 1
# Default set: everything that is meaningful for this device.  Not included:
#   xdp.py                 XDP_TX and adjust-head/tail cases fail; undiagnosed
#   hds.py                 expects TCP data split, which needs HW GRO (CX-7)
# Tests that need features the 6.18 mlx5 driver lacks skip by themselves.
for t in ${KSFT_TESTS:-ping.py queues.py stats.py napi_id.py napi_threaded.py \
                       hw/csum.py hw/irq.py hw/xsk_reconfig.py hw/rss_api.py \
                       hw/rss_ctx.py hw/rss_input_xfrm.py hw/tso.py \
                       hw/nic_timestamp.py}; do
    echo "=== $t"
    python3 "./$t" > /tmp/ksft.out 2>&1
    rc=$?
    # One line per test case; for failures, the line that names the cause.
    awk '/^# (Exception|Check)\|/ { why = $0 }
         /^not ok/ { print; if (why) print "    " why; why = ""; next }
         /^ok/ { print; why = "" }
         /^# Totals/ { print }' /tmp/ksft.out
    [ -n "${KSFT_VERBOSE:-}" ] && cat /tmp/ksft.out
    [ $rc -ne 0 ] && fails=$((fails + 1))
done
finish
