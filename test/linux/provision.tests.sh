#!/bin/bash
# adapter-provision.sh contract tests. Everything external is stubbed:
# apt-get/modinfo/uname/modprobe/install-kernel via PATH stubs, sysfs /
# firmware / kernel paths via SYSFS/FWDIR/KIMG/KSRC env seams.
# Usage: bash test/linux/provision.tests.sh   (run as root inside WSL)
set -u
cd "$(dirname "$0")/../.."
STUBS="$PWD/test/linux/stubs/bin"
SCRIPT="$PWD/kali/adapter-provision.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
t() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }

# runp <provision args>: fresh stub dir in $RD, rc in $RD/rc
RD=
runp() {
  RD=$(mktemp -d)
  mkdir -p "$RD/sysfs/bus/usb/devices" "$RD/sysfs/class/net" "$RD/fw"
  PATH="$STUBS:$PATH" STUB_STATE="$RD" SYSFS="$RD/sysfs" FWDIR="$RD/fw" \
    FWSERVE_BIN="$RD/fwserve-x" HOSTAPD_WEP_BIN="$RD/hostapd-wep-x" \
    KSRC="$RD/ksrc" KIMG="$RD/kimg" INSTALL_KERNEL="$STUBS/install-kernel" \
    bash "$SCRIPT" "$@" >"$RD/out" 2>&1
  echo $? >"$RD/rc"
}

echo "== registered profile, module already present =="
# STUB_APT_DELIVERS makes the apt stub actually drop rt73.bin into FWDIR,
# as the real firmware-misc-nonfree package would.
AIYUSPOT_YES=1 STUB_APT_DELIVERS=rt73.bin runp 148f:2573 wpa2
t "rt73 provision exits 0"        test "$(cat "$RD/rc")" = 0
t "says provisioning"             grep -q 'provision:.*RT73' "$RD/out"
t "apt installed firmware pkg"    test -f "$RD/apt-installed-firmware-misc-nonfree"

echo "== required firmware undelivered -> hard fail (was warn-only) =="
AIYUSPOT_YES=1 runp 148f:2573 wpa2
t "missing fw exits 1"            test "$(cat "$RD/rc")" = 1
t "names the missing blob"        grep -q 'required firmware rt73.bin' "$RD/out"

echo "== module missing -> kernel build -> exit 3 =="
AIYUSPOT_YES=1 STUB_MOD_MISSING=rt73usb STUB_APT_DELIVERS=rt73.bin runp 148f:2573 wpa2
t "exits 3 (switch needed)"       test "$(cat "$RD/rc")" = 3
t "kernel builder invoked"        test -f "$RD/kernel-build.log"

echo "== module missing + image+tree present -> exit 3, no rebuild =="
PRED=$(mktemp -d); mkdir -p "$PRED/sysfs/bus/usb/devices" "$PRED/sysfs/class/net" "$PRED/fw" "$PRED/ksrc/.git"; touch "$PRED/kimg"
PATH="$STUBS:$PATH" STUB_STATE="$PRED" SYSFS="$PRED/sysfs" FWDIR="$PRED/fw" \
  FWSERVE_BIN="$PRED/x" KSRC="$PRED/ksrc" KIMG="$PRED/kimg" \
  INSTALL_KERNEL="$STUBS/install-kernel" AIYUSPOT_YES=1 STUB_MOD_MISSING=rt73usb STUB_APT_DELIVERS=rt73.bin \
  bash "$SCRIPT" 148f:2573 wpa2 >"$PRED/out" 2>&1; echo $? >"$PRED/rc"
t "exits 3"                       test "$(cat "$PRED/rc")" = 3
t "no rebuild happened"           test ! -f "$PRED/kernel-build.log"
t "says already built"            grep -q 'already built' "$PRED/out"

echo "== declined kernel build -> exit 2 =="
STUB_MOD_MISSING=rt73usb STUB_APT_DELIVERS=rt73.bin runp 148f:2573 wpa2 </dev/null
t "exits 2"                       test "$(cat "$RD/rc")" = 2
t "builder not invoked"           test ! -f "$RD/kernel-build.log"

