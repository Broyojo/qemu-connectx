# Helpers shared by the guest test scripts.  Sourced, not run.

fails=0

# check <description> <command...>: run a command, record whether it passed.
check() {
    desc=$1
    shift
    if "$@" >/tmp/check.out 2>&1; then
        echo "ok   - $desc"
    else
        echo "FAIL - $desc"
        sed 's/^/       /' /tmp/check.out | tail -15
        fails=$((fails + 1))
    fi
}

# Two ports wired back to back: eth0 stays here, eth1 moves to netns "peer".
setup_pair() {
    # Keep IPv6 addresses when a test takes the link down.
    echo 1 > /proc/sys/net/ipv6/conf/all/keep_addr_on_down
    echo 1 > /proc/sys/net/ipv6/conf/default/keep_addr_on_down
    ip netns add peer
    ip netns exec peer sh -c '
        echo 1 > /proc/sys/net/ipv6/conf/all/keep_addr_on_down
        echo 1 > /proc/sys/net/ipv6/conf/default/keep_addr_on_down'
    ip link set eth1 netns peer
    ip addr add 10.9.0.1/24 dev eth0
    ip -6 addr add fd00:9::1/64 dev eth0 nodad
    ip link set eth0 up
    ip -n peer link set lo up
    ip -n peer addr add 10.9.0.2/24 dev eth1
    ip -n peer -6 addr add fd00:9::2/64 dev eth1 nodad
    ip -n peer link set eth1 up
    sleep 1
}

# stat <ifname> <counter>: one ethtool -S counter.
stat() {
    ethtool -S "$1" | awk -v k="$2:" '$1 == k { print $2 }'
}

# Kernel log must be free of driver errors and checksum complaints.  A test
# that provokes driver errors on purpose can narrow DMESG_BAD.
DMESG_BAD="hw csum failure|WARNING:|BUG:|Call trace|\
mlx5_core.*(err|fail|timeout|syndrome)"
dmesg_clean() {
    ! dmesg | grep -i -E "$DMESG_BAD"
}

finish() {
    check "kernel log is clean" dmesg_clean
    if [ "$fails" -eq 0 ]; then
        echo "RESULT: PASS"
    else
        echo "RESULT: FAIL ($fails)"
    fi
    exit "$fails"
}
