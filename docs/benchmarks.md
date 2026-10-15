# 📊 Benchmarks

Measured throughput and latency of the **aiyuspot** hotspot chain:

```
Wi-Fi client → USB adapter → usbipd (URB over TCP) → Kali WSL2
  → hostapd (nl80211) → ip_forward → iptables-legacy MASQUERADE
  → eth0 → Hyper-V vSwitch → Windows uplink → Internet
```

> Numbers are single-run spot checks on the maintainer's machine — not a
> controlled lab benchmark. See [Reproduce](#-reproduce) to run your own.

---

## 🧪 Test Environment

| Component | Value |
| :--- | :--- |
| Adapters under test | TP-Link Archer TX1U Nano (`3625:0110`, `aic8800_fdrv`); Ralink RT73 (`148f:2573`, `rt73usb`) |
| Kernel | `6.18.40.1-microsoft-standard-WSL2+` (custom build) |
| AP mode | WPA2-PSK (CCMP), 2.4 GHz ch 6, `hw_mode=g` |
| Hotspot subnet | `192.168.50.0/24` — DHCP `192.168.50.10–200` via `dnsmasq` |
| NAT | `MASQUERADE` on `eth0` (double-NAT through WSL2) |
| Client | Mobile device, WPA2-PSK, real-world RF conditions |
| Test tool | speedtest.net (multi-connection) |

---

## 📈 Results — 2026-10-15

### Throughput — TX1U vs RT73

![Hotspot throughput — TX1U vs RT73 across modes](images/benchmark-throughput.png)

*RT73 "WPA2" bar = TKIP fallback (rt73usb hw crypto rejects CCMP key install).
TX1U WPA2 runs CCMP. All bars are real-client speedtest runs.*

### Latency — idle vs loaded

![Latency — idle vs loaded](images/benchmark-latency.png)

Latency stays low while idle (~10 ms) but balloons once the link saturates —
classic bufferbloat amplified by the usbipd hop and the host uplink being
the bottleneck. Not great for latency-sensitive workloads under load.

---

## 📋 Raw numbers — TX1U Nano

| Metric | WPA2-PSK | WEP-64 | Open |
| :--- | ---: | ---: | ---: |
| **Download** | 7.42 Mbps | 6.31 Mbps | 11.70 Mbps |
| **Upload** | 6.57 Mbps | 5.19 Mbps | 7.31 Mbps |
| **Idle ping** | 11 ms | 9 ms | 16 ms |
| **Loaded ping (download)** | ~8–1145 ms, jitter 466 ms | ~30–1286 ms, jitter 280 ms | ~6–2308 ms, jitter 584 ms |
| **Loaded ping (upload)** | ~189–2684 ms, jitter 1446 ms | ~96–3406 ms, jitter 1415 ms | ~110–2625 ms, jitter 1530 ms |

*All runs: real mobile client, multi-connection speedtest, same chain.*

**Verdict:** ✅ works for browsing, messaging, SD video. Latency under load
is high — expected: every packet crosses USB-over-TCP (usbipd) plus a
double NAT, and the host uplink itself is the ceiling.

---

## 🔍 Where the throughput goes

The adapter is 2.4 GHz Wi-Fi 6 — raw PHY is far above 7 Mbps. The chain
narrows it down:

| Hop | Cost | Mitigation |
| :--- | :--- | :--- |
| Host uplink | Hard ceiling — test was bounded by it | Use a faster uplink |
| usbipd URB-over-TCP | Per-URB latency, limited queue depth | Fixed for now — it's the transport |
| WSL2 NAT (`eth0`) + in-Kali NAT | Double NAT adds a few ms | Could bridge instead, breaks isolation |
| 2.4 GHz ch 6 congestion | Shared band, co-channel interference | Try channels 1/11, or 5 GHz adapter |
| `hw_mode=g` in hostapd conf | Caps PHY at 54 Mbps legacy rates | Try `hw_mode=ax`/HT/VHT IEs — TX1U untested |

---

## 🧾 RT73 — 2026-10-15

Measured on the custom `rt73usb` kernel (`install-rt73.sh` build), same
chain as above, WEP-64 mode, real mobile client:

| Metric | WEP-64 | Open | WPA2-TKIP |
| :--- | ---: | ---: | ---: |
| **Download** | 11.74 Mbps | 5.59 Mbps | 4.34 Mbps |
| **Upload** | 6.80 Mbps | 5.77 Mbps | 0.95 Mbps |
| **Idle ping** | 9 ms | 10 ms | 20 ms |
| **Loaded ping (download)** | ~18–124 ms, jitter 54 ms | ~13–788 ms, jitter 49 ms | ~31–1611 ms, jitter 159 ms |
| **Loaded ping (upload)** | ~189–2550 ms, jitter 1546 ms | ~34–1982 ms, jitter 157 ms | ~403–6397 ms, jitter 712 ms |

*(WPA2 run used TKIP — rt73usb's hw crypto rejects CCMP key install;
the script auto-falls back. WPA2-TKIP runs are uplink/noise-sensitive —
treat the numbers as "works" rather than a ceiling.)*

Faster than the TX1U in this run — the RT73 does its WEP/crypto in
hardware (rt73 MAC cipher engine), while the TX1U path pays per-frame
costs through the aic8800 firmware. Loaded-ping is also noticeably
tamer on the download side, matching the lower sustained rate.

AP `AP-ENABLED` verified on the new kernel for **Open, WEP, and WPA2**
— note WPA2 uses an automatic **TKIP fallback**: `rt73usb`'s hardware
crypto rejects CCMP key installation (`nl80211: key addition failed`),
so the script retries with `rsn_pairwise=TKIP` when CCMP fails.

---

## 🔁 Reproduce

```bat
wifi-control.bat wpa2 <SSID> <PASS>
```

Then on a client device:

1. Join the SSID, confirm IP is `192.168.50.x`
2. Run https://www.speedtest.net or `iperf3` against a public server
3. For pure Wi-Fi throughput (uplink excluded), run `iperf3 -s` inside Kali
   (`wsl -d kali-linux -u root -- iperf3 -s`) and point the client at
   `192.168.50.1` — the hotspot gateway is the WSL guest itself

Additions welcome via PR — especially TX1U on 5 GHz channels, WEP/Open
mode results, and `iperf3` Wi-Fi-local numbers.
