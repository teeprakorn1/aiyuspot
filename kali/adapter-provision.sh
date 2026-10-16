#!/bin/bash
# ============================================================
# aiyuspot - adapter provisioner: install whatever the adapter's
# registry spec needs (packages, firmware, kernel, out-of-tree
# driver) before the launcher attaches anything.
# https://github.com/teeprakorn1/aiyuspot
#
# Usage:
#   adapter-provision.sh <hwid> [mode]        registered profile, pre-attach
#   adapter-provision.sh --generic <vid:pid>  unknown device, post-attach:
#                                           modalias-probe + phy80211 poll
#
# Exit codes: 0 ready | 1 failed | 2 declined | 3 kernel-switch needed
# AIYUSPOT_YES=1 accepts every confirmation (unattended/tests).
# ============================================================
set -u

[ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONF="${ADAPTERS_CONF:-$REPO/adapters.conf}"
KSRC="${KSRC:-/usr/src/wsl2-kernel}"
KIMG="${KIMG:-/mnt/c/wsl/wsl-kernel-bzImage}"
SYSFS="${SYSFS:-/sys}"                     # test seam: stub sysfs root
FWDIR="${FWDIR:-/lib/firmware}"            # test seam: stub firmware root
MODDIR="${MODDIR:-/lib/modules}"           # test seam: stub modules root
FWSERVE_BIN="${FWSERVE_BIN:-/usr/local/bin/fwserve}"
HOSTAPD_WEP_BIN="${HOSTAPD_WEP_BIN:-/usr/local/sbin/hostapd-wep}"
INSTALL_KERNEL="${INSTALL_KERNEL:-$REPO/kali/driver/install-rt73.sh}"

# Error log shared with the launcher (see :log in wifi-control.bat) -
# best-effort append; logging must never change the exit contract.
ALOG="${AIYUSPOT_LOG:-/var/log/aiyuspot.log}"
alog() {
  printf '%s|%s|%s|%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%F %T')" \
    "$1" "$2" "$3" >>"$ALOG" 2>/dev/null || true
}

confirm() {
  [ "${AIYUSPOT_YES:-0}" = "1" ] && return 0
  printf '%s [Y/n] ' "$1"
  local a=""
  read -r a || return 1
  case "$a" in n|N) return 1 ;; *) return 0 ;; esac
}

