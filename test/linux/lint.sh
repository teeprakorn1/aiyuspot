#!/bin/bash
# aiyuspot lint: bash -n on all scripts + CRLF check on .sh files.
# shellcheck runs when available (CI installs it).
set -u
cd "$(dirname "$0")/../.."
fail=0

echo "== bash -n =="
for f in kali/kali-wsl-hotspot.sh kali/driver/*.sh; do
  if bash -n "$f" 2>/dev/null; then echo "  ok   $f"; else echo "  FAIL $f"; fail=1; fi
done

echo "== CRLF check (.sh must be LF) =="
for f in $(find kali fwserve -name '*.sh' -o -name '*.c' 2>/dev/null); do
  if grep -q $'\r' "$f"; then echo "  FAIL CRLF: $f"; fail=1; else echo "  ok   $f"; fi
done

if command -v shellcheck >/dev/null; then
  echo "== shellcheck =="
  shellcheck -S warning kali/kali-wsl-hotspot.sh kali/driver/*.sh || fail=1
else
  echo "== shellcheck not installed - skipped =="
fi

echo "== VID:PID consistency =="
# The supported adapter ID set must be identical everywhere it appears.
for f in wifi-control.bat scripts/check-adapters.ps1 kali/kali-wsl-hotspot.sh; do
  ids=$(grep -oE '148f:2573|3625:0110|a69c:5721|VID_148F&PID_2573|VID_3625&PID_0110|VID_A69C&PID_5721' "$f" | sort -u | tr '\n' ' ')
  echo "  $f -> $ids"
done
# bat + hotspot.sh use lowercase colon form; ps1 uses VID_ form.
# hotspot.sh only sees WiFi-mode IDs - a69c:5721 (TX1U storage mode) is
# resolved to 3625:0110 by usb_modeswitch in wifi-control.bat first.
want_sh="148f:2573 3625:0110"
got=$(grep -oE '148f:2573|3625:0110|a69c:5721' kali/kali-wsl-hotspot.sh | sort -u | tr '\n' ' ' | sed 's/ $//')
[ "$got" = "$want_sh" ] || { echo "  FAIL hotspot.sh ID set: $got"; fail=1; }
want_bat="148f:2573 3625:0110 a69c:5721"
got=$(grep -oE '148f:2573|3625:0110|a69c:5721' wifi-control.bat | sort -u | tr '\n' ' ' | sed 's/ $//')
[ "$got" = "$want_bat" ] || { echo "  FAIL wifi-control.bat ID set: $got"; fail=1; }

exit $fail
