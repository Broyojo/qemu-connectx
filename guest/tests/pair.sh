#!/bin/sh
# Traffic between two emulated ports wired back to back: the data path,
# offloads, reconfiguration and driver reload.
#
# NICS="$(guest/tests/pair-nics)" guest/run.sh guest/tests/pair.sh
. /test/lib.sh
setup_pair

iperf() {
    # iperf <args...>: client here, server in the peer namespace
    ip netns exec peer iperf3 -s -1 -D >/dev/null 2>&1
    sleep 0.3
    iperf3 -c 10.9.0.2 -t 2 "$@"
}

iperf3_v6() {
    ip netns exec peer iperf3 -s -1 -D >/dev/null 2>&1
    sleep 0.3
    iperf3 -6 -c fd00:9::2 -t 2
}

check "link is up at 100G" sh -c 'ethtool eth0 | grep -q "Speed: 100000Mb/s"'
check "ping IPv4" ping -c 3 -i 0.2 -W 2 10.9.0.2
check "ping IPv6" ping -6 -c 3 -i 0.2 -W 2 fd00:9::2
check "ping, fragmented (8000 bytes)" ping -c 2 -W 2 -s 8000 10.9.0.2

check "TCP stream" iperf
check "TCP stream, reverse" iperf -R
check "TCP stream, IPv6" iperf3_v6
check "UDP stream" iperf -u -b 200M
# UDP segmentation offload, with the kernel's udpgso benchmark: the sender
# hands over 64K buffers for the port to cut into 1400-byte datagrams.
udp_gso() {
    before=$(stat eth0 tx_tso_packets)
    ip netns exec peer udpgso_bench_rx -4 >/dev/null 2>&1 &
    sleep 0.3
    udpgso_bench_tx -4 -D 10.9.0.2 -S 1400 -l 2 >/dev/null 2>&1
    killall udpgso_bench_rx
    test "$(( $(stat eth0 tx_tso_packets) - before ))" -gt 0
}
check "UDP segmentation offload" udp_gso
check "large sends were offloaded (TSO)" test "$(stat eth0 tx_tso_packets)" -gt 0
check "receive checksums verified by hardware" \
    test "$(ip netns exec peer ethtool -S eth1 |
            awk '$1 == "rx_csum_complete:" { print $2 }')" -gt 0
# A sender can outrun the receiver, as on real hardware; just report it.
echo "     receive buffer drops: eth0 $(stat eth0 rx_out_of_buffer)"

# RSS hash: the kernel's toeplitz selftest compares the hash the port reports
# for each frame with a software Toeplitz hash of the same addresses and
# ports, using the key the driver programmed.
toeplitz_ok() {
    # toeplitz_ok <-u|-t> <-4|-6> <our address> <socat address prefix>
    key=$(ethtool -x eth0 | sed -n '/RSS hash key/{n;p;}')
    toeplitz "$2" "$1" -d 8000 -i eth0 -k "$key" -T 1500 -s \
        >/tmp/toeplitz.out 2>&1 &
    sleep 0.3
    for i in $(seq 1 40); do
        echo msg | ip netns exec peer socat -u STDIN "$4:$3:8000" 2>/dev/null
    done
    wait
    cat /tmp/toeplitz.out
    grep -q "pass=[1-9][0-9]* nohash=0 fail=0" /tmp/toeplitz.out
}
# The driver defaults to a symmetric variant; the reference is plain Toeplitz.
check "plain Toeplitz RSS" ethtool -X eth0 xfrm none
check "RSS hash matches Toeplitz (UDP/IPv4)" toeplitz_ok -u -4 10.9.0.1 UDP4
check "RSS hash matches Toeplitz (TCP/IPv4)" toeplitz_ok -t -4 10.9.0.1 TCP4
check "RSS hash matches Toeplitz (UDP/IPv6)" \
    toeplitz_ok -u -6 "[fd00:9::1]" UDP6
check "RSS hash matches Toeplitz (TCP/IPv6)" \
    toeplitz_ok -t -6 "[fd00:9::1]" TCP6
ethtool -X eth0 xfrm symmetric-or-xor

# The data path modes a ConnectX-5 defaults to, and their fallbacks.
flag() { ethtool --show-priv-flags eth0 | grep -q "^$1 *: $2"; }
check "striding receive queue is the default" flag rx_striding_rq on
check "multi-packet send is the default" flag skb_tx_mpwqe on
check "TCP stream, striding RQ and multi-packet send" iperf
check "switch to legacy receive queue" \
    ethtool --set-priv-flags eth0 rx_striding_rq off
check "TCP stream, legacy receive queue" iperf -R
check "switch multi-packet send off" \
    ethtool --set-priv-flags eth0 skb_tx_mpwqe off
check "TCP stream, single-packet send" iperf
ethtool --set-priv-flags eth0 rx_striding_rq on skb_tx_mpwqe on
check "enable CQE compression" \
    ethtool --set-priv-flags eth0 rx_cqe_compress on
