#!/bin/bash
# aiyuspot hotspot tests - stub-PATH harness (no hardware, no root needed
# when run under `wsl -u root` or any Linux shell; EUID check requires root).
# Run from repo root inside WSL:  sudo bash test/linux/hotspot.tests.sh
set -u
cd "$(dirname "$0")/../.."
STUBS="$PWD/test/linux/stubs/bin"
SCRIPT="$PWD/kali/kali-wsl-hotspot.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

run_hotspot() {
  # $1=ssid $2=mode $3=key ; envs: STUB_USB STUB_HOSTAPD_FAILS SYSFS ...
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/fakesys"   # default: empty sysfs root - never scan real /sys
  STUB_STATE="$dir" HOSTAPD_CONF="$dir/hostapd.conf" DNSMASQ_CONF="$dir/dnsmasq.conf" \
  HOSTAPD_WPA2_BIN="$STUBS/hostapd" HOSTAPD_WEP_BIN="$STUBS/hostapd-wep" \
  SYSFS="${SYSFS:-$dir/fakesys}" \
  PATH="$STUBS:$PATH" bash "$SCRIPT" "$1" "$2" "$3" >"$dir/out" 2>&1
  local rc=$?
  LAST_DIR="$dir"
  echo "$dir"   # caller reads conf/out from dir; rc via $? cannot survive - print it
  echo "$rc" > "$dir/rc"
}

# Note: run_hotspot's rc is stored in <dir>/rc.

t() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else
    fail "$name"
    if [ -n "${LAST_DIR:-}" ] && [ -s "$LAST_DIR/out" ]; then
      sed 's/^/        | /' "$LAST_DIR/out" | tail -5
    fi
  fi
}

echo "== validation (fail fast, no conf written) =="
d=$(run_hotspot "net" "bogus" "");            t "unknown mode exits 2"        test "$(cat $d/rc)" = 2
d=$(run_hotspot "net" "wep" "abc");           t "wep 3-char rejected"         test "$(cat $d/rc)" = 2
d=$(run_hotspot "net" "wep" "abcdefghij");    t "wep 10-char rejected"        test "$(cat $d/rc)" = 2
d=$(run_hotspot "net" "wpa2" "short");        t "wpa2 <8 rejected"            test "$(cat $d/rc)" = 2
d=$(run_hotspot "net" "wpa2" "$(printf 'a%.0s' $(seq 64))"); t "wpa2 >63 rejected" test "$(cat $d/rc)" = 2
d=$(run_hotspot 'bad"ssid' "open" "");        t "SSID with quote rejected"    test "$(cat $d/rc)" = 2
d=$(run_hotspot "net" "wpa2" "$(printf 'bad\npasssss')"); t "wpa2 newline key rejected" test "$(cat $d/rc)" = 2
d=$(run_hotspot "net" "wpa2" 'bad"pass99');   t "wpa2 quote key rejected"     test "$(cat $d/rc)" = 2
d=$(run_hotspot "net" "wep" "$(printf 'ab\n45')");        t "wep newline key rejected"  test "$(cat $d/rc)" = 2

echo "== open mode =="
d=$(run_hotspot "cafe" "open" "")
t "open exits 0"             test "$(cat $d/rc)" = 0
t "conf has ssid"            grep -q '^ssid=cafe$' "$d/hostapd.conf"
t "conf open auth"           grep -q '^auth_algs=1$' "$d/hostapd.conf"
t "conf no wpa"              bash -c "! grep -q wpa_passphrase '$d/hostapd.conf'"
t "dnsmasq range"            grep -q 'dhcp-range=192.168.50.10' "$d/dnsmasq.conf"
t "started line"             grep -q 'WiFi started: cafe' "$d/out"
t "nat rule appended"        grep -q 'MASQUERADE' "$d/iptables.log"

echo "== wep mode =="
d=$(run_hotspot "net" "wep" "abcde")
t "wep exits 0"              test "$(cat $d/rc)" = 0
t "wep key in conf"          grep -q 'wep_key0="abcde"' "$d/hostapd.conf"

echo "== wpa2 mode =="
d=$(run_hotspot "net" "wpa2" "mypassword")
t "wpa2 exits 0"             test "$(cat $d/rc)" = 0
t "ccmp first"               grep -q 'rsn_pairwise=CCMP' "$d/hostapd.conf"
t "passphrase in conf"       grep -q 'wpa_passphrase=mypassword' "$d/hostapd.conf"
t "mode line says CCMP"      grep -q 'WPA2-PSK (CCMP)' "$d/out"

echo "== edimax detection (STUB_USB=edimax) =="
d=$(STUB_USB=edimax run_hotspot "net" "open" "")
t "edimax open exits 0"       test "$(cat $d/rc)" = 0
t "rtl8xxxu modprobed"        grep -q 'rtl8xxxu: OK' "$d/out"

echo "== wpa2 TKIP fallback (hostapd fails 2x then AP comes up) =="
d=$(STUB_HOSTAPD_FAILS=2 run_hotspot "net" "wpa2" "mypassword")
t "fallback exits 0"         test "$(cat $d/rc)" = 0
t "conf switched to TKIP"    grep -q 'rsn_pairwise=TKIP' "$d/hostapd.conf"
t "mode line says TKIP"      grep -q 'TKIP fallback' "$d/out"
unset STUB_HOSTAPD_FAILS   # never leak the knob into later tests

