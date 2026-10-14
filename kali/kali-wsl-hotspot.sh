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
WIFI_IF=$(ip -br link | awk '/^[wW]l/ {print $1; exit}')
[ -z "$WIFI_IF" ] && WIFI_IF="wlan0"
UPLINK_IF="eth0"

[ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }

echo "Using WiFi interface: $WIFI_IF"
ip -br link
lsusb | grep -iE '148f:2573|3625:0110|ralink|aicsemi' || echo "Supported adapter not found; check usbipd attach"
iw dev 2>/dev/null || true

case "$WIFI_IF" in
  *0019e0*|wlan*) modprobe rt73usb 2>/dev/null && echo "rt73usb: OK" || true ;;
esac
pkill -x hostapd-wep 2>/dev/null || true
pkill -x hostapd 2>/dev/null || true
ip link set "$WIFI_IF" down 2>/dev/null || true
iw dev "$WIFI_IF" set type managed 2>/dev/null || true
ip link set "$WIFI_IF" up 2>/dev/null || { echo "WiFi interface not found"; exit 1; }
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

$HOSTAPD_BIN /etc/hostapd/hostapd.conf -B
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
  wpa2) echo "Mode: WPA2-PSK (CCMP)" ;;
  *) echo "Mode: WEP key $HOTPASS" ;;
esac
echo "Clients use 192.168.50.x"
