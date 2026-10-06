# qemu-connectx

An emulated Mellanox/NVIDIA ConnectX-5 Ethernet adapter for QEMU.

The stock Linux `mlx5_core` driver binds to it unmodified and gets a working
100GbE netdev with a PTP hardware clock, so software that needs ConnectX
behaviour — in particular hardware timestamping with `HWTSTAMP_FILTER_ALL` —
can be developed and tested without the hardware.

```
$ ethtool -i eth0
driver: mlx5_core
firmware-version: 16.35.4030 (QEMU0000000001)
$ lspci -nn | grep Mellanox
01:00.0 Ethernet controller [0200]: Mellanox Technologies MT27800 Family [ConnectX-5] [15b3:1017]
$ hwstamp_ctl -i eth0 -t 1 -r 1
new settings:
tx_type 1
rx_filter 1
```

QEMU has no out-of-tree device API, so this is a patch series against a QEMU
release (currently v11.1.2) rather than a plugin. `scripts/build-qemu.sh`
fetches that release, applies `patches/` and builds it.

## Status

Tested with QEMU 11.1.2 and Linux 6.18 guests: aarch64 (`virt` machine,
HVF on an Apple Silicon host) and x86-64 (`q35` machine, TCG emulation on the
same host). Other kernel versions, other guest operating systems and KVM
hosts have not been tried yet.

What works:

- Driver probe, teardown and reload; link up/down; 100G by default, with
  1/10/25/40/50G selectable on the command line or with `ethtool -s`.
- The data path a ConnectX-5 uses by default: striding receive queues fed
  through UMR-updated memory keys, and multi-packet send WQEs. The driver's
  fallbacks (scatter-list receive queues, single-packet sends) work too.
- One channel per guest CPU (tested with up to 8), with checksum offload,
  TSO for IPv4/IPv6, UDP segmentation, VLAN stripping and jumbo frames.
- Hardware timestamps on every sent and received frame, a PTP hardware clock
  (`/dev/ptpN`) that can be read, set, stepped and frequency-adjusted, and
  `SIOCSHWTSTAMP` with `HWTSTAMP_FILTER_ALL`.
- Receive flow steering as the driver programs it: MAC and VLAN filtering,
  promiscuous mode, `ethtool -N` rules (drop, steer to queue, RSS context),
  and RSS with the Toeplitz hash, including the symmetric variant.
- Global pause (link-level flow control), on by default as on hardware: a
  receiver that runs out of buffers holds its link partner off instead of
  dropping.
- XDP (native and generic) and AF_XDP sockets.
- What the port says about itself: the ConnectX-5 link modes, FEC, the
  EEPROM of the cable plugged in (a QSFP28 passive copper cable), firmware
  version, a temperature sensor, port/vport/queue counters.
- The driver's `ethtool -t` self-test including loopback, `devlink` reload,
  and PCI function-level reset with the driver recovering through its health
  poll as it does on hardware.

Not modelled:

- RDMA/RoCE, SR-IOV, the e-switch and sub-functions. If `mlx5_ib` is loaded
  its probe fails with `-ENOMEM` and the netdev carries on unaffected.
- CQE compression can be switched on, but the device never chooses to
  compress.
- Tunnel, TLS, IPsec and MACsec offloads; flow counters; rules matching on
  tunnel or metadata fields.
- PTP pins (PPS in/out), real-time clock mode, firmware update and crash
  dump, NVIDIA's own tools that talk to the card through its vendor-specific
  PCI capability (`mstflint`, `mlxlink`).
- FEC and link mode settings are stored and reported back but have no effect
  on the (ideal) link.
- Live migration (the device blocks it).

Timestamps are taken from QEMU's virtual clock at the moment a frame is
handed to, or arrives from, the network backend. They are consistent and
monotonic, and good for exercising timestamping code paths, but they measure
emulation latency, not wire time. Two emulated ports wired back to back see a
one-way delay of a few microseconds, with `ptp4l` holding its offset within
roughly ±10µs. On macOS the host clock QEMU uses only resolves 1µs.

## Building

```
scripts/build-qemu.sh
```

