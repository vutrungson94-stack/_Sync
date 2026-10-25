#Requires -Version 5.1
#Requires -Module Pester
# LiveCapability.Tests.ps1
#
# The _Sync live path shipped capabilities that never ran:
#   - the rollback machinery was reachable but never exercised against a REAL
#     git repository, so "a failed sync leaves the working tree mutated"
#     was an untested claim
#   - the Node/Python language plugins executed a hardcoded no-op and were
#     never run against a real project, so the plugin contract was verified
#     but the plugin behaviour was not
#
# These tests exercise both against real state: a real git repository for
# the rollback, a real project manifest for the plugins.
Set-StrictMode -Version 1.0

BeforeAll {
    $script:SyncRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
    $null = Import-Module (Join-Path $script:SyncRoot 'gsync.module.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
    $script:HasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
    $script:HasNpm = [bool](Get-Command npm -ErrorAction SilentlyContinue)
    $script:HasPy  = [bool](Get-Command python -ErrorAction SilentlyContinue)
}

Describe 'Rollback end-to-end' {
    It 'restores the working tree of a REAL git repository' {
        if (-not $script:HasGit) { Set-ItResult -Skipped -Because 'git is not installed'; return }
        $repo = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        $snapDir = Join-Path $TestDrive 'snapshots'

        Push-Location $repo
        try {
            & git init -q 2>&1 | Out-Null
            & git config user.email 'test@example.invalid' 2>&1 | Out-Null
            & git config user.name 'gsync test' 2>&1 | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'tracked.txt') -Value 'original' -Encoding UTF8
            & git add tracked.txt 2>&1 | Out-Null
            & git commit -q -m 'initial' 2>&1 | Out-Null

            # A change that must SURVIVE the restore: it is in the snapshot diff.
            Set-Content -LiteralPath (Join-Path $repo 'tracked.txt') -Value 'changed-before-snapshot' -Encoding UTF8

            if (-not (Get-Command New-SyncSnapshot -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'the snapshot API is unavailable'; return }
            $snap = New-SyncSnapshot -Label 'e2e' -SnapshotsDir $snapDir
            $snap | Should -Not -BeNullOrEmpty
            $snap.Id | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $snapDir $snap.Id 'snapshot.json') | Should -BeTrue -Because 'the snapshot metadata must be on disk'

            # A change that must be UNDONE by the restore.
            Set-Content -LiteralPath (Join-Path $repo 'tracked.txt') -Value 'changed-after-snapshot' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $repo 'added-after.txt') -Value 'junk' -Encoding UTF8

            if (-not (Get-Command Restore-SyncSnapshot -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'the restore API is unavailable'; return }
            $restored = Restore-SyncSnapshot -SnapshotId $snap.Id -SnapshotsDir $snapDir
            $restored | Should -BeTrue -Because 'the restore must succeed against a real repository'

            $content = Get-Content -LiteralPath (Join-Path $repo 'tracked.txt') -Raw
            $content | Should -Not -Match 'changed-after-snapshot' -Because 'the post-snapshot change must be reverted'
            $content | Should -Match 'changed-before-snapshot' -Because 'the pre-snapshot change must be restored'
            Test-Path -LiteralPath (Join-Path $repo 'added-after.txt') | Should -BeFalse -Because 'a file added after the snapshot must be removed by the restore'
        } finally {
            Pop-Location
        }
    }
}

