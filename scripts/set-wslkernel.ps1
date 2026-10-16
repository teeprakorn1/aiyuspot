<#
.SYNOPSIS
    Point %USERPROFILE%\.wslconfig at the aiyuspot custom kernel.
    Backs up to .wslconfig.bak, upserts kernel= under [wsl2].
    Called by `wifi-control.bat` when a kernel switch is confirmed.
.PARAMETER KernelPath
    Windows path to the kernel image (backslashes are doubled for you).
#>
param([string]$KernelPath = 'C:\wsl\wsl-kernel-bzImage')
$ErrorActionPreference = 'Stop'

# Writing kernel= for a missing image bricks every WSL distro on the
# next start - refuse early rather than leave a broken .wslconfig.
if (-not (Test-Path -LiteralPath $KernelPath)) {
    Write-Error "Kernel image not found: $KernelPath - run 'wifi-control.bat kernel' first"
    exit 1
}

$cfg = Join-Path $env:USERPROFILE '.wslconfig'
if (Test-Path $cfg) { Copy-Item $cfg "$cfg.bak" -Force }
$lines = if (Test-Path $cfg) { Get-Content $cfg } else { @() }

$esc = $KernelPath -replace '\\', '\\'
$out = @(); $done = $false; $inWsl = $false
foreach ($l in $lines) {
    if ($l -match '^\s*\[') {
        if ($inWsl -and -not $done) { $out += "kernel=$esc"; $done = $true }
        $inWsl = ($l -match '^\s*\[wsl2\]\s*$')
    }
    if ($inWsl -and $l -match '^\s*kernel\s*=') { $out += "kernel=$esc"; $done = $true; continue }
    $out += $l
}
if (-not $done) {
    if (-not $inWsl) { if ($out.Count -and $out[-1] -and $out[-1].Trim()) { $out += '' }; $out += '[wsl2]' }
    $out += "kernel=$esc"
}
Set-Content $cfg $out -Encoding utf8
Write-Host ".wslconfig updated: kernel=$esc  (backup: $cfg.bak)"
