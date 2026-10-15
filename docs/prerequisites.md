# 📋 Prerequisites

This guide covers all requirements needed to run **aiyuspot**, both on the Windows host and inside the Kali Linux WSL2 environment.

---

## 🪟 1. Windows Host Requirements

| Requirement | Details & Notes |
| :--- | :--- |
| **Windows 10 / 11 (x64)** | Must have the **WSL2** feature enabled. |
| **`kali-linux` WSL2 Distro** | Install via `wsl --install -d kali-linux`. *(Note: The launcher scripts expect the exact distro name `kali-linux`).* |
| **[usbipd-win](https://github.com/dorssel/usbipd-win)** | Download and install the latest `.msi` release. This provides the `usbipd` background service and the `VBoxUSBMon` USB filter driver. |
| **Custom WSL2 Kernel** | **Required for Ralink RT73 only.** The stock Microsoft kernel lacks `rt73usb` — see [kernel-build.md](kernel-build.md). *(The TP-Link TX1U Nano builds its module out-of-tree via `wifi-control.bat driver`, though kernel headers are still required).* |

---

## 🐉 2. Inside Kali WSL2

### 2.1 Core Packages & Firmware

Update your package lists and install the networking utilities, USB mode-switcher, and non-free firmware package (which provides `rt73.bin` for the RT73 adapter):

```bash
sudo apt update
sudo apt install -y \
  hostapd \
  dnsmasq \
  iw \
  iptables \
  usb-modeswitch \
  firmware-misc-nonfree \
  build-essential
```

---

### 2.2 Building `hostapd-wep` *(Optional — WEP & Open Modes Only)*

> **ℹ️ Note:** If you only plan to use **WPA2-PSK**, you can skip this step. WPA2 uses the stock `/usr/sbin/hostapd` binary directly.

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

* **TX1U** — `wifi-control.bat` stages all AIC8800 blobs into the initns `/lib/firmware` and disables the udev stub on every start (idempotent).
* **RT73** — `rt73.bin` must be present in the initns `/lib/firmware` once. Stage it from Windows:

  ```bat
  wsl.exe -d kali-linux -u root -- sh -c "cat /lib/firmware/rt73.bin" | wsl.exe --system -u root -e sh -c "P=$(pidof systemd-udevd | cut -d' ' -f1); nsenter -m -t $P sh -c 'cat > /lib/firmware/rt73.bin'"
  ```

The `fwserve` helper remains as a fallback for pending sysfs firmware requests (works once the udev stub is disabled). Compile it inside Kali from the repository root:

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
* USB adapter detection and Windows PnP status
* `usbipd-win` service health
* Loaded Linux kernel modules (`rt73usb` / `aic8800_fdrv`)
* `hostapd` and `dnsmasq` availability