# ---------- generic (unregistered device) path: post-attach ----------
if [ "${1:-}" = "--generic" ]; then
  VID="${2:?usage: $0 --generic <vid:pid>}"
  echo "$VID" | grep -qiE '^[0-9a-f]{4}:[0-9a-f]{4}$' || { echo "bad hwid: $VID"; exit 1; }
  VID="${VID,,}"   # sysfs idVendor/idProduct are always lowercase
  echo "== generic probe for $VID =="
  # Minimal tool floor: the registered path installs these in Phase A,
  # but --generic skips it - a minimal Kali image can lack kmod/iproute2.
  gmiss=""
  for t in modprobe modinfo ip lsusb; do
    command -v "$t" >/dev/null 2>&1 || gmiss="$gmiss $t"
  done
  if [ -n "$gmiss" ]; then
    echo "Installing probe tools:$gmiss"
    apt-get update -qq || echo "WARNING: apt-get update failed - trying install anyway"
    apt-get install -y kmod iproute2 usbutils \
      || { echo "tool install failed - check eth0 connectivity"; alog L2 generic "rc=1 tool install failed"; exit 1; }
  fi
  # Snapshot existing wireless ifaces: only an iface that appears AFTER
  # our probe proves this device was bound - a pre-existing adapter's
  # phy80211 must not yield a false success.
  pre=""
  for d in $SYSFS/class/net/*/phy80211; do
    [ -e "$d" ] && pre="$pre $(basename "$(dirname "$d")")"
  done
  # Emulate udev's `kmod load $MODALIAS`, scoped to this device only.
  for i in $SYSFS/bus/usb/devices/*:*; do
    [ -f "$i/modalias" ] || continue
    # idVendor/idProduct live on the parent USB device dir - resolve through
    # the symlink ($i/.. lands on the real device dir, dirname does not).
    [ "$(cat "$i/../idVendor" 2>/dev/null):$(cat "$i/../idProduct" 2>/dev/null)" = "$VID" ] || continue
    if [ -L "$i/driver" ]; then
      echo "  $(basename "$i") already bound to $(basename "$(readlink "$i/driver")")"
      continue
    fi
    if modprobe "$(cat "$i/modalias")" 2>/dev/null; then
      echo "  $(basename "$i") bound via modalias"
    else
      echo "  modprobe $(cat "$i/modalias" | cut -c1-30) failed for $(basename "$i")"
      alog L3 modprobe "rc=1 modalias probe failed for $(basename "$i") $VID"
    fi
  done
  # A driver (built-in or just modprobed) takes a moment to raise a netdev.
  for _ in $(seq 1 20); do
    for d in $SYSFS/class/net/*/phy80211; do
      [ -e "$d" ] || continue
      n=$(basename "$(dirname "$d")")
      case " $pre " in *" $n "*) continue ;; esac
      echo "Wi-Fi interface up: $n"; exit 0
    done
    sleep 1
  done
  echo "No Wi-Fi interface appeared for $VID - diagnostics:"
  lsusb | grep -i "${VID%%:*}" || true
  pend=$(ls $SYSFS/class/firmware 2>/dev/null | tr '!' '/')
  [ -n "$pend" ] && echo "  pending firmware requests: $pend"
  [ -n "$pend" ] && echo "  -> apt-file search <name> to find the firmware package, install it, re-run"
  dmesg | grep -iE 'firmware|usb.*fail' | tail -n 10 || true
  echo "  If no driver bound at all: this chip lacks an in-tree driver on this"
  echo "  kernel. Identify it (linux-hardware.org / wikidevi for $VID), then add"
  echo "  a profile line to adapters.conf with its kconfig symbols and rebuild"
  echo "  via 'wifi-control.bat kernel'. See docs/adapters.md."
  alog L2 generic "rc=1 no iface for $VID"
  exit 1
fi

HWID="${1:?usage: $0 <hwid> [mode] | $0 --generic <vid:pid>}"
MODE="${2:-wpa2}"

# ---------- registry lookup (id must appear in column-1 list) ----------
line=$(grep -v '^[[:space:]]*#' "$CONF" | awk -F'|' -v id="$HWID" '
  { n=split($1,a,","); for (k=1;k<=n;k++) if (a[k]==id) {print; exit} }')
[ -z "$line" ] && { echo "no registry entry for $HWID"; alog L2 registry "rc=1 no profile $HWID"; exit 1; }
IFS='|' read -r _ _ name mod _ fwst fwpkg _ _ _ inst status _ <<<"$line"
echo "== provision: $name [$HWID] status=$status =="

# ---------- Phase A: packages/helpers (auto, idempotent) ----------
want=""
for t in hostapd dnsmasq iw iptables iptables-legacy lsusb usb_modeswitch gcc make tar modprobe modinfo rmmod ip sysctl pkill; do
  case "$t" in
    usb_modeswitch)        pkg=usb-modeswitch ;;
    gcc|make)              pkg=build-essential ;;
    lsusb)                 pkg=usbutils ;;
    iptables-legacy)       pkg=iptables ;;
    modprobe|modinfo|rmmod) pkg=kmod ;;
    ip)                    pkg=iproute2 ;;
    sysctl|pkill)          pkg=procps ;;
    *)                     pkg=$t ;;
  esac
  command -v "$t" >/dev/null 2>&1 || want="$want $pkg"
done
if [ "$MODE" != "wpa2" ] && [ ! -x "$HOSTAPD_WEP_BIN" ]; then
  echo "note: hostapd-wep missing - WEP/Open need it (SETUP.md), WPA2 unaffected"
