<#
.SYNOPSIS
    aiyuspot USB adapter recovery - purge corrupted Windows PnP state.
.DESCRIPTION
    Five-step recovery: detach/unbind via usbipd, remove device nodes,
    delete the Enum registry key via a SYSTEM scheduled task, restart the
    usbipd service, rescan hardware and report the adapter state.
    Requires elevation (self-elevated by wifi-control.bat).
    Targets the adapter given via -HwId (VID:PID); defaults to the RT73
    id this tool was originally built for.
.NOTES
    Part of: https://github.com/teeprakorn1/aiyuspot
.LINK
    See README.md "Troubleshooting".

    WARNING - DESTRUCTIVE RECOVERY OPERATION
    This script deletes registry keys under HKLM\SYSTEM\CurrentControlSet\Enum
    via a scheduled task running as SYSTEM and clears usbipd device records.
    Use ONLY when the adapter is stuck in a broken driver state (e.g. Code 19,
    "device busy (exported)", missing after reboot, dead USB I/O). Do not run
    as routine.
#>
param([string]$HwId = '148f:2573')
$ErrorActionPreference = 'Continue'
$usbipd = 'C:\Program Files\usbipd-win\usbipd.exe'
$fail = 0
$pat = 'VID_' + $HwId.Split(':')[0].ToUpper() + '&PID_' + $HwId.Split(':')[1].ToUpper()

function Step-Result {
    param([string]$Name, [bool]$Ok, [string]$Hint = '')
    if ($Ok) { return }
    $script:fail = 1
    Write-Host "  step failed: $Name" -ForegroundColor Red
    if ($Hint) { Write-Host "    $Hint" -ForegroundColor DarkGray }
}

Write-Host "Resetting adapter state for $HwId..." -ForegroundColor Cyan
Write-Host ''

# The scheduled-task registry purge needs elevation - refuse early
# instead of failing every step silently.
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'ERROR: reset must run elevated - launch it from wifi-control.bat.' -ForegroundColor Red
    exit 1
}

Write-Host '[1/5] Detaching and unbinding...' -ForegroundColor Yellow
if (Test-Path -LiteralPath $usbipd) {
    & $usbipd detach --hardware-id $HwId | Out-Null
    & $usbipd unbind --hardware-id $HwId | Out-Null
} else {
    Write-Host "  usbipd.exe not found at $usbipd - skipping detach/unbind" -ForegroundColor DarkYellow
}

Write-Host '[2/5] Removing device node...' -ForegroundColor Yellow
Get-PnpDevice | Where-Object { $_.InstanceId -match $pat } | ForEach-Object {
    pnputil /remove-device $_.InstanceId | Out-Null
    Step-Result 'pnputil /remove-device' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE for $($_.InstanceId)"
}

Write-Host '[3/5] Purging registry state (SYSTEM task)...' -ForegroundColor Yellow
try {
    $action = New-ScheduledTaskAction -Execute 'reg.exe' -Argument "delete `"HKLM\SYSTEM\CurrentControlSet\Enum\USB\$pat`" /f"
    Register-ScheduledTask -TaskName 'FixUsbEnum' -Action $action -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName 'FixUsbEnum'
    # Wait for the SYSTEM reg delete to finish instead of a fixed sleep -
    # unregistering while Running can fail and leave an orphan task.
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $st = (Get-ScheduledTask -TaskName 'FixUsbEnum' -ErrorAction SilentlyContinue).State
    } while ($st -eq 'Running' -and (Get-Date) -lt $deadline)
    $info = Get-ScheduledTaskInfo -TaskName 'FixUsbEnum'
    Step-Result 'FixUsbEnum registry purge' ($info.LastTaskResult -eq 0) "LastTaskResult=$($info.LastTaskResult)"
} catch {
    Step-Result 'FixUsbEnum registry purge' $false $_.Exception.Message
} finally {
    Unregister-ScheduledTask -TaskName 'FixUsbEnum' -Confirm:$false -ErrorAction SilentlyContinue
}
Remove-Item 'HKLM:\SOFTWARE\usbipd-win\Devices\*' -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '[4/5] Restarting usbipd service...' -ForegroundColor Yellow
try { Restart-Service usbipd -Force -ErrorAction Stop }
catch { Step-Result 'Restart-Service usbipd' $false $_.Exception.Message }
Start-Sleep -Seconds 2

Write-Host '[5/5] Rescanning hardware...' -ForegroundColor Yellow
pnputil /scan-devices | Out-Null
Step-Result 'pnputil /scan-devices' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
Start-Sleep -Seconds 4

Write-Host ''
$dev = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match $pat }
if ($dev) {
    Write-Host "Adapter re-detected: $($dev.FriendlyName) [$($dev.Status)]" -ForegroundColor Green
    if ($dev.Status -eq 'Error') {
        Write-Host "Still in error state - unplug and replug the $HwId adapter." -ForegroundColor Red
    }
} else {
    Write-Host "Adapter $HwId not on the bus - unplug and replug it now." -ForegroundColor Yellow
}
Write-Host ''
if ($fail) {
    Write-Host 'Reset finished WITH FAILURES - see the step errors above.' -ForegroundColor Red
    exit 1
}
Write-Host "Reset complete. Replug the $HwId adapter if needed, then start the hotspot from the menu." -ForegroundColor Cyan
exit 0
