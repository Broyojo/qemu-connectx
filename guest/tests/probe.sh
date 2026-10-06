#!/bin/sh
# Does mlx5_core bind and create a netdev?
dmesg | grep -i -E "mlx5|15b3" | tail -60
echo "--- links"
ip -br link
echo "--- lspci"
lspci -nn | grep -i -E "mell|15b3"
