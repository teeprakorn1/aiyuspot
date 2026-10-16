@echo off
rem ============================================================
rem  aiyuspot - USB WiFi hotspot via Kali WSL2 + usbipd-win
rem  https://github.com/teeprakorn1/aiyuspot
rem
rem  Usage:
rem    wifi-control.bat                Interactive arrow-key menu
rem    wifi-control.bat default        WPA2 AP  (SSID aiyuspot / pass aiyuspot)
rem    wifi-control.bat open [SSID]    Open AP  (default SSID aiyuspot)
rem    wifi-control.bat wep SSID KEY   WEP AP   (KEY = 5 or 13 chars)
rem    wifi-control.bat wpa2 SSID PASS WPA2-PSK (PASS = 8-63 chars)
rem    wifi-control.bat stop           Stop AP, detach USB, terminate Kali
rem    wifi-control.bat check          Adapter + driver health report
rem    wifi-control.bat provision      Auto-install adapter deps (kernel/driver/fw)
rem    wifi-control.bat driver         Build/install AIC8800 driver (TX1U)
rem    wifi-control.bat kernel         Build/install custom WSL2 kernel
rem    wifi-control.bat reset          Destructive PnP recovery (RT73, asks YES)
rem    wifi-control.bat help           Show this usage
rem
rem  Requires: usbipd-win, a WSL2 distro named kali-linux.
rem  Self-elevates via UAC for bind/reset operations.
rem  Portable: resolves its own path via %%~dp0 + wslpath.
rem  Adapter knowledge lives in adapters.conf - one registry line per
rem  supported profile (see docs/adapters.md).
rem ============================================================
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion
set "USBIPD=C:\Program Files\usbipd-win\usbipd.exe"
set "DISTRO=kali-linux"
set "DEFAULT_SSID=aiyuspot"
set "DEFAULT_KEY=aiyu1"
set "DEFAULT_WPA2KEY=aiyuspot"
set "CLI_MODE=0"
set "COMMAND=%~nx0 %*"
set "FAIL=0"
if not defined AIYUSPOT_LOG set "AIYUSPOT_LOG=%TEMP%\aiyuspot-errors.log"
rem Re-elevated children carry a --elevated marker arg so a broken UAC
rem flow cannot recurse forever.
set "ELEV_FLAG="
for %%A in (%*) do if /i "%%~A"=="--elevated" set "ELEV_FLAG=1"

if /i "%~1"=="help" goto help
if /i "%~1"=="/?" goto help
if /i "%~1"=="-h" goto help

rem Arg-verbs dispatch via labels, NOT parenthesized blocks: a value
rem containing ")" in %~2/%~3 expands at block-parse time and would
rem truncate the group - the exit-255 parse bomb class. Top-level
rem `set "X=value"` keeps every character literal.
if /i "%~1"=="default" goto cfg_default
if /i "%~1"=="open" goto cfg_open
if /i "%~1"=="wep" goto cfg_wep
if /i "%~1"=="wpa2" goto cfg_wpa2
if /i "%~1"=="stop" (set "CLI_MODE=1" & goto stop)
if /i "%~1"=="reset" (set "CLI_MODE=1" & goto reset)
if /i "%~1"=="check" (set "CLI_MODE=1" & goto check)
if /i "%~1"=="diag" (set "CLI_MODE=1" & goto diag)
if /i "%~1"=="driver" (set "CLI_MODE=1" & goto driver)
if /i "%~1"=="provision" (set "CLI_MODE=1" & goto provision)
if /i "%~1"=="kernel" (set "CLI_MODE=1" & goto kernel)
if "%~1"=="" goto menu
echo Unknown command: %~1
echo Run '%~nx0 help' for usage.
call :log L1 dispatch - "unknown command"
exit /b 2

:cfg_default
set "CLI_MODE=1"
set "SSID=%DEFAULT_SSID%"
set "MODE=wpa2"
set "KEY=%DEFAULT_WPA2KEY%"
echo Note: using public default credentials - pass 'wpa2 SSID PASS' for custom ones.
goto start

:cfg_open
set "CLI_MODE=1"
set "SSID=%~2"
if not defined SSID set "SSID=%DEFAULT_SSID%"
set "MODE=open"
set "KEY="
goto start

:cfg_wep
set "CLI_MODE=1"
set "SSID=%~2"
set "KEY=%~3"
if not defined SSID set "SSID=%DEFAULT_SSID%"
if not defined KEY (
  set "KEY=%DEFAULT_KEY%"
  echo WARNING: no WEP key given - using public default '%DEFAULT_KEY%'
)
set "MODE=wep"
goto start

:cfg_wpa2
set "CLI_MODE=1"
set "SSID=%~2"
set "KEY=%~3"
if not defined SSID set "SSID=%DEFAULT_SSID%"
if not defined KEY (
  set "KEY=%DEFAULT_WPA2KEY%"
  echo WARNING: no passphrase given - using public default '%DEFAULT_WPA2KEY%'
)
set "MODE=wpa2"
goto start

:menu
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0wifi-menu.ps1"
exit /b %ERRORLEVEL%

rem ------------------------------------------------------------
:start
cls
echo Command: %COMMAND%
echo.

