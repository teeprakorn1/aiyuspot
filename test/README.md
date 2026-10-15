# 🧪 Tests

Unit/lint coverage for the parts of aiyuspot that can run **without hardware**.
USB passthrough, AP bring-up, and real client traffic still require manual
verification on the actual RT73/TX1U adapters — these tests do not replace that.

---

## ▶️ Windows

```bat
test\windows\run-tests.bat
```

Exit-code/stdout assertions for `wifi-control.bat` (dispatch, key validation,
reset YES-gate). No dependencies.

```powershell
Invoke-Pester ./test/windows/
```

Pester 5+ (`Install-Module Pester -Scope CurrentUser`). Covers
`check-adapters.ps1` parsing via a `usbipd list` fixture + `AIYUSPOT_USBIPD`
override, and `wifi-menu.ps1` structure/`Build-Args`/validators via the
dot-source guard.

## 🐧 Linux (inside Kali/WSL)

```bash
sudo bash test/linux/lint.sh            # bash -n, CRLF, shellcheck, VID:PID sets
sudo bash test/linux/hotspot.tests.sh   # stub-PATH harness for kali-wsl-hotspot.sh
```

`hotspot.tests.sh` fakes `iw`/`hostapd`/`dnsmasq`/`iptables` via
`test/linux/stubs/bin` and redirects conf output with `HOSTAPD_CONF` /
`DNSMASQ_CONF`, so the full mode/validation/TKIP-fallback paths run without
touching hardware.

## 🧩 fwserve (C)

```bash
mkdir -p /tmp/fwtest_sysfw /tmp/fwtest_libfw
gcc -DFWSERVE_NO_MAIN -DSYSFW='"/tmp/fwtest_sysfw"' \
    -DLIBFW='"/tmp/fwtest_libfw"' -o /tmp/test_fwserve test/c/test_fwserve.c
/tmp/test_fwserve
```

Covers firmware serve success, missing-firmware pending state, and recursive
`scan()` into nested dirs (`aic8800DC/<file>`).

---

## 🤖 CI

`.github/workflows/tests.yml` runs the batch harness + Pester on
`windows-latest` and lint + stub + C tests on `ubuntu-latest`.
