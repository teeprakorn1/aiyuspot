#!/bin/bash
# aiyuspot lint: bash -n on shell scripts, CRLF check on LF-pinned files,
# adapters.conf registry validation, and consumer-vs-registry consistency.
# shellcheck runs when available (CI installs it).
set -u
cd "$(dirname "$0")/../.."
fail=0

echo "== bash -n =="
for f in kali/*.sh kali/driver/*.sh test/linux/*.sh; do
  if bash -n "$f" 2>/dev/null; then echo "  ok   $f"; else echo "  FAIL $f"; fail=1; fi
done

echo "== CRLF check (LF-pinned files) =="
for f in adapters.conf test/linux/lint.sh test/linux/*.sh test/linux/stubs/bin/* \
         $(find kali fwserve -name '*.sh' -o -name '*.c' 2>/dev/null); do
  if grep -q $'\r' "$f"; then echo "  FAIL CRLF: $f"; fail=1; else echo "  ok   $f"; fi
done

echo "== adapters.conf registry =="
if ! awk -F'|' '
  /^[[:space:]]*#/ || !NF { next }
  {
    if (NF != 13) { printf "  FAIL line %d: %d fields (want 13)\n", NR, NF; ok=0; next }
    n=split($1,I,","); m=split($2,W,",")
    delete inset
    for(i=1;i<=n;i++){
      gsub(/ /,"",I[i])
      if(I[i] !~ /^[0-9a-f]{4}:[0-9a-f]{4}$/){ printf "  FAIL line %d: bad id \x27%s\x27\n", NR, I[i]; ok=0 }
      if(seen[I[i]]++){ printf "  FAIL line %d: duplicate id %s\n", NR, I[i]; ok=0 }
      inset[I[i]]=1
    }
    for(i=1;i<=m;i++){
      gsub(/ /,"",W[i])
      if(W[i] !~ /^[0-9a-f]{4}:[0-9a-f]{4}$/){ printf "  FAIL line %d: bad wifi_id \x27%s\x27\n", NR, W[i]; ok=0 }
      if(!(W[i] in inset)){ printf "  FAIL line %d: wifi_id %s not in ids\n", NR, W[i]; ok=0 }
    }
    if($9 != "-" && n <= m){ printf "  FAIL line %d: modeswitch set but ids has no non-wifi personality\n", NR; ok=0 }
    if($12 != "noap" && $4 == "-"){ printf "  FAIL line %d: status=%s but module=-\n", NR, $12; ok=0 }
    if($12 !~ /^(verified|pending|noap)$/){ printf "  FAIL line %d: bad status \x27%s\x27\n", NR, $12; ok=0 }
    if($11 != "-" && $11 !~ /^kali\//){ printf "  FAIL line %d: install method must be a repo path (got \x27%s\x27)\n", NR, $11; ok=0 }
  }
  BEGIN{ ok=1 }
  END{ exit !ok }
' adapters.conf; then fail=1; else echo "  ok   $(grep -vcE '^[[:space:]]*#|^$' adapters.conf) profiles"; fi

echo "== consumers read the registry =="
for f in wifi-control.bat scripts/check-adapters.ps1 scripts/find-wifi.ps1 \
         kali/kali-wsl-hotspot.sh kali/adapter-provision.sh kali/driver/install-rt73.sh; do
  if grep -qi 'adapters\.conf' "$f"; then echo "  ok   $f"; else echo "  FAIL $f never references adapters.conf"; fail=1; fi
done

echo "== literal VID:PIDs must be registered =="
regids=$(awk -F'|' '!/^[[:space:]]*#/ && NF>1 {printf "%s,%s,",$1,$2}' adapters.conf | tr ',' '\n' | tr 'A-F' 'a-f' | /usr/bin/sort -u)
for f in wifi-control.bat scripts/check-adapters.ps1 kali/kali-wsl-hotspot.sh; do
  for id in $(grep -oiE '[0-9a-f]{4}:[0-9a-f]{4}' "$f" | tr 'A-F' 'a-f' | /usr/bin/sort -u); do
    if echo "$regids" | grep -qx "$id"; then echo "  ok   $f -> $id"; else echo "  FAIL $f: unregistered literal $id"; fail=1; fi
  done
done

if command -v shellcheck >/dev/null; then
  echo "== shellcheck =="
  shellcheck -S warning kali/*.sh kali/driver/*.sh || fail=1
else
  echo "== shellcheck not installed - skipped =="
fi

exit $fail
