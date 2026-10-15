# 🏗️ aiyuspot — Layered Architecture

This document explains how **aiyuspot**'s components fit together across **four logical layers** and **two operational planes** (Control Plane and Data Plane).

---

## 🗺️ System Overview

![aiyuspot architecture](images/e2e-architecture.jpg)

```text
┌──────────────────────────────────────────────────────────────┐
│ LAYER 4 — Clients      Phones / Laptops on 192.168.50.0/24   │
├──────────────────────────────────────────────────────────────┤
│ LAYER 3 — Kali WSL2    hostapd · dnsmasq · iptables NAT      │
│                        Kernel drivers: rt73usb / aic8800_fdrv│
├──────────────────────────────────────────────────────────────┤
│ LAYER 2 — Transport    usbipd-win (bind/attach) + Hyper-V    │
├──────────────────────────────────────────────────────────────┤
│ LAYER 1 — Windows      Launcher · UAC · PnP · usbipd service │
└──────────────────────────────────────────────────────────────┘
```

---

## 🧱 The Four Layers

### Layer 1 — Windows Host
Owns the physical USB port, hardware PnP state, and the primary Internet uplink (Ethernet/LAN).

| Component | Role |
| :--- | :--- |
| **`wifi-control.bat`** | Main entry point (Menu & CLI). Self-elevates via UAC and dynamically resolves paths using `%~dp0` + `wslpath`. |
| **`wifi-menu.ps1`** | Interactive arrow-key TUI. Prompts for parameters and previews the resolved CLI command before execution. |
| **`scripts/check-adapters.ps1`** | Read-only diagnostic tool. Reports `usbipd`, Windows PnP, background services, and WSL driver states. |
| **`scripts/reset-rt73.ps1`** | Destructive recovery tool. Runs a `SYSTEM`-level `Enum` registry purge to clear wedged Windows PnP states. |
| **`usbipd` + `VBoxUSBMon`** | Manages host USB sharing state. `bind` registers the adapter as attachable to WSL2. |

---

### Layer 2 — Transport (USB/IP & Hyper-V)
Bridges hardware and network traffic between the Windows host and the Linux guest VM.

* **Device Registration**: `usbipd bind --force --hardware-id <vid:pid>` claims the USB device on the host (requires Administrator privileges).
* **USB Passthrough**: `usbipd attach --wsl` forwards raw USB URBs into WSL2 via the Linux `vhci_hcd` driver over a local TCP/Hyper-V socket.
* **Device Release**: `usbipd detach` cleanly unmounts the device from WSL2 and returns control to Windows PnP.
* **Network Uplink**: Outbound internet traffic traverses WSL2's virtual `eth0` interface across the Hyper-V virtual switch to the Windows host NIC.

---

### Layer 3 — Kali WSL2 (Network & Wireless Stack)
The entire Access Point stack runs isolated inside Kali Linux — **Windows host networking remains completely untouched.**

| Sub-layer | Component | Role |
| :--- | :--- | :--- |
| **Driver** | `rt73usb` *(in-kernel)* / `aic8800_fdrv` *(out-of-tree)* | Binds to the attached USB device and exposes `wlan0` / `wlx*`. |
| **Firmware** | Init-ns `/lib/firmware` staging + `fwserve` fallback | Kernel `request_firmware` reads the **VM init mount namespace**, not the distro fs — the launcher stages blobs there via `wsl --system` + `nsenter` and disables the initns udev abort stub (`50-firmware.rules`). `fwserve` serves pending sysfs requests as a fallback. See [`fwserve/README.md`](../fwserve/README.md). |
| **Access Point** | `hostapd` *(WPA2)* / `hostapd-wep` *(WEP/Open)* | Manages 802.11 beacons, authentication, and client associations. |
| **Addressing** | `dnsmasq` | DHCP only (`port=0` — DNS disabled): leases `192.168.50.10–200`, gateway `192.168.50.1`, and pushes the WSL host DNS proxy via `dhcp-option`. |
| **Forwarding** | `iptables-legacy` + `ip_forward` | Performs `MASQUERADE` (NAT) from `wlan0` out through `eth0`. |

---

### Layer 4 — Wi-Fi Clients
Standard 802.11 client devices (phones, laptops, retro consoles, IoT).

* **IP Assignment**: Receives an IPv4 lease in `192.168.50.10–200/24` with default gateway `192.168.50.1`.
* **DNS Resolution**: Clients query the WSL2 host DNS proxy (`10.255.255.254`) directly — advertised via `dhcp-option` — which forwards to upstream DNS.
* **Internet Access**: Double-NAT'd (first via Kali `iptables`, second via the Windows Hyper-V NAT switch) onto the host's physical uplink.

---

## 🔄 Operational Planes

### 1. Control Plane *(Setup & Teardown — One-shot, Idempotent)*
Executed when launching or stopping the hotspot via `wifi-control.bat`:

```text
[Detect Adapter] ──► [Start VBoxUSBMon] ──► [usbipd bind] ──► [Clean Detach/Reset]
       │
       ▼
[Attach to WSL2] ──► [Stage FW → initns] ──► [Load Driver] ──► [Start hostapd] ──► [Start dnsmasq + NAT]
```
* Running `wifi-control.bat stop` cleanly unwinds the Control Plane in reverse order.
* Running `wifi-control.bat reset` forces a Layer-1 state repair when Windows PnP wedges the USB port.

### 2. Data Plane *(Per-Packet Flow)*
Once the AP is active, client network packets follow this path:

```text
[Wi-Fi Client] ◄──802.11──► [wlan0] ◄──► [Linux ip_forward] ◄──► [iptables MASQUERADE]
                                                                          │
[Internet] ◄── [Windows Physical NIC] ◄── [Hyper-V vSwitch] ◄───────── [eth0]
```

---

## 🚨 Failure Domains & Diagnostics

| Layer / Domain | Common Symptom | Resolution |
| :--- | :--- | :--- |
| **L1 — Windows PnP** | Device Manager **Code 19** or `Device busy (exported)` after reboot | Run `wifi-control.bat reset`, then unplug and replug the USB adapter. |
| **L2 — Transport** | Device shows as `Not shared` or `usbipd attach` fails | Run `wifi-control.bat check` to inspect state, then re-run to auto-rebind. |
| **L3 — Driver / FW** | Kernel module loads, but no `wlan0`/`wlx*` interface appears | Check `dmesg` for `Direct firmware load ... failed`. Firmware must be in the **init mount namespace** `/lib/firmware` (the launcher stages it automatically); `fwserve` covers the sysfs-fallback path once the initns udev stub is disabled.<br>**TX1U:** also re-run `wifi-control.bat driver` to rebuild the module. |
| **L3/L4 — Routing** | `AP-ENABLED` shows up, but clients get no DHCP lease or internet | Re-run the hotspot start command and verify `eth0` has connectivity inside Kali. |
