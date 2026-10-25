#Requires -Version 5.1
# SecurityPlugin.psm1

# Declare the sibling modules this one calls into.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('Security')
# Plugin-based security scanning for _Sync Platform
# Requires -Version 5.1


# Plugin interface check
function Test-SecurityPluginInterface {
    param([string]$ModulePath)

Set-StrictMode -Version 1.0
    $required = @('Scan', 'GetPatterns')
    $functions = Get-Command -Module (Import-Module $ModulePath -Force -PassThru -ErrorAction SilentlyContinue) -ErrorAction SilentlyContinue
    foreach ($req in $required) {
        if ($functions.Name -notcontains $req) { return $false }
    }
    return $true
}

# Secret scanner plugin — delegates to the canonical scanner in Security.psm1
# (Get-SyncSecretPatternCatalog / Invoke-SyncSecretScan). Signatures and finding
# shape ({File, Pattern, Line}) are unchanged.
if (-not (Get-Command Invoke-SyncSecretScan -ErrorAction SilentlyContinue)) {
    $secPath = Join-Path $PSScriptRoot 'Security.psm1'
    if (Test-Path $secPath) { Import-Module $secPath -Force -DisableNameChecking -Scope Global -ErrorAction SilentlyContinue }
}

# Secret scanner plugin
function Invoke-SecretScan {
    param([string[]]$Files, [string[]]$Patterns)

    if (Get-Command Invoke-SyncSecretScan -ErrorAction SilentlyContinue) {
        return @(Invoke-SyncSecretScan -Files $Files -Patterns $Patterns)
    }
    $findings = @()
    foreach ($file in $Files) {
        if (Test-Path $file -PathType Leaf) {
            try {
                $content = Get-Content $file -Raw -ErrorAction SilentlyContinue
                foreach ($p in $Patterns) {
                    if ($content -match $p) {
                        $findings += [PSCustomObject]@{
                            File = $file
                            Pattern = $p
                            Line = ($content -split "`n" | Select-String -Pattern $p).LineNumber
                        }
                    }
                }
            } catch { }
        }
    }
    return $findings
}

# GitHub secret patterns database (extensible) — canonical list lives in
# Security.psm1 $script:SyncGitHubSecretPatterns; this stays as the plugin view.
function Get-GitHubSecretPatterns {
    if (Get-Command Get-SyncSecretPatternCatalog -ErrorAction SilentlyContinue) {
        return @(Get-SyncSecretPatternCatalog -GitHubOnly)
    }
    return @(
        "(?i)(sk-or-v1-[a-z0-9]{20,})",
        "(?i)(ghp_[a-z0-9]{36})",
        "(?i)(gho_[a-z0-9]{36})",
        "(?i)(ghu_[a-z0-9]{36})",
        "(?i)(ghs_[a-z0-9]{36})",
        "(?i)(ghr_[a-z0-9]{36})",
        "(?i)(npm_[a-z0-9]{36})",
        "(?i)(token\s*=\s*[a-zA-Z0-9]{20,})",
        "(?i)(AKIA[0-9A-Z]{16})",
        "(?i)(-----BEGIN.*PRIVATE KEY-----)"
    )
}

Export-ModuleMember -Function @(
    'Test-SecurityPluginInterface',
    'Invoke-SecretScan',
    'Get-GitHubSecretPatterns'
)
