# Pester tests for scripts/check-adapters.ps1
# Run: Invoke-Pester ./test/windows/check-adapters.Tests.ps1
BeforeAll {
    $script:repo = Resolve-Path "$PSScriptRoot\..\.."
    $script:stubDir = Join-Path $TestDrive 'bin'
    New-Item -ItemType Directory -Path $stubDir | Out-Null
    # Stub usbipd.exe that prints the canned fixture for `list`.
    $fixture = Get-Content -Raw "$PSScriptRoot\fixtures\usbipd-list.txt"
    $stub = Join-Path $stubDir 'usbipd-stub.cmd'
    Set-Content $stub '@echo off'
    foreach ($l in ($fixture -split "`r?`n")) {
        Add-Content $stub "echo $l"
    }
    $env:AIYUSPOT_USBIPD = $stub
}

AfterAll {
    Remove-Item Env:AIYUSPOT_USBIPD -ErrorAction SilentlyContinue
}

Describe 'check-adapters.ps1 usbipd parsing' {
    It 'detects the RT73 from fixture output' {
        $out = & powershell.exe -NoProfile -File "$repo\scripts\check-adapters.ps1" 2>$null
        ($out -join "`n") | Should -Match 'Ralink RT73'
    }
    It 'parses the busid (not an empty leading-whitespace field)' {
        $out = & powershell.exe -NoProfile -File "$repo\scripts\check-adapters.ps1" 2>$null
        ($out -join "`n") | Should -Match 'busid=1-5'
    }
    It 'maps Attached state' {
        $out = & powershell.exe -NoProfile -File "$repo\scripts\check-adapters.ps1" 2>$null
        ($out -join "`n") | Should -Match 'Attached to WSL'
    }
}

Describe 'check-adapters.ps1 degraded mode' {
    It 'runs cleanly when nothing is installed' {
        $env:AIYUSPOT_USBIPD = 'C:\nonexistent\usbipd.exe'
        $out = & powershell.exe -NoProfile -File "$repo\scripts\check-adapters.ps1" 2>$null
        ($out -join "`n") | Should -Match 'No supported USB WiFi adapter'
        $env:AIYUSPOT_USBIPD = $stub
    }
}
