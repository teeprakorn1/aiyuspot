#!/bin/bash
# ============================================================
# aiyuspot - build & install a custom WSL2 kernel with rt73usb
# for the Ralink RT73 adapter (USB ID 148f:2573).
# https://github.com/teeprakorn1/aiyuspot
#
# The stock Microsoft WSL2 kernel ships without CONFIG_RT73USB,
# so the whole kernel must be rebuilt as a module. Steps: install
# build deps -> clone/update microsoft/WSL2-Linux-Kernel ->
# config-wsl + enable rt2x00/rt73usb stack -> make -> modules_install
# -> copy bzImage to C:\wsl\wsl-kernel-bzImage.
#
# After it finishes, point %USERPROFILE%\.wslconfig at the image
# and run `wsl --shutdown` once. This takes a while (~20-40 min).
# Invoked by `wifi-control.bat kernel`.
# ============================================================
set -e

SRC=/usr/src/wsl2-kernel
REPO=https://github.com/microsoft/WSL2-Linux-Kernel.git
OUT=/mnt/c/wsl/wsl-kernel-bzImage

apt-get update -qq
apt-get install -y -qq git build-essential flex bison libssl-dev libelf-dev bc dwarves libncurses-dev

if [ -d "$SRC/.git" ]; then
    git -C "$SRC" pull --ff-only || echo "WARNING: git pull failed - building from the existing (possibly stale) tree"
else
    git clone --depth 1 "$REPO" "$SRC"
fi
cd "$SRC"

cp Microsoft/config-wsl .config
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
# symbols hidden behind an unset WLAN_VENDOR_RALINK are silently
# dropped by olddefconfig - verify they actually stuck
grep -q '^CONFIG_RT73USB=m' .config || { echo "ERROR: CONFIG_RT73USB failed to stick in .config"; exit 1; }

echo "Building kernel (this takes a while)..."
make -j"$(nproc)"
make modules -j"$(nproc)"
make modules_install
depmod -a

mkdir -p /mnt/c/wsl
cp arch/x86/boot/bzImage "$OUT"

cat <<EOF

Kernel image installed to $OUT

Next steps (Windows):
  1. Edit %USERPROFILE%\\.wslconfig and add:

       [wsl2]
       kernel=C:\\\\wsl\\\\wsl-kernel-bzImage

  2. Restart WSL:

       wsl --shutdown

  3. Verify inside Kali:

       uname -r          # should match the new kernel
       modprobe rt73usb && lsmod | grep rt73

EOF
