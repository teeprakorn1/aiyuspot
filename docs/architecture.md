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
│            provision: adapter-provision.sh · registry-driven │
│            drivers: aic8800_fdrv + in-tree rt73usb/rtl8xxxu/ │
│            mt76*/rtw88_*/ath9k_htc                           │
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
| **`adapters.conf`** | Registry — one 13-column line per supported adapter profile (ids, wifi_ids, module, firmware, kconfig, modeswitch, status…). Every adapter decision derives from it; the only remaining hardcoded ID is the intentional TX1U `3625:` re-probe inside the hotspot. The reset script's RT73 ID is only a fallback default; the launcher passes the detected adapter. |
| **`wifi-control.bat`** | Main entry point (Menu & CLI). Self-elevates via UAC (async launch + rc-file handshake — `Start-Process -Wait` proved unreliable across the UAC boundary), detects the adapter from `adapters.conf`, runs provisioning, then attaches and starts the AP. Unknown adapters fall through to the tiered `find-wifi` path. |
| **`wifi-menu.ps1`** | Interactive arrow-key TUI. Prompts for parameters and previews the resolved CLI command before execution. |
| **`scripts/check-adapters.ps1`** | Read-only diagnostic tool. Reports `usbipd`, Windows PnP, background services, and WSL driver states — profiles rendered from `adapters.conf` incl. `pending`/`noap` annotations. |
| **`scripts/find-wifi.ps1`** | Unknown-adapter scout: ranks unregistered usbipd devices by confidence tier — tier 1 (Net-class PnP and a Wi-Fi keyword in the PnP name or usbipd description) auto-attaches; tier 2, tier 3, and malformed/unknown tiers ask `[Y/n]`. The launcher attaches these by `--busid`, never hardware-id. |
| **`scripts/set-wslkernel.ps1`** | Safely upserts `kernel=` under `[wsl2]` in `%USERPROFILE%\.wslconfig` (creates `.wslconfig.bak`) when a kernel switch is approved. |
| **`scripts/reset-rt73.ps1`** | Destructive recovery tool — targets the adapter given via `-HwId` (defaults to RT73 `148f:2573`; the launcher passes the detected adapter). Removes the device nodes, purges the `Enum` registry key via a `SYSTEM` scheduled task, wipes **all** usbipd-win device records, and restarts the service to clear wedged Windows PnP states. |
| **`usbipd` + `VBoxUSBMon`** | Manages host USB sharing state. `bind` registers the adapter as attachable to WSL2. |

---

### Layer 2 — Transport (USB/IP & Hyper-V)
Bridges hardware and network traffic between the Windows host and the Linux guest VM.

* **Device Registration**: `usbipd bind --force --hardware-id <vid:pid>` claims the USB device on the host (requires Administrator privileges); the unknown-adapter path binds by `--busid` instead. A `detach` before each `attach` clears any stale attachment state.
* **USB Passthrough**: `usbipd attach --wsl` forwards raw USB URBs into WSL2 via the Linux `vhci_hcd` driver over a local TCP/Hyper-V socket.
* **Device Release**: `usbipd detach` cleanly unmounts the device from WSL2 and returns control to Windows PnP.
* **Network Uplink**: Outbound internet traffic traverses WSL2's virtual `eth0` interface across the Hyper-V virtual switch to the Windows host NIC.

---

### Layer 3 — Kali WSL2 (Network & Wireless Stack)
The entire Access Point stack runs isolated inside Kali Linux — **Windows host networking remains completely untouched.**

| Sub-layer | Component | Role |
| :--- | :--- | :--- |
| **Provisioning** | `kali/adapter-provision.sh` | Runs **pre-attach**: reads the adapter's registry spec and idempotently installs packages, `fw_pkg` firmware, `fwserve`, kernel, or out-of-tree driver. Exit contract: `0` ready / `1` failed / `2` declined / `3` kernel switch needed. `--generic` handles unregistered devices post-attach (modalias probe + `phy80211` poll). |
| **Driver** | in-tree (`rt73usb`, `rtl8xxxu`, `mt76*`, `rtw88_*`, `ath9k_htc`, …) / `aic8800_fdrv` *(out-of-tree)* | Binds to the attached USB device and exposes `wlan0` / `wlx*`. |
| **Firmware** | Init-ns `/lib/firmware` staging + `fwserve` fallback | Kernel `request_firmware` reads the **VM init mount namespace**, not the distro fs — the launcher stages every `fw_stage` entry from the matched adapter profile there via `wsl --system` + `nsenter` and disables the initns udev abort stub (`50-firmware.rules`). With `force_sysfs_fallback=1`, `fwserve` serves pending sysfs requests as a fallback — the kernel mangles `/` to `!` in request-dir names, which it decodes back (and rejects `..`). See [`fwserve/README.md`](../fwserve/README.md). |
| **Access Point** | `kali-wsl-hotspot.sh` → `hostapd` *(WPA2)* / `hostapd-wep` *(WEP/Open)* | Picks the iface by bound driver (registry order), then falls back to any `phy80211` or `wl*` netdev; hard-gates on that phy's `iw` AP advertisement, falling back to global `iw list` only when the phy cannot be resolved; picks the band (Band 1 → 2.4 GHz ch 6, else 5 GHz ch 36), and retries WPA2 CCMP→TKIP on key-install failure (rt73usb quirk). |
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

Registered profile (any start verb: `default` / `open` / `wep` / `wpa2`):