echo "== hard AP gate (STUB_NO_AP=1 - driver without AP support) =="
d=$(STUB_NO_AP=1 run_hotspot "net" "open" "")
t "no-AP exits 1"                test "$(cat $d/rc)" = 1
t "AP-gate error printed"        grep -q 'does not advertise AP mode' "$d/out"
t "no conf written"              test ! -f "$d/hostapd.conf"

echo "== phy80211 pick (SYSFS seam - unregistered adapter iface) =="
FS=$(mktemp -d); mkdir -p "$FS/class/net/wlxfake/phy80211"
d=$(SYSFS="$FS" run_hotspot "net" "open" "")
t "exits 0 via phy80211 pick"    test "$(cat $d/rc)" = 0
t "phy80211 iface in conf"       grep -q 'interface=wlxfake' "$d/hostapd.conf"

echo "== band-aware hostapd (STUB_NO_BAND1 selects 5 GHz) =="
d=$(STUB_NO_BAND1=1 run_hotspot "net" "open" "")
t "5GHz channel in conf"         grep -q 'channel=36' "$d/hostapd.conf"
t "hw_mode=a in conf"            grep -q 'hw_mode=a' "$d/hostapd.conf"

echo "== phy-scoped AP gate (STUB_PHY_NO_AP: list has AP, phy0 does not) =="
d=$(STUB_PHY_NO_AP=1 run_hotspot "net" "open" "")
t "phy no-AP exits 1"            test "$(cat $d/rc)" = 1
t "phy AP-gate error printed"    grep -q 'does not advertise AP mode' "$d/out"

echo "== driver-name preference (registry module beats phy80211) =="
FS=$(mktemp -d)
mkdir -p "$FS/class/net/wlxother/phy80211" "$FS/class/net/wlxrt/device" "$FS/drivers/rt73usb"
ln -s "$FS/drivers/rt73usb" "$FS/class/net/wlxrt/device/driver"
d=$(SYSFS="$FS" run_hotspot "net" "open" "")
t "registry driver iface picked"  grep -q 'interface=wlxrt' "$d/hostapd.conf"

echo "== rebind_aic sysfs logic (unit: symlinked usb layout) =="
FS=$(mktemp -d)
mkdir -p "$FS/devices/1-9/1-9:1.0" "$FS/bus/usb/devices" "$FS/bus/usb/drivers/aic8800_fdrv"
echo 3625 > "$FS/devices/1-9/idVendor"; echo 0110 > "$FS/devices/1-9/idProduct"
ln -s "$FS/devices/1-9/1-9:1.0" "$FS/bus/usb/devices/1-9:1.0"
sed -n '/^rebind_aic()/,/^}/p' "$SCRIPT" > "$FS/rb.sh"
SYSFS="$FS" PATH="$STUBS:$PATH" bash -c '. "$0"; rebind_aic' "$FS/rb.sh" > "$FS/rb.out" 2>&1
t "rebind wrote unbind+bind"      bash -c "grep -q '1-9:1.0' '$FS/bus/usb/drivers/aic8800_fdrv/unbind' && grep -q '1-9:1.0' '$FS/bus/usb/drivers/aic8800_fdrv/bind'"
t "rebind reported probe"         grep -q 're-probed' "$FS/rb.out"

echo "== rebind_aic: unbind write failing must NOT skip the bind =="
# The retry exists precisely for already-unbound devices - writing an
# unbound id returns -ENODEV. A directory where 'unbind' should be makes
# every write fail even as root, exercising that exact failure.
FS=$(mktemp -d)
mkdir -p "$FS/devices/1-9/1-9:1.0" "$FS/bus/usb/devices" "$FS/bus/usb/drivers/aic8800_fdrv/unbind"
echo 3625 > "$FS/devices/1-9/idVendor"; echo 0110 > "$FS/devices/1-9/idProduct"
ln -s "$FS/devices/1-9/1-9:1.0" "$FS/bus/usb/devices/1-9:1.0"
sed -n '/^rebind_aic()/,/^}/p' "$SCRIPT" > "$FS/rb.sh"
SYSFS="$FS" PATH="$STUBS:$PATH" bash -c '. "$0"; rebind_aic' "$FS/rb.sh" > "$FS/rb.out" 2>&1
t "bind still attempted"          grep -q '1-9:1.0' "$FS/bus/usb/drivers/aic8800_fdrv/bind"

echo "== cleanup trap: dnsmasq failure rolls back partial bring-up =="
d=$(STUB_DNSMASQ_RC=1 run_hotspot "net" "open" "")
t "dnsmasq fail exits 1"           test "$(cat $d/rc)" = 1
t "hostapd had run"                test -s "$d/ap_tries"
t "cleanup issued rule deletes"    grep -q 'D POSTROUTING' "$d/iptables.log"

echo "== cleanup trap: hostapd dies after daemonizing =="
d=$(STUB_PGREP_RC=1 run_hotspot "net" "open" "")
t "post-daemonize death exits 1"   test "$(cat $d/rc)" = 1
t "death message printed"          grep -q 'exited after daemonizing' "$d/out"
t "nat rule added then removed"    bash -c "grep -q 'A POSTROUTING' '$d/iptables.log' && grep -q 'D POSTROUTING' '$d/iptables.log'"

echo
echo "============================"
echo "  PASS: $PASS  FAIL: $FAIL"
echo "============================"
[ "$FAIL" -eq 0 ]