This needs QEMU's usual build dependencies (ninja, meson, glib, pixman;
libslirp for `-netdev user`). The binary ends up in
`qemu/build/qemu-system-<arch>`. Set `TARGETS=x86_64-softmmu,aarch64-softmmu`
to build other system targets.

## Using the device

```
qemu-system-aarch64 ... \
    -device pcie-root-port,id=rp0,chassis=1 \
    -netdev user,id=n0 \
    -device mlx5,netdev=n0,bus=rp0
```

The guest needs a kernel with `mlx5_core` (`CONFIG_MLX5_CORE_EN`). Putting the
device behind a root port makes it look like a card in a slot; directly on
the root bus it also works, but the driver cannot report a PCIe link then.

| Property | Default | Meaning |
| --- | --- | --- |
| `netdev`, `mac` | | Backend and MAC address, as for any QEMU NIC |
| `vectors` | 64 | MSI-X vectors; one is for control, the rest bound the channel count |
| `speed` | 100000 | Link speed in Mb/s: 1000, 10000, 25000, 40000, 50000 or 100000 |
| `freq-khz` | 1000000 | Frequency of the free-running timer behind the PTP clock |
| `device-id` | 0x1017 | PCI device id (0x1017 is ConnectX-5) |
| `fw-major`, `fw-minor`, `fw-sub` | 16.35.4030 | Reported firmware version |

To see what the driver asks of the device, enable trace events:
`-trace 'mlx5_cmd'` logs every firmware command, `-trace 'mlx5_*'` everything
including per-frame events. `-d unimp,guest_errors` logs commands and
registers the model does not implement.

## Testing

`guest/` holds a self-contained test setup: an Alpine `linux-lts` kernel and a
small initramfs with `mlx5_core`, ethtool, iperf3, linuxptp and the Linux
kernel's own NIC selftests. Building it needs Docker and takes a few minutes:

```
guest/build-guest.sh
```

Both scripts default to the host's architecture. Set `ARCH=x86_64` or
`ARCH=aarch64` for the other one; `run.sh` then needs the matching
`qemu-system-<arch>` (see `TARGETS` above) and uses TCG instead of hardware
virtualisation.

`guest/run.sh <script>` boots the guest, runs the script after the driver has
loaded and powers off. Without a script it leaves a shell on the serial
console.

```
# one port on QEMU's user-mode network: link, ping, hardware timestamps
guest/run.sh guest/tests/hwts.sh

# two ports wired back to back
export NICS="$(guest/tests/pair-nics)"
guest/run.sh guest/tests/pair.sh          # traffic, offloads, steering, reload
guest/run.sh guest/tests/ptp.sh           # PHC tools and ptp4l synchronisation
guest/run.sh guest/tests/robust.sh        # MAC change, devlink reload, PCI reset
guest/run.sh guest/tests/fingerprint.sh   # dump the software-visible surface
SMP=8 guest/run.sh guest/tests/ksft.sh    # the kernel's driver selftests
```

| Test | What it covers | Result |
| --- | --- | --- |
| `hwts.sh` | `HWTSTAMP_FILTER_ALL` via `SIOCSHWTSTAMP`; TX and RX hardware timestamps on a packet socket, checked against the PHC | pass |
| `pair.sh` | ping, TCP/UDP iperf3 over IPv4/IPv6, TSO, UDP segmentation, checksums, RSS hash against the kernel's Toeplitz reference, striding/legacy receive queues, multi-packet send, speed change, FEC, module EEPROM, MAC filter, promiscuous mode, `ethtool -N` rules, jumbo, VLAN, ring/channel resize, link flap, `ethtool -t`, driver reload | pass (58 checks); TCP at about 6 Gbit/s with no drops or retransmits |
| `ptp.sh` | kernel `testptp` and `hwtstamp_config`, linuxptp `phc_ctl`/`hwstamp_ctl`, `ptp4l` between the two ports | pass; `ptp4l` locks with offsets under 10µs |
| `robust.sh` | MAC address change, `devlink dev reload`, PCI function-level reset and recovery, loading `mlx5_ib` | pass |
| `ksft.sh` | `tools/testing/selftests/drivers/net`: `ping`, `queues`, `stats`, `napi_id`, `napi_threaded`, `hw/csum`, `hw/irq`, `hw/xsk_reconfig`, `hw/rss_api`, `hw/rss_ctx`, `hw/rss_input_xfrm`, `hw/tso`, `hw/nic_timestamp` | 65 cases pass, 0 fail, 23 skip |

