#Requires -Version 5.1
# SmartCommitRules.psm1 - Rule-based smart commit engine (Enterprise)
# Requires -Version 5.1


# Make the logger available when this module is imported on its own.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1')
# Commit rule validation function
function Test-SmartCommitRules {
    param(
        [string]$Path,
        [string]$Status,
        $Config
    )

Set-StrictMode -Version 1.0
    
    if (-not $Config) { return $true }
    
    # Rule 1: Check excluded extensions (normalize: config uses '.ext', GetExtension returns 'ext')
    $excludedExts = $Config.autoCommit.excludedExtensions
    $rawExt = [System.IO.Path]::GetExtension($Path)
    $dot = '.'
    $ext = if ($rawExt.StartsWith($dot)) { $rawExt } else { "$dot$rawExt" }
    foreach ($xe in $excludedExts) {
        $normXe = if ([string]$xe -is [string] -and $xe.StartsWith($dot)) { $xe } else { "$dot$xe" }
        if ($ext -eq $normXe) {
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.rules.excludedExtension' -MessageArgs @($Path)) -Level Debug
            return $false
        }
    }
    
    # Rule 2: Check excluded directories (normalize path for cross-platform)
    $excludedDirs = $Config.autoCommit.excludedDirectories
    $normalized = $Path.Replace('\', '/')
    $isExcluded = $false
    foreach ($d in $excludedDirs) {
        $dirName = $d.TrimEnd('/').TrimEnd('\')
        if ($normalized.StartsWith("$dirName/")) {
            $isExcluded = $true
            break
        }
    }
    if ($isExcluded) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.rules.excludedDirectory' -MessageArgs @($Path)) -Level Debug
        return $false
    }
    
    # Rule 3: Check sensitive patterns (filename blocklist).
    # Canonical filename list: Core/SyncTypes.psm1 SyncConstants.DefaultBlockedPatterns.
    $sensitivePatterns = $Config.sensitive.blockedPatterns
    if ((-not $sensitivePatterns -or @($sensitivePatterns).Count -eq 0) -and $global:SyncConstants -and $global:SyncConstants.DefaultBlockedPatterns) {
        $sensitivePatterns = @($global:SyncConstants.DefaultBlockedPatterns)
    }
    if ($sensitivePatterns) {
        foreach ($pattern in $sensitivePatterns) {
            if ($Path -match $pattern) {
                Write-Log (Get-LocaleMessage -Key 'gsync.msg.rules.blockedPattern' -MessageArgs @($Path)) -Level Warn
                return $false
            }
        }
    }
    
    # Rule 4: Check gitignore integration
    if ($Config.gsyncIgnore -and $Config.gsyncIgnore.enabled) {
        $ignorePatterns = $Config.gsyncIgnore.patterns
        foreach ($p in $ignorePatterns) {
            if ($Path -like $p) {
                Write-Log (Get-LocaleMessage -Key 'gsync.msg.rules.ignored' -MessageArgs @($Path)) -Level Debug
                return $false
            }
        }
    }
    
    return $true
}

# Get smart staged changes based on rules
function Get-SmartStagedChanges {
    param($Config)
    
    $staged = & git diff --cached --name-only
    $smartChanges = @()
    
    foreach ($file in $staged) {
        if (Test-SmartCommitRules -Path $file -Status 'A' -Config $Config) {
            $smartChanges += $file
        }
    }
    
    return $smartChanges
}

Export-ModuleMember -Function @('Test-SmartCommitRules', 'Get-SmartStagedChanges')
