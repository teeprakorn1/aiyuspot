<#
.SYNOPSIS
    aiyuspot RT73 recovery - purge corrupted Windows PnP state for VID_148F&PID_2573.
.DESCRIPTION
    Five-step recovery: detach/unbind via usbipd, remove device nodes,
    delete the Enum registry key via a SYSTEM scheduled task, restart the
    usbipd service, rescan hardware and report the adapter state.
    Requires elevation (self-elevated by wifi-control.bat).
.NOTES
    Part of: https://github.com/teeprakorn1/aiyuspot
.LINK
    See README.md "Troubleshooting".

    WARNING - DESTRUCTIVE RECOVERY OPERATION
    This script deletes registry keys under HKLM\SYSTEM\CurrentControlSet\Enum
    via a scheduled task running as SYSTEM and clears usbipd device records.
    Use ONLY when the adapter is stuck in a broken driver state (e.g. Code 19,
    "device busy (exported)", missing after reboot). Do not run as routine.
#>
$ErrorActionPreference = 'SilentlyContinue'
$usbipd = 'C:\Program Files\usbipd-win\usbipd.exe'

Write-Host 'Resetting RT73 adapter state...' -ForegroundColor Cyan
Write-Host ''

Write-Host '[1/5] Detaching and unbinding...' -ForegroundColor Yellow
& $usbipd detach --hardware-id 148f:2573 | Out-Null
& $usbipd unbind --hardware-id 148f:2573 | Out-Null

Write-Host '[2/5] Removing device node...' -ForegroundColor Yellow
Get-PnpDevice | Where-Object { $_.InstanceId -match 'VID_148F' } | ForEach-Object {
    pnputil /remove-device $_.InstanceId | Out-Null
}

Write-Host '[3/5] Purging registry state (SYSTEM task)...' -ForegroundColor Yellow
$action = New-ScheduledTaskAction -Execute 'reg.exe' -Argument 'delete "HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_148F&PID_2573" /f'
Register-ScheduledTask -TaskName 'FixRT73Enum' -Action $action -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'FixRT73Enum'
Start-Sleep -Seconds 3
Unregister-ScheduledTask -TaskName 'FixRT73Enum' -Confirm:$false
Remove-Item 'HKLM:\SOFTWARE\usbipd-win\Devices\*' -Recurse -Force

Write-Host '[4/5] Restarting usbipd service...' -ForegroundColor Yellow
Restart-Service usbipd -Force
Start-Sleep -Seconds 2

Write-Host '[5/5] Rescanning hardware...' -ForegroundColor Yellow
pnputil /scan-devices | Out-Null
Start-Sleep -Seconds 4

Write-Host ''
$dev = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_148F' }
if ($dev) {
    Write-Host "Adapter re-detected: $($dev.FriendlyName) [$($dev.Status)]" -ForegroundColor Green
    if ($dev.Status -eq 'Error') {
        Write-Host 'Still in error state - unplug and replug the RT73 adapter.' -ForegroundColor Red
    }
} else {
    Write-Host 'Adapter not on the bus - unplug and replug the RT73 now.' -ForegroundColor Yellow
}
Write-Host ''
Write-Host 'Reset complete. Run Start WPA2 AP to test.' -ForegroundColor Cyan