These results are the same for the aarch64 and the x86-64 guest.

The skipped kernel selftest cases need things the 6.18 mlx5 driver itself
does not offer (per-queue LSO statistics, timestamp configuration over
netlink, FEC) or more queues than the guest has CPUs. Three kernel test
scripts are left out of the default run:

- `xdp.py`: 5 of 13 cases pass. Six count datagrams and are thrown off by
  the guest's socat (1.8.1), which sends an extra empty datagram when it
  closes a UDP socket; device traces show each frame sent and received once.
  Two check per-queue statistics, which the driver keeps in software and
  does not update for frames that XDP drops or sends back.
- `hds.py`: two cases expect TCP header/data split, which the driver only
  offers with hardware GRO (ConnectX-7).
- `hw/rss_flow_label.py`: the driver does not support hashing on the IPv6
  flow label.

Run a subset with `APPEND="KSFT_TESTS=ping.py,hw/csum.py"`.

## Comparing with a real card

There is no public conformance suite for ConnectX adapters, so the tests
above are the standard ones that exist: the kernel's driver selftests (which
upstream CI also runs against real mlx5 hardware), the driver's self-test and
linuxptp. They show that the driver is satisfied, not that the model matches
a physical card in every detail.

For that, `guest/tests/fingerprint.sh` prints everything software can see of
a port in a diffable form: PCI capabilities, `ethtool` output of every kind,
`devlink` information and parameters, the PTP clock's properties, sensor and
statistics names, and the driver's log lines. Per-card values are masked.
`guest/tests/fingerprint.emulated.txt` is its output for the emulated device.
On a machine with a real ConnectX-5:

```
sh fingerprint.sh <ifname> > real.txt
diff real.txt fingerprint.emulated.txt
```

Each difference is either an intended one (the board id reads
`QEMU0000000001`; features listed above as not modelled) or something to fix
in the model. This comparison has not been done yet.

## How it works

The driver talks to a ConnectX in three ways, and the model has a file for
each (under `hw/net/mlx5/` in the QEMU tree):

- **Initialization segment** (`mlx5.c`): registers at the start of BAR0 —
  firmware revision, command queue address, command doorbell, a health
  counter, and the free-running timer the driver builds its PTP clock on.
- **Command interface** (`mlx5_cmd.c`): the driver writes commands into a
  page of guest memory and rings a doorbell; this file plays the firmware,
  answering capability queries and creating the objects below. The
  capabilities it advertises decide which driver features switch on.
- **Data path** (`mlx5_dp.c`, `mlx5_fs.c`, `mlx5_mkey.c`): event,
  completion, send and receive queues live in guest memory. A doorbell write
  makes the device walk new send WQEs and transmit; a frame from the backend
  is classified by the flow tables the driver programmed, copied into the
  chosen receive queue and completed. Addresses in queue entries are resolved
  through memory keys, whose translation tables the driver rewrites on the
  fly. Every completion carries the timer value, which is where hardware
  timestamps come from.

`mlx5_reg.c` holds the port and management registers (link modes, FEC, the
cable's EEPROM, firmware version, temperature).

`mlx5_ifc.h` is the driver's own description of the command layouts,
imported unmodified from Linux.

## Repository layout

```
patches/            the device, as a patch series against QEMU
scripts/            build-qemu.sh, export-patches.sh
guest/              test guest: image build, run.sh, test scripts
guest/src/hwts.c    timestamping test program
```

`scripts/build-qemu.sh` leaves a git checkout in `qemu/` on a branch named
`mlx5`. To change the device, commit there and run
`scripts/export-patches.sh` to refresh `patches/`.

## License

The QEMU patches are GPL-2.0-or-later, like QEMU. `mlx5_ifc.h` is imported
from Linux under its GPL-2.0/OpenIB BSD dual license. The test scripts and
programs in `guest/` are GPL-2.0-or-later.
