#Requires -Version 5.1
#Requires -Module Pester
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $root 'Modules/Logging.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'Modules/SmartCommitRules.psm1') -Force -DisableNameChecking

Describe "dbg" {
    It "binds config" {
        $cfg = @{ autoCommit = @{ excludedExtensions = @('.tmp'); excludedDirectories = @('bin/') } }
        Write-Host ("CFG_NULL=" + ($null -eq $cfg))
        $r = Test-SmartCommitRules -Path "a.tmp" -Status 'A' -Config $cfg
        $r | Should -Be $false
    }
}
