# 📋 Prerequisites

This guide covers all requirements needed to run **aiyuspot**, both on the Windows host and inside the Kali Linux WSL2 environment.

---

## 🪟 1. Windows Host Requirements

| Requirement | Details & Notes |
| :--- | :--- |
| **Windows 10 / 11 (x64)** | Must have the **WSL2** feature enabled. |
| **`kali-linux` WSL2 Distro** | Install via `wsl --install -d kali-linux`. *(Note: The launcher scripts expect the exact distro name `kali-linux`).* |
| **[usbipd-win](https://github.com/dorssel/usbipd-win)** | Download and install the latest `.msi` release. This provides the `usbipd` background service and the `VBoxUSBMon` USB filter driver. |
| **Custom WSL2 Kernel** | **Required for every in-tree adapter in `adapters.conf`** (RT73, Edimax/RTL8723BU, and all pending MediaTek/Atheros/rtw88 profiles). The stock Microsoft kernel ships none of these modules — see [kernel-build.md](kernel-build.md). *(The TP-Link TX1U Nano builds its module out-of-tree — via `wifi-control.bat driver`, or automatically during `wifi-control.bat provision` — though the kernel build tree is still required).* |

---

## 🐉 2. Inside Kali WSL2

### 2.1 Core Packages & Firmware

Update your package lists and install the networking utilities, USB mode-switcher, and non-free firmware packages. Each adapter profile in `adapters.conf` names the package it needs (column `fw_pkg`); the full set covers every registered chip:

```bash
sudo apt update
sudo apt install -y \
  hostapd \
  dnsmasq \
  iw \
  iptables \
  usb-modeswitch \
  usbutils \
  kmod \
  iproute2 \
  procps \
  tar \
  git \
  python3 \
  firmware-misc-nonfree \
  firmware-realtek \
  firmware-mediatek \
  firmware-ath9k-htc \
  build-essential
```

> ⚡ `wifi-control.bat provision` installs the right subset automatically for the detected adapter. The list above is a convenient broad manual set; the provisioner may additionally install `kmod`, `iproute2`, `procps`, `python3`, and `git` for driver/provisioning work.

---

### 2.2 Building `hostapd-wep` *(Optional — WEP & Open Modes Only)*

> **ℹ️ Note:** If you only plan to use **WPA2-PSK**, you can skip this step. WPA2 uses the stock `/usr/sbin/hostapd` binary directly. The `wep` and `open` start flows print a reminder when `hostapd-wep` is missing — `wifi-control.bat provision` itself always runs in WPA2 provisioning mode and cannot auto-build it from source.

Modern Debian and Kali distributions compile `hostapd` without legacy WEP support (`CONFIG_WEP`). To support legacy devices via WEP or Open AP modes, **aiyuspot** expects a separately compiled binary located at `/usr/local/sbin/hostapd-wep`.

1. Ensure `deb-src` repositories are enabled in `/etc/apt/sources.list`, then fetch the build dependencies and source code:
   ```bash
   sudo apt update
   sudo apt build-dep -y hostapd
   apt source hostapd
   cd wpa-*/hostapd
   ```

2. Configure and compile with `CONFIG_WEP=y`:
   ```bash
   cp defconfig .config
   echo "CONFIG_WEP=y" >> .config
   make -j$(nproc)
   ```

3. Install the custom binary to `/usr/local/sbin/`:
   ```bash
   sudo cp hostapd /usr/local/sbin/hostapd-wep
   sudo chmod 755 /usr/local/sbin/hostapd-wep
   ```

---

### 2.3 Firmware & `fwserve`

Under WSL2, `request_firmware()` reads `/lib/firmware` in the **VM init mount namespace** — not the distro's filesystem — and the init-namespace `systemd-udevd` aborts pending sysfs requests within ~1 ms (stub rule `50-firmware.rules`).

The launcher handles this automatically:

* **Detected adapter** — `wifi-control.bat` stages every `fw_stage` entry from the matched profile in `adapters.conf` into the initns `/lib/firmware` and disables the udev stub on every start (idempotent) — no manual staging needed.

The `fwserve` helper remains as a fallback for pending sysfs firmware requests (works once the udev stub is disabled). `wifi-control.bat provision` compiles it when missing or when `fwserve.c` is newer than the installed binary, and the launcher starts it (`nohup fwserve`) before every driver probe — or build it yourself inside Kali from the repository root:

```bash
sudo gcc -O2 -o /usr/local/bin/fwserve fwserve/fwserve.c
sudo chmod 755 /usr/local/bin/fwserve
```

*(See [`fwserve/README.md`](../fwserve/README.md) for the full technical breakdown.)*

---

## ✅ 3. Verify Your Setup

Once both the Windows and Kali environments are prepared, run the health check command from Windows Command Prompt or PowerShell:

```bat
wifi-control.bat check
```

This generates a single diagnostic report confirming:
* USB adapter detection (`usbipd list`) and Windows PnP status
* `usbipd` / `VBoxUSBMon` service health
* Kali-side `lsusb` visibility, loaded kernel modules (every `module` column in `adapters.conf`), and `wl*` interfaces
* `hostapd` and `dnsmasq` running state
