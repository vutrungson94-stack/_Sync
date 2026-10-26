BeforeAll {
    $global:ScriptRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $global:ScriptRoot "Modules\gsync-BranchProtection.ps1")
}
Describe "gsync-BranchProtection module" {
    It "Test-BranchProtected detects protected branches" {
        $rules = @{ branches = @('main','release/*') }
        Test-BranchProtected -BranchName "main" -ProtectionRules $rules | Should -Be $true
        Test-BranchProtected -BranchName "develop" -ProtectionRules $rules | Should -Be $false
    }
    It "Invoke-BranchProtectionCheck blocks direct push to main" {
        $cfg = @{ branches = @('main'); rules = @('no-direct-push') }
        Invoke-BranchProtectionCheck -BranchName "main" -Config $cfg 2>$null | Should -Be $false
        Invoke-BranchProtectionCheck -BranchName "main" -Config $cfg -AllowForce 2>$null | Should -Be $true
    }
}
