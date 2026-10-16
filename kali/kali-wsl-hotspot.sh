#!/bin/bash
# ============================================================
# aiyuspot - hostapd AP + DHCP + NAT inside Kali WSL2
# https://github.com/teeprakorn1/aiyuspot
#
# Usage: kali-wsl-hotspot.sh [SSID] [MODE] [KEY]
#   SSID  network name                 (default: aiyuspot)
#   MODE  wep | open | wpa2            (default: wpa2)
#   KEY   WEP: 5 or 13 ASCII bytes; WPA2: 8-63 chars
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
MODE="${2:-wpa2}"
HOTPASS="${3:-}"
HOTNET="192.168.50.0/24"
HOTIP="192.168.50.1"
HOSTAPD_CONF="${HOSTAPD_CONF:-/etc/hostapd/hostapd.conf}"
DNSMASQ_CONF="${DNSMASQ_CONF:-/etc/dnsmasq.conf}"

UPLINK_IF="eth0"

[ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }

# Shared error log (see :log in wifi-control.bat) - best-effort append;
# logging must never change exit codes or trip set -e.
ALOG="${AIYUSPOT_LOG:-/var/log/aiyuspot.log}"
alog() {
  printf '%s|%s|%s|%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%F %T')" \
    "$1" "$2" "$3" >>"$ALOG" 2>/dev/null || true
}

command -v iw >/dev/null 2>&1 || {
  echo "iw is not installed - run 'wifi-control.bat provision' first"
  alog L3 hotspot "rc=1 iw missing"
  exit 1
}

# Roll back partial bring-up: a failure after hostapd/dnsmasq/NAT setup
# would otherwise leave an SSID broadcasting with no DHCP or NAT. The
# flag flips only once every step has succeeded.
AP_DONE=""
cleanup_partial() {
  [ -n "$AP_DONE" ] && return 0
  trap - EXIT
  # Every line needs || true: under set -e a single failing pkill/ip
  # (e.g. 'no process matched') would abort the rest of the cleanup.
  pkill -x hostapd-wep 2>/dev/null || true
  pkill -x hostapd 2>/dev/null || true
  pkill -x dnsmasq 2>/dev/null || true
  if [ -n "${WIFI_IF:-}" ]; then
    iptables-legacy -t nat -D POSTROUTING -o "$UPLINK_IF" -s "$HOTNET" -j MASQUERADE 2>/dev/null || true
    iptables-legacy -D FORWARD -i "$WIFI_IF" -o "$UPLINK_IF" -j ACCEPT 2>/dev/null || true
    iptables-legacy -D FORWARD -i "$UPLINK_IF" -o "$WIFI_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    ip addr del "$HOTIP/24" dev "$WIFI_IF" 2>/dev/null || true
  fi
  return 0
}
trap cleanup_partial EXIT

# --- Validate inputs before touching any interface or file ---
case "$MODE" in
  wep|open|wpa2) ;;
  *) echo "Unknown mode '$MODE' - use: wep | open | wpa2"; exit 2 ;;
esac

# Reject SSIDs that could inject config lines or break the beacon.
ssid_bytes=$(printf %s "$HOTSSID" | wc -c)
if [ "$ssid_bytes" -lt 1 ] || [ "$ssid_bytes" -gt 32 ] \
   || [[ "$HOTSSID" == *'"'* || "$HOTSSID" == *$'\n'* || "$HOTSSID" == *$'\r'* ]]; then
  echo "SSID must be 1-32 bytes and contain no quotes or control characters"
  exit 2
fi

# Key defaults per mode + length checks (byte counts, not characters).
if [ -z "$HOTPASS" ]; then
  [ "$MODE" = "wep" ]  && HOTPASS="aiyu1"
  [ "$MODE" = "wpa2" ] && HOTPASS="aiyuspot"
fi
pass_bytes=$(printf %s "$HOTPASS" | wc -c)
if [ "$MODE" = "wep" ]; then
  if [ "$pass_bytes" -ne 5 ] && [ "$pass_bytes" -ne 13 ]; then
    echo "WEP key must be exactly 5 or 13 ASCII characters"
    exit 2
  fi
elif [ "$MODE" = "wpa2" ]; then
  if [ "$pass_bytes" -lt 8 ] || [ "$pass_bytes" -gt 63 ]; then
    echo "WPA2 passphrase must be 8-63 characters"
    exit 2
  fi
fi
# Keys land in hostapd.conf verbatim - reject quotes and any
# non-printable byte. (grep can't see '\n' - it's a line separator -
# so strip printable bytes with tr and check anything remains.)
if [ -n "$HOTPASS" ] && { [[ "$HOTPASS" == *'"'* ]] \
   || [ "$(printf %s "$HOTPASS" | LC_ALL=C tr -d '[:print:]' | wc -c)" -gt 0 ]; }; then
  echo "Key must not contain quotes or control characters"
  exit 2
fi

# Registry of supported adapters - one pipe-delimited profile per line
# (see adapters.conf header for the 13-field schema).
ADAPTERS_CONF="${ADAPTERS_CONF:-$(cd "$(dirname "$0")/.." && pwd)/adapters.conf}"
SYSFS="${SYSFS:-/sys}"   # test seam: stub sysfs root

