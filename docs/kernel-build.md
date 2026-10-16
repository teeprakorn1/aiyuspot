# 🛠️ Building a Custom WSL2 Kernel

The stock `Microsoft/standard` WSL2 kernel ships **none** of the in-tree drivers the `adapters.conf` registry needs: `rt73usb` (RT73), `rtl8xxxu` (Edimax/Realtek), `mt7921u`/`mt76x2u`/`mt76x0u`/`mt7601u` (MediaTek), `ath9k_htc` (Atheros), and the `rtw88_*` family. This guide walks you through compiling and installing a custom WSL2 kernel with all of them built as modules.

> **🚀 Automated:** `wifi-control.bat kernel` runs `kali/driver/install-rt73.sh` through the build and copies `bzImage` to `C:\wsl\` (deps → clone → registry config → build → `modules_install`/`depmod` → image). It does not edit `.wslconfig` or shut down WSL itself; those steps are applied by the start flow when provisioning returns exit code 3, or can be done manually below. This page documents the manual path.

> **ℹ️ Note:** A custom kernel image is **strictly required for every in-tree adapter in `adapters.conf`** — RT73, Edimax RTL8723BU, and all pending profiles (MediaTek `mt76*`/`mt7921u`, Atheros `ath9k_htc`, Realtek `rtw88_*`, `rtl8xxxu` extras) ship in no stock WSL2 kernel. `install-rt73.sh` derives the symbol set from the registry's `kconfig` columns. The TP-Link Archer TX1U Nano uses an out-of-tree driver (`aic8800_fdrv`) built via `wifi-control.bat driver`, though it still requires the kernel headers/build tree prepared in Step 4.

---

## 📋 Prerequisites

Before building, ensure your Kali WSL2 instance has the necessary build tools installed:

```bash
sudo apt update
sudo apt install -y git build-essential flex bison libssl-dev libelf-dev bc dwarves libncurses-dev
```

---

## 1. Fetch the Kernel Source & Config

Clone the official Microsoft WSL2 Linux Kernel repository and copy the default WSL configuration:

```bash
git clone --depth 1 https://github.com/microsoft/WSL2-Linux-Kernel.git
cd WSL2-Linux-Kernel
cp Microsoft/config-wsl .config
```

> **📂 Path note:** `install-rt73.sh` clones to `/usr/src/wsl2-kernel` (`KSRC`) and the provisioner checks that path to detect an already-built kernel. Any directory works for the manual build — but keep the tree intact afterwards, since `wifi-control.bat driver` compiles out-of-tree modules against it.

---

## 2. Enable the Wireless Drivers

The symbol set is **registry-driven**: `install-rt73.sh` reads the `kconfig` column (field 8) of every `adapters.conf` line, unions it with the always-required base stack (`WLAN`, `CFG80211`, `MAC80211`), and turns each `SYM=value` pair into a `--module` (`=m`) or `--enable` (`=y`) flag for `scripts/config`. You can apply the resulting set either via command line or interactively.

### Option A: Via CLI (Recommended)
Mirror the installer — derive the flags straight from the registry instead of a hand-maintained list:

```bash
# Run inside the kernel tree. ADAPTERS_CONF points at the repo registry;
# the Windows checkout is visible under /mnt/<drive>/...
ADAPTERS_CONF=/mnt/c/aiyuspot/adapters.conf   # adjust to your repo path

declare -A SYMVAL=( [WLAN]=y [CFG80211]=m [MAC80211]=m )
while IFS='|' read -r _ids _w _n _m _p _f _pkg kconf _rest; do
  case "$_ids" in ''|\#*) continue ;; esac   # skip blanks & comments
  [ "$kconf" = "-" ] && continue
  IFS=',' read -ra KVS <<<"$kconf"
  for kv in "${KVS[@]}"; do SYMVAL[${kv%%=*}]="${kv##*=}"; done
done < "$ADAPTERS_CONF"
CFGARGS=""
for s in "${!SYMVAL[@]}"; do
  case "${SYMVAL[$s]}" in m) CFGARGS="$CFGARGS --module $s" ;; *) CFGARGS="$CFGARGS --enable $s" ;; esac
done
./scripts/config $CFGARGS
make olddefconfig

# sanity check: every registry symbol must have stuck - olddefconfig
# silently drops symbols whose vendor/LEDS gates were not set first.
for s in "${!SYMVAL[@]}"; do
  grep -q "^CONFIG_${s}=${SYMVAL[$s]}" .config \
    || echo "CONFIG_${s} was silently dropped!"
