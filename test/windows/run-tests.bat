@echo off
rem aiyuspot - batch test harness (no dependencies)
rem Asserts exit codes and stdout substrings for wifi-control.bat's
rem non-elevated surface: dispatch, validation, reset gate.
setlocal EnableDelayedExpansion
cd /d "%~dp0..\.."
set "BAT=wifi-control.bat"
set PASS=0
set FAILN=0

call :expect_code "help exits 0" 0 %BAT% help
call :expect_code "bogus verb exits 2" 2 %BAT% bogus
call :expect_out "bogus prints hint" "Unknown command" %BAT% bogus
call :expect_code "wep 3-char key rejected" 2 %BAT% wep net abc
call :expect_code "wep 10-char key rejected" 2 %BAT% wep net abcdefghij
call :expect_code "wpa2 short pass rejected" 2 %BAT% wpa2 net short
call :expect_code "wpa2 64-char pass rejected" 2 %BAT% wpa2 net aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
call :expect_out "wep warns on default key" "public default" %BAT% wep net
echo n | call %BAT% reset > %TEMP%\aiyu-reset.out 2>&1
findstr /c:"Cancelled" %TEMP%\aiyu-reset.out >nul
if errorlevel 1 (call :fail "reset cancel prints Cancelled") else (call :ok "reset cancel prints Cancelled")
del %TEMP%\aiyu-reset.out >nul 2>&1

echo.
echo ============================
echo  PASS: %PASS%  FAIL: %FAILN%
echo ============================
if %FAILN% gtr 0 exit /b 1
exit /b 0

rem ---- helpers ----
:expect_code
set "name=%~1"
set "want=%~2"
shift & shift
call %1 %2 %3 %4 %5 %6 >nul 2>&1
if !errorlevel!==%want% (call :ok "%name%") else (call :fail "%name% (want %want%, got !errorlevel!)")
exit /b 0

:expect_out
set "name=%~1"
set "needle=%~2"
shift & shift
call %1 %2 %3 %4 %5 %6 > %TEMP%\aiyu-t.out 2>&1
findstr /c:"%needle%" %TEMP%\aiyu-t.out >nul
if errorlevel 1 (call :fail "%name% (missing '%needle%')") else (call :ok "%name%")
del %TEMP%\aiyu-t.out >nul 2>&1
exit /b 0

:ok
set /a PASS+=1
echo   PASS  %~1
exit /b 0

:fail
set /a FAILN+=1
echo   FAIL  %~1
exit /b 0