echo "== generic path (modalias probe binds a phy) =="
GD=$(mktemp -d)
# mimic real sysfs nesting: interface dir lives inside the device dir,
# with a bus-view symlink pointing at it
mkdir -p "$GD/sysfs/bus/usb/devices/1-9/1-9:1.0" "$GD/sysfs/class/net" "$GD/fw"
echo "usb:vFFFFpAAAAd0000dc00dsc00dp00icffiscffip00in00" > "$GD/sysfs/bus/usb/devices/1-9/1-9:1.0/modalias"
echo ffff > "$GD/sysfs/bus/usb/devices/1-9/idVendor"
echo aaaa > "$GD/sysfs/bus/usb/devices/1-9/idProduct"
ln -s "1-9/1-9:1.0" "$GD/sysfs/bus/usb/devices/1-9:1.0"
PATH="$STUBS:$PATH" STUB_STATE="$GD" SYSFS="$GD/sysfs" FWDIR="$GD/fw" \
  bash "$SCRIPT" --generic ffff:aaaa >"$GD/out" 2>&1; echo $? >"$GD/rc"
t "generic probe exits 0"         test "$(cat "$GD/rc")" = 0
t "modalias passed to modprobe"   grep -q 'usb:vFFFF' "$GD/modprobe.log"
t "reports interface"             grep -q 'Wi-Fi interface up: wlxfake' "$GD/out"

echo "== generic path, nothing binds -> diagnostics =="
GD=$(mktemp -d); mkdir -p "$GD/sysfs/bus/usb/devices" "$GD/sysfs/class/net" "$GD/fw"
PATH="$STUBS:$PATH" STUB_STATE="$GD" SYSFS="$GD/sysfs" FWDIR="$GD/fw" \
  bash "$SCRIPT" --generic ffff:aaaa >"$GD/out" 2>&1; echo $? >"$GD/rc"
t "exits 1"                       test "$(cat "$GD/rc")" = 1
t "prints guidance"               grep -q 'adapters.conf' "$GD/out"

echo "== generic: pre-existing iface must NOT count as success =="
# A phy80211 netdev that was already up before probing proves nothing
# about the attached device - delta check must reject it.
GD=$(mktemp -d)
mkdir -p "$GD/sysfs/bus/usb/devices/1-9/1-9:1.0" "$GD/sysfs/class/net/wlxold/phy80211" "$GD/fw"
echo "usb:vFFFFpAAAAd0000dc00dsc00dp00icffiscffip00in00" > "$GD/sysfs/bus/usb/devices/1-9/1-9:1.0/modalias"
echo ffff > "$GD/sysfs/bus/usb/devices/1-9/idVendor"; echo aaaa > "$GD/sysfs/bus/usb/devices/1-9/idProduct"
ln -s "1-9/1-9:1.0" "$GD/sysfs/bus/usb/devices/1-9:1.0"
# STUB_MODPROBE_RC=1 -> the probe binds nothing new; only the stale
# wlxold exists and it must not satisfy the poll.
PATH="$STUBS:$PATH" STUB_STATE="$GD" SYSFS="$GD/sysfs" FWDIR="$GD/fw" STUB_MODPROBE_RC=1 \
  bash "$SCRIPT" --generic ffff:aaaa >"$GD/out" 2>&1; echo $? >"$GD/rc"
t "pre-existing iface exits 1"    test "$(cat "$GD/rc")" = 1

echo "== generic: modprobe failure is diagnosed, not silent =="
GD=$(mktemp -d)
mkdir -p "$GD/sysfs/bus/usb/devices/1-9/1-9:1.0" "$GD/sysfs/class/net" "$GD/fw"
echo "usb:vFFFFpAAAAd0000dc00dsc00dp00icffiscffip00in00" > "$GD/sysfs/bus/usb/devices/1-9/1-9:1.0/modalias"
echo ffff > "$GD/sysfs/bus/usb/devices/1-9/idVendor"; echo aaaa > "$GD/sysfs/bus/usb/devices/1-9/idProduct"
ln -s "1-9/1-9:1.0" "$GD/sysfs/bus/usb/devices/1-9:1.0"
PATH="$STUBS:$PATH" STUB_STATE="$GD" SYSFS="$GD/sysfs" FWDIR="$GD/fw" STUB_MODPROBE_RC=1 \
  bash "$SCRIPT" --generic ffff:aaaa >"$GD/out" 2>&1; echo $? >"$GD/rc"
t "modprobe-fail exits 1"         test "$(cat "$GD/rc")" = 1
t "modprobe failure printed"      grep -q 'modprobe .* failed' "$GD/out"

echo "== error log written on failure =="
GD=$(mktemp -d); mkdir -p "$GD/sysfs/bus/usb/devices" "$GD/sysfs/class/net" "$GD/fw"
PATH="$STUBS:$PATH" STUB_STATE="$GD" SYSFS="$GD/sysfs" FWDIR="$GD/fw" AIYUSPOT_LOG="$GD/alog" \
  bash "$SCRIPT" --generic ffff:aaaa >"$GD/out" 2>&1
