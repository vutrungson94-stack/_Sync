#Requires -Version 5.1
#Requires -Module Pester

Set-StrictMode -Version 1.0

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Describe "SyncCore (skipped on PS < 7)" -Skip {
        It "Placeholder" { }
    }
    return
}

$bootstrapPath = Join-Path $PSScriptRoot '_TestBootstrap.ps1'
if (Test-Path $bootstrapPath) {
    . $bootstrapPath
} else {
    Write-Error "Cannot find _TestBootstrap.ps1 at $bootstrapPath"
    exit 1
}


$isClassSafe = $PSVersionTable.PSVersion.Major -ge 7

Describe "SyncContext" {
    It "Creates context with correct paths" {
        $testRoot = Join-Path $env:TEMP "gsync_test_$(New-Guid)"
        New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
        $ctx = New-SyncContext -ScriptRoot $testRoot
        $ctx.ScriptRoot | Should -Be $testRoot
        $ctx.StartTime | Should -Not -BeNullOrEmpty
        Remove-Item $testRoot -Recurse -Force
    }

    It "Tracks errors correctly" {
        $ctx = New-SyncContext -ScriptRoot $env:TEMP
        $ctx.HasErrors() | Should -Be $false
        $ctx.AddError("Test error")
        $ctx.HasErrors() | Should -Be $true
        $ctx.Errors.Count | Should -Be 1
    }

    It "Manages phase state" {
        $testRoot = Join-Path $env:TEMP "gsync_state_$(New-Guid)"
        New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
        $ctx = New-SyncContext -ScriptRoot $testRoot
        $ctx.SetPhase('fetch')
        $ctx.CurrentPhase | Should -Be 'fetch'
        Remove-Item $testRoot -Recurse -Force
    }
}

Describe "SyncEventManager" {
    It "Subscribes and publishes events" {
        $mgr = New-SyncEventManager
        $state = @{ received = $false }
        $mgr.Subscribe('TestEvent', { param($s, $a) $state.received = $true })
        $mgr.Publish('TestEvent', $null, @{})
        $state.received | Should -Be $true
    }

    It "Handles multiple subscribers" {
        $mgr = New-SyncEventManager
        $state = @{ count = 0 }
        $mgr.Subscribe('Test', { $state.count++ })
        $mgr.Subscribe('Test', { $state.count++ })
        $mgr.Publish('Test', $null, @{})
        $state.count | Should -Be 2
    }
}







Describe "SyncRollback" -Skip:$(-not $isClassSafe) {
    It "Creates a snapshot" {
        $snapDir = Join-Path $env:TEMP "gsync_snap_$(New-Guid)"
        $snap = New-SyncSnapshot -Label "test" -SnapshotsDir $snapDir
        $snap.Label | Should -Be "test"
        $snap.Id | Should -Not -BeNullOrEmpty
        Remove-Item $snapDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Lists snapshots after creation" {
        $snapDir = Join-Path $env:TEMP "gsync_snap_list_$(New-Guid)"
        $null = New-SyncSnapshot -Label "first" -SnapshotsDir $snapDir
        $null = New-SyncSnapshot -Label "second" -SnapshotsDir $snapDir
        $list = Get-SyncSnapshots -SnapshotsDir $snapDir
        $list.Count | Should -Be 2
        Remove-Item $snapDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Creates valid JSON snapshot file" {
        $snapDir = Join-Path $env:TEMP "gsync_snap_json_$(New-Guid)"
        $snap = New-SyncSnapshot -Label "json_test" -SnapshotsDir $snapDir
        $snapFile = Join-Path $snapDir "$($snap.Id)\snapshot.json"
        Test-Path $snapFile | Should -Be $true
        $content = Get-Content $snapFile -Raw | ConvertFrom-Json
        $content.Label | Should -Be "json_test"
        Remove-Item $snapDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