check "TCP stream, CQE compression allowed" iperf -R
ethtool --set-priv-flags eth0 rx_cqe_compress off

# Link mode selection, FEC and the cable's EEPROM.
check "force 25G" ethtool -s eth0 speed 25000 autoneg off
sleep 1
check "link reports 25G" sh -c 'ethtool eth0 | grep -q "Speed: 25000Mb/s"'
check "ping at 25G" ping -c 2 -W 2 10.9.0.2
check "back to autonegotiation" ethtool -s eth0 autoneg on
sleep 1
check "link is back at 100G" sh -c 'ethtool eth0 | grep -q "Speed: 100000Mb/s"'
check "RS-FEC active at 100G" \
    sh -c 'ethtool --show-fec eth0 | grep -q "Active FEC encoding: RS"'
check "module EEPROM decodes as QSFP28" \
    sh -c 'ethtool -m eth0 | grep -q "Identifier.*QSFP28"'
check "firmware version in devlink" sh -c \
    'devlink dev info | grep -q "fw.version 16.35.4030"'

# Receive flow steering.  Frames for someone else's address must be filtered
# out by the port unless it is promiscuous.
vport_rx() { stat eth0 rx_vport_unicast_packets; }
foreign() {
    # five pings from the peer to our IP, but to a MAC address we don't own
    ip -n peer neigh replace 10.9.0.1 lladdr 02:00:00:00:00:99 dev eth1
    ip netns exec peer ping -c 5 -i 0.05 -W 1 -q 10.9.0.1 >/dev/null
    ip -n peer neigh del 10.9.0.1 dev eth1
    sleep 1.2    # the driver refreshes its counters once a second
}
before=$(vport_rx); foreign
check "frames to a foreign MAC are filtered" \
    test "$(( $(vport_rx) - before ))" -lt 5
ip link set eth0 promisc on
before=$(vport_rx); foreign
check "promiscuous mode receives them" \
    test "$(( $(vport_rx) - before ))" -ge 5
ip link set eth0 promisc off

# ethtool flow rules: drop, then steer to a chosen queue.
udp_arrives() {
    # udp_arrives <port>: does a datagram from the peer reach a listener?
    socat -u -T 1 "UDP-RECV:$1" STDOUT >/tmp/udp.out &
    sleep 0.3
    echo hello | ip netns exec peer socat -u STDIN "UDP:10.9.0.1:$1"
    wait
    grep -q hello /tmp/udp.out
}
udp_dropped() { ! udp_arrives "$1"; }
queue1_rx() { stat eth0 rx1_packets; }

check "enable ntuple filters" ethtool -K eth0 ntuple on
check "UDP datagram arrives" udp_arrives 7777
check "add drop rule for UDP port 7777" \
    ethtool -N eth0 flow-type udp4 dst-port 7777 action -1 loc 1
check "drop rule drops" udp_dropped 7777
check "other ports still arrive" udp_arrives 7778
check "delete drop rule" ethtool -N eth0 delete 1
check "UDP datagram arrives again" udp_arrives 7777
check "add rule steering UDP port 7779 to queue 1" \
    ethtool -N eth0 flow-type udp4 dst-port 7779 action 1 loc 2
before=$(queue1_rx)
for i in 1 2 3 4 5; do
    echo hello | ip netns exec peer socat -u STDIN UDP:10.9.0.1:7779
done
check "steered datagrams land on queue 1" \
    test "$(( $(queue1_rx) - before ))" -ge 5
ethtool -N eth0 delete 2
ethtool -K eth0 ntuple off

ip link set eth0 mtu 9000
ip -n peer link set eth1 mtu 9000
check "jumbo ping (MTU 9000)" ping -c 2 -W 2 -M do -s 8972 10.9.0.2
check "jumbo TCP stream" iperf

ip link add link eth0 name eth0.5 type vlan id 5
ip addr add 10.9.5.1/24 dev eth0.5
ip link set eth0.5 up
ip -n peer link add link eth1 name eth1.5 type vlan id 5
ip -n peer addr add 10.9.5.2/24 dev eth1.5
ip -n peer link set eth1.5 up
sleep 0.5
check "ping over VLAN 5" ping -c 3 -i 0.2 -W 2 10.9.5.2

check "resize rings" ethtool -G eth0 rx 256 tx 256
check "ping after ring resize" ping -c 2 -W 2 10.9.0.2
check "single channel" ethtool -L eth0 combined 1
check "ping with one channel" ping -c 2 -W 2 10.9.0.2
check "TCP stream with one channel" iperf

ip link set eth0 down
sleep 0.2
ip link set eth0 up
sleep 1
check "ping after link down/up" ping -c 2 -W 2 10.9.0.2

check "driver self-test (link, speed, health, loopback)" ethtool -t eth0

ip netns del peer
check "driver unload" modprobe -r mlx5_core
check "driver reload" modprobe mlx5_core
sleep 0.5
setup_pair
check "ping after driver reload" ping -c 3 -i 0.2 -W 2 10.9.0.2

echo "--- stats"
ip -s link show eth0
finish
