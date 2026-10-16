# 🔌 Supported Adapters

Adapter support is **registry-driven**: [`adapters.conf`](../adapters.conf) at the repo root is the single source of truth. The Windows launcher, `check-adapters.ps1`, `find-wifi.ps1`, the Kali hotspot script, the provisioner, and the kernel builder all read that file — the only remaining hardcoded ID is the intentional TX1U `3625:` re-probe inside the hotspot. The reset script's `148f:2573` value is only its fallback default; the launcher passes the detected adapter with `-HwId`.

---

## 🗂️ `adapters.conf` format

One line per profile, **13 pipe-delimited columns** (use `-` for empty, `,` to join multiple values inside a column — `cmd.exe for /f` collapses empty fields so never leave a column blank):

| # | Column | Meaning |
| :-: | :--- | :--- |
| 1 | `ids` | Every `VID:PID` personality the device can enumerate as (incl. storage/CD-ROM), comma-separated |
| 2 | `wifi_ids` | The `VID:PID`s that are Wi-Fi interfaces — subset of `ids` |
| 3 | `name` | Display name |
| 4 | `module` | Kernel module that binds the Wi-Fi interface — may still be set for `noap` (lets `check`/diagnostics name the iface before the AP gate refuses it) |
| 5 | `pre_modules` | Space-separated modules to load first (`-` if none) |
| 6 | `fw_stage` | Comma-separated firmware paths to stage into the WSL init namespace. `foo.bin` = preserve path; `dir/.` = flatten dir contents into `/lib/firmware` |
| 7 | `fw_pkg` | Kali apt package providing the blobs (`-` = kernel-internal / none) |
| 8 | `kconfig` | Comma-separated `SYM=value` requirements for the custom kernel build |
| 9 | `modeswitch` | `usb_modeswitch` method letter (e.g. `K` → `-K`), `-` if none |
| 10 | `min_kernel` | Informational minimum kernel version for AP support (`-` = any); the kernel builder warns when the running/build kernel is below it, while the hotspot AP gate relies on `iw` capability detection |
| 11 | `install` | Repo-relative installer script for out-of-tree drivers (`-` = in-tree) |
| 12 | `status` | `verified` / `pending` (code complete, needs hardware) / `noap` (detected but cannot host) |
| 13 | `note` | One-line caveat shown in health checks |

Consumers and lint are in `test/linux/lint.sh` — it validates all of the above plus no duplicate IDs, and that every consumer file actually references `adapters.conf`.

---

## 📊 Compatibility Matrix

| USB ID (`VID:PID`) | Adapter | Linux Driver | AP Mode | Status |
| :---: | :--- | :---: | :---: | :--- |
| `148f:2573` | **Ralink RT73** (54M USB) | `rt73usb` *(in-kernel)* | ✅ WPA2 (TKIP) / WEP / Open | **verified** |
| `3625:0110` (+ `a69c:5721` storage) | **TP-Link Archer TX1U Nano** | `aic8800_fdrv` *(out-of-tree)* | ✅ WPA2 / WEP / Open | **verified** |
| `7392:a611`, `0bda:b720` | **Edimax EW-7611ULB** / generic RTL8723BU | `rtl8xxxu` *(in-kernel)* | ✅ WPA2 / WEP / Open verified (kernel ≥ 6.6) | **verified** |
| `0bda:818b`, `0bda:f179`, `2357:0107`, `2357:0109` | **RTL8192EU / RTL8188FU** | `rtl8xxxu` | AP needs kernel ≥ 6.6 | pending |
| `0bda:8178`, `0bda:8191`, `7392:7811` | **RTL8192CU / RTL8188CUS** | `rtl8xxxu` | AP merged ~6.14; TX capped ~4 Mbit — poor AP | pending |
| `0bda:d723`, `7392:d611` | **RTL8723DU** (incl. **EW-7611ULB V2 `7392:d611`**) | `rtw88_8723du` | ✅ upstream ≥ 6.2 | pending |
| `0bda:b812`, `0bda:b81a`, `0bda:b82c`, `7392:b822…f822`, `0b05:1841…19aa` | **RTL8822BU/CU** | `rtw88_8822bu` | ✅ upstream ≥ 6.2 | pending |
| `0bda:c811`, `0bda:c820`, `0bda:8731`, `7392:c811`, … | **RTL8821CU / RTL8811CU** | `rtw88_8821cu` | ✅ upstream ≥ 6.2 | pending |
| `0e8d:7961`, `3574:6211`, `0846:9060`, `0846:9065`, `35bc:0107`, `0e8d:7902` | **MediaTek MT7921AU** (Wi-Fi 6) | `mt7921u` | ✅ upstream ≥ 5.19 | pending |
| `0e8d:7612`, `0e8d:7632`, `0846:9053`, `7392:b711`, … | **MediaTek MT7612U** | `mt76x2u` | ✅ verified on OpenWrt | pending |
| `0e8d:7610`, `148f:7610`, `148f:761a`, `2357:0103`, … | **MediaTek MT7610U** | `mt76x0u` | ✅ upstream | pending |
| `0cf3:9271`, `0cf3:1006`, `0846:9030`, `0846:9018`, … | **Atheros AR9271/AR7010** | `ath9k_htc` | ✅ ≤ 7 stations (fw limit) | pending |
| `148f:7601`, `0e8d:760a`, `0e8d:760b`, `7392:7710` | **MediaTek MT7601U** | `mt7601u` | ❌ **no AP upstream** | `noap` |

