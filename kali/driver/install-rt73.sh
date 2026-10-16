#!/bin/bash
# ============================================================
# aiyuspot - build & install the custom WSL2 kernel.
# https://github.com/teeprakorn1/aiyuspot
#
# Enables the in-tree drivers for every adapter in adapters.conf
# (kconfig column -> --module/--enable flags + .config guards).
# Currently includes: rt73usb (RT73), rtl8xxxu (Edimax/Realtek),
# mt7921u/mt76x2u/mt76x0u (MediaTek), ath9k_htc (AR9271), rtw88_*
# (RTL8822BU/8821CU/8723DU) - plus build-tree headers the TX1U's
# out-of-tree aic8800_fdrv needs.
#
# The stock Microsoft WSL2 kernel ships without these drivers, so the
# whole kernel must be rebuilt as modules. Steps: install build deps
# -> clone/update microsoft/WSL2-Linux-Kernel -> config-wsl + enable
# registry symbol stacks -> make -> modules_install
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
echo "Kernel source: $(make -s kernelversion 2>/dev/null || echo '?')"
KVER=$(make -s kernelversion 2>/dev/null || echo 0.0)

cp Microsoft/config-wsl .config

# kconfig symbols come from the registry: column 8 of every adapters.conf
# line (SYM=m|y), deduped. The base wireless stack is always required.
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ADAPTERS_CONF="${ADAPTERS_CONF:-$REPO_DIR/adapters.conf}"
declare -A SYMVAL=( [WLAN]=y [CFG80211]=m [MAC80211]=m )
GUARDS="CONFIG_WLAN=y CONFIG_CFG80211=m CONFIG_MAC80211=m"
while IFS='|' read -r _ids _w _n _m _p _f _pkg kconf _msw mink _i _s _note; do
  case "$_ids" in ''|\#*) continue ;; esac
  [ "$kconf" = "-" ] && continue
  if [ "$mink" != "-" ] && [ "$(printf '%s\n' "$KVER" "$mink" | sort -V | head -1)" != "$mink" ]; then
    echo "WARNING: kernel $KVER < $mink - profile '$_ids' (first id) will lack AP"
  fi
  IFS=',' read -ra KVS <<<"$kconf"
  for kv in "${KVS[@]}"; do
    sym="${kv%%=*}"; val="${kv##*=}"
    SYMVAL[$sym]="$val"
    GUARDS="$GUARDS CONFIG_${sym}=${val}"
  done
done < "$ADAPTERS_CONF"
CFGARGS=""
for s in "${!SYMVAL[@]}"; do
  case "${SYMVAL[$s]}" in m) CFGARGS="$CFGARGS --module $s" ;; *) CFGARGS="$CFGARGS --enable $s" ;; esac
done
# shellcheck disable=SC2086
./scripts/config $CFGARGS
make olddefconfig
# symbols hidden behind unset vendor/LEDS gates are silently
# dropped by olddefconfig - verify every registry symbol stuck
for g in $GUARDS; do
  grep -q "^$g" .config || { echo "ERROR: $g failed to stick in .config"; exit 1; }
done

echo "Building kernel (this takes a while)..."
make -j"$(nproc)"
make modules -j"$(nproc)"
make modules_install
depmod -a

# /mnt/c must be the real Windows drive mount (9p/drvfs). If it is a
# bare directory inside the VM we'd happily 'install' the image into
# the distro fs and Windows would never see it.
grep -qE ' /mnt/c (9p|drvfs|fuse\.drvfs|fuseblk) ' /proc/mounts \
  || { echo "ERROR: /mnt/c is not a Windows drive mount - cannot deliver kernel image"; exit 1; }
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
       modprobe rtl8xxxu && lsmod | grep rtl8xxxu

EOF