call :validate
if errorlevel 1 (
  if "%CLI_MODE%"=="0" (pause & goto menu)
  exit /b 2
)

net session >nul 2>&1
if %errorlevel% neq 0 (
  if defined ELEV_FLAG (
    echo ERROR: still not elevated after UAC approval - cannot continue.
    call :log L1 elevate - "elevated child lacks admin"
    if "%CLI_MODE%"=="0" (pause & goto menu)
    call :hold 1
    exit /b 1
  )
  echo Requesting administrator rights for USB device binding...
  rem Launch async + poll the rc file the child writes in :hold -
  rem -Wait hung even after the elevated child exited (verified via the
  rem process tree), while the rc file travels regardless.
  del "%TEMP%\aiyuspot-elev-rc" 2>nul
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*','--elevated' -Verb RunAs"
  if not "%errorlevel%"=="0" (
    echo UAC declined or elevation failed - cannot continue.
    call :log L1 elevate %errorlevel% "UAC launch failed"
    if "%CLI_MODE%"=="0" (pause & goto menu)
    call :hold 1
    exit /b 1
  )
  echo Waiting for the elevated run - its own window shows live progress...
  call :waitelev
  exit /b %ERC%
)

rem --- Preflight: verify prerequisites before touching hardware ---
if not exist "%USBIPD%" (
  echo ERROR: usbipd-win not found at:
  echo   %USBIPD%
  echo Install it: https://github.com/dorssel/usbipd-win/releases
  call :log L1 preflight - "usbipd-win missing"
  goto fail
)
rem 'wsl -l -q' emits UTF-16 which findstr can't match - probe directly.
rem %errorlevel% (not 'if errorlevel 1'): negative transport codes like
rem 0xFFFFFFFF (distro not found) must not pass as success.
wsl.exe -d %DISTRO% -u root -- true >nul 2>&1
if not "%errorlevel%"=="0" (
  echo ERROR: WSL distro '%DISTRO%' not found or not startable.
  echo Install it: wsl --install -d %DISTRO%
  call :log L1 preflight %errorlevel% "distro not startable"
  goto fail
)

echo Starting Kali WSL runtime...
start "Kali WSL hotspot runtime" /min wsl.exe -d %DISTRO% -u root -- sleep infinity
timeout /t 5 /nobreak >nul

set "WINSELF=%~dp0"
set "WINSELF=%WINSELF:\=/%"
if "%WINSELF:~-1%"=="/" set "WINSELF=%WINSELF:~0,-1%"
set "WSLDIR="
for /f "usebackq delims=" %%P in (`wsl.exe -d %DISTRO% -u root -- wslpath -u "%WINSELF%" 2^>nul`) do set "WSLDIR=%%P"
if not defined WSLDIR (
  echo ERROR: could not reach the %DISTRO% distro - is WSL healthy?
  call :log L1 wslpath - "wslpath resolution failed"
  goto fail
)
set "HOTSPOT=%WSLDIR%/kali/kali-wsl-hotspot.sh"

echo Starting USB monitor driver...
sc.exe start VBoxUSBMon >nul 2>&1

echo Detecting WiFi adapter...
call :detect
if not defined HWID goto tryunknown
if !FOUND! gtr 1 echo Note: !FOUND! supported adapters detected - using the first match.
echo Found %ADAPT% [%HWID%]
if "!STATUS!"=="noap" (
  echo.
  echo !ADAPT! is detected but CANNOT host a hotspot:
  echo   !PROFNOTE!
  call :log L1 detect - "noap adapter refused"
  set "FAIL=1"
  goto startdone
)

rem --- Auto-provision: install whatever this adapter's spec needs ---
rem Pre-attach on purpose: a kernel switch (wsl --shutdown) would kill
rem any attach anyway, and nothing here requires the device present.
echo Provisioning adapter requirements...
wsl.exe -d %DISTRO% -u root -- bash "%WSLDIR%/kali/adapter-provision.sh" %HWID% %MODE%
set "PRC=%errorlevel%"
if "%PRC%"=="3" goto kernelswitch
if not "%PRC%"=="0" (
  if %PRC% lss 0 (
    echo WSL transport failed - is the distro healthy?
  ) else (
    echo Adapter provisioning failed or was declined - cannot start.
    echo   Retry manually: wifi-control.bat provision
  )
  call :log L2 provision %PRC% "provision failed"
  set "FAIL=1"
  goto startdone
)

rem Clear stale driver state first: a crashed previous session can leave a
rem wedged ghost usb device (driver remove-path deadlock) that blocks new
rem enumeration - rmmod releases it before we attach anything.
wsl.exe -d %DISTRO% -u root -- sh -c "rmmod !MODLIST! 2>/dev/null; true"