> Full, exact ID lists per profile live in `adapters.conf` — the matrix above is abbreviated.

### Unregistered adapters

If `usbipd list` shows a Wi-Fi adapter that matches **no** registry line, `scripts/find-wifi.ps1` emits `busid vid:pid tier` candidates: tier 1 means a Net-class PnP device with a Wi-Fi keyword in its PnP name or usbipd description and is auto-attached; tier 2 is description-only and requires `[Y/n]` confirmation. Non-tier-1, tier-3, or malformed candidates also require confirmation, and candidates matching the host's default-route interface are warned about. The generic path auto-installs its probe floor (`kmod`, `iproute2`, and `usbutils`) when needed. The launcher performs the bind/detach/attach **by busid only**, stages generic firmware plumbing first, then modalias-probes via `adapter-provision.sh --generic` and waits up to 20 seconds for a `phy80211` netdev. The resulting interface must still pass the **`iw` AP gate**, checked on its own phy when resolvable and falling back to global `iw list` only when it is not — no AP advertisement, no hostapd.

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
* **Adapter Selection**: `kali-wsl-hotspot.sh` picks the interface by its bound kernel driver, preferring profiles in `adapters.conf` file order (TX1U first, then the in-tree drivers — rtl8xxxu family, RT73, MediaTek, Atheros, rtw88), then any `phy80211` netdev, then `wl*`. To force a specific adapter, detach the others from WSL first.
* **Firmware Loading**: The driver requests ~15 blobs (`fmacfw_*`, `fw_adid_*`, `fw_patch_table_*`, `aic_userconfig_*.txt`) by flat filename via `request_firmware()` — requires the module built with `CONFIG_USE_FW_REQUEST=y` (see `kali/driver/install-aic8800.sh`). The blobs must be visible in the WSL2 **init mount namespace** `/lib/firmware`; the launcher stages them automatically (`wsl --system` + `nsenter`) and disables the init-ns udev stub that otherwise aborts pending firmware requests in ~1 ms.
* **Current Status**: **Verified** — driver probes, firmware downloads via initns staging, `iw list` advertises `AP`, hostapd reaches `AP-ENABLED` in **WPA2, WEP, and Open** modes, and real clients associated, received a `192.168.50.x` lease, and reached the Internet through NAT in all three modes.

---

### 3. Edimax EW-7611ULB (`7392:a611`) / Generic RTL8723BU (`0bda:b720`) — ✅ Verified

The Edimax N150 is a Wi-Fi + Bluetooth combo dongle built on the **Realtek RTL8723BU** (1T1R 802.11n, 2.4 GHz only). Unlike the TX1U it has **no CD-ROM personality** — it enumerates directly as a composite device: interfaces 0/1 = Bluetooth (claimed by `btusb`), interface 2 = Wi-Fi (claimed by `rtl8xxxu`). `usbipd` attaches the whole device, so the BT function disappears from Windows while in use (harmless — `btusb` may log a `rtl_bt/*` firmware error, ignorable).

