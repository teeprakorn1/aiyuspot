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
  # $1=ssid $2=mode $3=key ; envs: STUB_USB STUB_HOSTAPD_FAILS
  local dir; dir=$(mktemp -d)
  STUB_STATE="$dir" HOSTAPD_CONF="$dir/hostapd.conf" DNSMASQ_CONF="$dir/dnsmasq.conf" \
  HOSTAPD_WPA2_BIN="$STUBS/hostapd" HOSTAPD_WEP_BIN="$STUBS/hostapd-wep" \
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

echo "== wpa2 TKIP fallback (hostapd fails 2x then AP comes up) =="
STUB_HOSTAPD_FAILS=2
d=$(STUB_HOSTAPD_FAILS=2 run_hotspot "net" "wpa2" "mypassword")
t "fallback exits 0"         test "$(cat $d/rc)" = 0
t "conf switched to TKIP"    grep -q 'rsn_pairwise=TKIP' "$d/hostapd.conf"
t "mode line says TKIP"      grep -q 'TKIP fallback' "$d/out"

echo
echo "============================"
echo "  PASS: $PASS  FAIL: $FAIL"
echo "============================"
[ "$FAIL" -eq 0 ]