rem --- Firmware env BEFORE attach: the kernel auto-probes the attached
rem device's driver immediately - an in-flight firmware request races any
rem staging/fwserve started afterwards and then dies on the ~60 s timeout.
rem fw_stage entries: 'path' = preserve-path tar idiom, 'dir/.' = flatten
rem the directory contents. Each pipe also disables the init-namespace
rem udev stub that aborts pending firmware requests in ~1ms.
echo Preparing firmware environment...
set "FWWARN="
for %%S in (!FWSTAGE!) do (
  set "FSP=%%S"
  if "!FSP:~-2!"=="/." (
    set "FSD=!FSP:~0,-2!"
    wsl.exe -d %DISTRO% -u root -- sh -c "cd /lib/firmware/!FSD! 2>/dev/null && tar cf - ." | wsl.exe --system -u root -e sh -c "P=$(pidof systemd-udevd | cut -d' ' -f1); P=${P:-1}; nsenter -m -t $P sh -c 'mkdir -p /lib/firmware && tar xf - -C /lib/firmware' 2>/dev/null; XRC=$?; nsenter -m -t $P sh -c 'mv /usr/lib/udev/rules.d/50-firmware.rules /usr/lib/udev/rules.d/50-firmware.rules.disabled 2>/dev/null || true'; exit $XRC"
    if not "!errorlevel!"=="0" set "FWWARN=1"
  ) else (
    wsl.exe -d %DISTRO% -u root -- sh -c "cd /lib/firmware 2>/dev/null && tar cf - !FSP! 2>/dev/null" | wsl.exe --system -u root -e sh -c "P=$(pidof systemd-udevd | cut -d' ' -f1); P=${P:-1}; nsenter -m -t $P sh -c 'mkdir -p /lib/firmware && tar xf - -C /lib/firmware' 2>/dev/null; XRC=$?; nsenter -m -t $P sh -c 'mv /usr/lib/udev/rules.d/50-firmware.rules /usr/lib/udev/rules.d/50-firmware.rules.disabled 2>/dev/null || true'; exit $XRC"
    if not "!errorlevel!"=="0" set "FWWARN=1"
  )
)
if defined FWWARN (echo WARNING: init-ns firmware staging failed - relying on fwserve fallback & call :log L1 fwstage - "init-ns staging failed")
if not "!FWPKG!"=="-" (
  set "FWCHK=!FWSTAGE:/.=!"
  for %%S in (!FWCHK!) do wsl.exe -d %DISTRO% -u root -- sh -c "test -e /lib/firmware/%%S || echo 'WARNING: /lib/firmware/%%S missing - apt-get install -y !FWPKG!'"
)

echo Starting firmware helper...
if not "!PREMOD!"=="-" (set "PREMOD_LOAD=!PREMOD!") else (set "PREMOD_LOAD=")
rem fwserve stderr folds into the same Kali-side error log - the daemon
rem has no other voice when it dies or fails to launch.
wsl.exe -d %DISTRO% -u root -- sh -c "echo 1 > /proc/sys/kernel/firmware_config/force_sysfs_fallback; pkill -x fwserve 2>/dev/null; nohup /usr/local/bin/fwserve >>/var/log/aiyuspot.log 2>&1 & sleep 1"
if not "%errorlevel%"=="0" call :log L3 fwserve %errorlevel% "fwserve launch failed"

echo Binding USB adapter...
"%USBIPD%" bind --force --hardware-id %HWID% >nul 2>&1
if not "%errorlevel%"=="0" call :log L1 bind %errorlevel% "usbipd bind failed - attach may fail"

echo Resetting USB adapter...
"%USBIPD%" detach --hardware-id %HWID% >nul 2>&1
timeout /t 2 /nobreak >nul
"%USBIPD%" attach --wsl %DISTRO% --hardware-id %HWID%
set "ARC=%errorlevel%"
if not "%ARC%"=="0" (
  echo.
  echo Attach failed. Next step: unplug and replug the adapter, or run
  echo   wifi-control.bat check
  call :log L1 attach %ARC% "usbipd attach failed"
  set "FAIL=1"
  goto startdone
)
timeout /t 3 /nobreak >nul

rem Storage-mode personality: modeswitch, then re-attach the Wi-Fi id.
rem %WIFIIDS% must be percent-expanded: a pipe runs each side in a fresh
rem cmd child where delayed expansion is OFF - !WIFIIDS! printed the
rem literal string, so this skip-check silently never matched.
echo %WIFIIDS% | findstr /c:"%HWID%" >nul || (
  echo Switching adapter to WiFi mode...
  rem usb_modeswitch needs usb-storage to claim the interface first -
  rem without it the EJECT sequence times out (error -7).
  for /f "tokens=1,2 delims=:" %%v in ("%HWID%") do wsl.exe -d %DISTRO% -u root -- sh -c "modprobe usb-storage uas 2>/dev/null; sleep 2; usb_modeswitch -v 0x%%v -p 0x%%w -!MODESW! 2>/dev/null; rc=$?; sleep 3; exit $rc"
  if not "!errorlevel!"=="0" call :log L3 modeswitch !errorlevel! "usb_modeswitch failed - attach may fail"
  for /f "tokens=1 delims=," %%W in ("!WIFIIDS!") do set "WIFIID=%%W"
  echo Attaching adapter in WiFi mode...
  "%USBIPD%" bind --force --hardware-id !WIFIID! >nul 2>&1
  "%USBIPD%" detach --hardware-id !WIFIID! >nul 2>&1
  "%USBIPD%" attach --wsl !DISTRO! --hardware-id !WIFIID!
  set "ARC=!errorlevel!"
  if not "!ARC!"=="0" (
    echo.
    echo WiFi-mode attach failed. Next step: unplug and replug the adapter,
    echo   then run wifi-control.bat check
    call :log L1 attach !ARC! "wifi-mode attach failed"
    set "FAIL=1"
    goto startdone
  )
  timeout /t 3 /nobreak >nul
  set "HWID=!WIFIID!"
)

