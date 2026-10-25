#Requires -Version 5.1
#Requires -Module Pester

$bootstrapPath = Join-Path $PSScriptRoot '_TestBootstrap.ps1'
if (Test-Path $bootstrapPath) { . $bootstrapPath }

Import-Module (Join-Path $PSScriptRoot '../Modules/SelfHeal.psm1') -Force -DisableNameChecking -Scope Global

Set-StrictMode -Version 1.0

Describe "SyncSelfBootstrap" {
    It "Is a cheap no-op when session already bootstrapped" {
        { Invoke-SyncSelfBootstrap -Sentinels @('Write-Log', 'Get-DefaultConfig') -Modules @() } | Should -Not -Throw
        Get-Command Write-Log -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "Heals a missing module on demand without throwing" {
        { Import-SyncModuleOnDemand -ModuleNames @('Messages') } | Should -Not -Throw
        Get-Command Get-Message -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "Skips unknown modules silently" {
        { Import-SyncModuleOnDemand -ModuleNames @('NoSuchModule_xyz') } | Should -Not -Throw
    }
}

Describe "SyncHealth" {
    It "Passes Git Tool check when git exists" {
        $r = @(Test-SyncHealth -Checks @('GitTool'))
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'Git Tool'
        $r[0].Status | Should -Be 'Pass'
    }

    It "Warns on non-repo directory without throwing" {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("syncheal_norepo_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $r = @(Test-SyncHealth -RepoRoot $tmp -Checks @('GitRepo', 'StaleLock'))
            ($r | Where-Object { $_.Name -eq 'Git Repo' }).Status | Should -Be 'Warn'
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Detects stale lock and autofix removes it" {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("syncheal_lock_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            & git -C $tmp init -q 2>$null
            $gitDir = (& git -C $tmp rev-parse --git-dir 2>$null | Out-String).Trim()
            if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $tmp $gitDir }
            $lock = Join-Path $gitDir 'index.lock'
            New-Item -ItemType File -Path $lock -Force | Out-Null
            (Get-Item -LiteralPath $lock).LastWriteTime = (Get-Date).AddHours(-2)
            $before = @(Test-SyncHealth -RepoRoot $tmp -Checks @('StaleLock'))
            ($before | Where-Object { $_.Name -eq 'Stale Lock' }).Status | Should -Be 'Fail'
            $fix = Invoke-SyncAutoFix -Results $before -RepoRoot $tmp -Confirm:$false
            $fix.Fixed | Should -Be 1
            $after = @(Test-SyncHealth -RepoRoot $tmp -Checks @('StaleLock'))
            ($after | Where-Object { $_.Name -eq 'Stale Lock' }).Status | Should -Be 'Pass'
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Recreates missing config via autofix" {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("syncheal_cfg_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $cfgPath = Join-Path $tmp 'gsync.config.json'
            $before = @(Test-SyncHealth -RepoRoot $tmp -ConfigPath $cfgPath -Checks @('ConfigFile'))
            ($before | Where-Object { $_.Name -eq 'Config' }).Status | Should -Be 'Warn'
            $fix = Invoke-SyncAutoFix -Results @(
                New-SyncHealthResult -Name 'Config' -Status 'Fail' -Message "Missing (regenerable): $cfgPath"
            ) -RepoRoot $tmp -ConfigPath $cfgPath -Confirm:$false
            $fix.Fixed | Should -Be 1
            Test-Path -LiteralPath $cfgPath -PathType Leaf | Should -Be $true
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Doctor runs end-to-end without throwing" {
        { Invoke-SyncDoctor -RepoRoot ([System.IO.Path]::GetTempPath()) } | Should -Not -Throw
    }
}
