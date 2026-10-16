# 🌐 aiyuspot

<p align="center">
  <strong>Turn a Windows PC into a Wi-Fi hotspot using a USB adapter — powered by Kali WSL2 and usbipd-win.</strong>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge" alt="License: MIT"></a>
  <a href="https://github.com/teeprakorn1/aiyuspot"><img src="https://img.shields.io/badge/platform-Windows%20%2B%20WSL2-blue?style=for-the-badge" alt="Platform"></a>
  <a href="https://github.com/teeprakorn1/aiyuspot"><img src="https://img.shields.io/badge/version-v0.3.0-orange?style=for-the-badge" alt="Version"></a>
</p>

---

**aiyuspot** passes a USB Wi-Fi adapter through to **Kali WSL2** via `usbipd-win`. Inside WSL, Kali runs `hostapd` (AP mode), `dnsmasq` (DHCP), and `iptables` NAT to route traffic out through the PC's existing network uplink. Wireless clients simply see and connect to a standard Wi-Fi network. 

> 💡 **Zero Host Pollution:** No changes are made to your Windows networking configuration — the entire routing and AP stack lives cleanly inside WSL2.

---

## 📌 Contents

- [Architecture](#%EF%B8%8F-architecture)
- [Features](#-features)
- [Supported Adapters](#-supported-adapters)
- [Quick Start](#-quick-start)
- [CLI Usage](#-cli-usage)
- [Security Notes](#%EF%B8%8F-security-notes)
- [Troubleshooting](#%EF%B8%8F-troubleshooting)
- [Repository Layout](#-repository-layout)
- [Contributing](#-contributing)
- [License](#-license)

---

## 🏗️ Architecture

![aiyuspot architecture](docs/images/e2e-architecture.jpg)

> 📐 **Deep dive:** [docs/architecture.md](docs/architecture.md) — layered view, control/data planes, and failure domains.

<details>
<summary>🔍 <strong>View ASCII Architecture Diagram</strong></summary>

```text
     Wi-Fi clients (phones, laptops)
       192.168.50.10–.200  (DHCP via dnsmasq)
                 │
                 ▼  802.11 AP (hostapd)
┌─────────────────────────────────────────────────┐
│                  Kali WSL2                      │
│                                                 │
│   hostapd ──► wlan0  (AP, gateway .50.1)        │
│   dnsmasq ──► DHCP on 192.168.50.0/24           │
│   iptables ──► NAT/MASQUERADE ──► eth0 ─────────┼──┐
└────────────▲────────────────────────────────────┘  │ Hyper-V
             │ USB passthrough                       │ switch
   usbipd-win (bind → attach)                        ▼
             │                               ┌───────────────┐
     USB Wi-Fi adapter                       │ Windows host  │──► LAN ──► Internet
     (RT73 / TX1U Nano)                      │ uplink        │
                                             └───────────────┘
```
</details>

---

## ✨ Features

- 🔒 **Multiple Security Modes:** Supports **WPA2-PSK** (recommended, using stock `/usr/sbin/hostapd`), legacy **WEP** (5/13-char), and **Open** AP modes (using a custom `/usr/local/sbin/hostapd-wep`).
- ⌨️ **Dual Interface:** Includes both an interactive arrow-key menu UI and a full CLI. `wifi-control.bat` is completely portable and runs from any directory (`%~dp0` + `wslpath`).
- 🔌 **Automated Passthrough:** Automatically detects supported adapters and executes `usbipd bind ➔ attach ➔ start`.
- 🩺 **Diagnostics & Recovery:** Built-in adapter/driver health reporting (`check`) and automated stuck-PnP state recovery (`reset`).
- 🛠️ **Driver Builder:** Includes an automated out-of-tree driver build script (`driver`) for AIC8800-based adapters (TX1U Nano).

---

## 📡 Supported Adapters

| Adapter | USB ID | Driver | Status |
| :--- | :---: | :---: | :--- |
| **Ralink RT73** *(54M USB)* | `148f:2573` | `rt73usb` *(custom kernel)* | ✅ **Verified** — all modes client-tested (WPA2 auto-falls back to TKIP) |
| **TP-Link Archer TX1U Nano** *(AX300, Wi-Fi 6)* | `3625:0110` <br>*(Storage: `a69c:5721`)* | `aic8800_fdrv` | ✅ **Verified** — AP works (WPA2 / WEP / Open) |
| **Edimax EW-7611ULB** *(N150 + BT4.0)* | `7392:a611` <br>*(Clone: `0bda:b720`)* | `rtl8xxxu` *(custom kernel ≥6.6)* | ✅ **Verified** — WPA2, WEP, and Open client-tested |

All profiles live in **`adapters.conf`** — including *pending* entries for MT7921AU / MT7612U / MT7610U / AR9271 / RTL8822BU·CU / RTL8821CU·8811CU / RTL8723DU / RTL8192EU·8188FU·8192CU and a `noap` marker for MT7601U. Unregistered adapters get a best-effort fallback: `find-wifi.ps1` ranks candidates by confidence, the launcher attaches by busid, and `adapter-provision.sh --generic` modalias-probes for a driver — gated by an `iw` AP check.

> ➕ **Adding another adapter:** add one line to `adapters.conf` — detection, firmware staging, modeswitch, health checks, provisioning and kernel symbols all derive from it. See [docs/adapters.md](docs/adapters.md).

---

## 🚀 Quick Start

> 📦 **Full setup guide:** [SETUP.md](SETUP.md) — end-to-end installation from scratch.
>
> 📘 **How to use the menu and commands:** [docs/user-guide.md](docs/user-guide.md)

### 1. Install Prerequisites
Ensure you have WSL2 with a `kali-linux` distribution and [usbipd-win](https://github.com/dorssel/usbipd-win) installed on Windows. Then plug the adapter in and run **`wifi-control.bat provision`** (menu → *Setup → Auto-setup adapter*) — it reads the adapter's registry spec and installs what it needs: apt packages (`hostapd`, `dnsmasq`, `iw`, `iptables`, `usb-modeswitch`, the right `firmware-*` package), the `fwserve` helper, and — with a `[Y/n]` confirm — a custom kernel build. The start flow applies the kernel switch when provisioning returns code 3.
* 📖 **Setup Guides:** [docs/prerequisites.md](docs/prerequisites.md) · [docs/kernel-build.md](docs/kernel-build.md) · [CHANGELOG.md](CHANGELOG.md)

### 2. Launch the Hotspot
Run `wifi-control.bat` (it will automatically self-elevate via UAC to manage `usbipd bind`). Select **Start hotspot → WPA2-PSK (recommended)** from the interactive menu, or launch it directly via CLI:
```bat
wifi-control.bat wpa2 MyNet MyPass123
```

### 3. Connect Your Devices
Join the newly broadcast SSID from your client devices. They will automatically receive an IP address in the `192.168.50.x` range via DHCP (Gateway: `192.168.50.1`).

> ⚠️ **Important:** Always change the default credentials before using the hotspot in a live environment. See [Security Notes](#️-security-notes) below.

---

## 💻 CLI Usage

```bat
wifi-control.bat                        :: Launch interactive arrow-key menu
wifi-control.bat default                :: Start WPA2 AP (SSID: aiyuspot / Pass: aiyuspot)
wifi-control.bat open [MyNet]           :: Start Open AP (unencrypted)
wifi-control.bat wep MyNet abcde        :: Start WEP AP (Key must be 5 or 13 ASCII chars)
wifi-control.bat wpa2 MyNet MyPass123   :: Start WPA2-PSK AP (Passphrase >= 8 chars)
wifi-control.bat stop                   :: Stop AP, detach USB, and terminate Kali WSL
wifi-control.bat check                  :: Run adapter & driver health report
wifi-control.bat diag                   :: Show collected error log (Windows + Kali)
wifi-control.bat driver                 :: Build and install AIC8800 driver in Kali (TX1U)
wifi-control.bat kernel                 :: Build custom WSL2 kernel (all adapters.conf modules)
wifi-control.bat provision              :: Auto-install what the detected adapter's spec needs
wifi-control.bat reset                  :: Execute destructive PnP recovery (see warning)
wifi-control.bat help                   :: Show usage and all commands
```

> 📝 **CLI caveats:** SSID/passphrases containing `!` are eaten by cmd's delayed expansion — use the interactive menu instead. The menu accepts printable ASCII only and rejects `&|<>"'`. Windows validates length in *characters*; Kali enforces the real limit in *bytes* (SSID ≤ 32 B, WPA2 8–63 B) — multibyte input that passes the CLI can still be rejected inside Kali.

**Network Configuration:**
* **Subnet:** `192.168.50.0/24`
* **DHCP Pool:** `192.168.50.10` – `192.168.50.200`
* **Gateway:** `192.168.50.1`
* **DNS:** `10.255.255.254` (WSL2 host DNS proxy; dnsmasq runs DHCP-only)

---

## 🛡️ Security Notes

* **Use WPA2:** WEP is cryptographically broken and Open mode provides zero encryption. Both are included strictly for testing or connecting vintage/legacy hardware.
* **Change Default Credentials:** The default SSID (`aiyuspot`), WEP key (`aiyu1`), and WPA2 passphrase (`aiyuspot`) are publicly documented in this repository.
* **Administrator Privileges:** The launcher requests UAC administrator elevation on Windows to execute `usbipd bind` operations.
* **`reset` is Destructive:** The `reset` command purges device registry keys under `HKLM\SYSTEM\CurrentControlSet\Enum` via a temporary `SYSTEM`-level scheduled task and clears `usbipd` state records. Only run this when an adapter is severely stuck in a broken Windows PnP state. Review the header in `scripts/reset-rt73.ps1` for full details.
* **Modifies the WSL VM init namespace:** For the TX1U, the launcher stages AIC8800 firmware into the VM init `/lib/firmware` and disables a firmware-abort udev stub (`50-firmware.rules`) there via `wsl --system` + `nsenter`. This affects all WSL2 distros on the machine and persists across restarts.
* **Authorized Networks Only:** Only operate this tool on networks you own or have explicit permission to administer, as it bridges external Wi-Fi clients directly onto your host machine's network uplink.

---

## 🛠️ Troubleshooting

> 🔍 **Start with `wifi-control.bat diag`** (menu → *Tools → Error log*) — failure boundaries write parseable lines to `%TEMP%\aiyuspot-errors.log` (Windows: `ts|L#|site|rc=N|msg`) and `/var/log/aiyuspot.log` (Kali: `ts|L#|site|rc=N msg`), so the real cause usually shows up there before it surfaces as a symptom below. `L1` = Windows/USB/WSL transport, `L2` = provisioning, `L3` = driver/AP runtime.

| Symptom | Resolution |
| :--- | :--- |
| **`Device busy (exported)`** or **Code 19** after reboot | Run `wifi-control.bat reset`, then physically unplug and replug the USB adapter. |
| **`No supported adapter found`** | Run `wifi-control.bat check` and verify that the device is detected under `usbipd list`. |
| **`rfkill` warning** inside WSL | Harmless WSL2 virtualized hardware limitation — safe to ignore. |
| **Kernel module missing** after WSL/kernel update | Re-run `wifi-control.bat driver` (for TX1U) or run `wifi-control.bat kernel` to rebuild the registry-driven custom kernel and modules. |
| **TX1U shows a CD-ROM / access-denied dialog** | Normal — that's its storage-mode personality (`a69c:5721`). Click **Cancel**; the launcher mode-switches it automatically. |
| **`usb_modeswitch: No devices in default mode found`** or `lsusb` hangs in Kali | A stale ghost USB device is wedging the stack. Run `wifi-control.bat stop`, then `usbipd detach --all`, then retry. (v0.1.1+ auto-`rmmod`s stale modules before attach.) |
| **`No devices found with hardware-id 3625:0110`** | The mode-switch didn't take — unplug and replug the TX1U, then start again. |
| **`usbipd-win not found` / `usbipd` errors** | Install it from [dorssel/usbipd-win releases](https://github.com/dorssel/usbipd-win/releases) — the launcher checks for it before touching hardware. |
| **`WSL distro 'kali-linux' not found`** | Run `wsl --install -d kali-linux` — the distro name must be exactly `kali-linux` (or edit `DISTRO=` in `wifi-control.bat`). |
| **`'git' is not recognized`** | Install [Git for Windows](https://git-scm.com/download/win), or download the repo ZIP instead — scripts don't need git to run. |
| **`Kernel build tree missing`** during `driver` | `aic8800_fdrv` builds against `/lib/modules/$(uname -r)/build` — run `wifi-control.bat kernel` once (it installs the build tree the TX1U driver needs). |
| **`firmware: failed to load rt73.bin`** | The launcher stages `rt73.bin` into the WSL init namespace and disables the udev abort-stub automatically. If it persists, check `dmesg` for `fwserve` activity and see [fwserve/README.md](fwserve/README.md). |

---

## 📂 Repository Layout

```text
├── SETUP.md                 # End-to-end installation guide
├── CHANGELOG.md             # Release history (Keep a Changelog)
├── adapters.conf            # Adapter registry — one 13-col line per profile (source of truth)
├── wifi-control.bat         # Main entry point — interactive menu & CLI (portable)
├── wifi-menu.ps1            # PowerShell arrow-key menu interface (v0.3.0)
├── scripts/                 # Windows-side utilities
│   ├── check-adapters.ps1   # Adapter and driver health diagnostic script
│   ├── find-wifi.ps1        # Unknown-adapter scout (tiered confidence for attach)
│   ├── set-wslkernel.ps1    # Safe .wslconfig kernel= editor (backs up first)
│   └── reset-rt73.ps1       # Stuck-PnP recovery utility (SYSTEM registry purge)
├── kali/
│   ├── kali-wsl-hotspot.sh  # Orchestrates hostapd, dnsmasq, and iptables NAT in Kali
│   ├── adapter-provision.sh # Spec-driven installer: pkgs / firmware / kernel / driver
│   └── driver/
│       ├── install-aic8800.sh  # Compiles aic8800_fdrv driver with patched VID:PID (TX1U)
│       └── install-rt73.sh     # Builds custom WSL2 kernel (kconfig from adapters.conf)
├── fwserve/
│   └── fwserve.c            # sysfs firmware fallback daemon (rt73.bin, rtlwifi/*, AIC8800 blobs)
├── test/                    # Test harnesses (no hardware needed)
│   ├── linux/               # lint + stub-PATH shell suites + stubs/
│   ├── windows/             # batch harness + Pester + fixtures/
│   └── c/                   # fwserve unit test
├── .github/workflows/       # CI: Windows + Linux jobs on every push
├── .gitattributes           # LF/CRLF line-ending rules (scripts break otherwise)
└── docs/
    ├── architecture.md      # Layered architecture, control/data planes, failure domains
    ├── prerequisites.md     # Windows host and Kali WSL2 setup instructions
    ├── kernel-build.md      # Custom WSL2 kernel guide (kconfig from adapters.conf)
    ├── adapters.md          # Hardware notes and guide for adding new VID:PIDs
    ├── benchmarks.md        # Measured throughput/latency and how to reproduce
    ├── user-guide.md       # Menu buttons, keyboard controls, CLI, and troubleshooting
    └── images/
        ├── e2e-architecture.jpg
        ├── benchmark-throughput.png
        └── benchmark-latency.png
```

---

## 🤝 Contributing

Issues and Pull Requests are welcome! We are especially looking for:
* Real-client verification for `pending` registry profiles (MT7921AU, MT7612U/7610U, AR9271, rtw88 family, rtl8xxxu gen1/gen2) — flip `status` in `adapters.conf` and add benchmark numbers.
* `adapters.conf` lines for USB Wi-Fi adapters not yet covered (see [docs/adapters.md](docs/adapters.md)).

---

## 📜 License

Distributed under the **MIT License**. See [LICENSE](LICENSE) for full details.
