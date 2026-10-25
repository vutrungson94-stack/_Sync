#Requires -Version 5.1
#Requires -Module Pester
# GitScope.Tests.ps1
#
# The git state a tool creates must belong to the PROJECT the tool was
# pointed at, and to nothing else.
#
# Initialize-GitRepository used to run "git init" in the process working
# directory. Started from a folder that merely CONTAINS repositories, that
# created a new repository wrapping every project below it - git state
# appearing outside the project. The function now takes an explicit path,
# runs every git command with -C against it, and refuses a directory that
# holds other repositories and is not itself a project.
Set-StrictMode -Version 1.0

BeforeAll {
    $script:SyncRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
    Import-Module (Join-Path $script:SyncRoot 'Modules/GitUtils.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
}

Describe 'Git state stays inside the project' {
    It 'refuses to initialise git in a folder that only contains repositories' {
        $folderOfRepos = Join-Path $TestDrive 'folder-of-repos'
        $inner = Join-Path $folderOfRepos 'ProjectA'
        New-Item -ItemType Directory -Path $inner -Force | Out-Null
        & git -C $inner init -q 2>&1 | Out-Null
        Test-Path -LiteralPath (Join-Path $inner '.git') | Should -BeTrue -Because 'the fixture needs a real repository below the folder'

        { Initialize-GitRepository -RepoUrl 'https://example.invalid/x.git' -Path $folderOfRepos } | Should -Not -Throw
        $ok = Initialize-GitRepository -RepoUrl 'https://example.invalid/x.git' -Path $folderOfRepos
        $ok | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $folderOfRepos '.git') | Should -BeFalse -Because 'no repository may be created around other repositories'
    }

    It 'recognises a project root that is not a repository yet' {
        $project = Join-Path $TestDrive 'a-project'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Test-GitProjectRoot -Path $project | Should -BeTrue
    }

    It 'does not treat a folder of repositories as a project root' {
        $folder = Join-Path $TestDrive 'not-a-project'
        $inner = Join-Path $folder 'ProjectB'
        New-Item -ItemType Directory -Path $inner -Force | Out-Null
        & git -C $inner init -q 2>&1 | Out-Null
        Test-GitProjectRoot -Path $folder | Should -BeFalse
    }

    It 'reports a repository only for the path it was given' {
        $project = Join-Path $TestDrive 'scoped-repo'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        & git -C $project init -q 2>&1 | Out-Null
        Test-GitRepository -Path $project | Should -BeTrue

        $elsewhere = Join-Path $TestDrive 'not-a-repo'
        New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
        Test-GitRepository -Path $elsewhere | Should -BeFalse
    }

    It 'clears the lock of the project it was given, not the working directory' {
        $project = Join-Path $TestDrive 'lock-project'
        New-Item -ItemType Directory -Path (Join-Path $project '.git') -Force | Out-Null
        $lock = Join-Path $project '.git/index.lock'
        Set-Content -LiteralPath $lock -Value 'lock' -Encoding UTF8
        { Clear-GitLock -Path $project } | Should -Not -Throw
        Test-Path -LiteralPath $lock | Should -BeFalse
    }
}