echo Loading driver !PROFMOD! - firmware request can take up to a minute, live kernel log follows...
if not "!PROFMOD!"=="-" (
  set "MODSEQ="
  for %%M in (!PREMOD_LOAD!) do set "MODSEQ=!MODSEQ!modprobe %%M 2>/dev/null; sleep 1; "
  rem Keep modprobe's real rc: a trailing '; sleep 3' made the sh -c
  rem always exit 0, hiding a dead driver until the iface poll timed out.
  rem Load in background and stream new kernel messages while it runs -
  rem a blocked firmware request otherwise looks like a silent hang.
  rem -e is required: plain wsl joins args through the distro's default
  rem shell, which pre-evaluates $(...) - the loop needs live evaluation.
  wsl.exe -d %DISTRO% -u root -e sh -c "rmmod !PROFMOD! !PREMOD_LOAD! 2>/dev/null; !MODSEQ!rm -f /tmp/.aiyuspot-mprc; ( modprobe !PROFMOD!; echo $? >/tmp/.aiyuspot-mprc ) & T0=$(date +%%s); DL=$(dmesg | wc -l); until [ -f /tmp/.aiyuspot-mprc ]; do sleep 2; dmesg | tail -n +$((DL+1)) | grep --line-buffered -E 'firmware|!PROFMOD!|usb 1-1'; DL=$(dmesg | wc -l); if [ $(( $(date +%%s) - T0 )) -gt 90 ]; then echo '  driver load timed out after 90s'; kill $(pgrep -x modprobe) 2>/dev/null; break; fi; done; MPRC=$(cat /tmp/.aiyuspot-mprc 2>/dev/null); rm -f /tmp/.aiyuspot-mprc; exit ${MPRC:-1}"
  set "MRC=!errorlevel!"
  if not "!MRC!"=="0" (
    echo WARNING: modprobe !PROFMOD! failed - driver may not load
    call :log L3 modprobe !MRC! "modprobe !PROFMOD! failed"
  )
  timeout /t 3 /nobreak >nul
)
timeout /t 2 /nobreak >nul

:starthotspot
echo Starting WiFi: %SSID% [%MODE%]...
wsl.exe -d %DISTRO% -u root -- bash "%HOTSPOT%" "%SSID%" "%MODE%" "%KEY%"
set "HRC=%errorlevel%"
rem !SSID!/!KEY! in the success echo: runtime expansion cannot break
rem block parsing even when the value contains parentheses.
if not "%HRC%"=="0" (
  if %HRC% lss 0 (
    echo WSL transport failed - is the distro healthy?
  ) else (
    echo Failed to start WiFi. Next step: wifi-control.bat check
  )
  call :log L3 hotspot %HRC% "hotspot start failed"
  set "FAIL=1"
) else (
  if "%MODE%"=="open" echo WiFi started: !SSID! ^(Open AP^)
  if "%MODE%"=="wep" echo WiFi started: !SSID! ^(WEP key: !KEY!^)
  if "%MODE%"=="wpa2" echo WiFi started: !SSID! ^(WPA2 passphrase set^)
)

:startdone
echo.
if "%FAIL%"=="0" (echo === RESULT: success ===) else echo === RESULT: failed - scroll up, or run 'wifi-control.bat diag' ===
if "%CLI_MODE%"=="0" pause
call :hold %FAIL%
exit /b %FAIL%

