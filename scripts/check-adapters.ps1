<#
.SYNOPSIS
    aiyuspot device health report - USB adapters, PnP state, services, Kali WSL state.
.DESCRIPTION
    Adapter profiles come from adapters.conf (repo root) - one registry line
    per supported profile. Matches `usbipd list` output against every id in
    column 1, reports Windows PnP status, usbipd/VBoxUSBMon services, and
    inside Kali: USB visibility, loaded modules, wireless interfaces,
    hostapd/dnsmasq status.
    Read-only - requires no elevation.
.NOTES
    Part of: https://github.com/teeprakorn1/aiyuspot
#>
$Usbipd = if ($env:AIYUSPOT_USBIPD) { $env:AIYUSPOT_USBIPD } else { 'C:\Program Files\usbipd-win\usbipd.exe' }
$Distro = 'kali-linux'

# profiles[id] = @{ Name; Module; Status; Note } - generated from adapters.conf
$repo = Split-Path $PSScriptRoot -Parent
$profiles = [ordered]@{}
$allIds = @()
$allMods = @()
Get-Content "$repo\adapters.conf" | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' } | ForEach-Object {
    $f = $_ -split '\|'
    $name = $f[2]; $mod = $f[3]; $status = $f[11]; $note = $f[12]
    if ($mod -ne '-') { $allMods += $mod }
    foreach ($id in ($f[0] -split ',')) {
        $id = $id.Trim().ToLower()
        $allIds += $id
        $profiles[$id] = @{ Name = $name; Module = $mod; Status = $status; Note = $note }
    }
}

Write-Host '=== WiFi Adapter Check ===' -ForegroundColor Cyan
Write-Host ''

Write-Host '-- usbipd devices --' -ForegroundColor Yellow
try { $list = & $Usbipd list 2>$null } catch { $list = @() }
$supported = @()
foreach ($hwid in $profiles.Keys) {
    $line = $list | Where-Object { $_ -match [regex]::Escape($hwid) } | Select-Object -First 1
    if ($line) {
        $busid = ($line.Trim() -split '\s+')[0]
        $state = 'Present'
        if ($line -match 'Not shared') { $state = 'Present' }
        elseif ($line -match 'Attached') { $state = 'Attached to WSL' }
        elseif ($line -match 'Shared') { $state = 'Shared (bound)' }
        $p = $profiles[$hwid]
        Write-Host ("  [{0}] {1}  busid={2}  state={3}" -f $hwid, $p.Name, $busid, $state) -ForegroundColor Green
        Write-Host ("       module={0}  | {1}" -f $p.Module, $p.Note) -ForegroundColor DarkGray
        if ($p.Status -eq 'noap') {
            Write-Host '       *** no AP mode upstream - cannot host a hotspot ***' -ForegroundColor DarkYellow
        } elseif ($p.Status -eq 'pending') {
            Write-Host '       (support pending real-client verification)' -ForegroundColor DarkGray
        }
        $supported += $hwid
    }
}
if (-not $supported) {
    Write-Host '  No supported USB WiFi adapter found.' -ForegroundColor Red
    Write-Host '  See adapters.conf for the registered VID:PIDs (docs/adapters.md).' -ForegroundColor Gray
}

Write-Host ''
Write-Host '-- Windows PnP state --' -ForegroundColor Yellow
$pnpRegex = ($allIds | ForEach-Object { 'VID_{0}&PID_{1}' -f ($_ -split ':') }) -join '|'
$pnp = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
    $_.InstanceId -match $pnpRegex
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
$idRe = ($allIds | ForEach-Object { [regex]::Escape($_) }) -join '|'
$modRe = ($allMods | ForEach-Object { [regex]::Escape($_) }) -join '|'
$wslOut = wsl.exe -d $Distro -u root -- sh -c "echo USB:; lsusb 2>/dev/null | grep -iE '$idRe'; echo MODULES:; lsmod | grep -E '$modRe'; echo IFACE:; ip -br link 2>/dev/null | awk '/^[wW]l/ {print}'; echo AP:; pgrep -x 'hostapd(-wep)?' >/dev/null && echo hostapd running || echo hostapd stopped; pgrep -x dnsmasq >/dev/null && echo dnsmasq running || echo dnsmasq stopped" 2>$null
if ($LASTEXITCODE -eq 0 -and $wslOut) {
    $wslOut | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
} else {
    Write-Host "  $Distro not running (start it via the menu first)." -ForegroundColor Gray
}
Write-Host ''