fi
# firmware blobs present in the distro fs?
fwmiss=""
if [ "$fwst" != "-" ]; then
  IFS=',' read -ra FWS <<<"$fwst"
  for f in "${FWS[@]}"; do
    f="${f%/.}"
    [ -e "$FWDIR/$f" ] || fwmiss="$fwmiss $f"
  done
fi
[ -n "$fwmiss" ] && [ "$fwpkg" != "-" ] && want="$want $fwpkg"
if [ -n "$want" ]; then
  echo "Installing packages:$want"
  apt-get update -qq || echo "WARNING: apt-get update failed - trying install anyway"
  apt-get install -y $want \
    || { echo "apt-get install failed - check eth0 connectivity"; alog L2 apt "rc=1 install:$want"; exit 1; }
fi
# Rebuild when the source is newer: a stale fwserve silently misses the
# '!'-decode for subdirectory firmware (e.g. rtlwifi/x.bin) and requests
# then sit out the full kernel timeout before failing the probe.
if [ ! -x "$FWSERVE_BIN" ] || [ "$REPO/fwserve/fwserve.c" -nt "$FWSERVE_BIN" ]; then
  echo "Building fwserve..."
  gcc -O2 -o "$FWSERVE_BIN" "$REPO/fwserve/fwserve.c" \
    && chmod 755 "$FWSERVE_BIN" \
    || echo "WARNING: fwserve build failed - sysfs fallback unavailable"
fi
if [ -n "$fwmiss" ]; then
  for f in "${FWS[@]}"; do
    f="${f%/.}"
    if [ ! -e "$FWDIR/$f" ]; then
      if [ "$fwpkg" != "-" ]; then
        # Registry-required firmware that apt cannot deliver means the
        # probe WILL fail - this is a provision failure, not a warning.
        echo "ERROR: required firmware $f still missing after apt" >&2
        alog L2 firmware "rc=1 $f missing ($fwpkg)"
        exit 1
      else
        echo "WARNING: $f still missing - supplied by the driver installer"
      fi
    fi
  done
fi

# ---------- Phase B: module readiness ----------
[ "$mod" = "-" ] && exit 0
modinfo "$mod" >/dev/null 2>&1 && exit 0

if [ "$inst" != "-" ]; then
  # Out-of-tree driver: needs the running kernel's build tree.
  if [ ! -d "$MODDIR/$(uname -r)/build" ]; then
    if [ -f "$KIMG" ] && [ -d "$KSRC/.git" ]; then
      echo "Custom kernel already built but not running (uname -r=$(uname -r))."
      exit 3
    fi
    confirm "Kernel build tree missing for $(uname -r) - build custom kernel (~20-40 min)?" || exit 2
    bash "$INSTALL_KERNEL" || { echo "kernel build failed"; alog L2 kernel "rc=1 build failed"; exit 1; }
    [ -d "$MODDIR/$(uname -r)/build" ] || exit 3
  fi
  confirm "Build out-of-tree driver for $name (~2-5 min)?" || exit 2
  bash "$REPO/$inst" || { echo "driver build failed"; alog L2 driver "rc=1 $inst failed"; exit 1; }
  modinfo "$mod" >/dev/null 2>&1 || { echo "$mod still not resolvable after install"; alog L3 modprobe "rc=1 $mod unresolved"; exit 1; }
  exit 0
fi

# In-tree driver absent from the running kernel -> custom kernel required.
if [ -f "$KIMG" ] && [ -d "$KSRC/.git" ]; then
  echo "Custom kernel already built - it just isn't running yet."
  exit 3
fi
confirm "Module $mod not in the stock kernel - build custom WSL2 kernel (~20-40 min)?" || exit 2
bash "$INSTALL_KERNEL" || { echo "kernel build failed"; alog L2 kernel "rc=1 build failed"; exit 1; }
exit 3   # the image carries the module; usable only after it boots
