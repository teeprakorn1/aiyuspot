# 📝 Changelog

All notable changes to **aiyuspot** are documented here. This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [0.1.1] — 2026-10-15

### 🎯 Fix — TX1U firmware loading under WSL2 (verified end-to-end)

Root-caused and fixed the AIC8800 probe failure that produced no wireless interface. Two independent blockers were hiding behind the same `-ENOENT`/`probe -1` symptom:

1. **Wrong filesystem view** — `request_firmware()` reads `/lib/firmware` in the WSL2 VM **init mount namespace** (`kernel_read_file_from_path_initns`), not the distro's filesystem, so blobs installed inside Kali were invisible to the kernel.
2. **Instant abort by the init-namespace udevd** — the WSL2 system distro (Azure Linux) runs `systemd-udevd` with stub rule `50-firmware.rules` that writes `loading=-1` to **every** pending `/sys/class/firmware/*` request within ~0.5 ms — so the forced sysfs fallback was killed before `fwserve` (or anything) could serve it. Confirmed via ftrace: `(udev-worker)` calling `firmware_loading_store → __fw_load_abort` immediately after `device_add`.

Also explains why RT73 "just worked": `rt73.bin` was already resident in the init-namespace `/lib/firmware`, so its direct load never needed the fallback path.

### 🆕 Added

- **Init-namespace firmware staging in `wifi-control.bat`** — pipes Kali's `/lib/firmware/aic8800DC/*` into the init-ns `/lib/firmware` via `wsl --system` + `nsenter -m -t <pid> tar` (falls back to PID 1 when `systemd-udevd` isn't running), and renames `50-firmware.rules` → `.disabled` so pending requests stay pending — initns rootfs persists across WSL reboots
- **`kali/driver/install-rt73.sh` + `wifi-control.bat kernel`** — one-command custom WSL2 kernel build for the RT73 (deps → `microsoft/WSL2-Linux-Kernel` clone → `config-wsl` + `RT73USB` stack → `make` → `modules_install` → `bzImage` to `C:\wsl\`), symmetric with `wifi-control.bat driver` for the TX1U; includes the `WLAN_VENDOR_RALINK` gate fix (`config-wsl` disables it, so `olddefconfig` silently dropped `RT73USB` — first build exited 0 with no `.ko`) and a `.config` guard so that can't happen again. Driver scripts moved to `kali/driver/`; `wifi-menu.ps1` gains a **Build RT73 kernel** item
- **WPA2 CCMP→TKIP auto-fallback for RT73** — `rt73usb`'s hardware crypto rejects CCMP key installation (`nl80211: key addition failed`), so `kali-wsl-hotspot.sh` retries hostapd and switches `rsn_pairwise` to TKIP, reporting the actual cipher used
- **Stale-driver cleanup in `wifi-control.bat`** — `rmmod aic8800_fdrv aic_load_fw rt73usb` before every attach; a crashed session can leave a ghost usb device that deadlocks usbfs enumeration (`lsusb` hangs) and makes the next `usb_modeswitch`/attach silently fail
- **`modprobe usb-storage` before TX1U modeswitch** — the SCSI EJECT sequence timed out (error -7) when no storage driver had claimed the interface
- **`docs/benchmarks.md`** — measured hotspot throughput/latency for both adapters across all modes (real client) plus a reproduce-it-yourself guide including `iperf3` Wi-Fi-local testing

### 🔧 Changed

- **`install-aic8800.sh`** — driver now built with `CONFIG_USE_FW_REQUEST=y` so firmware flows through the standard `request_firmware` path instead of a raw `filp_open` that always fails in probe context under WSL2
- **`kali-wsl-hotspot.sh`** — re-probes `N-N:1.0` through `aic8800_fdrv` sysfs `unbind`/`bind` when the first probe fails (a device-level `authorized` toggle is *not* used — it drops the entire usbipd attach)
- **`fwserve/README.md`** — rewritten with the real WSL2 firmware model (initns lookup + udev stub race); `fwserve` retained as a fallback helper, functional once the stub is disabled
- **`SETUP.md`** — Step 3 gained the automated `wifi-control.bat kernel` path; Step 6 documents the automatic initns staging; new **⚠️ Warnings** section (TX1U CD-ROM personality, usbipd hiding the device, initns modification affecting all distros, UAC, destructive `reset`, WEP, public defaults)
- **`docs/architecture.md` / `kernel-build.md` / `prerequisites.md` / `adapters.md`** — corrected the WSL2 firmware model (initns lookup + udev stub); prerequisites documents one-time `rt73.bin` initns staging; kernel-build documents the vendor gate; README gained an initns security note and ghost-device/CD-ROM troubleshooting rows

### 🧪 Verification

- Full TX1U chain on real hardware, via `wifi-control.bat` end-to-end: `a69c:5721` → `usb_modeswitch` → `3625:0110` re-attach → initns firmware staging → `aic8800_fdrv` probe → `wlx*` netdev → `hostapd` **`AP-ENABLED`** + `dnsmasq` + NAT up — repeatable across runs
- **`install-rt73.sh` verified end-to-end** — build → `bzImage` to `C:\wsl\` → `.wslconfig` → `wsl --shutdown` → new kernel boots → `modprobe rt73usb` → usbipd attach detects `rt: 2573` → `wlan0` appears (caveat: when initns `/lib/firmware` is empty and no udevd is running, `rt73.bin` arrives via the `fwserve` sysfs fallback — handled automatically)
- **Client E2E — every mode on both adapters:**

| Adapter | WPA2 | WEP | Open |
|---|---|---|---|
| TX1U | ✅ 7.4/6.6 Mbps (CCMP) | ✅ 6.3/5.2 Mbps | ✅ 11.7/7.3 Mbps |
| RT73 | ✅ 4.3/1.0 Mbps (TKIP fallback) | ✅ 11.7/6.8 Mbps | ✅ 5.6/5.8 Mbps |

- Initns persistence confirmed: blob staged Oct 8 survived a VM boot on Oct 15; wedged ghost-device recovery verified via `rmmod`
- Note: out-of-tree `aic8800_fdrv` must be rebuilt after every kernel `modules_install` (`wifi-control.bat driver`)

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

[0.1.1]: https://github.com/teeprakorn1/aiyuspot/releases/tag/v0.1.1
[0.1.0]: https://github.com/teeprakorn1/aiyuspot/releases/tag/v0.1.0