```text
[Preflight: validate → UAC elevate → usbipd.exe → kali-linux probe
 → sleep-infinity runtime + VBoxUSBMon → wslpath]
      │
      ▼
[Detect via adapters.conf] ──status=noap──► [refuse: cannot host]
      │ match
      ▼
[adapter-provision.sh HWID MODE  (pre-attach:
 pkgs / fw_pkg / fwserve / kernel / out-of-tree driver)]
      │ rc=0                          │ rc=3: kernel built, not running
      │                               ▼
      │                        [confirm → set-wslkernel.ps1 → .wslconfig kernel=
      │                         → wsl --shutdown → re-enter from the top]
      ▼
[rmmod stale modules]
      │
      ▼
[FW env BEFORE attach: stage fw_stage → initns /lib/firmware ·
 udev-stub off · force_sysfs_fallback=1 · fwserve on]
      │   (kernel auto-probes drivers at attach — the firmware request
      │    fires immediately, so plumbing must be armed beforehand)
      ▼
[usbipd bind --force] ──► [detach] ──► [attach --wsl %DISTRO%]
      │
      ▼
[storage personality? usb_modeswitch → bind+detach+attach the first
 wifi_ids entry, then retarget HWID]
      │
      ▼
[rmmod stale modules → modprobe pre_modules → module
 (live dmesg, 90 s timeout)]
      │
      ▼
[kali-wsl-hotspot.sh: iface pick → phy-scoped `iw` AP gate →
 band pick (Band 1 → 2.4 GHz ch 6, else 5 GHz ch 36)]
      │
      ▼
[hostapd (wpa2) / hostapd-wep (wep·open) — CCMP→TKIP retry]
      │
      ▼
[dnsmasq DHCP] ──► [iptables-legacy MASQUERADE]
```

Unregistered adapter (no registry match — busid-scoped path):

```text
[find-wifi.ps1 tiers] ──► non-tier-1 (tier 2/3/malformed) → [Y/n]
 confirm (tier 1 auto)
      │
      ▼
[FW plumbing BEFORE attach: force_sysfs_fallback=1 + fwserve + initns udev-stub off]
      │
      ▼
[usbipd bind → detach → attach --busid] ──► [persist busid → %TEMP%\aiyuspot-attached]
      │
      ▼
[adapter-provision.sh --generic: modalias probe → phy80211 poll]
      │
      └──► rejoins at kali-wsl-hotspot.sh — same AP gate → hostapd → dnsmasq → NAT tail
```
* `wifi-control.bat stop` unwinds the Control Plane in reverse: pkills `hostapd`/`hostapd-wep`/`dnsmasq`/`fwserve`, detaches every `ids` entry in `adapters.conf` plus any busid persisted in `%TEMP%\aiyuspot-attached`, then `wsl --terminate`s the distro.
* `wifi-control.bat reset` forces a Layer-1 state repair when Windows PnP wedges the USB port — targets the detected adapter (RT73 default when nothing is detected) and is destructive (the interactive path asks for `YES`, then self-elevates; `reset YES` is the explicit-confirmation form).

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
| **L1 — Windows PnP** | Device Manager **Code 19** or `Device busy (exported)` after reboot — or every USB transfer failing (`urb->status -104` / `failed to read EFuse`) | Run `wifi-control.bat reset` (targets the detected adapter), then unplug and replug the USB adapter. |
| **L2 — Transport** | Device shows as `Not shared` or `usbipd attach` fails | Run `wifi-control.bat check` to inspect state, then re-run to auto-rebind. |
| **L3 — Driver / FW** | Kernel module loads, but no `wlan0`/`wlx*` interface appears | Check `dmesg` for `Direct firmware load ... failed`. Firmware must be in the **init mount namespace** `/lib/firmware` (the launcher stages it automatically); `fwserve` covers the sysfs-fallback path once the initns udev stub is disabled.<br>**TX1U:** also re-run `wifi-control.bat driver` to rebuild the module. |
| **L3/L4 — Routing** | `AP-ENABLED` shows up, but clients get no DHCP lease or internet | Re-run the hotspot start command and verify `eth0` has connectivity inside Kali. |

### 📋 Error-log collector

Failures historically surfaced 15–20 s *after* their cause (a dead `modprobe` reported as "interface never appeared"), and some surfaced never (elevated children, parse aborts). Every error boundary now appends one parseable line through `:log` (batch) / `alog` (bash):

```text
timestamp|L#|site|rc=N|message        e.g. 2026-10-16 05:12:41|L3|modprobe|rc=1|rtl8xxxu not found
```

* **Windows side:** `%TEMP%\aiyuspot-errors.log` — written by `wifi-control.bat` at each boundary using the local Windows `%DATE% %TIME%` format; elevated children share the same `%TEMP%` so UAC-launched steps still land in the file. Rotates to `.old` past 100 KB. `AIYUSPOT_LOG` overrides the path (tests seam).
* **Kali side:** `/var/log/aiyuspot.log` — written by `adapter-provision.sh` / `kali-wsl-hotspot.sh`; `fwserve` logs to stderr which the launcher redirects into the same file. Two files rather than one on purpose: calling `wslpath` per write would be slow and is exactly what breaks during the WSL-transport failures being logged.
* **`wifi-control.bat diag`** merges both tails — the first thing to run when anything fails.
* Layers: `L1` Windows/USB/WSL transport · `L2` provisioning/config · `L3` driver/AP runtime. Secrets never reach the log — callers pass site+rc only, never `KEY`/`HOTPASS`.
* Exit-contract separation stays intact: user cancel, semantic failure, WSL transport failure, parser failure, provision decline, and kernel-switch-needed remain distinct codes — the log records *which* one fired.
