<#
.SYNOPSIS
    Interactive arrow-key menu for aiyuspot (USB WiFi hotspot via Kali WSL2 + usbipd).
.DESCRIPTION
    Two-level menu: main categories -> submenus -> action confirmation
    (Enter = run, Esc = back). Returns to the menu after each action.
    Custom WEP/WPA2/Open items prompt for SSID and key with project
    defaults and validate lengths before launching.
.NOTES
    Version: 0.2.0
    Part of: https://github.com/teeprakorn1/aiyuspot
#>
$ErrorActionPreference = 'Stop'
$batch = Join-Path $PSScriptRoot 'wifi-control.bat'

# --- Menu tree ---------------------------------------------------------------
$menu = @(
    @{ Name = 'Start hotspot';  Desc = 'Pick the security mode';  Sub = @(
        @{ Name = 'WPA2-PSK (recommended)';     Desc = 'Secure - SSID aiyuspot / passphrase aiyuspot';      Cmd = 'wpa2' },
        @{ Name = 'WEP (custom key)';           Desc = 'Legacy, INSECURE - key must be 5 or 13 chars';      Cmd = 'wep' },
        @{ Name = 'WEP (default key)';          Desc = 'Legacy, INSECURE - SSID aiyuspot / key aiyu1';      Cmd = 'default-wep' },
        @{ Name = 'Open (insecure)';            Desc = 'No password, unencrypted - temporary testing only'; Cmd = 'open' }
    )},
    @{ Name = 'Tools';          Desc = 'Status and stop';         Sub = @(
        @{ Name = 'Check adapters'; Desc = 'Detect USB adapters, drivers and hotspot state - run this first'; Cmd = 'check' },
        @{ Name = 'Stop WiFi';      Desc = 'Stop hotspot, detach USB, terminate the kali-linux distro';       Cmd = 'stop' }
    )},
    @{ Name = 'Setup';          Desc = 'One-time driver/kernel builds in Kali'; Sub = @(
        @{ Name = 'Build custom kernel';   Desc = 'WSL2 kernel with rt73usb - RT73 driver + TX1U build headers (~20-40 min)'; Cmd = 'kernel' },
        @{ Name = 'Install TX1U driver';   Desc = 'Build AIC8800 driver for Archer TX1U Nano (needs kernel tree)';            Cmd = 'driver' }
    )},
    @{ Name = 'Reset adapter state (destructive)'; Desc = 'Wipes ALL usbipd bindings + registry purge, RT73 only - asks YES'; Cmd = 'reset' },
    @{ Name = 'Exit';  Desc = 'Close the menu';  Cmd = '' }
)

# --- Input helpers ------------------------------------------------------------
function Read-KeyWithDefault {
    param([string]$Prompt, [string]$Default)
    $in = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($in)) { return $Default }
    return $in
}

function Read-ValidatedKey {
    param([string]$Prompt, [string]$Default, [string]$Mode)
    while ($true) {
        $k = Read-KeyWithDefault $Prompt $Default
        $len = $k.Length
        if ($Mode -eq 'wep') {
            if ($len -eq 5 -or $len -eq 13) { return $k }
            Write-Host "  WEP key must be exactly 5 or 13 characters (got $len). Ctrl+C to abort." -ForegroundColor Red
        } else {
            if ($len -ge 8 -and $len -le 63) { return $k }
            Write-Host "  WPA2 passphrase must be 8-63 characters (got $len). Ctrl+C to abort." -ForegroundColor Red
        }
    }
}

function Read-ValidSsid {
    while ($true) {
        $ssid = Read-KeyWithDefault 'SSID' 'aiyuspot'
        if ($ssid.Length -ge 1 -and $ssid.Length -le 32) { return $ssid }
        Write-Host '  SSID must be 1-32 characters. Ctrl+C to abort.' -ForegroundColor Red
    }
}

