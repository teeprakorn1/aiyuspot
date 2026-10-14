# 🚀 aiyuspot — End-to-End Setup Guide

This guide walks you through the complete installation process — from a stock Windows machine to a fully functional Wi-Fi hotspot.

---

## 🗺️ Installation Roadmap

| Step | Component | Environment | Required For |
| :---: | :--- | :---: | :--- |
| **1** | [WSL2 + Kali Linux](#1%EF%B8%8F⃣-install-wsl2--kali-linux) | 🪟 Windows | All adapters |
| **2** | [usbipd-win](#2%EF%B8%8F⃣-install-usbipd-win) | 🪟 Windows | All adapters |
| **3** | [Custom WSL2 Kernel](#3%EF%B8%8F⃣-build-a-custom-wsl2-kernel-rt73-only) | 🐉 Kali / 🪟 Windows | **Ralink RT73 only** |
| **4** | [Core Packages & `fwserve`](#4%EF%B8%8F⃣-install-kali-packages--fwserve) | 🐉 Kali | All adapters |
| **5** | [`hostapd-wep` Binary](#5%EF%B8%8F⃣-build-hostapd-wep-wep--open-modes-only) | 🐉 Kali | **WEP / Open modes only** |
| **6** | [AIC8800 Driver](#6%EF%B8%8F⃣-install-tx1u-nano-driver-tx1u-only) | 🪟 Windows / 🐉 Kali | **TP-Link TX1U Nano only** |
| **7** | [Clone & Launch](#7%EF%B8%8F⃣-clone--launch) | 🪟 Windows | Everyone |

---

## 1️⃣ Install WSL2 + Kali Linux

Open **Windows Command Prompt** or **PowerShell** as Administrator and install the Kali Linux WSL2 distribution:

```bat
wsl --install -d kali-linux
```

Reboot your PC if prompted, then complete the initial Kali username/password setup.

> **ℹ️ Note:** The launcher scripts expect the exact distribution name **`kali-linux`**. If your distro uses a different name, update the `set "DISTRO=..."` variable inside `wifi-control.bat`.

---

## 2️⃣ Install `usbipd-win`

Download and install the latest `.msi` installer from the official [dorssel/usbipd-win releases](https://github.com/dorssel/usbipd-win/releases) page. 

This installs both the `usbipd` background service and the `VBoxUSBMon` USB filter driver (both are automatically started by `wifi-control.bat`).

**Verify installation:**
```bat
"C:\Program Files\usbipd-win\usbipd.exe" list
```

---

## 3️⃣ Build a Custom WSL2 Kernel *(RT73 Only)*

The stock Microsoft WSL2 kernel does not include the `rt73usb` driver module. You must compile a custom kernel and point `%USERPROFILE%\.wslconfig` to the resulting image:

```ini
[wsl2]
kernel=C:\\wsl\\wsl-kernel-bzImage
```

📖 **Full step-by-step instructions:** [docs/kernel-build.md](docs/kernel-build.md)

> **💡 Using the TP-Link TX1U Nano?** You do **not** need a custom kernel image — the TX1U's driver (`aic8800_fdrv`) builds out-of-tree in Step 6. However, ensure your kernel build headers remain installed at `/lib/modules/$(uname -r)/build` so the module can compile.

---

## 4️⃣ Install Kali Packages & `fwserve`

Inside your **Kali WSL2** terminal, install the required networking utilities, non-free firmware, compiler toolchain, and compile the `fwserve` helper:

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

# Compile and install the sysfs firmware helper (run from the repo root)
sudo gcc -O2 -o /usr/local/bin/fwserve fwserve/fwserve.c
sudo chmod 755 /usr/local/bin/fwserve
```

---

## 5️⃣ Build `hostapd-wep` *(WEP / Open Modes Only)*

> **⏭️ Using WPA2 only?** Skip this step! WPA2 mode runs directly on the stock `/usr/sbin/hostapd` binary installed in Step 4.

Because Debian/Kali compiles `hostapd` without legacy WEP support, build a secondary binary with `CONFIG_WEP=y` enabled:

```bash
# Ensure deb-src entries are enabled in /etc/apt/sources.list first
sudo apt update
sudo apt build-dep -y hostapd

apt source hostapd && cd wpa-*/hostapd
cp defconfig .config && echo "CONFIG_WEP=y" >> .config
make -j$(nproc)

sudo cp hostapd /usr/local/sbin/hostapd-wep
sudo chmod 755 /usr/local/sbin/hostapd-wep
```

---

## 6️⃣ Install TX1U Nano Driver *(TX1U Only)*

> **⏭️ Using the Ralink RT73?** Skip to Step 7.

From the repository root on **Windows**, run the automated driver builder:

```bat
wifi-control.bat driver
```

This patches, builds, and installs the `aic8800_fdrv` kernel module (with USB ID `3625:0110` registered) inside Kali. Remember to re-run this command whenever you update your WSL2 kernel.  
📖 **More details:** [docs/adapters.md](docs/adapters.md)

---

## 7️⃣ Clone & Launch

1. On **Windows**, clone the repository and launch the interactive control menu:
   ```bat
   git clone https://github.com/teeprakorn1/aiyuspot.git
   cd aiyuspot
   wifi-control.bat
   ```

2. Select **Start WPA2 AP** from the arrow-key menu (or run `wifi-control.bat wpa2 MyNet MyPass123`).
3. Approve the Windows **UAC prompt** (required for `usbipd bind`).
4. Connect your phones or laptops to the Wi-Fi network!

**Run a full health check anytime:**
```bat
wifi-control.bat check
```

---

## ✅ Expected First-Run Output

When the hotspot starts cleanly, you should see console output similar to this:

```text
usbipd: info: Device with hardware-id '148f:2573' found at busid '1-5'.
rt73usb: OK
wlan0: AP-ENABLED
net.ipv4.ip_forward = 1
WiFi started: aiyuspot
Clients use 192.168.50.x
```

🔧 **Running into issues?** Check the [Troubleshooting section in README.md](README.md#%EF%B8%8F-troubleshooting).