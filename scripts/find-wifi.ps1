<#
.SYNOPSIS
    Discover USB Wi-Fi candidates NOT registered in adapters.conf.
    Prints "<busid> <vid:pid> <tier>" lines on stdout for wifi-control.bat.
.DESCRIPTION
    tier 1 = device is in the Windows PnP 'Net' class AND has a Wi-Fi-ish
             name  -> reasonably safe to attach automatically.
    tier 2 = Wi-Fi keyword in the usbipd description only (PnP match
             missing, e.g. stub-bound already) -> caller must confirm.
    Warnings (uplink etc.) go to the warning stream, not stdout -
    Write-Host would land in the caller's `>`-redirected file.
    Honors $env:AIYUSPOT_USBIPD for tests.
#>
$ErrorActionPreference = 'Continue'
$usbipd = if ($env:AIYUSPOT_USBIPD) { $env:AIYUSPOT_USBIPD } else { 'C:\Program Files\usbipd-win\usbipd.exe' }
$repo = Split-Path $PSScriptRoot -Parent

# --- registered ids (column 1 of adapters.conf) ---
$known = @{}
Get-Content "$repo\adapters.conf" | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' } | ForEach-Object {
    ($_.Split('|')[0] -split ',') | ForEach-Object { $known[$_.Trim().ToLower()] = $true }
}

# --- candidate rows: usbipd state JSON first, text table fallback ---
$cands = @()
try {
    $j = & $usbipd state 2>$null | ConvertFrom-Json -ErrorAction Stop
    foreach ($d in $j.Devices) {
        if ($d.InstanceId -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') {
            $cands += [pscustomobject]@{ BusId = $d.BusId; Id = ("{0}:{1}" -f $Matches[1], $Matches[2]).ToLower(); Desc = [string]$d.Description }
        }
    }
} catch { }
if (-not $cands) {
    & $usbipd list 2>$null | ForEach-Object {
        if ($_ -match '^\s*(\S+)\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s+(.*?)\s{2,}(\S.*)$') {
            $cands += [pscustomobject]@{ BusId = $Matches[1]; Id = $Matches[2].ToLower(); Desc = $Matches[3] }
        }
    }
}
if (-not $cands) { exit 0 }

# --- PnP 'Net' class map (VID:PID -> FriendlyName) ---
$netPnp = @{}
try {
    Get-PnpDevice -Class Net -ErrorAction Stop | ForEach-Object {
        if ($_.InstanceId -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') {
            $netPnp[("{0}:{1}" -f $Matches[1], $Matches[2]).ToLower()] = $_.FriendlyName
        }
    }
} catch { }

# --- host uplink interface (attach would kill host internet) ---
$uplink = ''
try { $uplink = (Get-NetRoute '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1).InterfaceAlias } catch { }

$wifi = 'Wi-?Fi|Wireless|802\.11|WLAN'
foreach ($c in $cands) {
    if ($known.ContainsKey($c.Id)) { continue }
    if (-not $c.BusId -or $c.BusId -eq '-') { continue }   # persisted/unpluggable rows can't attach
    $tier = 0
    if ($netPnp.ContainsKey($c.Id) -and (($netPnp[$c.Id] -match $wifi) -or ($c.Desc -match $wifi))) { $tier = 1 }
    elseif ($c.Desc -match $wifi) { $tier = 2 }
    if ($tier -eq 0) { continue }
    if ($uplink -and ($netPnp[$c.Id] -eq $uplink -or $c.Desc -match [regex]::Escape($uplink))) {
        Write-Warning "candidate looks like the host uplink ($uplink) - attaching kills host internet"
    }
    Write-Output "$($c.BusId) $($c.Id) $tier"
}
exit 0
