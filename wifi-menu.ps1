<#
.SYNOPSIS
    Interactive arrow-key menu for aiyuspot (USB WiFi hotspot via Kali WSL2 + usbipd).
.DESCRIPTION
    Presents a navigable list of actions; on Enter it shows the resolved
    wifi-control.bat command for confirmation, then invokes it.
    Custom WEP/WPA2 items prompt for SSID and key with project defaults.
.NOTES
    Version: 0.1.1
    Part of: https://github.com/teeprakorn1/aiyuspot
#>
$ErrorActionPreference = 'Stop'
$items = @(
    'Start WPA2 AP (recommended)',
    'Start default WEP',
    'Start custom WEP',
    'Start Open AP',
    'Check adapters',
    'Install TX1U driver',
    'Build RT73 kernel',
    'Stop WiFi',
    'Reset adapter state',
    'Exit'
)
$descriptions = @(
    'Secure mode - SSID aiyuspot / passphrase aiyuspot',
    'Legacy mode - SSID aiyuspot / key aiyu1',
    'WEP key must be exactly 5 or 13 characters',
    'For temporary testing only',
    'Detect USB adapters, drivers and hotspot state',
    'Build AIC8800 driver for Archer TX1U Nano in Kali',
    'Compile custom WSL2 kernel with rt73usb (long build)',
    'Stop services and terminate Kali WSL',
    'Fix stuck USB driver state after reboot',
    'Close the menu'
)
$batch = Join-Path $PSScriptRoot 'wifi-control.bat'
$index = 0

try { [Console]::CursorVisible = $false } catch {}
try {
    while ($true) {
        Clear-Host
        Write-Host '========================================' -ForegroundColor DarkCyan
        Write-Host '  aiyuspot - USB WiFi Hotspot' -ForegroundColor Yellow
        Write-Host '  Version 0.1.1' -ForegroundColor DarkYellow
        Write-Host '  Select an action for the wireless hotspot.' -ForegroundColor Gray
        Write-Host '========================================' -ForegroundColor DarkCyan

        for ($i = 0; $i -lt $items.Count; $i++) {
            if ($i -eq $index) {
                Write-Host (" > " + $items[$i]) -ForegroundColor Black -BackgroundColor Cyan
                Write-Host ("     " + $descriptions[$i]) -ForegroundColor Gray
            } else {
                Write-Host ("   " + $items[$i]) -ForegroundColor White
            }
        }

        Write-Host ''
        Write-Host 'Use Up/Down and Enter; Esc = Exit' -ForegroundColor DarkYellow
        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            'UpArrow' { $index = ($index - 1 + $items.Count) % $items.Count }
            'DownArrow' { $index = ($index + 1) % $items.Count }
            'Escape' { exit 0 }
            'Enter' { break }
        }

        if ($key.Key -eq 'Enter') { break }
    }
} catch {
    $index = 0
}

switch ($index) {
    0 {
        $ssid = Read-Host 'SSID [aiyuspot]'
        if ([string]::IsNullOrWhiteSpace($ssid)) { $ssid = 'aiyuspot' }
        $key = Read-Host 'WPA2 passphrase [aiyuspot]'
        if ([string]::IsNullOrWhiteSpace($key)) { $key = 'aiyuspot' }
        $arguments = @('wpa2', $ssid, $key)
        $command = "$($batch) wpa2 `"$ssid`" `"$key`""
    }
    1 {
        $arguments = @('default')
        $command = "$($batch) default"
    }
    2 {
        $ssid = Read-Host 'SSID [aiyuspot]'
        if ([string]::IsNullOrWhiteSpace($ssid)) { $ssid = 'aiyuspot' }
        $key = Read-Host 'WEP key [aiyu1]'
        if ([string]::IsNullOrWhiteSpace($key)) { $key = 'aiyu1' }
        $arguments = @('wep', $ssid, $key)
        $command = "$($batch) wep `"$ssid`" `"$key`""
    }
    3 {
        $arguments = @('open')
        $command = "$($batch) open"
    }
    4 {
        $arguments = @('check')
        $command = "$($batch) check"
    }
    5 {
        $arguments = @('driver')
        $command = "$($batch) driver"
    }
    6 {
        $arguments = @('kernel')
        $command = "$($batch) kernel"
    }
    7 {
        $arguments = @('stop')
        $command = "$($batch) stop"
    }
    8 {
        $arguments = @('reset')
        $command = "$($batch) reset"
    }
    default { exit 0 }
}

Write-Host ''
Write-Host "Command: $command" -ForegroundColor Green
Read-Host 'Press Enter to continue'
& $batch @arguments
exit $LASTEXITCODE