* **Custom Kernel Required**: AP mode for RTL8723BU was only upstreamed in **kernel 6.6** (`supports_ap` for `rtl8xxxu`). The `wifi-control.bat kernel` build enables `WLAN_VENDOR_REALTEK`, `NEW_LEDS`, `LEDS_CLASS`, and `RTL8XXXU` (+`RTL8XXXU_UNTESTED` for clone IDs like `0bda:b720`). Stock WSL2 kernel will never bind it.
* **Firmware**: requests exactly `rtlwifi/rtl8723bu_nic.bin` — provided by Kali's **`firmware-realtek`** package (a *different* package than `firmware-misc-nonfree` used for `rt73.bin`). The launcher stages it into the WSL init namespace, preserving the `rtlwifi/` subdirectory, **and** arms `fwserve` before attach — on current WSL2 builds the subdirectory request (`rtlwifi!…` in sysfs) is what `fwserve` actually serves; direct initns load still returns `-2`.
* **Hardware crypto via sec CAM**: CCMP/TKIP/WEP handled in hardware with transparent SW fallback — no rt73usb-style key-install failures expected; the generic TKIP retry remains as a safety net.
* **⚠️ Revision warning**: the **EW-7611ULB *V2*** is `7392:d611` = RTL8723**D**U — a different chip, handled by its own `rtw88_8723du` registry entry (`pending`), not this one. This profile covers the **v1** (`a611`) only.
* **Throughput expectation**: 1T1R 11n → ~72 Mbps PHY ceiling (HT20). Under `hw_mode=g` expect ~20–30 Mbps upper bound before the usbipd+NAT path limit (~12 Mbps) kicks in.
* **Current Status**: **verified** — `rtl8xxxu` probe → `fwserve` serves `rtlwifi/rtl8723bu_nic.bin` (fw rev 35.0) → `wlan0` → `iw` advertises `AP`/`AP/VLAN` on kernel `6.18.40.1` → hostapd reaches `AP-ENABLED` in WPA2-PSK, WEP, and Open modes. Real clients associated, received a `192.168.50.x` lease, and reached the Internet through NAT. WPA2 measured 4.20/3.00 Mbps with 15 ms idle ping; WEP measured 3.17/2.18 Mbps with 50 ms idle ping; Open measured 5.31/6.00 Mbps with 36 ms idle ping — see [benchmarks](benchmarks.md).

---

## ➕ Adding a New Adapter

### Step 1: Identify the Hardware ID
`usbipd list` on Windows (or `lsusb` inside Kali). If the device shows as a CD-ROM/storage personality, note *both* IDs — they go in column 1, the Wi-Fi one also in column 2.

### Step 2: Add one line to `adapters.conf`
Fill the 13 columns: ids, wifi_ids, name, module, pre_modules, fw_stage, fw_pkg, kconfig, modeswitch, min_kernel, install, status, note. Start with `status=pending` — only promote to `verified` after a real client associates.

That single line automatically wires up: launcher detection + firmware staging + modeswitch, `check-adapters.ps1` health reporting, `find-wifi.ps1` known-id suppression, hotspot driver preference + interface picking, `adapter-provision.sh` package/firmware/kernel checks, and the kernel builder's Kconfig set.

### Step 3: Verify
1. `bash test/linux/lint.sh` — registry schema + consumer consistency.
2. `wifi-control.bat provision` — installs packages/firmware, tells you if a kernel rebuild is needed, and returns the documented provisioner contract: `0` ready, `1` failed, `2` declined, `3` kernel switch needed (column 8 `kconfig` drives `install-rt73.sh`).
3. Attach + `iw list` must show `AP` under "Supported interface modes" — the hotspot hard-fails without it.
4. `wifi-control.bat open testssid` → real client associates → DHCP lease → iperf3. Only then flip `status` to `verified` and update the matrix + `docs/benchmarks.md`.
