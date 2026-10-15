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
rem    wifi-control.bat driver         Build/install AIC8800 driver (TX1U)
rem    wifi-control.bat kernel         Build/install custom WSL2 kernel
rem    wifi-control.bat reset          Destructive PnP recovery (RT73, asks YES)
rem    wifi-control.bat help           Show this usage
rem
rem  Requires: usbipd-win, a WSL2 distro named kali-linux.
rem  Self-elevates via UAC for bind/reset operations.
rem  Portable: resolves its own path via %%~dp0 + wslpath.
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

if /i "%~1"=="help" goto help
if /i "%~1"=="/?" goto help
if /i "%~1"=="-h" goto help

if /i "%~1"=="default" (
  set "CLI_MODE=1"
  set "SSID=%DEFAULT_SSID%"
  set "MODE=wpa2"
  set "KEY=%DEFAULT_WPA2KEY%"
  echo Note: using public default credentials - pass 'wpa2 SSID PASS' for custom ones.
  goto start
)
if /i "%~1"=="open" (
  set "CLI_MODE=1"
  set "SSID=%~2"
  if not defined SSID set "SSID=%DEFAULT_SSID%"
  set "MODE=open"
  set "KEY="
  goto start
)
if /i "%~1"=="wep" (
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
)
if /i "%~1"=="wpa2" (
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
)
if /i "%~1"=="stop" (
  set "CLI_MODE=1"
  goto stop
)
if /i "%~1"=="reset" (
  set "CLI_MODE=1"
  goto reset
)
if /i "%~1"=="check" (
  set "CLI_MODE=1"
  goto check
)
if /i "%~1"=="driver" (
  set "CLI_MODE=1"
  goto driver
)
if /i "%~1"=="kernel" (
  set "CLI_MODE=1"
  goto kernel
)
if not "%~1"=="" (
  echo Unknown command: %~1
  echo Run '%~nx0 help' for usage.
  exit /b 2
)

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
  echo Requesting administrator rights for USB device binding...
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
  exit /b
)

rem --- Preflight: verify prerequisites before touching hardware ---
if not exist "%USBIPD%" (
  echo ERROR: usbipd-win not found at:
  echo   %USBIPD%
  echo Install it: https://github.com/dorssel/usbipd-win/releases
  goto fail
)
rem 'wsl -l -q' emits UTF-16 which findstr can't match - probe directly.
wsl.exe -d %DISTRO% -u root -- true >nul 2>&1
if errorlevel 1 (
  echo ERROR: WSL distro '%DISTRO%' not found or not startable.
  echo Install it: wsl --install -d %DISTRO%
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
  goto fail
)
set "HOTSPOT=%WSLDIR%/kali/kali-wsl-hotspot.sh"

echo Starting USB monitor driver...
sc.exe start VBoxUSBMon >nul 2>&1

echo Detecting WiFi adapter...
set "HWID="
set "FOUND=0"
for %%H in (148f:2573 3625:0110 a69c:5721) do (
  "%USBIPD%" list | findstr /c:"%%H" >nul && (
    set /a FOUND+=1
    if not defined HWID set "HWID=%%H"
  )
)
if not defined HWID (
  echo No supported WiFi adapter found.
  echo.
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\check-adapters.ps1"
  goto fail
)
if !FOUND! gtr 1 echo Note: !FOUND! supported adapters detected - using the first match.
set "ADAPT=Unknown adapter"
if "%HWID%"=="148f:2573" set "ADAPT=Ralink RT73"
if "%HWID%"=="3625:0110" set "ADAPT=TP-Link TX1U Nano"
if "%HWID%"=="a69c:5721" set "ADAPT=TP-Link TX1U (storage mode)"
echo Found %ADAPT% [%HWID%]

rem Clear stale driver state first: a crashed previous session can leave a
rem wedged ghost usb device (driver remove-path deadlock) that blocks new
rem enumeration - rmmod releases it before we attach anything.
wsl.exe -d %DISTRO% -u root -- sh -c "rmmod aic8800_fdrv aic_load_fw rt73usb 2>/dev/null; true"

echo Binding USB adapter...
"%USBIPD%" bind --force --hardware-id %HWID% >nul 2>&1

echo Resetting USB adapter...
"%USBIPD%" detach --hardware-id %HWID% >nul 2>&1
timeout /t 2 /nobreak >nul
"%USBIPD%" attach --wsl --hardware-id %HWID%
if errorlevel 1 (
  echo.
  echo Attach failed. Next step: unplug and replug the adapter, or run
  echo   wifi-control.bat check
  set "FAIL=1"
  goto startdone
)
timeout /t 3 /nobreak >nul

