# 🔌 Supported Adapters

This document outlines the hardware compatibility, driver requirements, and setup details for USB Wi-Fi adapters used with **aiyuspot**, along with instructions on how to add support for new hardware.

---

## 📊 Compatibility Matrix

| USB ID (`VID:PID`) | Adapter | Linux Driver | AP Mode | Notes |
| :---: | :--- | :---: | :---: | :--- |
| `148f:2573` | **Ralink RT73** (54M USB) | `rt73usb` *(in-kernel)* | ✅ WPA2 (TKIP) / WEP / Open | Verified end-to-end — real clients on all modes |
| `3625:0110` | **TP-Link Archer TX1U Nano** | `aic8800_fdrv` *(out-of-tree)* | ✅ WPA2 / WEP / Open | Wi-Fi 6, FullMAC driver |
| `a69c:5721` | **TX1U Storage / CD-ROM Mode** | — | — | Auto-ejects and re-enumerates as `3625:0110` |

---

## 🔍 Hardware Profiles

### 1. Ralink RT73 (`148f:2573`) — ✅ Verified

The Ralink RT73 is fully tested and supports WEP and Open AP modes reliably. WPA2 works via an automatic **TKIP fallback** — `rt73usb`'s hardware crypto intermittently rejects CCMP key installation (`nl80211: key addition failed`), so the hotspot script retries with `rsn_pairwise=TKIP`. Clients still connect fine; TKIP is just older WPA2-era crypto (still better than WEP).

* **Custom Kernel Required**: The stock Microsoft WSL2 kernel does not include the `rt73usb` module. You must compile a custom WSL2 kernel (see [kernel-build.md](kernel-build.md)).
* **Proprietary Firmware**: Requires `rt73.bin` from the `linux-firmware` or `firmware-misc-nonfree` packages. *(Note: Do not commit this binary to the repository as it is proprietary).*
* **WSL Firmware Workaround**: `request_firmware()` reads `/lib/firmware` in the WSL2 VM **init mount namespace**, not the distro's — `rt73.bin` must be staged there (see [`fwserve/README.md`](../fwserve/README.md) for the `nsenter` mechanism and why the sysfs fallback needs the init-ns udev stub disabled).
* **Windows PnP Recovery**: Driver conflicts on the Windows host (e.g., `VBoxUSB`, stale PnP states, or Device Manager **Code 19**) may occur after a reboot. Run `wifi-control.bat reset` to purge the stuck registry state.

---

### 2. TP-Link Archer TX1U Nano (`3625:0110`) — ✅ Verified (WPA2)

Driver compilation, firmware staging, and AP bring-up are automated and verified end-to-end in WPA2-PSK mode.

* **USB Mode-Switching**: Some hardware revisions initially enumerate as a virtual CD-ROM / mass-storage device (`a69c:5721`) containing Windows drivers. The launcher attaches the storage-mode device to WSL2, runs `usb_modeswitch -v 0xa69c -p 0x5721 -K` inside Kali to eject it, then **re-attaches the re-enumerated `3625:0110` device** — the original usbipd attach dies when the device resets. (`aic.rules` remains installed for reference, but explicit `usb_modeswitch` is the actual mechanism in WSL2.)
* **Out-of-Tree Driver**: Uses [`saish660/aic8800dc`](https://github.com/saish660/aic8800dc) with a custom two-line patch that registers `3625:0110` under the `AIC8800DW` chip family. Running `wifi-control.bat driver` (which executes `kali/driver/install-aic8800.sh`) automatically patches, builds, and installs the module. At runtime the launcher loads `aic_load_fw` (firmware loader) first, then `aic8800_fdrv`.
* **Dual-Adapter Selection**: When both the RT73 and TX1U are attached, `kali-wsl-hotspot.sh` picks the interface by its bound kernel driver and prefers `aic8800_fdrv` (TX1U) over `rt73usb` (RT73). To force the RT73, detach the TX1U from WSL first (`usbipd detach --hardware-id 3625:0110`).
* **Firmware Loading**: The driver requests ~15 blobs (`fmacfw_*`, `fw_adid_*`, `fw_patch_table_*`, `aic_userconfig_*.txt`) by flat filename via `request_firmware()` — requires the module built with `CONFIG_USE_FW_REQUEST=y` (see `kali/driver/install-aic8800.sh`). The blobs must be visible in the WSL2 **init mount namespace** `/lib/firmware`; the launcher stages them automatically (`wsl --system` + `nsenter`) and disables the init-ns udev stub that otherwise aborts pending firmware requests in ~1 ms.
* **Current Status**: **Verified** — driver probes, firmware downloads via initns staging, `iw list` advertises `AP`, hostapd reaches `AP-ENABLED` in **WPA2, WEP, and Open** modes, and real clients associated, received a `192.168.50.x` lease, and reached the Internet through NAT in all three modes.

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
