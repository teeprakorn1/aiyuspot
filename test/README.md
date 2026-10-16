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
reset YES-gate, `)`-in-arg parse safety, `diag`/`help` output, error-log
collector). No dependencies.

The reset **YES**-path test only runs elevated (`net session` gate) and swaps
the destructive script via the `AIYUSPOT_RESET_PS1` seam — never executes the
real `reset-rt73.ps1` in tests. `AIYUSPOT_LOG` redirects the error log to a
temp file for the collector assertions.

```powershell
Invoke-Pester ./test/windows/
```

Pester 5+ (`Install-Module Pester -Scope CurrentUser`). Covers
`check-adapters.ps1` parsing via a `usbipd list` fixture + `AIYUSPOT_USBIPD`
override, and `wifi-menu.ps1` structure/`Build-Args`/validators plus the
`Invoke-WifiControl` scalar-return contract (stdout must not pollute the
exit-code return value) via the dot-source guard.

## 🐧 Linux (inside Kali/WSL)

```bash
sudo bash test/linux/lint.sh             # bash -n, CRLF, shellcheck, registry+consumer validation
sudo bash test/linux/hotspot.tests.sh    # stub-PATH harness for kali-wsl-hotspot.sh
sudo bash test/linux/provision.tests.sh  # stub-PATH harness for adapter-provision.sh
```

`hotspot.tests.sh` fakes `iw`/`hostapd`/`dnsmasq`/`iptables` via
`test/linux/stubs/bin` and redirects conf output with `HOSTAPD_CONF` /
`DNSMASQ_CONF`, so the full mode/validation/TKIP-fallback paths run without
touching hardware. Failure-injection knobs: `STUB_DNSMASQ_RC`,
`STUB_PGREP_RC`, `STUB_MODPROBE_RC`, `STUB_MOD_MISSING`, `STUB_NO_AP`,
`STUB_PHY_NO_AP`, `STUB_HOSTAPD_FAILS`, plus `SYSFS`/`FWDIR`/`MODDIR`/`KIMG`/
`KSRC`/`ADAPTERS_CONF`/`AIYUSPOT_LOG` seams — covering the cleanup trap's
partial bring-up rollback, post-daemonize liveness, and `rebind_aic` when
unbind fails. `provision.tests.sh` stubs `apt`/`modprobe`/`modinfo`/`uname`/
driver installers the same way (plus `STUB_APT_DELIVERS` to simulate packages
really delivering firmware) covering required-firmware hard-fail, kernel-build
confirm/decline, `--generic` modalias probing + iface-delta, and out-of-tree
installs.

## 🧩 fwserve (C)

```bash
mkdir -p /tmp/fwtest_sysfw /tmp/fwtest_libfw
gcc -DFWSERVE_NO_MAIN -DSYSFW='"/tmp/fwtest_sysfw"' \
    -DLIBFW='"/tmp/fwtest_libfw"' -o /tmp/test_fwserve test/c/test_fwserve.c
/tmp/test_fwserve
```

Covers firmware serve success, missing-firmware pending state, kernel
`!`-encoded request dirs (`rtlwifi!rtl8723bu_nic.bin` → `rtlwifi/rtl8723bu_nic.bin`),
recursive `scan()` into nested dirs, and `fread` error → `loading=-1` abort.

---

## 🔍 Known coverage gaps

- **Negative `wsl.exe` exit codes** — the launcher compares captured codes with
  exact-nonzero checks (a signed `if errorlevel 1` misses them), but faking a
  negative-returning `wsl.exe` needs a real `.exe` stub, which the repo can't
  build without a Windows toolchain. Verified manually.
- **`:tryunknown` candidate filtering** — depends on `usbipd list` +
  `find-wifi.ps1` + PowerShell; not isolatable in the batch harness without
  exe stubs. The pieces it calls (find-wifi tiering, bat `)`-dispatch) are
  covered separately.

---

## 🤖 CI

`.github/workflows/tests.yml` runs the batch harness + Pester on
`windows-latest` and lint + stub + C tests on `ubuntu-latest`.
