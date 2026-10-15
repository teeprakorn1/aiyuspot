# 🛠️ Building a Custom WSL2 Kernel with `rt73usb`

The stock `Microsoft/standard` WSL2 kernel does not include the Ralink driver (`CONFIG_RT73USB`), which the RT73 adapter requires. This guide walks you through compiling and installing a custom WSL2 kernel with wireless module support.

> **🚀 Automated:** `wifi-control.bat kernel` runs `kali/driver/install-rt73.sh` which performs this entire guide for you (deps → clone → config → build → `bzImage` to `C:\wsl\`). This page documents the manual path.

> **ℹ️ Note:** A custom kernel image is **strictly required for the Ralink RT73**. The TP-Link Archer TX1U Nano uses an out-of-tree driver (`aic8800_fdrv`) built via `wifi-control.bat driver`, though it still requires the kernel headers/build tree prepared in Step 4.

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

---

## 2. Enable the Wireless Drivers

You can enable the required `rt73usb` and `mac80211`/`cfg80211` wireless stack modules either interactively or via command line.

### Option A: Via CLI (Recommended)
Run the kernel configuration script to enable the necessary modules directly:

```bash
./scripts/config \
  --enable WLAN \
  --enable WLAN_VENDOR_RALINK \
  --module CFG80211 \
  --module MAC80211 \
  --module RT2X00 \
  --module RT2X00_LIB \
  --module RT2X00_LIB_MMIO \
  --module RT2X00_LIB_USB \
  --module RT2X00USB \
  --module RT73USB

make olddefconfig
# sanity check: this must print CONFIG_RT73USB=m
grep '^CONFIG_RT73USB=m' .config || echo "CONFIG_RT73USB was silently dropped!"
```

> ⚠️ **`WLAN_VENDOR_RALINK` must be enabled first.** `config-wsl` disables every wireless vendor except MediaTek, so the `RT73USB`/`RT2X00*` symbols are invisible to Kconfig and `make olddefconfig` **silently drops** them — the build completes successfully but produces no `rt73usb.ko`. Always run the `grep` sanity check above before compiling.

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

---

## 5. Activate & Verify

1. Open **Windows Command Prompt** or **PowerShell** and restart WSL2 to load the new kernel:
   ```bat
   wsl --shutdown
   wsl -d kali-linux
   ```

2. Inside **Kali WSL2**, verify that the custom kernel is active and the `rt73usb` module loads cleanly:
   ```bash
   uname -r
   sudo modprobe rt73usb && lsmod | grep rt73
   ```

If `rt73usb` appears in the output, your custom WSL2 kernel is ready for **aiyuspot**!

> **ℹ️ Firmware note:** kernel `request_firmware()` reads `/lib/firmware` in the WSL2 VM **init mount namespace**, not the distro's. Both `rt73.bin` and the AIC8800 blobs must be visible there — `wifi-control.bat` stages them automatically at launch (see [`fwserve/README.md`](../fwserve/README.md)). Keep `CONFIG_FW_LOADER_USER_HELPER=y` (stock WSL2 default) so the sysfs fallback stays available for `fwserve`.
