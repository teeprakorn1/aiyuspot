# 🔌 Supported Adapters

This document outlines the hardware compatibility, driver requirements, and setup details for USB Wi-Fi adapters used with **aiyuspot**, along with instructions on how to add support for new hardware.

---

## 📊 Compatibility Matrix

| USB ID (`VID:PID`) | Adapter | Linux Driver | AP Mode | Notes |
| :---: | :--- | :---: | :---: | :--- |
| `148f:2573` | **Ralink RT73** (54M USB) | `rt73usb` *(in-kernel)* | ✅ WPA2 / WEP / Open | Verified end-to-end |
| `3625:0110` | **TP-Link Archer TX1U Nano** | `aic8800_fdrv` *(out-of-tree)* | 🟡 Unverified | Wi-Fi 6, FullMAC driver |
| `a69c:5721` | **TX1U Storage / CD-ROM Mode** | — | — | Auto-ejects and re-enumerates as `3625:0110` |

---

## 🔍 Hardware Profiles

### 1. Ralink RT73 (`148f:2573`) — ✅ Verified

The Ralink RT73 is fully tested and supports WPA2, WEP, and Open AP modes reliably.

* **Custom Kernel Required**: The stock Microsoft WSL2 kernel does not include the `rt73usb` module. You must compile a custom WSL2 kernel (see [kernel-build.md](kernel-build.md)).
* **Proprietary Firmware**: Requires `rt73.bin` from the `linux-firmware` or `firmware-misc-nonfree` packages. *(Note: Do not commit this binary to the repository as it is proprietary).*
* **WSL Firmware Workaround**: The WSL2 kernel never forwards firmware requests to userspace, so even a running `udev` daemon cannot serve them. [`fwserve`](../fwserve/README.md) works around this by feeding `rt73.bin` to the kernel via the sysfs fallback mechanism (`force_sysfs_fallback=1`).
* **Windows PnP Recovery**: Driver conflicts on the Windows host (e.g., `VBoxUSB`, stale PnP states, or Device Manager **Code 19**) may occur after a reboot. Run `wifi-control.bat reset` to purge the stuck registry state.

---

### 2. TP-Link Archer TX1U Nano (`3625:0110`) — 🟡 Prepared (Experimental)

Driver compilation and module loading are automated, though full AP mode functionality remains under testing.

* **USB Mode-Switching**: Some hardware revisions initially enumerate as a virtual CD-ROM / mass-storage device (`a69c:5721`) containing Windows drivers. The bundled `aic.rules` udev rule ejects the storage volume so the adapter re-enumerates in Wi-Fi mode (`3625:0110`); inside WSL2 the launcher also calls `usb_modeswitch -v 0xa69c -p 0x5721 -K` explicitly in case no udev daemon is running.
* **Out-of-Tree Driver**: Uses [`saish660/aic8800dc`](https://github.com/saish660/aic8800dc) with a custom two-line patch that registers `3625:0110` under the `AIC8800DW` chip family. Running `wifi-control.bat driver` (which executes `kali/install-aic8800.sh`) automatically patches, builds, and installs the module.
* **Current Status**: 
  * **Working**: Modules build cleanly and `modprobe aic8800_fdrv` loads successfully on Linux kernel `6.18`.
  * **Unverified**: Access Point (AP) mode capability. Because this is a FullMAC driver, its `nl80211` AP support may have limitations. Community test reports and PRs are welcome!

---

## ➕ Adding a New Adapter

To add support for another USB Wi-Fi adapter, follow these three steps:

### Step 1: Identify the Hardware ID
Find the adapter's `VID:PID` by running `usbipd list` in Windows PowerShell or `lsusb` inside Kali WSL2.

### Step 2: Register the VID:PID in Scripts
Update the detection logic in the following files:
1. **`wifi-control.bat`**:
   * Add the `VID:PID` to the `for %%H in (...)` detection loop.
   * Add a friendly name mapping to the `ADAPT` variable block.
2. **`scripts/check-adapters.ps1`**:
   * Add the adapter's profile entry to the `$profiles` array so it shows up in health checks.

### Step 3: Configure Driver Loading (If Applicable)
If your adapter requires an out-of-tree kernel module or custom initialization step, add the `modprobe` or setup command to the `:start` routine inside `wifi-control.bat` (and/or `kali/kali-wsl-hotspot.sh`).