rem ------------------------------------------------------------
:tryunknown
rem No registry match - tiered discovery for unregistered Wi-Fi devices.
echo No registry adapter found - scanning for unknown Wi-Fi devices...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\find-wifi.ps1" > "%TEMP%\aiyu-cand.txt"
if not "%errorlevel%"=="0" call :log L1 find-wifi %errorlevel% "find-wifi script failed"
rem Keep only well-formed rows "<busid> <vid:pid> <tier>" - a warning or
rem partial line that slips into the file must not reach the parser.
set "UBUSID=" & set "UHWID=" & set "UTIER=" & set "NCAND=0"
findstr /r /c:"^[^ ][^ ]* [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F] [0-9]" "%TEMP%\aiyu-cand.txt" >"%TEMP%\aiyu-cand-ok.txt" 2>nul
for /f "usebackq tokens=1-3" %%A in ("%TEMP%\aiyu-cand-ok.txt") do (
  set /a NCAND+=1
  echo   candidate: %%B on bus %%A ^(tier %%C^)
  if not defined UHWID (set "UBUSID=%%A" & set "UHWID=%%B" & set "UTIER=%%C")
)
if not defined UHWID (
  echo No supported WiFi adapter found.
  echo.
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\check-adapters.ps1"
  call :log L1 detect - "no adapter candidates"
  goto fail
)
rem Anything that is not a clean tier-1 match gets the same confirm -
rem a malformed/missing tier field must not bypass the [Y/n] gate.
if not defined UTIER set "UTIER=3"
if !NCAND! gtr 1 echo   %NCAND% candidates - using the first.
echo Selected: %UHWID% on bus %UBUSID% (tier %UTIER%)
if not "%UTIER%"=="1" (
  echo.
  echo This device is NOT in adapters.conf - attaching takes it away
  echo from Windows and the name match may be wrong.
  if "%AIYUSPOT_YES%"=="1" (set "UOK=y") else if "%AIYUSPOT_NO%"=="1" (set "UOK=n") else set /p "UOK=Attach and try to host anyway? [Y/n] "
  if /i "!UOK!"=="n" goto fail
)
rem Firmware plumbing BEFORE attach: a built-in/auto-loaded driver probes
rem at attach time - pending requests must be servable already.
echo Preparing firmware helper before attach...
wsl.exe -d %DISTRO% -u root -- sh -c "echo 1 > /proc/sys/kernel/firmware_config/force_sysfs_fallback; pkill -x fwserve 2>/dev/null; nohup /usr/local/bin/fwserve >>/var/log/aiyuspot.log 2>&1 & sleep 1"
if not "%errorlevel%"=="0" call :log L3 fwserve %errorlevel% "fwserve launch failed"
wsl.exe --system -u root -e sh -c "P=$(pidof systemd-udevd | cut -d' ' -f1); P=${P:-1}; nsenter -m -t $P sh -c 'mv /usr/lib/udev/rules.d/50-firmware.rules /usr/lib/udev/rules.d/50-firmware.rules.disabled 2>/dev/null || true'"
if not "%errorlevel%"=="0" echo WARNING: init-ns udev-stub disable unavailable - relying on fwserve only
echo Binding %UHWID% on bus %UBUSID%...
"%USBIPD%" bind --force --busid %UBUSID% >nul 2>&1
"%USBIPD%" detach --busid %UBUSID% >nul 2>&1
timeout /t 2 /nobreak >nul
"%USBIPD%" attach --wsl %DISTRO% --busid %UBUSID%
set "ARC=%errorlevel%"
if not "%ARC%"=="0" (
  echo Attach failed. Next step: unplug/replug, wifi-control.bat check
  call :log L1 attach %ARC% "unknown attach failed"
  set "FAIL=1"
  goto startdone
)
>"%TEMP%\aiyuspot-attached" echo %UBUSID% %UHWID%
if not "%errorlevel%"=="0" call :log L1 persist %errorlevel% "attached-state write failed"
timeout /t 3 /nobreak >nul
echo Probing for a driver inside Kali...
wsl.exe -d %DISTRO% -u root -- bash "%WSLDIR%/kali/adapter-provision.sh" --generic %UHWID% %MODE%
set "GRC=%errorlevel%"
if not "%GRC%"=="0" (
  echo Unknown adapter could not be hosted - see messages above.
  "%USBIPD%" detach --busid %UBUSID% >nul 2>&1
  del "%TEMP%\aiyuspot-attached" >nul 2>&1
  call :log L2 generic-provision %GRC% "generic probe failed"
  set "FAIL=1"
  goto startdone
)
goto starthotspot