function Build-Args {
    param([string]$Cmd)
    switch ($Cmd) {
        'wpa2' {
            $ssid = Read-ValidSsid
            $key  = Read-ValidatedKey 'WPA2 passphrase' 'aiyuspot' 'wpa2'
            return @{ Args = @('wpa2', $ssid, $key); Show = "$batch wpa2 `"$ssid`" `"$key`"" }
        }
        'wep' {
            $ssid = Read-ValidSsid
            $key  = Read-ValidatedKey 'WEP key' 'aiyu1' 'wep'
            return @{ Args = @('wep', $ssid, $key); Show = "$batch wep `"$ssid`" `"$key`"" }
        }
        'default-wep' {
            return @{ Args = @('wep', 'aiyuspot', 'aiyu1'); Show = "$batch wep aiyuspot aiyu1" }
        }
        'open' {
            $ssid = Read-ValidSsid
            return @{ Args = @('open', $ssid); Show = "$batch open `"$ssid`"" }
        }
        'reset' {
            Write-Host ''
            Write-Host '  DESTRUCTIVE: wipes ALL usbipd bindings + purges device registry.' -ForegroundColor Red
            Write-Host '  RT73 only. You will be asked to type YES again inside the command.' -ForegroundColor Red
            return @{ Args = @('reset'); Show = "$batch reset" }
        }
        default {
            return @{ Args = @($Cmd); Show = "$batch $Cmd" }
        }
    }
}

# --- Rendering ----------------------------------------------------------------
function Show-Menu {
    param([array]$Items, [int]$Index, [string]$Title)
    Clear-Host
    Write-Host '========================================' -ForegroundColor DarkCyan
    Write-Host '  aiyuspot - USB WiFi Hotspot' -ForegroundColor Yellow
    Write-Host '  Version 0.2.0' -ForegroundColor DarkYellow
    Write-Host "  $Title" -ForegroundColor Gray
    Write-Host '========================================' -ForegroundColor DarkCyan

    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($i -eq $Index) {
            Write-Host (" > " + $Items[$i].Name) -ForegroundColor Black -BackgroundColor Cyan
            Write-Host ("       " + $Items[$i].Desc) -ForegroundColor DarkGray
        } else {
            Write-Host ("   " + $Items[$i].Name) -ForegroundColor White
        }
    }
}

# --- Seams for tests (mock these with Pester / reassign in tests) ---
function Read-MenuKey { [Console]::ReadKey($true) }
function Invoke-WifiControl {
    param([string[]]$A)
    & $script:batch @A
    return $LASTEXITCODE
}

# --- Menu engine ---------------------------------------------------------------
# Pick an item from a list; returns the item, or $null on Esc/Back.
function Select-Item {
    param([array]$Items, [string]$Title, [switch]$WithBack)
    $index = 0
    $all = @($Items)
    if ($WithBack) { $all += @{ Name = 'Back'; Desc = 'Return to the previous menu' } }
    while ($true) {
        Show-Menu -Items $all -Index $index -Title $Title
        Write-Host ''
        Write-Host 'Up/Down = move, Enter = select, Esc/Backspace = back' -ForegroundColor DarkYellow
        try { $key = Read-MenuKey }
        catch {
            Write-Host 'Interactive console required - run wifi-control.bat <command> instead.' -ForegroundColor Red
            exit 1
        }
        switch ($key.Key) {
            'UpArrow'   { $index = ($index - 1 + $all.Count) % $all.Count }
            'DownArrow' { $index = ($index + 1) % $all.Count }
            'Escape'    { return $null }
            'Backspace' { return $null }
            'Enter'     { if ($all[$index].Name -eq 'Back') { return $null } else { return $all[$index] } }
        }
    }
}

# Skip the interactive loop when dot-sourced (Pester tests import the
# functions/menu data without running the TUI).
if ($MyInvocation.InvocationName -eq '.') { return }

try { [Console]::CursorVisible = $false } catch {}

try {
    while ($true) {
        # --- Level 1: category ---
        $cat = Select-Item -Items $menu -Title 'Select a category.'
        if ($null -eq $cat) { exit 0 }
        if ($cat.Name -eq 'Exit') { exit 0 }

        # --- Level 2: action (submenu if present) ---
        if ($cat.Sub) {
            $sel = Select-Item -Items $cat.Sub -Title $cat.Name -WithBack
            if ($null -eq $sel) { continue }
        } else {
            $sel = $cat
        }

        # --- Confirm ---
        Clear-Host
        $built = Build-Args -Cmd $sel.Cmd
        if ($null -eq $built) { Read-Host 'Aborted - press Enter to go back'; continue }

        Write-Host ''
        Write-Host "Action:  $($sel.Name) - $($sel.Desc)" -ForegroundColor Cyan
        Write-Host "Command: $($built.Show)" -ForegroundColor Green
        Write-Host ''
        Write-Host '  Enter          = run this command' -ForegroundColor DarkYellow
        Write-Host '  Esc/Backspace  = cancel, back to the menu' -ForegroundColor DarkYellow
        try { $confirm = Read-MenuKey }
        catch { exit 1 }
        if ($confirm.Key -ne 'Enter') { continue }

        Write-Host ''
        $code = Invoke-WifiControl $built.Args
        Write-Host ''
        if ($code -eq 0) {
            Write-Host 'Done - command finished successfully.' -ForegroundColor Green
        } else {
            Write-Host "Command failed (exit $code) - scroll up for the error." -ForegroundColor Red
        }
        Read-Host 'Press Enter to return to the menu'
    }
} finally {
    try { [Console]::CursorVisible = $true } catch {}
}
