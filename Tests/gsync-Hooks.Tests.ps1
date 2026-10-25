BeforeAll {
    $global:ScriptRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '_Sync'
    # Dot-sourcing inside BeforeAll puts the functions in the BeforeAll
    # scope, where the It bodies cannot see them. Import-Module -Global
    # publishes them for the whole container.
    Import-Module (Join-Path $global:ScriptRoot "Modules\gsync-Hooks.ps1") -Force -Global -DisableNameChecking -ErrorAction Stop
}
Describe "gsync-Hooks module" {
    It "Test-GSyncHooks returns array" {
        # A real repository to inspect. The _Sync folder has no .git
        # directory, so Install-GSyncHooks could never install anything and
        # the assertions below could never hold.
        $repo = Join-Path $TestDrive 'readrepo'
        New-Item -ItemType Directory -Path (Join-Path $repo '.git/hooks') -Force | Out-Null
        $h = Test-GSyncHooks -RepoPath $repo
        # Piping an empty array to Should sends it NO input, so
        # "Should -BeOfType" would report $null. Assert on the value
        # directly instead.
        ($h -is [System.Array]) | Should -BeTrue -Because 'Test-GSyncHooks must always return an array'
    }
    It "Install-GSyncHooks and Remove-GSyncHooks work" {
        $repo = Join-Path $TestDrive 'installrepo'
        New-Item -ItemType Directory -Path (Join-Path $repo '.git/hooks') -Force | Out-Null
        Install-GSyncHooks -RepoPath $repo -HookTypes @('pre-commit') -Force
        $hooks = Test-GSyncHooks -RepoPath $repo
        $hooks | Should -Contain "pre-commit"
        # The launcher must be a POSIX sh script (git runs a hook through the
        # shell named in its shebang) and must not carry a BOM, which would
        # break the shebang on every platform.
        $hookFile = Join-Path $repo '.git/hooks/pre-commit'
        (Get-Content -LiteralPath $hookFile -Raw) | Should -Match '#!/bin/sh'
        $bytes = [System.IO.File]::ReadAllBytes($hookFile)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        Test-Path -LiteralPath "$hookFile.gsync.ps1" | Should -BeTrue
        Remove-GSyncHooks -RepoPath $repo -HookTypes @('pre-commit')
        $hooks2 = Test-GSyncHooks -RepoPath $repo
        $hooks2 | Should -Not -Contain "pre-commit"
    }
    It "blocks a commit when the handler returns false" {
        # The handler signals a block by returning $false. The previous
        # implementation used "if (-not $?)", which reports whether the last
        # command ERRORED, not what it returned - so a $false verdict left
        # $? as $true and the secret gate never blocked a commit.
        # The check runs against a real repository with a real staged file.
        $repo = Join-Path $TestDrive 'blockrepo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Push-Location $repo
        try {
            & git init -q 2>&1 | Out-Null
            & git config user.email 'test@example.invalid' 2>&1 | Out-Null
            & git config user.name 'Test' 2>&1 | Out-Null
            '*.tmp' | Set-Content -LiteralPath (Join-Path $repo '.gitignore')
            'temp' | Set-Content -LiteralPath (Join-Path $repo 'junk.tmp')
            & git add .gitignore 2>&1 | Out-Null
            # The .gitignore in this repo contains '*.tmp', so git refuses to
            # stage the junk file the test depends on. Force it.
            & git add -f junk.tmp 2>&1 | Out-Null
            $cfg = [PSCustomObject]@{
                autoCommit  = [PSCustomObject]@{ enabled = $false }
                junkCleanup = [PSCustomObject]@{ enabled = $true; patterns = @('*.tmp'); confirmBeforeDelete = $true }
                secretScan  = [PSCustomObject]@{ enabled = $false }
            }
            $verdict = Invoke-GSyncHook -HookType 'pre-commit' -Config $cfg
            $verdict | Should -BeFalse -Because 'the handler returned $false for a staged junk file'
        } finally { Pop-Location }
    }
    It "allows a commit when the handler returns true" {
        $repo = Join-Path $TestDrive 'okrepo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Push-Location $repo
        try {
            & git init -q 2>&1 | Out-Null
            & git config user.email 'test@example.invalid' 2>&1 | Out-Null
            & git config user.name 'Test' 2>&1 | Out-Null
            'hello' | Set-Content -LiteralPath (Join-Path $repo 'ok.txt')
            & git add ok.txt 2>&1 | Out-Null
            $cfg = [PSCustomObject]@{
                autoCommit  = [PSCustomObject]@{ enabled = $false }
                junkCleanup = [PSCustomObject]@{ enabled = $false; patterns = @() }
                secretScan  = [PSCustomObject]@{ enabled = $false }
            }
            $verdict = Invoke-GSyncHook -HookType 'pre-commit' -Config $cfg
            $verdict | Should -BeTrue
        } finally { Pop-Location }
    }
}