rem ------------------------------------------------------------
:kernelswitch
if defined KSWDONE (
  echo Kernel switch did not take effect - set it manually:
  echo   %USERPROFILE%\.wslconfig -^> [wsl2] kernel=C:\wsl\wsl-kernel-bzImage
  echo   then: wsl --shutdown   and re-run this command.
  call :log L2 kernelswitch - "kernel switch did not take effect"
  set "FAIL=1"
  goto startdone
)
echo.
echo A custom kernel image is ready but WSL is running the stock kernel.
echo This edits %USERPROFILE%\.wslconfig and runs 'wsl --shutdown'
echo ^(kills ALL running WSL sessions^).
if "%AIYUSPOT_YES%"=="1" (set "KSW=y") else if "%AIYUSPOT_NO%"=="1" (set "KSW=n") else set /p "KSW=Apply kernel switch and retry now? [Y/n] "
if /i "!KSW!"=="n" (
  echo Deferred. Manual steps: .wslconfig kernel= line, wsl --shutdown, re-run.
  call :log L2 kernelswitch - "kernel switch declined"
  set "FAIL=1"
  goto startdone
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\set-wslkernel.ps1" -KernelPath "C:\wsl\wsl-kernel-bzImage"
if not "%errorlevel%"=="0" (
  echo .wslconfig update failed - do it manually per the lines above.
  call :log L2 kernelswitch %errorlevel% "set-wslkernel failed"
  set "FAIL=1"
  goto startdone
)
wsl.exe --shutdown
if not "%errorlevel%"=="0" call :log L1 kernelswitch %errorlevel% "wsl --shutdown failed"
set "KSWDONE=1"
goto start

rem ------------------------------------------------------------
:detect
rem Registry-driven detection. Returns globals:
rem   HWID ADAPT PROFMOD PREMOD FWSTAGE FWPKG MODESW WIFIIDS STATUS PROFNOTE
rem   FOUND (match count) MODLIST (union of module+pre_modules for rmmod)
set "HWID=" & set "ADAPT=" & set "PROFMOD=" & set "PREMOD=" & set "FWSTAGE="
set "FWPKG=" & set "MODESW=" & set "WIFIIDS=" & set "STATUS=" & set "PROFNOTE="
set "FOUND=0" & set "MODLIST="
"%USBIPD%" list >"%TEMP%\aiyu-usbipd.txt" 2>nul
if not "%errorlevel%"=="0" (
  echo ERROR: usbipd not responding - is the usbipd service running?
  call :log L1 detect %errorlevel% "usbipd list failed"
  rem DETECT_SOFT: callers that can proceed without a target (reset)
  rem get a soft exit instead of aborting the whole flow.
  if defined DETECT_SOFT exit /b 1
  goto fail
)
for /f "usebackq eol=# tokens=1-13 delims=|" %%A in ("%~dp0adapters.conf") do (
  if "%%D" neq "-" set "MODLIST=!MODLIST! %%D"
  if "%%E" neq "-" set "MODLIST=!MODLIST! %%E"
  for %%Z in (%%A) do (
    findstr /c:"%%Z" "%TEMP%\aiyu-usbipd.txt" >nul && (
      set /a FOUND+=1
      if not defined HWID (
        set "HWID=%%Z" & set "ADAPT=%%C" & set "PROFMOD=%%D" & set "PREMOD=%%E"
        set "FWSTAGE=%%F" & set "FWPKG=%%G" & set "MODESW=%%I" & set "WIFIIDS=%%B"
        set "STATUS=%%L" & set "PROFNOTE=%%M"
      )
    )
  )
)
exit /b 0

rem ------------------------------------------------------------
:provision
cls
echo Command: %COMMAND%
echo.
echo Auto-provisioning the detected adapter inside Kali WSL...
echo.
if not exist "%USBIPD%" (
  echo ERROR: usbipd-win not found at:
  echo   %USBIPD%
  call :log L1 preflight - "usbipd-win missing"
  goto fail
)
set "WINSELF=%~dp0"
set "WINSELF=%WINSELF:\=/%"
if "%WINSELF:~-1%"=="/" set "WINSELF=%WINSELF:~0,-1%"
for /f "usebackq delims=" %%P in (`wsl.exe -d %DISTRO% -u root -- wslpath -u "%WINSELF%" 2^>nul`) do set "WSLDIR=%%P"
if not defined WSLDIR (
  echo ERROR: could not reach the %DISTRO% distro - is WSL healthy?
  goto fail
)
call :detect
if not defined HWID (
  echo No registry adapter found - unknown devices are handled by the
  echo start flow after attach. Plug a registered adapter first.
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\check-adapters.ps1"
  goto fail
)
echo Found %ADAPT% [%HWID%]
if not defined MODE set "MODE=wpa2"
wsl.exe -d %DISTRO% -u root -- bash "%WSLDIR%/kali/adapter-provision.sh" %HWID% %MODE%
set "PRC=%errorlevel%"
if "%PRC%"=="3" (
  echo A custom kernel is ready but not booted - run a hotspot command
  echo ^(default/wpa2/open/wep^) to apply the kernel switch, or do it manually.
  call :log L2 provision 3 "kernel ready but not booted"
  set "FAIL=1"
) else if not "%PRC%"=="0" (
  if %PRC% lss 0 (echo WSL transport failed - is the distro healthy?) else (echo Provisioning failed or was declined.)
  call :log L2 provision %PRC% "provision failed"
  set "FAIL=1"
) else echo Adapter provisioned - start with: wifi-control.bat wpa2 SSID PASS
if "%CLI_MODE%"=="0" pause
exit /b %FAIL%

rem ------------------------------------------------------------
:stop
cls
echo Stopping WiFi services...
wsl.exe -d %DISTRO% -u root -- sh -c "pkill -x hostapd-wep 2>/dev/null; pkill -x hostapd 2>/dev/null; pkill -x dnsmasq 2>/dev/null; pkill -x fwserve 2>/dev/null"
echo Detaching USB adapter...
for /f "usebackq eol=# tokens=1 delims=|" %%A in ("%~dp0adapters.conf") do (
  for %%Z in (%%A) do "%USBIPD%" detach --hardware-id %%Z >nul 2>&1
)
if exist "%TEMP%\aiyuspot-attached" (
  for /f "usebackq tokens=1" %%A in ("%TEMP%\aiyuspot-attached") do "%USBIPD%" detach --busid %%A >nul 2>&1
  del "%TEMP%\aiyuspot-attached" >nul 2>&1
)
echo Terminating the %DISTRO% distro ^(all WSL sessions in it^)...
wsl.exe --terminate %DISTRO%
set "TRC=%errorlevel%"
if not "%TRC%"=="0" (
  echo WARNING: wsl --terminate failed ^(rc=%TRC%^) - distro may still be running
  call :log L1 stop %TRC% "wsl --terminate failed"
)
echo WiFi stopped.
if "%CLI_MODE%"=="0" pause
exit /b 0

rem ------------------------------------------------------------
:reset
cls
echo Command: %COMMAND%
echo.
echo  WARNING: reset is DESTRUCTIVE.
echo   - Purges the detected adapter's USB registry entries ^(SYSTEM level^)
echo   - Wipes ALL usbipd-win device bindings on this machine
echo   - Use only for wedged PnP/USB states ^(Code 19, dead device I/O^)
echo.
rem Confirm once, THEN elevate: the elevated child is re-invoked as
rem `reset YES` so it skips this prompt instead of asking a second time.
rem (`wifi-control.bat reset YES` typed directly is an explicit confirm.)
if /i not "%~2"=="YES" (
  set "CONFIRM="
  set /p "CONFIRM=Type YES to continue: "
  rem !CONFIRM! is required here: %CONFIRM% would expand at block-parse
  rem time (before set /p runs) making the prompt always "Cancelled".
  if /i not "!CONFIRM!"=="YES" (
    echo Cancelled.
    call :log L1 reset - "user declined"
    if "%CLI_MODE%"=="0" (pause & goto menu)
    exit /b 1
  )
)
net session >nul 2>&1
if %errorlevel% neq 0 (
  if defined ELEV_FLAG (
    echo ERROR: still not elevated after UAC approval - cannot continue.
    call :log L1 elevate - "elevated child lacks admin"
    call :hold 1
    exit /b 1
  )
  echo Requesting administrator rights for adapter reset...
  rem Same handshake as :start - see the comment there.
  del "%TEMP%\aiyuspot-elev-rc" 2>nul
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'reset YES','--elevated' -Verb RunAs"
  if not "%errorlevel%"=="0" (
    echo UAC declined or elevation failed - cannot continue.
    call :log L1 elevate %errorlevel% "UAC launch failed"
    if "%CLI_MODE%"=="0" (pause & goto menu)
    call :hold 1
    exit /b 1
  )
  echo Waiting for the elevated reset - its own window shows progress...
  call :waitelev
  exit /b %ERC%
)
rem AIYUSPOT_RESET_PS1 lets tests substitute a stub for the real
rem destructive script.
set "RPS1=%AIYUSPOT_RESET_PS1%"
if not defined RPS1 set "RPS1=%~dp0scripts\reset-rt73.ps1"
rem Target the detected adapter; fall back to the script's RT73 default
rem when detection fails (wedged usbipd is exactly what reset repairs).
set "DETECT_SOFT=1"
if not defined HWID call :detect
set "DETECT_SOFT="
set "RARGS="
if defined HWID set "RARGS=-HwId %HWID%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%RPS1%" !RARGS!
set "RRC=%errorlevel%"
if not "%RRC%"=="0" call :log L1 reset %RRC% "reset script failed"
if "%CLI_MODE%"=="0" pause
call :hold %RRC%
exit /b %RRC%

rem ------------------------------------------------------------
:check
cls
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\check-adapters.ps1"
if "%CLI_MODE%"=="0" pause
exit /b 0

rem ------------------------------------------------------------
:driver
cls
echo Command: %COMMAND%
echo.
echo Installing AIC8800 driver (TP-Link TX1U Nano) inside Kali WSL...
echo Requires the kernel build tree - run 'wifi-control.bat kernel' first
echo on a fresh machine.
echo.
set "WINSELF=%~dp0"
set "WINSELF=%WINSELF:\=/%"
if "%WINSELF:~-1%"=="/" set "WINSELF=%WINSELF:~0,-1%"
for /f "usebackq delims=" %%P in (`wsl.exe -d %DISTRO% -u root -- wslpath -u "%WINSELF%" 2^>nul`) do set "WSLDIR=%%P"
if not defined WSLDIR (
  echo ERROR: could not reach the %DISTRO% distro - is WSL healthy?
  goto fail
)
wsl.exe -d %DISTRO% -u root -- bash "%WSLDIR%/kali/driver/install-aic8800.sh"
if not "%errorlevel%"=="0" (
  echo Driver install failed. If it reported 'Kernel build tree missing',
  echo run 'wifi-control.bat kernel' first.
  call :log L3 driver %errorlevel% "aic8800 install failed"
  set "FAIL=1"
)
if "%CLI_MODE%"=="0" pause
exit /b %FAIL%

rem ------------------------------------------------------------
:kernel
cls
echo Command: %COMMAND%
echo.
echo Building custom WSL2 kernel with all adapters.conf modules inside Kali WSL...
echo This takes a while - grab a coffee. ^(Also provides the build tree
echo that the TX1U driver needs.^)
echo.
set "WINSELF=%~dp0"
set "WINSELF=%WINSELF:\=/%"
if "%WINSELF:~-1%"=="/" set "WINSELF=%WINSELF:~0,-1%"
for /f "usebackq delims=" %%P in (`wsl.exe -d %DISTRO% -u root -- wslpath -u "%WINSELF%" 2^>nul`) do set "WSLDIR=%%P"
if not defined WSLDIR (
  echo ERROR: could not reach the %DISTRO% distro - is WSL healthy?
  goto fail
)
wsl.exe -d %DISTRO% -u root -- bash "%WSLDIR%/kali/driver/install-rt73.sh"
if not "%errorlevel%"=="0" (
  echo Kernel build failed; check the output above.
  call :log L3 kernel %errorlevel% "kernel build failed"
  set "FAIL=1"
)
if "%CLI_MODE%"=="0" pause
exit /b %FAIL%

rem ------------------------------------------------------------
:help
echo aiyuspot - USB WiFi hotspot via Kali WSL2 + usbipd-win
echo.
echo   wifi-control.bat              Interactive arrow-key menu
echo   wifi-control.bat default      WPA2 AP   (SSID aiyuspot / pass aiyuspot)
echo   wifi-control.bat open [SSID]  Open AP   (unencrypted - testing only)
echo   wifi-control.bat wep SSID KEY WEP AP    (KEY = 5 or 13 chars, insecure)
echo   wifi-control.bat wpa2 SSID PASS  WPA2-PSK  (PASS = 8-63 chars)
echo   wifi-control.bat stop         Stop AP, detach USB, terminate Kali
echo   wifi-control.bat check        Adapter + driver health report
echo   wifi-control.bat diag         Show the collected error log ^(Windows + Kali^)
echo   wifi-control.bat provision    Auto-install adapter deps (kernel/driver/firmware)
echo   wifi-control.bat driver       Build AIC8800 driver (TX1U; needs kernel tree)
echo   wifi-control.bat kernel       Build custom WSL2 kernel (all adapters.conf modules)
echo   wifi-control.bat reset        Destructive PnP recovery - asks for YES
exit /b 0

rem ------------------------------------------------------------
:validate
if "%MODE%"=="open" exit /b 0
call :strlen KEY KLEN
if "%MODE%"=="wep" (
  if not "%KLEN%"=="5" if not "%KLEN%"=="13" (
    echo ERROR: WEP key must be exactly 5 or 13 characters ^(got %KLEN%^).
    exit /b 1
  )
)
if "%MODE%"=="wpa2" (
  if %KLEN% lss 8 (
    echo ERROR: WPA2 passphrase must be at least 8 characters ^(got %KLEN%^).
    exit /b 1
  )
  if %KLEN% gtr 63 (
    echo ERROR: WPA2 passphrase must be 63 characters or fewer ^(got %KLEN%^).
    exit /b 1
  )
)
exit /b 0

rem :strlen <varname> <resultvar> - string length without external tools
:strlen
setlocal EnableDelayedExpansion
set "s=!%~1!"
set /a n=0
:strlen_loop
if defined s (set "s=!s:~1!" & set /a n+=1 & goto strlen_loop)
endlocal & set "%~2=%n%"
exit /b 0

rem ------------------------------------------------------------
:diag
rem Merge both error-log tails - Windows side (this file's :log writes)
rem and Kali side (provision/hotspot alog + fwserve stderr).
cls
echo === aiyuspot error log - Windows side ===
if exist "%AIYUSPOT_LOG%" (
  powershell.exe -NoProfile -Command "Get-Content -LiteralPath '%AIYUSPOT_LOG%' -Tail 40"
) else (
  echo ^(no entries yet^)
)
echo.
echo === aiyuspot error log - Kali side ===
wsl.exe -d %DISTRO% -u root -- sh -c "tail -n 40 /var/log/aiyuspot.log 2>/dev/null || echo '(no entries yet)'"
if "%CLI_MODE%"=="0" pause
exit /b 0

rem ------------------------------------------------------------
rem :log <layer> <site> <rc> <msg> - one line into the error log.
rem Format: "date time|L#|site|rc=N|message". Best-effort: a logging
rem failure must never mask the real error. Secrets stay out - callers
rem pass site+rc only, never KEY/HOTPASS.
:log
set "ALOGF=%AIYUSPOT_LOG%"
if not defined ALOGF set "ALOGF=%TEMP%\aiyuspot-errors.log"
for %%F in ("%ALOGF%") do if %%~zF gtr 102400 move /y "%ALOGF%" "%ALOGF%.old" >nul 2>&1
>>"%ALOGF%" echo %DATE% %TIME%^|%~1^|%~2^|rc=%~3^|%~4
exit /b 0

rem ------------------------------------------------------------
:fail
if "%CLI_MODE%"=="0" pause
call :hold 1
exit /b 1

rem ------------------------------------------------------------
rem :hold <rc> - keep our own UAC-relaunched window alive long enough to
rem read the result. Success = 8 s auto-close (any key skips); failure =
rem real pause - the error is in this window.
rem The rc is ALSO written to a handshake file BEFORE pausing: the
rem parent's Start-Process -Wait proved unreliable across the UAC
rem boundary (child exited, waiter never noticed - verified via the
rem process tree), so the parent polls this file instead.
:hold
if not defined ELEV_FLAG exit /b 0
>"%TEMP%\aiyuspot-elev-rc" echo %~1
if "%~1"=="0" (timeout /t 8 >nul) else pause
exit /b 0

rem ------------------------------------------------------------
rem :waitelev - parent side of the handshake: poll for the elevated
rem child's rc file (written by :hold). 900 ticks x 2 s = 30 min cap -
rem an in-child kernel build can legitimately run that long.
:waitelev
set "ERC="
set /a ETICK=0
:waitelev_loop
if exist "%TEMP%\aiyuspot-elev-rc" (
  set /p ERC=<"%TEMP%\aiyuspot-elev-rc"
  goto waitelev_done
)
set /a ETICK+=1
if %ETICK% gtr 900 goto waitelev_done
timeout /t 2 /nobreak >nul
goto waitelev_loop
:waitelev_done
del "%TEMP%\aiyuspot-elev-rc" 2>nul
if not defined ERC (
  echo WARNING: no result from the elevated run within 30 min.
  set "ERC=1"
)
echo Elevated run finished with exit code %ERC%
exit /b %ERC%
