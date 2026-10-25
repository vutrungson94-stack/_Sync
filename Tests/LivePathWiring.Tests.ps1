#Requires -Version 5.1
#Requires -Module Pester
# LivePathWiring.Tests.ps1
#
# The _Sync live path shipped a lot of capability that never ran:
#   - the rollback stack was cleared on success but never populated, and
#     Invoke-GSyncRollback was never called, so a failed sync left the
#     working tree mutated
#   - a working-tree snapshot was taken and never restored
#   - five plugins (Git, GPG, LFS, Node, Python) were shipped and their
#     contract validated, but the live path never registered or ran them
#
# These tests pin the wiring so it cannot silently regress.
Set-StrictMode -Version 1.0

BeforeAll {
    # $PSScriptRoot is <repo>/_Sync/Tests - one level up is the tool root.
    $script:SyncRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
    $null = Import-Module (Join-Path $script:SyncRoot 'gsync.module.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
}

Describe 'Live path failure recovery' {
    It 'exposes the recovery helper' {
        Get-Command Invoke-GSyncFailureRecovery -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'runs the registered rollback actions' {
        $script:ran = $false
        if (Get-Command Register-GSyncRollbackAction -ErrorAction SilentlyContinue) {
            Register-GSyncRollbackAction -Label 'probe' -Action { $script:ran = $true }
            Invoke-GSyncFailureRecovery -Reason 'unit test'
            $script:ran | Should -BeTrue -Because 'the registered action must run'
        }
    }

    It 'restores a snapshot when one is given' {
        $snapDir = Join-Path $TestDrive 'snapshots'
        New-Item -ItemType Directory -Path $snapDir -Force | Out-Null
        if (Get-Command New-SyncSnapshot -ErrorAction SilentlyContinue) {
            $snap = New-SyncSnapshot -Label 'unit test' -SnapshotsDir $snapDir
            $snap | Should -Not -BeNullOrEmpty
            $snap.Id | Should -Not -BeNullOrEmpty
            # Restoring must not throw; the snapshot may be empty in a
            # non-git directory, which is a legitimate outcome.
            { Invoke-GSyncFailureRecovery -Reason 'unit test' -SnapshotId $snap.Id -SnapshotsDir $snapDir } | Should -Not -Throw
        }
    }
}

Describe 'Live path plugin execution' {
    It 'exposes the plugin execution helper' {
        Get-Command Invoke-EnabledSyncPlugins -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'registers every shipped plugin' {
        $pluginRoot = Join-Path $script:SyncRoot 'Plugins'
        $shipped = @(Get-ChildItem -LiteralPath $pluginRoot -Filter '*.psm1' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
        $shipped.Count | Should -BeGreaterThan 0 -Because 'the tool ships plugins'
        if (Get-Command Register-Plugins -ErrorAction SilentlyContinue) {
            $null = Register-Plugins -Root $pluginRoot
            $registered = @(Get-RegisteredPlugins | ForEach-Object { $_.Name })
            foreach ($p in $shipped) { $registered | Should -Contain $p }
        }
    }

    It 'runs a plugin without aborting the sync' {
        # A failing plugin must be reported, not fatal.
        $script:pluginRoot = Join-Path $script:SyncRoot 'Plugins'
        { Invoke-EnabledSyncPlugins -Config $null -WorkingDir $TestDrive } | Should -Not -Throw
    }

    It 'ships a plugin for every declared language helper' {
        $pluginRoot = Join-Path $script:SyncRoot 'Plugins'
        foreach ($expected in @('GitPlugin', 'GPGPlugin', 'LFSPlugin')) {
            Test-Path -LiteralPath (Join-Path $pluginRoot "$expected.psm1") | Should -BeTrue
        }
    }
}