# Load the driver for whichever adapter is attached
# (backup; the launcher already modprobes before calling us).
# Registry-driven: wifi_ids hit -> modprobe pre_modules then module.
while IFS='|' read -r _ids _wifi _name _mod _prem _rest; do
  case "$_ids" in ''|\#*) continue ;; esac
  [ "$_mod" = "-" ] && continue
  _hit=""
  IFS=',' read -ra _wids <<<"$_wifi"
  for _w in "${_wids[@]}"; do lsusb | grep -qi "$_w" && { _hit=1; break; }; done
  [ -z "$_hit" ] && continue
  if [ "$_prem" != "-" ]; then modprobe $_prem 2>/dev/null || true; fi
  if modprobe "$_mod" 2>/dev/null; then
    echo "$_mod: OK"
  else
    echo "  modprobe $_mod failed - module missing from this kernel?"
    alog L3 modprobe "rc=1 $_mod"
  fi
done < "$ADAPTERS_CONF"
true

# Pick the wireless iface bound to a supported adapter driver.
# Preference order = adapters.conf file order (module column), then any
# phy80211-capable netdev (unregistered adapters), then any wl* iface.
pick_wifi_if() {
  while IFS='|' read -r _ids _w _n mod _r; do
    case "$_ids" in ''|\#*) continue ;; esac
    [ "$mod" = "-" ] && continue
    for p in $SYSFS/class/net/*/device/driver; do
      [ -e "$p" ] || continue
      if [ "$(basename "$(readlink "$p")")" = "$mod" ]; then
        basename "$(dirname "$(dirname "$p")")"
        return 0
      fi
    done
  done < "$ADAPTERS_CONF"
  for p in $SYSFS/class/net/*/phy80211; do
    [ -e "$p" ] && { basename "$(dirname "$p")"; return 0; }
  done
  ip -br link | awk '/^[wW]l/ {print $1; exit}'
}

