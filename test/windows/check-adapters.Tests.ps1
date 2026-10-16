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
    It 'maps Not shared to Present (not Shared-bound)' {
        $out = & powershell.exe -NoProfile -File "$repo\scripts\check-adapters.ps1" 2>$null
        ($out -join "`n") | Should -Match 'state=Present'
        ($out -join "`n") | Should -Not -Match 'Shared \(bound\)'
    }
    It 'detects the Edimax RTL8723BU from fixture output' {
        $out = & powershell.exe -NoProfile -File "$repo\scripts\check-adapters.ps1" 2>$null
        ($out -join "`n") | Should -Match 'Edimax EW-7611ULB'
        ($out -join "`n") | Should -Match '7392:a611'
    }
    It 'flags registered noap adapters as unable to host' {
        $out = & powershell.exe -NoProfile -File "$repo\scripts\check-adapters.ps1" 2>$null
        ($out -join "`n") | Should -Match 'MediaTek MT7601U'
        ($out -join "`n") | Should -Match 'no AP mode upstream'
    }
}

Describe 'find-wifi.ps1 unknown candidates' {
    It 'emits a tier-2 line for the unregistered wireless dongle' {
        $out = & powershell.exe -NoProfile -File "$repo\scripts\find-wifi.ps1" 2>$null
        ($out -join "`n") | Should -Match '9-9 ffff:aaaa 2'
    }
    It 'does not emit registered adapters' {
        $out = & powershell.exe -NoProfile -File "$repo\scripts\find-wifi.ps1" 2>$null
        ($out -join "`n") | Should -Not -Match '148f:2573'
        ($out -join "`n") | Should -Not -Match '7392:a611'
        ($out -join "`n") | Should -Not -Match '148f:7601'
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