if "%HWID%"=="148f:2573" (
  echo Preparing RT73 firmware environment...
  rem Disable the init-namespace udev stub that aborts pending firmware
  rem requests in ~1ms, and stage rt73.bin into the initns /lib/firmware
  rem so a fresh machine does not depend on fwserve alone.
  wsl.exe -d %DISTRO% -u root -- sh -c "cd /lib/firmware 2>/dev/null && tar cf - rt73.bin 2>/dev/null" | wsl.exe --system -u root -e sh -c "P=$(pidof systemd-udevd | cut -d' ' -f1); P=${P:-1}; nsenter -m -t $P sh -c 'mkdir -p /lib/firmware && tar xf - -C /lib/firmware' 2>/dev/null; nsenter -m -t $P sh -c 'mv /usr/lib/udev/rules.d/50-firmware.rules /usr/lib/udev/rules.d/50-firmware.rules.disabled 2>/dev/null || true'"
  echo Loading RT73 firmware helper...
  wsl.exe -d %DISTRO% -u root -- sh -c "echo 1 > /proc/sys/kernel/firmware_config/force_sysfs_fallback; pkill -x fwserve 2>/dev/null; nohup /usr/local/bin/fwserve ^& rmmod rt73usb rt2x00usb rt2x00lib 2>/dev/null; modprobe rt73usb; sleep 3"
) else (
  echo Staging AIC8800 firmware into WSL kernel namespace...
  rem Kernel request_firmware reads /lib/firmware in the VM init mount
  rem namespace, not the distro fs, so stage blobs there via nsenter.
  rem Also neutralize the init-namespace udev stub that writes loading=-1
  rem to every pending firmware request within ~1ms - 50-firmware.rules.
  wsl.exe -d %DISTRO% -u root -- sh -c "cd /lib/firmware/aic8800DC 2>/dev/null && tar cf - ." | wsl.exe --system -u root -e sh -c "P=$(pidof systemd-udevd | cut -d' ' -f1); P=${P:-1}; nsenter -m -t $P sh -c 'mkdir -p /lib/firmware && tar xf - -C /lib/firmware'; nsenter -m -t $P sh -c 'mv /usr/lib/udev/rules.d/50-firmware.rules /usr/lib/udev/rules.d/50-firmware.rules.disabled 2>/dev/null || true'"
  echo Starting firmware helper for AIC8800...
  wsl.exe -d %DISTRO% -u root -- sh -c "echo 1 > /proc/sys/kernel/firmware_config/force_sysfs_fallback; pkill -x fwserve 2>/dev/null; nohup /usr/local/bin/fwserve ^& sleep 1"
  if "%HWID%"=="a69c:5721" (
    rem usb_modeswitch needs usb-storage to claim the interface first -
    rem without it the EJECT sequence times out (error -7).
    echo Switching adapter to WiFi mode...
    wsl.exe -d %DISTRO% -u root -- sh -c "modprobe usb-storage uas 2>/dev/null; sleep 2; usb_modeswitch -v 0xa69c -p 0x5721 -K 2>/dev/null; sleep 3"
  )
  echo Attaching adapter in WiFi mode...
  "%USBIPD%" bind --force --hardware-id 3625:0110 >nul 2>&1
  "%USBIPD%" detach --hardware-id 3625:0110 >nul 2>&1
  "%USBIPD%" attach --wsl --hardware-id 3625:0110
  if errorlevel 1 (
    echo.
    echo WiFi-mode attach failed. Next step: unplug and replug the TX1U,
    echo   then run wifi-control.bat check
    set "FAIL=1"
    goto startdone
  )
  timeout /t 3 /nobreak >nul
  set "HWID=3625:0110"
  wsl.exe -d %DISTRO% -u root -- sh -c "modprobe aic_load_fw 2>/dev/null; sleep 1; modprobe aic8800_fdrv; sleep 2"
)
timeout /t 2 /nobreak >nul

echo Starting WiFi: %SSID% [%MODE%]...
wsl.exe -d %DISTRO% -u root -- bash "%HOTSPOT%" "%SSID%" "%MODE%" "%KEY%"
if errorlevel 1 (
  echo Failed to start WiFi. Next step: wifi-control.bat check
  set "FAIL=1"
) else (
  if "%MODE%"=="open" echo WiFi started: %SSID% ^(Open AP^)
  if "%MODE%"=="wep" echo WiFi started: %SSID% ^(WEP key: %KEY%^)
  if "%MODE%"=="wpa2" echo WiFi started: %SSID% ^(WPA2 passphrase set^)
)

:startdone
if "%CLI_MODE%"=="0" pause
exit /b %FAIL%

rem ------------------------------------------------------------
:stop
cls
echo Stopping WiFi services...
wsl.exe -d %DISTRO% -u root -- sh -c "pkill -x hostapd-wep 2>/dev/null; pkill -x hostapd 2>/dev/null; pkill -x dnsmasq 2>/dev/null; pkill -x fwserve 2>/dev/null"
echo Detaching USB adapter...
for %%H in (148f:2573 3625:0110 a69c:5721) do "%USBIPD%" detach --hardware-id %%H >nul 2>&1
echo Terminating the %DISTRO% distro ^(all WSL sessions in it^)...
wsl.exe --terminate %DISTRO%
echo WiFi stopped.
if "%CLI_MODE%"=="0" pause
exit /b 0

rem ------------------------------------------------------------
:reset
cls
echo Command: %COMMAND%
echo.
echo  WARNING: reset is DESTRUCTIVE and RT73-only.
echo   - Purges USB device registry entries ^(SYSTEM level^)
echo   - Wipes ALL usbipd-win device bindings on this machine
echo   - Use only for wedged PnP states ^(Code 19^)
echo.
set "CONFIRM="
set /p "CONFIRM=Type YES to continue: "
if /i not "%CONFIRM%"=="YES" (
  echo Cancelled.
  if "%CLI_MODE%"=="0" (pause & goto menu)
  exit /b 1
)
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator rights for adapter reset...
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
  exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\reset-rt73.ps1"
if "%CLI_MODE%"=="0" pause
exit /b 0

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
if errorlevel 1 (
  echo Driver install failed. If it reported 'Kernel build tree missing',
  echo run 'wifi-control.bat kernel' first.
  set "FAIL=1"
)
if "%CLI_MODE%"=="0" pause
exit /b %FAIL%

rem ------------------------------------------------------------
:kernel
cls
echo Command: %COMMAND%
echo.
echo Building custom WSL2 kernel with rt73usb inside Kali WSL...
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
if errorlevel 1 (
  echo Kernel build failed; check the output above.
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
echo   wifi-control.bat driver       Build AIC8800 driver (TX1U; needs kernel tree)
echo   wifi-control.bat kernel       Build custom WSL2 kernel (RT73 + TX1U headers)
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
:fail
if "%CLI_MODE%"=="0" pause
exit /b 1