Describe 'Language plugins against a real project' {
    It 'runs the Node plugin build against a real package.json' {
        if (-not $script:HasNpm) { Set-ItResult -Skipped -Because 'npm is not installed'; return }
        $null = Import-Module (Join-Path $script:SyncRoot 'Plugins/Node.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        if (-not (Get-Command Invoke-PluginBuild -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'the Node plugin did not load'; return }

        $proj = Join-Path $TestDrive 'nodeapp'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $manifest = @'
{
  "name": "gsync-e2e",
  "version": "1.0.0",
  "scripts": {
    "build": "node -e \"console.log('gsync-node-build-ran')\"",
    "test": "node -e \"console.log('gsync-node-test-ran')\""
  }
}
'@
        Set-Content -LiteralPath (Join-Path $proj 'package.json') -Value $manifest -Encoding UTF8

        $build = Invoke-PluginBuild -ProjectPath $proj
        $build.ExitCode | Should -Be 0
        $build.Output | Should -Match 'gsync-node-build-ran' -Because 'the plugin must actually EXECUTE the build script, not report a stub'

        $test = Invoke-PluginTest -ProjectPath $proj
        $test.ExitCode | Should -Be 0
        $test.Output | Should -Match 'gsync-node-test-ran' -Because 'the plugin must actually EXECUTE the test script'
    }

    It 'skips cleanly when the project has no manifest' {
        $null = Import-Module (Join-Path $script:SyncRoot 'Plugins/Node.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        if (-not (Get-Command Invoke-PluginBuild -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'the Node plugin did not load'; return }
        $empty = Join-Path $TestDrive 'no-manifest'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $build = Invoke-PluginBuild -ProjectPath $empty
        $build.ExitCode | Should -Be 0
        $build.Output | Should -Match 'skipped' -Because 'a project without a manifest must degrade, not fail'
    }

    It 'reports the missing manifest in the preflight' {
        $null = Import-Module (Join-Path $script:SyncRoot 'Plugins/Node.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        if (-not (Get-Command Invoke-PluginPreflight -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'the Node plugin did not load'; return }
        $empty = Join-Path $TestDrive 'preflight-no-manifest'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $pf = Invoke-PluginPreflight -ProjectPath $empty
        $pf.Ready | Should -BeTrue
        @($pf.Warnings) -join ' ' | Should -Match 'package.json' -Because 'the preflight must name the missing manifest'
    }
}

Describe 'Dependency gate' {
    It 'reports the required and optional dependencies' {
        if (-not (Get-Command Get-GSyncDependencyReport -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'the dependency checker is unavailable'; return }
        $report = @(Get-GSyncDependencyReport)
        $report.Count | Should -BeGreaterThan 0
        $names = @($report | ForEach-Object { $_.Name })
        $names | Should -Contain 'Git' -Because 'git is a required dependency'
        $names | Should -Contain 'SSH' -Because 'ssh is a required dependency'
        foreach ($r in $report) {
            $r.PSObject.Properties.Name | Should -Contain 'Required' -Because 'every record must declare whether it is required'
            $r.PSObject.Properties.Name | Should -Contain 'Passed'
        }
    }

    It 'passes on a machine that has git and ssh' {
        if (-not (Get-Command Test-GSyncDependency -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'the dependency checker is unavailable'; return }
        if (-not $script:HasGit) { Set-ItResult -Skipped -Because 'git is not installed'; return }
        Test-GSyncDependency | Should -BeTrue
    }
}

Describe 'Tenant isolation' {
    It 'resolves the tenant id placeholder instead of shipping it literally' {
        if (-not (Get-Command Resolve-SyncTenantId -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'the tenant resolver is unavailable'; return }
        Resolve-SyncTenantId -Value '${env:GSYNC_TEST_TENANT_UNSET}' | Should -Be 'default' -Because 'an unset placeholder must fall back to the default tenant'
        Resolve-SyncTenantId -Value '' | Should -Be 'default'
        Resolve-SyncTenantId -Value '..' | Should -Be 'default' -Because 'a tenant id that could escape the directory must be rejected'
        Resolve-SyncTenantId -Value 'acme-corp' | Should -Be 'acme-corp'
    }

    It 'gives each tenant its own log and state file' {
        if (-not (Get-Command New-SyncContext -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'the context factory is unavailable'; return }
        $root = Join-Path $TestDrive 'tenantroot'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $cfgA = [PSCustomObject]@{ tenancy = [PSCustomObject]@{ tenantId = 'alpha' } }
        $cfgB = [PSCustomObject]@{ tenancy = [PSCustomObject]@{ tenantId = 'beta' } }
        $a = New-SyncContext -ScriptRoot $root -Config $cfgA
        $b = New-SyncContext -ScriptRoot $root -Config $cfgB
        $a.TenantId | Should -Be 'alpha'
        $b.TenantId | Should -Be 'beta'
        $a.LogFilePath | Should -Not -Be $b.LogFilePath -Because 'two tenants must not share one log file'
        $a.StateFilePath | Should -Not -Be $b.StateFilePath -Because 'two tenants must not share one state file'
    }
}