t "alog file created"             test -f "$GD/alog"
t "alog line has layer+rc"        grep -q '|L2|.*rc=1' "$GD/alog"

echo "== bad hwid rejected =="
runp --generic 'not-an-id'
t "exits 1"                       test "$(cat "$RD/rc")" = 1

echo "== unknown profile rejected =="
runp dead:beef wpa2
t "exits 1"                       test "$(cat "$RD/rc")" = 1

echo "== generic path accepts UPPERCASE vid:pid =="
GD=$(mktemp -d)
mkdir -p "$GD/sysfs/bus/usb/devices/1-9/1-9:1.0" "$GD/sysfs/class/net" "$GD/fw"
echo "usb:vA69Cp5721d0000dc00dsc00dp00icffiscffip00in00" > "$GD/sysfs/bus/usb/devices/1-9/1-9:1.0/modalias"
echo a69c > "$GD/sysfs/bus/usb/devices/1-9/idVendor"
echo 5721 > "$GD/sysfs/bus/usb/devices/1-9/idProduct"
ln -s "1-9/1-9:1.0" "$GD/sysfs/bus/usb/devices/1-9:1.0"
PATH="$STUBS:$PATH" STUB_STATE="$GD" SYSFS="$GD/sysfs" FWDIR="$GD/fw" \
  bash "$SCRIPT" --generic A69C:5721 >"$GD/out" 2>&1; echo $? >"$GD/rc"
t "uppercase vid exits 0"         test "$(cat "$GD/rc")" = 0
t "modalias probed"               grep -q 'usb:vA69C' "$GD/modprobe.log"

echo "== out-of-tree profile: MODDIR seam + installer invoked =="
OD=$(mktemp -d)
# stub conf: the TX1U row with its install column repointed at the stub
awk -F'|' 'BEGIN{OFS="|"} !/^[[:space:]]*#/ { $11="test/linux/stubs/bin/install-driver"; print; exit }' \
  adapters.conf > "$OD/conf"
mkdir -p "$OD/sysfs/bus/usb/devices" "$OD/sysfs/class/net" "$OD/fw" "$OD/mod/6.6.0-0/build"
PATH="$STUBS:$PATH" STUB_STATE="$OD" SYSFS="$OD/sysfs" FWDIR="$OD/fw" \
  FWSERVE_BIN="$OD/x" KSRC="$OD/ksrc" KIMG="$OD/kimg" MODDIR="$OD/mod" \
  ADAPTERS_CONF="$OD/conf" INSTALL_KERNEL="$STUBS/install-kernel" \
  AIYUSPOT_YES=1 STUB_MOD_MISSING=aic8800_fdrv \
  bash "$SCRIPT" 3625:0110 wpa2 >"$OD/out" 2>&1; echo $? >"$OD/rc"
t "out-of-tree exits 0"           test "$(cat "$OD/rc")" = 0
t "driver installer invoked"      test -f "$OD/driver-build.log"

echo "== out-of-tree: missing build tree -> kernel-switch 3 =="
OD2=$(mktemp -d)
awk -F'|' 'BEGIN{OFS="|"} !/^[[:space:]]*#/ { $11="test/linux/stubs/bin/install-driver"; print; exit }' \
  adapters.conf > "$OD2/conf"
mkdir -p "$OD2/sysfs/bus/usb/devices" "$OD2/sysfs/class/net" "$OD2/fw" "$OD2/ksrc/.git"
touch "$OD2/kimg"
PATH="$STUBS:$PATH" STUB_STATE="$OD2" SYSFS="$OD2/sysfs" FWDIR="$OD2/fw" \
  FWSERVE_BIN="$OD2/x" KSRC="$OD2/ksrc" KIMG="$OD2/kimg" MODDIR="$OD2/mod" \
  ADAPTERS_CONF="$OD2/conf" AIYUSPOT_YES=1 STUB_MOD_MISSING=aic8800_fdrv \
  bash "$SCRIPT" 3625:0110 wpa2 >"$OD2/out" 2>&1; echo $? >"$OD2/rc"
t "exits 3 (kernel switch)"       test "$(cat "$OD2/rc")" = 3

echo "== fwpkg '-' prints no bogus apt hint =="
AIYUSPOT_YES=1 runp 3625:0110 wpa2
t "exits 0"                       test "$(cat "$RD/rc")" = 0
t "no '-y -' hint"                bash -c "! grep -q 'install -y -' '$RD/out'"
t "says installer supplies fw"    grep -q 'driver installer' "$RD/out"

echo "============================"
echo "PASS: $PASS FAIL: $FAIL"
echo "============================"
exit $FAIL
