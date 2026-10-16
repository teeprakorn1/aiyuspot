# Pester tests for wifi-menu.ps1 (dot-sourced - main loop is guarded).
# Run: Invoke-Pester ./test/windows/wifi-menu.Tests.ps1
BeforeAll {
    . "$PSScriptRoot\..\..\wifi-menu.ps1"
}

Describe 'menu tree shape' {
    It 'every leaf has Name/Desc and a Cmd or Sub' {
        foreach ($item in $menu) {
            $item.Name | Should -Not -BeNullOrEmpty
            $item.Desc | Should -Not -BeNullOrEmpty
            if (-not $item.Sub) { $item.ContainsKey('Cmd') | Should -BeTrue }
            foreach ($sub in @($item.Sub)) {
                if ($null -eq $sub) { continue }
                $sub.Name | Should -Not -BeNullOrEmpty
                $sub.Cmd  | Should -Not -BeNullOrEmpty
            }
        }
    }
    It 'top level has exactly the 5 categories' {
        $menu.Count | Should -Be 5
        $menu[-1].Name | Should -Be 'Exit'
    }
}

Describe 'menu Cmd -> bat verb consistency' {
    It 'every Cmd maps to a bat verb or a Build-Args special case' {
        $batVerbs = 'default','open','wep','wpa2','stop','reset','check','diag','driver','kernel','provision','help'
        $special  = 'default-wep',''   # handled inside Build-Args
        $cmds = @()
        foreach ($item in $menu) {
            if ($item.Sub) { $cmds += $item.Sub.Cmd } else { $cmds += $item.Cmd }
        }
        foreach ($c in $cmds) {
            ($batVerbs + $special) | Should -Contain $c
        }
    }
}

Describe 'Build-Args' {
    It 'default-wep maps to wep with public defaults, no prompts' {
        $r = Build-Args -Cmd 'default-wep'
        $r.Args | Should -Be @('wep','aiyuspot','aiyu1')
    }
    It 'open carries the SSID arg' {
        Mock Read-Host { '' }
        $r = Build-Args -Cmd 'open'
        $r.Args[0] | Should -Be 'open'
        $r.Args[1] | Should -Be 'aiyuspot'
    }
    It 'wpa2 builds 3 args' {
        Mock Read-Host { 'MyNet' }
        Mock Read-ValidatedKey { 'longenough' }
        $r = Build-Args -Cmd 'wpa2'
        $r.Args | Should -Be @('wpa2','MyNet','longenough')
    }
    It 'reset is a single verb with no args' {
        $r = Build-Args -Cmd 'reset'
        $r.Args | Should -Be @('reset')
    }
}

Describe 'Invoke-WifiControl' {
    # Regression: the bat's stdout once flowed into the function return,
    # making $code an Object[] so `-eq 0` filtered instead of comparing and
    # every command reported "failed". Out-Host diverts output; the return
    # must stay a scalar int.
    BeforeEach {
        $env:AIYUSPOT_LOG = Join-Path $env:TEMP 'aiyu-pester-log.txt'
    }
    AfterEach {
        Remove-Item $env:AIYUSPOT_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:AIYUSPOT_LOG -ErrorAction SilentlyContinue
    }
    It 'returns a scalar int, not the bat stdout' {
        $r = Invoke-WifiControl -A @('bogus')
        @($r).Count | Should -Be 1
        $r | Should -BeOfType [int]
        $r | Should -Be 2
    }
    It 'returns 0 for help' {
        Invoke-WifiControl -A @('help') | Should -Be 0
    }
}

Describe 'validators' {
    It 'accepts only 5 or 13 chars for WEP' {
        Mock Read-Host { 'abcde' }
        Read-ValidatedKey 'k' 'aiyu1' 'wep' | Should -Be 'abcde'
    }
    It 'rejects bad WEP length then accepts' {
        $script:i = 0
        $seq = @('abc', 'abcde')
        Mock Read-Host { $seq[$script:i++] }
        Read-ValidatedKey 'k' 'aiyu1' 'wep' | Should -Be 'abcde'
    }
    It 'rejects >63-char WPA2 then accepts' {
        $script:i = 0
        $long = 'x' * 64
        $seq = @($long, 'validpass')
        Mock Read-Host { $seq[$script:i++] }
        Read-ValidatedKey 'k' 'aiyuspot' 'wpa2' | Should -Be 'validpass'
    }
}
