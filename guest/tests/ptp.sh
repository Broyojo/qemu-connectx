#!/bin/sh
# PTP hardware clock and timestamping with standard tools: the kernel's
# testptp and hwtstamp_config selftests, linuxptp's hwstamp_ctl/phc_ctl, and
# ptp4l synchronising one emulated port's clock to the other's.
#
# NICS="$(guest/tests/pair-nics)" guest/run.sh guest/tests/ptp.sh
. /test/lib.sh
setup_pair

phc=/dev/ptp$(ethtool -T eth0 | sed -n 's/.*provider index: //p')
echo "eth0 PHC: $phc"

check "PHC capabilities (testptp -c)" testptp -d "$phc" -c
check "PHC get time" testptp -d "$phc" -g
check "PHC set time from system clock" testptp -d "$phc" -s
check "PHC shift time by 10s" testptp -d "$phc" -t 10
check "PHC adjust frequency by 100 ppb" testptp -d "$phc" -f 100
check "PHC frequency back to nominal" testptp -d "$phc" -f 0
check "PHC vs system clock offsets" testptp -d "$phc" -k 5
check "phc_ctl get/cmp" phc_ctl eth0 get cmp

check "hwtstamp_config: tx ON, rx filter ALL" hwtstamp_config eth0 ON ALL
check "hwstamp_ctl reports rx_filter ALL" \
    sh -c 'hwstamp_ctl -i eth0 | grep -q "rx_filter 1"'
check "hardware timestamps on sent and received frames" \
    hwts eth0 10.9.0.2 10.9.0.1 5

# ptp4l: eth1 (peer namespace) is grandmaster, eth0 follows it, both using
# hardware timestamps over layer 2.
ip netns exec peer ptp4l -i eth1 -2 -H -m --priority1 10 \
    >/tmp/master.log 2>&1 &
ptp4l -i eth0 -2 -H -s -m --summary_interval 0 >/tmp/slave.log 2>&1 &
sleep "${PTP_SECONDS:-25}"
killall ptp4l

echo "--- ptp4l follower"
grep -E "selected|UNCALIBRATED|SLAVE|FAULT" /tmp/slave.log | tail -6
tail -8 /tmp/slave.log
check "ptp4l follower reached the locked servo state (s2)" \
    grep -q " s2 " /tmp/slave.log
# Largest |offset| over the last 8 samples must be under 50 microseconds.
worst=$(grep "master offset" /tmp/slave.log | tail -8 |
        awk '{ v = $4 < 0 ? -$4 : $4; if (v > m) m = v } END { print m + 0 }')
echo "     worst offset over the last 8 samples: ${worst} ns"
check "ptp4l offset from master under 50us" test "$worst" -lt 50000
check "ptp4l master saw no faults" sh -c '! grep -q FAULT /tmp/master.log'
finish
