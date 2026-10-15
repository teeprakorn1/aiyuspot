<#
.SYNOPSIS
    aiyuspot device health report - USB adapters, PnP state, services, Kali WSL state.
.DESCRIPTION
    Detects supported adapters by VID:PID (RT73 148f:2573, TX1U 3625:0110,
    TX1U storage mode a69c:5721) via `usbipd list`, maps each to its Linux
    module, reports Windows PnP status, usbipd/VBoxUSBMon services, and
    inside Kali: USB visibility, loaded modules, wireless interfaces,
    hostapd/dnsmasq status.
    Read-only - requires no elevation.
.NOTES
    Part of: https://github.com/teeprakorn1/aiyuspot
#>
$Usbipd = 'C:\Program Files\usbipd-win\usbipd.exe'
$Distro = 'kali-linux'

$profiles = @{
    '148f:2573' = @{ Name = 'Ralink RT73 USB WiFi'; Module = 'rt73usb'; Note = 'AP ready (WEP/open/WPA2)' }
    '3625:0110' = @{ Name = 'TP-Link Archer TX1U Nano (AIC8800)'; Module = 'aic8800_fdrv'; Note = 'WiFi 6 - client/monitor (AP experimental)' }
    'a69c:5721' = @{ Name = 'TP-Link TX1U storage mode'; Module = '(eject -> 3625:0110)'; Note = 'auto-switch via udev/usb_modeswitch' }
}

Write-Host '=== WiFi Adapter Check ===' -ForegroundColor Cyan
Write-Host ''

Write-Host '-- usbipd devices --' -ForegroundColor Yellow
$list = & $Usbipd list 2>$null
$supported = @()
foreach ($hwid in $profiles.Keys) {
    $line = $list | Where-Object { $_ -match [regex]::Escape($hwid) } | Select-Object -First 1
    if ($line) {
        $busid = ($line -split '\s+')[0]
        $state = 'Present'
        if ($line -match 'Attached') { $state = 'Attached to WSL' }
        elseif ($line -match 'Shared') { $state = 'Shared (bound)' }
        $p = $profiles[$hwid]
        Write-Host ("  [{0}] {1}  busid={2}  state={3}" -f $hwid, $p.Name, $busid, $state) -ForegroundColor Green
        Write-Host ("       module={0}  | {1}" -f $p.Module, $p.Note) -ForegroundColor DarkGray
        $supported += $hwid
    }
}
if (-not $supported) {
    Write-Host '  No supported USB WiFi adapter found.' -ForegroundColor Red
    Write-Host '  Plug in the RT73 (148f:2573) or TX1U (3625:0110 / a69c:5721).' -ForegroundColor Gray
}

Write-Host ''
Write-Host '-- Windows PnP state --' -ForegroundColor Yellow
$pnp = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
    $_.InstanceId -match 'VID_148F&PID_2573|VID_3625&PID_0110|VID_A69C&PID_5721'
}
if ($pnp) {
    foreach ($d in $pnp) {
        $color = if ($d.Status -eq 'OK') { 'Green' } else { 'Red' }
        Write-Host ("  {0}  [{1}]  {2}" -f $d.FriendlyName, $d.Status, $d.InstanceId) -ForegroundColor $color
    }
} else {
    Write-Host '  No matching device nodes.' -ForegroundColor Gray
}

Write-Host ''
Write-Host '-- Services --' -ForegroundColor Yellow
foreach ($svc in 'usbipd', 'VBoxUSBMon') {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if ($s) {
        $color = if ($s.Status -eq 'Running') { 'Green' } else { 'Yellow' }
        Write-Host ("  {0,-12} {1}" -f $s.Name, $s.Status) -ForegroundColor $color
    } else {
        Write-Host ("  {0,-12} not installed" -f $svc) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '-- Kali WSL state --' -ForegroundColor Yellow
$wslOut = wsl.exe -d $Distro -u root -- sh -c "echo USB:; lsusb 2>/dev/null | grep -iE '148f|3625|a69c'; echo MODULES:; lsmod | grep -E 'rt73usb|aic'; echo IFACE:; ip -br link 2>/dev/null | awk '/^[wW]l/ {print}'; echo AP:; pgrep -x hostapd >/dev/null && echo hostapd running || echo hostapd stopped; pgrep -x dnsmasq >/dev/null && echo dnsmasq running || echo dnsmasq stopped" 2>$null
if ($LASTEXITCODE -eq 0 -and $wslOut) {
    $wslOut | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
} else {
    Write-Host "  $Distro not running (start it via the menu first)." -ForegroundColor Gray
}
Write-Host ''
