#!/bin/sh
# Link up, basic traffic, then hardware timestamping with HWTSTAMP_FILTER_ALL.
ip link set eth0 up
ip addr add 10.0.2.15/24 dev eth0
sleep 1
ip -br link show eth0
ethtool eth0 | grep -E "Speed|Link detected"
ethtool -i eth0 | head -4
echo "--- ethtool -T"
ethtool -T eth0
echo "--- ping"
ping -c 3 -W 2 10.0.2.2
echo "--- hwts"
hwts eth0 10.0.2.2 10.0.2.15 5
rc=$?
echo "--- dmesg"
dmesg | grep -i -E "mlx5|csum|WARN|BUG|Call trace" | tail -15
exit $rc
