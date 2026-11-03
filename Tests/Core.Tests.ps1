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

    It "Restores a rename target and a pre-existing untracked file (data-loss regression)" {
        # QPM-2026-003: Restore-SyncSnapshot ran a plain `git apply`, which
        # leaves a rename/new-file target UNTRACKED; the post-snapshot cleanup
        # then deleted it as "created after the snapshot". The untracked files
        # themselves were listed but never copied, so a restore also lost their
        # contents. Both are asserted here against a real temporary repository.
        $repo = Join-Path $env:TEMP "gsync_restore_$(New-Guid)"
        $snapDir = Join-Path $env:TEMP "gsync_snap_restore_$(New-Guid)"
        $null = New-Item -ItemType Directory -Path $repo -Force
        Push-Location $repo
        try {
            & git init -q 2>&1 | Out-Null
            & git config user.email 'test@test.local'
            & git config user.name 'test'
            Set-Content -LiteralPath 'a.txt' -Value 'alpha' -NoNewline
            & git add -A
            & git commit -qm init
            $null = New-Item -ItemType Directory -Path 'sub' -Force
            & git mv 'a.txt' 'sub/a.txt'
            Set-Content -LiteralPath 'sub/a.txt' -Value 'alpha-mod' -NoNewline
            Set-Content -LiteralPath 'untracked.txt' -Value 'keep-me' -NoNewline
            $snap = New-SyncSnapshot -Label 'restore' -SnapshotsDir $snapDir

            & git reset --hard -q HEAD
            & git clean -fdq
            Test-Path 'sub/a.txt' | Should -BeFalse
            Test-Path 'untracked.txt' | Should -BeFalse

            $ok = Restore-SyncSnapshot -SnapshotId $snap.Id -SnapshotsDir $snapDir
            $ok | Should -BeTrue
            Test-Path 'sub/a.txt' | Should -BeTrue -Because 'a restored rename target must not be deleted as post-snapshot untracked'
            (Get-Content -LiteralPath 'sub/a.txt' -Raw) | Should -Be 'alpha-mod'
            Test-Path 'untracked.txt' | Should -BeTrue -Because 'untracked file contents must be snapshotted and restored'
            (Get-Content -LiteralPath 'untracked.txt' -Raw) | Should -Be 'keep-me'
        } finally {
            Pop-Location
            Remove-Item -LiteralPath $repo, $snapDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
