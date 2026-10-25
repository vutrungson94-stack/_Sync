#Requires -Version 5.1
#Requires -Module Pester
# Cross-platform end-to-end smoke test for the _Sync system.
# Verifies: smart .gitignore generation, smart commit from diff, and
# smart commit rules work on the current OS without a remote repository.

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

Import-Module (Join-Path $root 'Modules/Logging.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'Modules/Config.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'Modules/GitUtils.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'Modules/Security.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'Modules/SmartGitignore.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'Modules/SmartCommitRules.psm1') -Force -DisableNameChecking

Describe "Cross-platform _Sync e2e" {
    BeforeAll {
        $global:RuleConfig = @{ autoCommit = @{ excludedExtensions = @('.tmp'); excludedDirectories = @('bin/') } }
        $global:tmp = Join-Path $env:TEMP ("gsync_e2e_$(New-Guid)")
        New-Item -ItemType Directory -Path $global:tmp -Force | Out-Null
        & git -C $global:tmp init -q 2>$null
        & git -C $global:tmp config user.email "ci@gsync.local"
        & git -C $global:tmp config user.name "gsync-ci"
        $global:cfg = Get-DefaultConfig
        $global:cfg.gitignore.enabled = $true
    }

    AfterAll {
        if ($global:tmp -and (Test-Path $global:tmp)) {
            Remove-Item $global:tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Smart .gitignore applies project rules" {
        New-Item -ItemType File -Path (Join-Path $global:tmp "app.csproj") | Out-Null
        New-Item -ItemType File -Path (Join-Path $global:tmp "package.json") | Out-Null
        Push-Location $global:tmp
        try { Update-SmartGitignore -Config $global:cfg } finally { Pop-Location }
        Test-Path (Join-Path $global:tmp ".gitignore") | Should -Be $true
        $content = Get-Content (Join-Path $global:tmp ".gitignore") -Raw
        $content | Should -Match "node_modules/"
        $content | Should -Match "bin/"
    }

    It "Smart commit message reflects staged diff" {
        $f = Join-Path $global:tmp "app.js"
        'console.log("ci")' | Set-Content $f
        & git -C $global:tmp add -A
        $msg = New-CommitMessageSuggestion -StagedFiles @("app.js") -AnalyzeDiff
        $msg | Should -Match "^feat: app.js"
        $null = & git -C $global:tmp commit -m $msg 2>&1
        $LASTEXITCODE | Should -Be 0
        $log = & git -C $global:tmp log --oneline 2>&1
        ($log -join "`n") | Should -Match "feat: app.js"
    }

    It "SmartCommitRules excludes configured paths" {
        Test-SmartCommitRules -Path "a.tmp" -Status 'A' -Config $global:RuleConfig | Should -Be $false
        Test-SmartCommitRules -Path "src/app.cs" -Status 'A' -Config $global:RuleConfig | Should -Be $true
    }
}
