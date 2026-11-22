# ATBM603x Wi-Fi test kit (Ingenic T31)

Static tools and a logger to run from RAM on a Thingino camera with an AltoBeam ATBM6031 radio (Wyze Cam v3 and Pan v3 variants), for [thingino-firmware#1915](https://github.com/themactep/thingino-firmware/issues/1915): the uplink that drops to 13 Mbps (HT MCS1) and stays there. Nothing is written to flash; a reboot removes everything.

## Contents

| File | What | Version |
|---|---|---|
| `bin/iw` | nl80211 client: link, station counters, the AP's beacon flags, scans | iw 6.17, libnl 3.12.0 |
| `bin/tcpdump` | packet capture (on `wlan0`, or on a monitor interface of a second device) | tcpdump 4.99.6, libpcap 1.10.7 |
| `bin/iperf3` | throughput tests against a host on the LAN | iperf 3.22 |
| `wifi-watch.sh` | once-a-minute logger with wedge detection | |
| `SHA256SUMS`, `SOURCES.txt`, `LICENSES/` | checksums, where each binary came from, the licences | |

All three binaries are static MIPS32 (XBurst1) uClibc builds and run on a T31 with no libraries. They have been run on a Pan v3 (T31X, ATBM6031, driver 3174, firmware 18438).

## Get it

Download `wifi-kit-t31.tar.gz` from the [Releases](../../releases) page, or build it (below). The release also carries `libnl-3.12.0.tar.gz`, the source of the LGPL library that `bin/iw` links statically.

## Install

```sh
# from a PC
scp -O wifi-kit-t31.tar.gz root@<camera-ip>:/tmp/
# on the camera
cd /tmp && gunzip -c wifi-kit-t31.tar.gz | tar -x && cd wifi-kit-t31   # BusyBox tar has no -z
sha256sum -c SHA256SUMS
```

## The logger

```sh
(trap "" HUP; sh wifi-watch.sh -s > /dev/null 2>&1 < /dev/null &)   # start, survives logout
tail -f /tmp/wifi-watch.log
kill $(cat /tmp/wifi-watch.pid)                                     # stop
```

One line a sample, for example:

```text
2026-11-22T17:23:26Z rate=138 rssi=-30 tx_frames=127 tx_ok_pct=99.2 mac_tx_retries=8 mac_tx_failed=0 mac_tx_bitrate=65.0 signal=-31 noise=-70 idle=939 conn=1 erp=Barker_Preamble_Mode htprot=no nongf=1 obss_nongf=0
```

| Field | Source | Meaning |
|---|---|---|
| `rate` | `iwpriv common get_maxrate` | the firmware's TX rate in 100 kbps, truncated to one byte: `138` is 65 Mbps, `130` is 13 Mbps (the wedge), `4` is 26 Mbps, `8` is 52 Mbps |
| `rssi` | `get_txrx_info` | the firmware's RSSI |
| `tx_frames`, `tx_ok_pct` | `get_txrx_info` `tp`, `tsp` | frames the firmware sent since the last sample, and the share it counts as sent OK; the reports' wedged units read 90 to 94 % |
| `mac_tx_*`, `signal` | `iw station dump` | mac80211's view. It does **not** follow the firmware's rate or failures on this driver (it stays at 65 Mbps during a wedge); kept for the signal |
| `noise` | `get_noise_level` | the firmware's noise estimate, dBm |
| `idle` | `get_channel_idle` | channel idle, apparently per mille |
| `conn` | `get_conn_state` | 1 connected |
| `erp`, `htprot`, `nongf`, `obss_nongf` | `iw scan dump`, the AP's last beacon | the AP's protection state: 802.11b devices, HT protection mode, non-greenfield stations, overlapping networks |

`EVENT` lines mark the start, a wedge (`rate=130` for `-n` samples, default 3) and its end, a change in the AP's beacon flags, and a change in the connection state. At a wedge the last 15 kernel log lines are copied in.

Options: `-t` seconds between samples (60), `-n` samples at 13 Mbps that make a wedge (3), `-a max650` to re-apply the full TX ceiling once at a wedge (`iwpriv wlan0 fwcmd lmac_max_rate,650`) and log the next 10 seconds, `-s` one active scan at start that lists the other networks on and next to the camera's channel (channel, signal, flags; a short gap in traffic), `-o` the log file.

**What it writes:** no SSID and no MAC address. Other networks are listed by frequency, signal and flags only. Read the log before posting it all the same.

## Firmware commands the kit relies on

Checked on firmware 18438 on a healthy link, with the rate capped to stand in for a wedge:

- `iwpriv wlan0 fwcmd lmac_max_rate,<n>` caps the TX rate; `n` is in 100 kbps (130 = 13 Mbps, 260 = 26 Mbps, 650 = 65 Mbps). `lmac_max_rate,650` lifts a cap at once.
- `iwpriv wlan0 fwcmd lmac_min_rate,<n>` sets a floor; it does not lift a cap.
- On a healthy link, 13 Mbps by itself gave no failed frames.

## Capturing frames

The ATBM6031 driver supports monitor mode, but not beside a connected `wlan0`: a monitor interface is created but will not come up (`Device or resource busy`). Bringing `wlan0` down to capture would also end the wedge. So capture with a **second** device near the wedged camera, on the AP's channel: a spare camera with this kit, or a PC with a card that does monitor mode. The steps below have not yet been run on a camera with `wlan0` down.

```sh
# on the spare camera: off the network for the capture
killall wpa_supplicant udhcpc; ip link set wlan0 down
./bin/iw phy phy0 interface add mon0 type monitor
./bin/iw dev mon0 set channel <AP channel>
ip link set mon0 up
./bin/tcpdump -i mon0 -s 256 -w /tmp/air.pcap -G 300 -W 12     # 12 files of 5 minutes, in RAM
# reboot the spare camera afterwards to put it back on the network
```

What to look for in the capture, around the minute the logger marks a wedge: the AP's beacons (a change in ERP or HT protection), deauthentication or disassociation frames, a group-key handshake (EAPOL from the AP to all), the camera's frames and their retry bit, block-ack sessions torn down (DELBA), and traffic from devices not on the network (beacons and probe requests of others on the channel).

## iperf3

```sh
./bin/iperf3 -c <host> -R -t 10        # the camera sends to the host
```

Reverse mode (`-R`) has the host pull, so the camera's uplink is measured. Run it once on a healthy link and once during a wedge.

## Build

```sh
./build.sh                 # downloads the sources and Thingino's XBurst1 uClibc toolchain
./build.sh -t /path/to/toolchain   # or use a toolchain you have
```

Every source is fetched from its upstream site and checked against a pinned sha256 (listed in `build.sh`); the result is `work/wifi-kit-t31.tar.gz`. The toolchain is a rolling release asset, so its sum is printed rather than pinned; set `TOOLCHAIN_SHA256` to enforce one. Needs a Linux x86_64 host with bash, curl, tar, xz, make, pkg-config, bison and flex.

## Licence

`wifi-watch.sh` and `build.sh`: MIT (`LICENSE`). The tools in the kit keep their own licences, in the kit's `LICENSES/`: tcpdump and libpcap (BSD), iw (ISC), iperf3 (BSD), libnl (LGPL-2.1).
