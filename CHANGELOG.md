# 📝 Changelog

All notable changes to **aiyuspot** are documented here. This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [0.1.0] — 2026-10-14

### 🎯 Feature — Wi-Fi hotspot on Windows via Kali WSL2 + usbipd-win

First public release. **aiyuspot** turns a USB Wi-Fi adapter passed through to Kali WSL2 into a working access point — `hostapd` (WPA2) / `hostapd-wep` (WEP/Open), `dnsmasq` DHCP on `192.168.50.0/24`, and `iptables-legacy` MASQUERADE out through WSL's `eth0` — while Windows networking stays completely untouched. `wifi-control.bat` drives the whole flow end-to-end: adapter detection (`VID:PID` → busid), `VBoxUSBMon`/`usbipd` service recovery, bind → detach → attach, firmware + driver loading, and AP teardown on `stop`. The Ralink RT73 (`148f:2573`) is verified end-to-end including a custom WSL2 kernel (`rt73usb` module) and the `fwserve` sysfs firmware fallback; the TP-Link Archer TX1U Nano (`3625:0110` / `a69c:5721` storage mode) is prepared with an out-of-tree `aic8800_fdrv` build — AP mode unverified.

### 🆕 Added

- **`wifi-control.bat`** — portable menu/CLI entry point (`%~dp0` + `wslpath` path resolution, UAC self-elevation, `default`/`open`/`wep`/`wpa2`/`stop`/`check`/`driver`/`reset` commands, per-adapter `ADAPT` map with multi-device collision detection)
- **`wifi-menu.ps1`** — arrow-key TUI with per-action descriptions, WEP key / WPA2 passphrase prompts, and resolved-command preview before execution
- **`kali/kali-wsl-hotspot.sh`** — full AP bring-up: `usb-modeswitch` for storage-mode adapters, `fwserve` + `modprobe`, interface discovery (`wlx*`/`wlan*`), `hostapd`/`hostapd-wep` launch, `dnsmasq` DHCP `192.168.50.10–200` (DNS via WSL host proxy `10.255.255.254`), `ip_forward` + `MASQUERADE`
- **`fwserve/fwserve.c`** — sysfs firmware fallback feeding `rt73.bin` to the kernel (the WSL2 kernel never forwards firmware requests to userspace)
- **`kali/install-aic8800.sh`** — out-of-tree `aic8800_fdrv` build (`saish660/aic8800dc` fork), `3625:0110` device-ID patch, `aic_load_fw` symbol resolution via `KBUILD_EXTRA_SYMBOLS`, firmware + module install
- **`scripts/check-adapters.ps1`** — read-only health report (usbipd list, Windows PnP states, `VBoxUSBMon`/`usbipd` services, WSL modules, `hostapd`/`dnsmasq`/`fwserve`/`usb-modeswitch` presence)
- **`scripts/reset-rt73.ps1`** — destructive SYSTEM-level `Enum` registry purge + usbipd state wipe for wedged PnP (Code 19)
- **`SETUP.md`** — end-to-end installation guide with per-adapter skip paths
- **`docs/`** — `architecture.md` (four layers / two planes / failure domains), `prerequisites.md`, `kernel-build.md` (RT73USB config → `.wslconfig`), `adapters.md` (compatibility matrix), `images/e2e-architecture.jpg`
- **MIT License**

### 🏗️ Architecture

- **Four layers** — L1 Windows host (PnP, uplink, usbipd service) → L2 transport (`usbipd` TCP/Hyper-V, `vhci_hcd` URB forwarding) → L3 Kali WSL2 (driver/firmware/AP stack) → L4 Wi-Fi clients
- **Two planes** — control plane (setup/teardown orchestration) vs data plane (client → `wlan0` → `ip_forward` → `MASQUERADE` → `eth0` → Hyper-V vSwitch → host NIC)
- **Layered repo layout** — entry points at root, `scripts/` Windows helpers, `kali/` guest-side scripts, `fwserve/` firmware component, `docs/` guides

### 🔐 Semantics & security

- **WPA2-PSK is the recommended mode** — runs on the stock `/usr/sbin/hostapd`; WEP is cryptographically broken and Open is unencrypted — both kept for legacy/testing only
- **Default credentials are public** — SSID `aiyuspot`, WEP key `aiyu1` must be changed by users
- **`reset` is destructive** — purges `HKLM\SYSTEM\CurrentControlSet\Enum` device keys via a temporary SYSTEM scheduled task; use only for severely wedged PnP states
- **Authorized use only** — the tool bridges Wi-Fi clients onto an existing network uplink; operator must own or be authorized on that network
- **No proprietary artifacts** — `rt73.bin` firmware and the compiled kernel are documented but not redistributed

### 🧪 Verification

- `bash -n` syntax check — `kali/kali-wsl-hotspot.sh`, `kali/install-aic8800.sh` clean
- `gcc` build check — `fwserve.c` compiles clean (`BUILD-OK`)
- `wifi-control.bat check` — runs correctly from the repository root (portability verified)
- `wslpath` round-trip — `D:\Teepakorn-54850\non-work\aiyuspot` → `/mnt/d/Teepakorn-54850/non-work/aiyuspot`
- GitHub anchor slugs verified for emoji/VS16 headings across README, SETUP.md, and docs

[0.1.0]: https://github.com/teeprakorn1/aiyuspot/releases/tag/v0.1.0
