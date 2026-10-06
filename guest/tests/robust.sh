#!/bin/sh
# Things a card has to survive besides traffic: address changes, driver
# reload through devlink, PCI function-level reset, and the RDMA driver
# probing it.
#
# NICS="$(guest/tests/pair-nics)" guest/run.sh guest/tests/robust.sh
. /test/lib.sh
# The reset below makes the driver log errors while it recovers.
DMESG_BAD="hw csum failure|WARNING:|BUG:|Call trace"
setup_pair
pci=$(basename "$(readlink /sys/class/net/eth0/device)")

readd() {
    # the netdev was re-created: configure and wait for it again
    ip addr add 10.9.0.1/24 dev eth0 2>/dev/null
    ip link set eth0 up
    sleep 1
}
pingpeer() { ping -c 3 -i 0.2 -W 2 10.9.0.2; }

check "ping" pingpeer

check "change MAC address" ip link set eth0 address 02:11:22:33:44:55
ip netns exec peer ip neigh flush dev eth1
check "ping from the new address" pingpeer

check "devlink reload" devlink dev reload "pci/$pci"
readd
check "ping after devlink reload" pingpeer

# The driver is not told about a reset requested through sysfs.  It finds
# out from its health poll that the device lost its state and recovers.
check "PCI function-level reset" sh -c "echo 1 > /sys/bus/pci/devices/$pci/reset"
recovered() {
    for i in $(seq 1 40); do
        dmesg | grep -q "health recovery succeeded" && return 0
        sleep 0.5
    done
    return 1
}
check "driver notices and recovers" recovered
readd
check "ping after PCI reset" pingpeer

# The RDMA driver is loaded automatically on most distributions.  The device
# does not offer RDMA; the driver must cope and the netdev must keep working.
modprobe mlx5_ib
sleep 1
echo "--- mlx5_ib"
dmesg | grep -i -E "mlx5_ib|infiniband|rdma" | tail -5
ls /sys/class/infiniband 2>/dev/null
check "ping with mlx5_ib loaded" pingpeer
check "unload mlx5_ib" modprobe -r mlx5_ib
finish
