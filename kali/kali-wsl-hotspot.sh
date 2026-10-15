#!/bin/bash
# ============================================================
# aiyuspot - hostapd AP + DHCP + NAT inside Kali WSL2
# https://github.com/teeprakorn1/aiyuspot
#
# Usage: kali-wsl-hotspot.sh [SSID] [MODE] [KEY]
#   SSID  network name                 (default: aiyuspot)
#   MODE  wep | open | wpa2            (default: wep)
#   KEY   WEP: 5 or 13 ASCII chars; WPA2: >= 8 chars
#         (default: aiyu1 for wep, aiyuspot for wpa2)
#
# Environment: runs as root inside the kali-linux WSL2 distro.
# Uplink: eth0 (WSL NAT -> Windows uplink). Clients get
# 192.168.50.0/24 addresses via dnsmasq; traffic is NAT'd with
# iptables-legacy MASQUERADE.
#
# hostapd binaries: /usr/sbin/hostapd (wpa2, stock),
# /usr/local/sbin/hostapd-wep (wep/open, built with CONFIG_WEP=y).
# ============================================================
set -e

HOTSSID="${1:-aiyuspot}"
MODE="${2:-wep}"
HOTPASS="${3:-aiyu1}"
HOTNET="192.168.50.0/24"
HOTIP="192.168.50.1"

UPLINK_IF="eth0"

[ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }

# Load the driver for whichever adapter is attached
# (backup; the launcher already modprobes before calling us).
if lsusb | grep -qi '148f:2573'; then
  modprobe rt73usb 2>/dev/null && echo "rt73usb: OK" || true
elif lsusb | grep -qi '3625:0110'; then
  modprobe aic_load_fw 2>/dev/null || true
  modprobe aic8800_fdrv 2>/dev/null && echo "aic8800_fdrv: OK" || true
fi

