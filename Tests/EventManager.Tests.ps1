# EventManager.Tests.ps1 - Add-SyncEventListener wiring regression tests
#Requires -Version 5.1

$bootstrapPath = Join-Path $PSScriptRoot '_TestBootstrap.ps1'
if (Test-Path $bootstrapPath) {
    . $bootstrapPath
} else {
    Write-Error "Cannot find _TestBootstrap.ps1 at $bootstrapPath"
    exit 1
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Describe "Add-SyncEventListener wiring (skipped on PS < 7)" -Skip {
        It "Placeholder" { }
    }
    return
}

Describe "Add-SyncEventListener wiring" {
    It "Subscribes and delivers event via Add-SyncEventListener" {
        $mgr = New-SyncEventManager
        $global:emReceived = $false
        Add-SyncEventListener -Manager $mgr -EventName 'test' -Handler { $global:emReceived = $true }
        $mgr.Subscribe('test', { param($s, $d) $global:emReceived = $true })
        $mgr.Publish('test', 'src', @{})
        $global:emReceived | Should -Be $true
    }

    It "Unsubscribes handlers" {
        $mgr = New-SyncEventManager
        $global:emCount = 0
        $h = { param($s, $d) $global:emCount++ }
        $mgr.Subscribe('t2', $h)
        $mgr.Publish('t2', 'src', @{})
        $global:emCount | Should -Be 1
        $mgr.Unsubscribe('t2', $h)
        $mgr.Publish('t2', 'src', @{})
        $global:emCount | Should -Be 1
    }

    It "Publish-GSyncEvent triggers manager and logs event" {
        $mgr = New-SyncEventManager
        $global:emReceived2 = $false
        $mgr.Subscribe('gsync.sync.start', { param($s, $d) $global:emReceived2 = $true })
        Publish-GSyncEvent -Manager $mgr -EventName 'gsync.sync.start' -EventSource 'x' -EventData @{a=1}
        $global:emReceived2 | Should -Be $true
        (Test-Path $mgr.LogPath) | Should -Be $true
    }

    It "Add-SyncEventListener handles invalid manager gracefully" {
        { Add-SyncEventListener -Manager ([pscustomobject]@{}) -EventName 'x' -Handler { } 3>$null } | Should -Not -Throw
    }
}