done
```

📊 **The current union resolves to:** the base stack plus `WLAN_VENDOR_RALINK` + `RT2X00*` + `RT73USB` (RT73); `WLAN_VENDOR_REALTEK` + `NEW_LEDS` + `LEDS_CLASS` + `RTL8XXXU`/`RTL8XXXU_UNTESTED` and the `RTW88*` stack (Realtek); `WLAN_VENDOR_MEDIATEK` + `MT7921U`/`MT76x2U`/`MT76x0U`/`MT7601U`; `WLAN_VENDOR_ATH` + `ATH9K_HW`/`ATH9K_COMMON`/`ATH9K_HTC` (Atheros); and `USB_STORAGE` for the TX1U modeswitch path. **Adding a registry line with new `kconfig` pairs extends this set automatically** — no script or doc edits needed.

> ⚠️ **Vendor/hidden gates must be enabled first.** `config-wsl` disables most wireless vendors, so `RT73USB`/`RT2X00*`/`RTL8XXXU` symbols are invisible to Kconfig and `make olddefconfig` **silently drops** them — the build completes successfully but produces no `.ko`. `LEDS_CLASS` is an extra hidden dependency of `RTL8XXXU` on kernels ≥ 6.3. Always run the `grep` sanity checks above before compiling.

> 🧩 **Mind each profile's `min_kernel` column.** `rtl8xxxu` needs kernel ≥ 6.6 for AP mode (`supports_ap` for RTL8723BU was merged in 6.6); other floors in the registry today are 6.14 (RTL8192CU), 6.2 (`rtw88_*`), and 5.19 (`mt7921u`). The default clone branch is fine today, but a stale `linux-msft-wsl-5.15.y` clone will build successfully and silently lack AP — `install-rt73.sh` prints `make kernelversion` and warns for every profile whose `min_kernel` exceeds it.

### Option B: Via Interactive Menu (`menuconfig`)
Launch the configuration UI:

```bash
make menuconfig
```

Navigate to the following path and press `M` to build it as a loadable module:

```text
Device Drivers 
  └─> Network device support 
        └─> Wireless LAN 
              └─> Ralink driver support 
                    └─> <M> Ralink rt2501/rt73 (USB) support
```

The other families sit under their own vendor submenus on the same *Wireless LAN* page (`Realtek`, `Mediatek`, `Atheros`, …) — enable every symbol from that profile's `kconfig` column, vendor gate included. For anything beyond a single driver, Option A (or `wifi-control.bat kernel`) is far less error-prone: menuconfig hides a symbol until its gate is set, and it is easy to miss one.

---

## 3. Compile the Kernel & Modules

Build the kernel image and loadable modules using all available CPU cores:

```bash
make -j$(nproc)
make modules -j$(nproc)
```

Once finished, the compiled kernel image will be located at:
`arch/x86/boot/bzImage`

---

## 4. Install the Kernel & Modules

### 4.1 Install Modules Inside Kali WSL2
Install the compiled modules into `/lib/modules/<kver>` and generate the module dependency map so `modprobe` can resolve them:

```bash
sudo make modules_install
sudo depmod -a
```

> **⚠️ Important:** Keep the kernel source/build tree intact (or linked at `/lib/modules/$(uname -r)/build`). The `wifi-control.bat driver` command relies on these build headers to compile out-of-tree drivers like `aic8800_fdrv` later.

### 4.2 Copy the Kernel Image to Windows
Create a directory on your Windows host (e.g., `C:\wsl\`) and copy the compiled `bzImage` over:

```bash
mkdir -p /mnt/c/wsl
cp arch/x86/boot/bzImage /mnt/c/wsl/wsl-kernel-bzImage
```

### 4.3 Configure `.wslconfig`
On Windows, create or edit `%USERPROFILE%\.wslconfig` and point WSL2 to your new kernel image (use double backslashes):

```ini
[wsl2]
kernel=C:\\wsl\\wsl-kernel-bzImage
```

> ⚡ **Automated:** when provisioning reports 'kernel-switch needed' (exit code 3), the `wifi-control.bat` start flow offers to apply this for you — it runs `scripts/set-wslkernel.ps1` (upserts `kernel=` under `[wsl2]`, keeps a `.wslconfig.bak` backup, handles a missing/empty file), runs `wsl --shutdown`, and retries the start flow once.

---

## 5. Activate & Verify

1. Open **Windows Command Prompt** or **PowerShell** and restart WSL2 to load the new kernel:
   ```bat
   wsl --shutdown
   wsl -d kali-linux
   ```

2. Inside **Kali WSL2**, verify that the custom kernel is active and the module your adapter's `module` column names loads cleanly:
   ```bash
   uname -r
   sudo modprobe rt73usb  && lsmod | grep rt73      # Ralink RT73
   sudo modprobe rtl8xxxu && lsmod | grep rtl8xxxu  # Edimax / rtl8xxxu family
   sudo modprobe mt7921u  && lsmod | grep mt7921u   # MediaTek MT7921AU
   ```
   Same idea for `mt76x2u`, `mt76x0u`, `ath9k_htc`, `rtw88_8822bu`, … — modprobe only what your profile lists.

If the module appears in the `lsmod` output, your custom WSL2 kernel is ready for **aiyuspot**!

> **ℹ️ Firmware note:** kernel `request_firmware()` reads `/lib/firmware` in the WSL2 VM **init mount namespace**, not the distro's. The matched adapter profile's `fw_stage` blobs (`rt73.bin`, `rtlwifi/*`, `mediatek/*`, `ath9k_htc`, or AIC8800 files) must be visible there — `wifi-control.bat` stages that active profile automatically at launch (see [`fwserve/README.md`](../fwserve/README.md)). Keep `CONFIG_FW_LOADER_USER_HELPER=y` (stock WSL2 default) so the sysfs fallback stays available for `fwserve`.