# Pick the wireless iface bound to a supported adapter driver.
# Preference order: aic8800_fdrv (TX1U) -> rt73usb (RT73) -> any wl* iface.
pick_wifi_if() {
  for drv in aic8800_fdrv rt73usb; do
    for p in /sys/class/net/*/device/driver; do
      [ -e "$p" ] || continue
      if [ "$(basename "$(readlink "$p")")" = "$drv" ]; then
        basename "$(dirname "$(dirname "$p")")"
        return 0
      fi
    done
  done
  ip -br link | awk '/^[wW]l/ {print $1; exit}'
}

# Force a re-probe of the AIC8800 interface (e.g. 1-1:1.0) via driver
# bind. The first probe may fail before fwserve is up or before the
# module is resident; a fresh bind retries it without dropping the
# usbipd attach.
rebind_aic() {
  for i in /sys/bus/usb/devices/*:*; do
    [ -d "$i" ] || continue
    p=$(dirname "$i")
    [ -f "$p/idVendor" ] || continue
    [ "$(cat "$p/idVendor" 2>/dev/null)" = "3625" ] || continue
    dev=$(basename "$i")
    echo "$dev" > /sys/bus/usb/drivers/aic8800_fdrv/unbind 2>/dev/null || true
    sleep 1
    echo "$dev" > /sys/bus/usb/drivers/aic8800_fdrv/bind 2>/dev/null || true
    echo "re-probed $dev on aic8800_fdrv"
  done
  return 0
}

# FullMAC drivers (aic8800) need several seconds to load firmware
# before the netdev appears - poll for up to 15s, re-probing once.
WIFI_IF=""
for i in $(seq 1 15); do
  WIFI_IF=$(pick_wifi_if)
  [ -n "$WIFI_IF" ] && break
  if [ "$i" -eq 5 ] && lsusb | grep -qi '3625:0110'; then
    echo "No iface yet - retrying aic8800_fdrv probe..."
    rebind_aic
  fi
  sleep 1
done

echo "Using WiFi interface: ${WIFI_IF:-none}"
ip -br link
lsusb | grep -iE '148f:2573|3625:0110|ralink|aicsemi' || echo "Supported adapter not found; check usbipd attach"
iw dev 2>/dev/null || true
if [ -z "$WIFI_IF" ]; then
  echo "WiFi interface never appeared - last kernel messages:"
  dmesg | tail -n 20
  exit 1
fi
pkill -x hostapd-wep 2>/dev/null || true
pkill -x hostapd 2>/dev/null || true
ip link set "$WIFI_IF" down 2>/dev/null || true
iw dev "$WIFI_IF" set type managed 2>/dev/null || true
ip link set "$WIFI_IF" up 2>/dev/null || { echo "WiFi interface not found"; exit 1; }
if ! iw list 2>/dev/null | awk '/Supported interface modes/{f=1} f&&/^}/{f=0} f' | grep -qw 'AP'; then
  echo "WARNING: $WIFI_IF does not advertise AP mode - hostapd may fail."
  echo "         (TX1U/aic8800 AP support is experimental; RT73 is verified.)"
fi
ip addr replace "$HOTIP/24" dev "$WIFI_IF"

if [ "$MODE" = "wpa2" ]; then
  if [ "${#HOTPASS}" -lt 8 ]; then
    echo "WPA2 passphrase must be at least 8 characters"
    exit 1
  fi
  HOSTAPD_BIN="/usr/sbin/hostapd"
  cat > /etc/hostapd/hostapd.conf <<EOF
interface=$WIFI_IF
driver=nl80211
ssid=$HOTSSID
hw_mode=g
channel=6
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$HOTPASS
EOF
elif [ "$MODE" = "open" ]; then
  HOSTAPD_BIN="/usr/local/sbin/hostapd-wep"
  cat > /etc/hostapd/hostapd.conf <<EOF
interface=$WIFI_IF
driver=nl80211
ssid=$HOTSSID
hw_mode=g
channel=6
auth_algs=1
EOF
else
  if [ "${#HOTPASS}" -ne 5 ] && [ "${#HOTPASS}" -ne 13 ]; then
    echo "WEP key must be exactly 5 or 13 ASCII characters"
    exit 1
  fi
  HOSTAPD_BIN="/usr/local/sbin/hostapd-wep"
  cat > /etc/hostapd/hostapd.conf <<EOF
interface=$WIFI_IF
driver=nl80211
ssid=$HOTSSID
hw_mode=g
channel=6
auth_algs=1
wep_default_key=0
wep_key0="$HOTPASS"
EOF
fi

# rt73usb's hardware crypto intermittently rejects CCMP key install
# (nl80211: key addition failed). Retry; after 2 failed tries fall
# back to TKIP which the rt73 key table accepts reliably.
AP_UP=""
for _try in 1 2 3 4; do
  $HOSTAPD_BIN /etc/hostapd/hostapd.conf -B || true
  sleep 1
  if iw dev "$WIFI_IF" info 2>/dev/null | grep -q 'type AP'; then AP_UP=1; break; fi
  pkill -x "$(basename "$HOSTAPD_BIN")" 2>/dev/null || true
  if [ "$_try" -eq 2 ] && [ "$MODE" = "wpa2" ]; then
    sed -i 's/^rsn_pairwise=CCMP/rsn_pairwise=TKIP/' /etc/hostapd/hostapd.conf
    echo "CCMP key install rejected; retrying with TKIP"
  fi
  sleep 2
done
if [ -z "$AP_UP" ]; then
  echo "hostapd could not enable AP mode on $WIFI_IF"
  exit 1
fi
pkill dnsmasq 2>/dev/null || true
cat > /etc/dnsmasq.conf <<EOF
port=0
interface=$WIFI_IF
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.200,12h
dhcp-option=6,10.255.255.254  # WSL2 host DNS proxy - resolves via Windows DNS
EOF
dnsmasq

sysctl -w net.ipv4.ip_forward=1
for module in ip_tables iptable_filter iptable_nat nf_conntrack xt_conntrack xt_MASQUERADE; do
  modprobe "$module" 2>/dev/null || true
done
IPT=iptables-legacy
$IPT -t nat -C POSTROUTING -o "$UPLINK_IF" -s "$HOTNET" -j MASQUERADE 2>/dev/null || $IPT -t nat -A POSTROUTING -o "$UPLINK_IF" -s "$HOTNET" -j MASQUERADE
$IPT -C FORWARD -i "$WIFI_IF" -o "$UPLINK_IF" -j ACCEPT 2>/dev/null || $IPT -A FORWARD -i "$WIFI_IF" -o "$UPLINK_IF" -j ACCEPT
$IPT -C FORWARD -i "$UPLINK_IF" -o "$WIFI_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || $IPT -A FORWARD -i "$UPLINK_IF" -o "$WIFI_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "WiFi started: $HOTSSID"
case "$MODE" in
  open) echo "Mode: Open AP" ;;
  wpa2) grep -q 'rsn_pairwise=TKIP' /etc/hostapd/hostapd.conf \
          && echo "Mode: WPA2-PSK (TKIP fallback - rt73usb rejected CCMP key)" \
          || echo "Mode: WPA2-PSK (CCMP)" ;;
  *) echo "Mode: WEP key $HOTPASS" ;;
esac
echo "Clients use 192.168.50.x"
