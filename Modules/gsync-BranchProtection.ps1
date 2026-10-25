#Requires -Version 5.1


# The shared bootstrap makes the logger and the locale resolver available.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1')
function Get-SyncConfigProperty {
    <#
    .SYNOPSIS
        Reads a property from a config node that may be a hashtable OR a
        PSCustomObject.
    .DESCRIPTION
        The config arrives as PSCustomObject when it came through
        ConvertFrom-Json, and as a hashtable when it came from the in-memory
        default config. The previous code called .ContainsKey() on both, which
        is a method only hashtables have - on a PSCustomObject it threw
        "method not found" the moment branch protection was configured.
    #>
    [CmdletBinding()]
    param($Node, [Parameter(Mandatory)][string]$Name)

Set-StrictMode -Version 1.0
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Collections.IDictionary]) {
        if (-not $Node.Contains($Name)) { return $null }
        return $Node[$Name]
    }
    $prop = $Node.PSObject.Properties[$Name]
    if (-not $prop) { return $null }
    return $prop.Value
}

function Test-BranchProtected {
    [CmdletBinding()]
    param([string]$BranchName, $ProtectionRules)
    if (-not $ProtectionRules) { return $false }
    $protected = @()
    $branches = Get-SyncConfigProperty -Node $ProtectionRules -Name 'branches'
    if ($null -ne $branches) { $protected = @($branches) }
    else {
        $alt = Get-SyncConfigProperty -Node $ProtectionRules -Name 'protectedBranches'
        if ($null -ne $alt) { $protected = @($alt) }
    }
    if ($protected.Count -eq 0) { return $false }
    foreach ($pattern in $protected) {
        if ($BranchName -eq $pattern) { return $true }
        $re = [WildcardPattern]::new($pattern, [System.Management.Automation.WildcardOptions]::IgnoreCase)
        if ($re.IsMatch($BranchName)) { return $true }
    }
    return $false
}
function Invoke-BranchProtectionCheck {
    [CmdletBinding()]
    param([string]$BranchName, $Config, [switch]$AllowForce)
    if (-not $Config) { return $true }
    if (-not (Test-BranchProtected -BranchName $BranchName -ProtectionRules $Config)) { return $true }
    $rules = @()
    $cfgRules = Get-SyncConfigProperty -Node $Config -Name 'rules'
    if ($null -ne $cfgRules) { $rules = @($cfgRules) }
    if ($rules.Count -eq 0) { $rules = @('no-direct-push','require-pull-request','require-review') }
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.protect.branchProtected' -MessageArgs @($BranchName, $($rules -join ', '))) -ForegroundColor Yellow
    if ($rules -contains 'no-direct-push' -and -not $AllowForce) { Write-GSyncError "Direct push to '$BranchName' not allowed."; return $false }
    return $true
}
function Get-BranchProtectionStatus {
    param([string]$RepoPath, $Config)
    $current = (git -C $RepoPath rev-parse --abbrev-ref HEAD 2>$null)
    if (-not $current) { return @{ CurrentBranch = $null; Protected = $false; Rules = @() } }
    $protected = Test-BranchProtected -BranchName $current -ProtectionRules $Config
    $rules = if ($protected) { $cfgRules = Get-SyncConfigProperty -Node $Config -Name 'rules'; if ($null -ne $cfgRules) { @($cfgRules) } else { @() } } else { @() }
    return @{ CurrentBranch = $current; Protected = $protected; Rules = $rules }
}