# Force a re-probe of the AIC8800 interface (e.g. 1-1:1.0) via driver
# bind. The first probe may fail before fwserve is up or before the
# module is resident; a fresh bind retries it without dropping the
# usbipd attach.
rebind_aic() {
  for i in $SYSFS/bus/usb/devices/*:*; do
    [ -d "$i" ] || continue
    # Entries here are symlinks into /sys/devices; the device dir is the
    # interface's parent, reachable via ../ - never dirname(1).
    [ "$(cat "$i/../idVendor" 2>/dev/null)" = "3625" ] || continue
    [ "$(cat "$i/../idProduct" 2>/dev/null)" = "0110" ] || continue
    dev=$(basename "$i")
    # unbind is best-effort, never fatal: the whole point of this retry
    # is a device whose first probe FAILED - which often means it is not
    # bound at all, and writing an unbound id returns -ENODEV. Skipping
    # the bind on that error made this remediation dead code.
    echo "$dev" > "$SYSFS/bus/usb/drivers/aic8800_fdrv/unbind" 2>/dev/null || true
    sleep 1
    if echo "$dev" > "$SYSFS/bus/usb/drivers/aic8800_fdrv/bind"; then
      echo "re-probed $dev on aic8800_fdrv"
      alog L3 rebind "rc=0 re-probed $dev"
    else
      echo "re-probe FAILED for $dev" >&2
      alog L3 rebind "rc=1 re-probe failed $dev"
    fi
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
  if [ $((i % 3)) -eq 0 ]; then echo "  waiting for WiFi interface... ${i}s/15s"; fi
  sleep 1
done

echo "Using WiFi interface: ${WIFI_IF:-none}"
ip -br link
WIDS=$(awk -F'|' '!/^[[:space:]]*#/ && NF>1 {gsub(",","|",$2); printf "%s|", $2}' "$ADAPTERS_CONF")
WIDS=${WIDS%|}
# Only warn when the failure is real: an unregistered (--generic) adapter
# can't match the registry list even on the success path.
if [ -z "$WIFI_IF" ]; then
  lsusb | grep -iE "$WIDS" || echo "Registered adapter not found; check usbipd attach"
fi
iw dev 2>/dev/null || true
if [ -z "$WIFI_IF" ]; then
  echo "WiFi interface never appeared - last kernel messages:"
  dmesg | tail -n 20
  alog L3 hotspot "rc=1 no wifi iface after 15s"
  exit 1
fi
pkill -x hostapd-wep 2>/dev/null || true
pkill -x hostapd 2>/dev/null || true
ip link set "$WIFI_IF" down 2>/dev/null || true
iw dev "$WIFI_IF" set type managed 2>/dev/null || true
ip link set "$WIFI_IF" up 2>/dev/null || { echo "Failed to bring up $WIFI_IF"; exit 1; }
# Hard AP gate: scope iw to the SELECTED interface's phy - with multiple
# adapters attached, another phy's capabilities must not pass the gate.
# `iw list` indents section items by two tabs; a lone \t line ends the
# block. No AP advertisement -> fail before hostapd retries.
PHY=$(iw dev "$WIFI_IF" info 2>/dev/null | sed -n 's/.*wiphy \([0-9][0-9]*\).*/\1/p')
if [ -n "$PHY" ]; then
  IWDUMP=$(iw phy$PHY info 2>/dev/null)
else
  echo "  note: no wiphy id for $WIFI_IF - checking the global iw list instead"
  IWDUMP=$(iw list 2>/dev/null)
fi
IWMODES=$(printf '%s\n' "$IWDUMP" | awk '/Supported interface modes/{f=1;next} f&&/^\t\t/{print} f&&!/^\t\t/{f=0}')
if ! echo "$IWMODES" | grep -qw 'AP'; then
  echo "ERROR: $WIFI_IF does not advertise AP mode - cannot host." >&2
  drv=$(basename "$(readlink "$SYSFS/class/net/$WIFI_IF/device/driver" 2>/dev/null)" 2>/dev/null)
  [ -n "$drv" ] && echo "  bound driver: $drv" >&2
  echo "  Causes: driver lacks AP support, or kernel too old" >&2
  echo "  (rtl8xxxu needs >=6.6; run 'wifi-control.bat kernel' on a stale clone)." >&2
  alog L3 hotspot "rc=1 $WIFI_IF no AP mode${drv:+ ($drv)}"
  exit 1
fi
# Band-aware mode: a phy without Band 1 (2.4 GHz) cannot do hw_mode=g/ch6.
HWMODE=g
HOTCHAN=6
printf '%s\n' "$IWDUMP" | grep -q 'Band 1:' || { HWMODE=a; HOTCHAN=36; }
ip addr replace "$HOTIP/24" dev "$WIFI_IF"

if [ "$MODE" = "wpa2" ]; then
  HOSTAPD_BIN="${HOSTAPD_WPA2_BIN:-/usr/sbin/hostapd}"
  cat > "$HOSTAPD_CONF" <<EOF
interface=$WIFI_IF
driver=nl80211
ssid=$HOTSSID
hw_mode=$HWMODE
channel=$HOTCHAN
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$HOTPASS
EOF
elif [ "$MODE" = "open" ]; then
  HOSTAPD_BIN="${HOSTAPD_WEP_BIN:-/usr/local/sbin/hostapd-wep}"
  cat > "$HOSTAPD_CONF" <<EOF
interface=$WIFI_IF
driver=nl80211
ssid=$HOTSSID
hw_mode=$HWMODE
channel=$HOTCHAN
auth_algs=1
EOF
else
  HOSTAPD_BIN="${HOSTAPD_WEP_BIN:-/usr/local/sbin/hostapd-wep}"
  cat > "$HOSTAPD_CONF" <<EOF
interface=$WIFI_IF
driver=nl80211
ssid=$HOTSSID
hw_mode=$HWMODE
channel=$HOTCHAN
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
  $HOSTAPD_BIN "$HOSTAPD_CONF" -B || true
  sleep 1
  if iw dev "$WIFI_IF" info 2>/dev/null | grep -q 'type AP'; then AP_UP=1; break; fi
  pkill -x "$(basename "$HOSTAPD_BIN")" 2>/dev/null || true
  if [ "$_try" -eq 2 ] && [ "$MODE" = "wpa2" ]; then
    sed -i 's/^rsn_pairwise=CCMP/rsn_pairwise=TKIP/' "$HOSTAPD_CONF"
    echo "CCMP key install rejected; retrying with TKIP"
  fi
  sleep 2
done
if [ -z "$AP_UP" ]; then
  echo "hostapd could not enable AP mode on $WIFI_IF"
  alog L3 hotspot "rc=1 hostapd AP-up failed $WIFI_IF"
  exit 1
fi
pkill -x dnsmasq 2>/dev/null || true
# dhcp-option 6 = DNS: WSL2 host proxy resolves via Windows DNS
cat > "$DNSMASQ_CONF" <<EOF
port=0
interface=$WIFI_IF
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.200,12h
dhcp-option=6,10.255.255.254
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

# hostapd can die right after daemonizing (-B): confirm it is still
# alive before declaring success - the cleanup trap rolls back if not.
# (pgrep comes from procps; skip the check where it is absent.)
if command -v pgrep >/dev/null 2>&1; then
  pgrep -x "$(basename "$HOSTAPD_BIN")" >/dev/null 2>&1 || {
    echo "hostapd exited after daemonizing - check hostapd output"
    alog L3 hotspot "rc=1 hostapd died post-daemonize"
    exit 1
  }
fi
AP_DONE=1   # from here on, nothing may roll back

echo "WiFi started: $HOTSSID"
case "$MODE" in
  open) echo "Mode: Open AP" ;;
  wpa2) grep -q 'rsn_pairwise=TKIP' "$HOSTAPD_CONF" \
          && echo "Mode: WPA2-PSK (TKIP fallback - rt73usb rejected CCMP key)" \
          || echo "Mode: WPA2-PSK (CCMP)" ;;
  *) echo "Mode: WEP key $HOTPASS" ;;
esac
echo "Clients use 192.168.50.x"
