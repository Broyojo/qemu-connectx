#!/bin/sh
# Print what software can see of an mlx5 port, in a form that can be diffed.
#
# Run it in the test guest (guest/run.sh guest/tests/fingerprint.sh) and on a
# machine with a real ConnectX card (sh fingerprint.sh <ifname>), then diff
# the two outputs.  Differences are either expected (addresses, serial
# numbers, features the model leaves out) or things to fix in the model.
#
# Values that are unique per card or per boot are masked.
if=${1:-eth0}
pci=$(basename "$(readlink "/sys/class/net/$if/device")")

sec() { echo; echo "### $*"; }
mask() {
    sed -E 's/([0-9a-f]{2}:){5}[0-9a-f]{2}/<mac>/g
            s/[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]/<pci>/g'
}

ip link set "$if" up 2>/dev/null
sleep 1

sec "driver"
ethtool -i "$if" | grep -v -E "^(bus-info|version)" | mask
sec "pci"
lspci -s "$pci" -nn | mask
lspci -s "$pci" -vv 2>/dev/null |
    grep -E "Capabilities:|LnkCap:|LnkSta:|Region|MSI-X:|DevCap:" | mask |
    sed -E 's/at [0-9a-f]+/at <addr>/; s/\[[0-9a-f]+( v[0-9])?\]//'
sec "link"
ethtool "$if" | grep -v -E "Link detected|Current message|drv probe" | mask
sec "features"
ethtool -k "$if"
sec "private flags"
ethtool --show-priv-flags "$if"
sec "rings"
ethtool -g "$if"
sec "channels"
ethtool -l "$if" | sed -E 's/^(Combined|RX|TX|Other):.*/\1: <n>/'
sec "coalescing"
ethtool -c "$if"
sec "pause"
ethtool -a "$if"
sec "timestamping"
ethtool -T "$if" | sed -E 's/(provider index|PTP Hardware Clock): .*/\1: <n>/'
sec "rss"
ethtool -x "$if" | sed -n '/RSS hash function/,$p'
ethtool -x "$if" | sed -n 's/^RSS hash key:.*/RSS hash key: present/p'
sec "fec"
ethtool --show-fec "$if" 2>&1
sec "module"
ethtool -m "$if" 2>&1 | head -12
sec "statistics (names only)"
ethtool -S "$if" | sed -n 's/^ *\([a-zA-Z_0-9]*\):.*/\1/p' |
    sed -E 's/^(rx|tx|ch)[0-9]+_/\1N_/' | sort -u
sec "devlink"
devlink dev info "pci/$pci" 2>&1 | mask |
    sed -E 's/(serial_number|board.serial_number) .*/\1 <serial>/'
devlink dev param show "pci/$pci" 2>&1 | mask
devlink health show "pci/$pci" 2>&1 | mask | sed -E 's/ (error|recover) [0-9]+/ \1 <n>/g'
sec "ptp clock"
phc=$(ethtool -T "$if" | sed -n 's/.*provider index: //p; s/^PTP Hardware Clock: //p' | head -1)
[ -n "$phc" ] && cat "/sys/class/ptp/ptp$phc/clock_name" \
    "/sys/class/ptp/ptp$phc/max_adjustment" "/sys/class/ptp/ptp$phc/n_alarms" \
    "/sys/class/ptp/ptp$phc/n_external_timestamps" \
    "/sys/class/ptp/ptp$phc/n_periodic_outputs" \
    "/sys/class/ptp/ptp$phc/n_programmable_pins" "/sys/class/ptp/ptp$phc/pps" \
    2>&1
sec "hwmon"
for h in /sys/bus/pci/devices/"$pci"/hwmon/hwmon*; do
    [ -d "$h" ] && ls "$h" | grep -E "^(name|temp)" | sort
done
sec "kernel log"
dmesg | grep "mlx5_core $pci" | sed -E 's/^\[[ 0-9.]+\] //' | mask | head -30
