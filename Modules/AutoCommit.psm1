#Requires -Version 5.1
# Event dependency: canonical Send-GSyncEventSafe lives in EventBus.psm1 (same dir).
if (-not (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'EventBus.psm1') -Force -DisableNameChecking -Scope Global -ErrorAction SilentlyContinue
}

# AutoCommit.psm1 - Automatic smart commit engine (Enterprise)
# Requires -Version 5.1


# Make the logger available when this module is imported on its own.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('AiCommit', 'EventBus', 'GitUtils', 'Security')

# Multi-language commit message support (same dir; AiCommit provides New-AiCommitSummary)
if (-not (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'Locale.psm1') -Force -DisableNameChecking -Scope Global -ErrorAction SilentlyContinue
}
if (-not (Get-Command New-AiCommitSummary -ErrorAction SilentlyContinue)) {
    $aiPath = Join-Path $PSScriptRoot 'AiCommit.psm1'
    if (Test-Path $aiPath) { Import-Module $aiPath -Force -DisableNameChecking -Scope Global -ErrorAction SilentlyContinue }
}
# Main auto commit function
function Start-AutoCommit {
    param(
        [PSCustomObject]$Config,
        [string]$CommitMessage,
        [string]$RepoRoot = (Get-Location)
    )

Set-StrictMode -Version 1.0
    
    if (-not $Config.autoCommit.enabled) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.autocommit.disabled') -Level Info
        return $false
    }
    
    Push-Location $RepoRoot
    try {
        # Step 1: Smart staging
        if ($Config.autoCommit.smartStaging) {
            $staged = & git diff --cached --name-only
            $smartFiles = Get-SmartAutoStageChanges -StagedFiles $staged -Config $Config.autoCommit
            
            # Unstage all first
            if ($staged) { & git reset HEAD $staged 2>$null }
            
            # Re-stage only smart files
            foreach ($file in $smartFiles) {
                & git add $file 2>$null
            }
            
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.autocommit.smartStaged' -MessageArgs @($($smartFiles.Count))) -Level Info
        }
        
        # Step 2: Security scan
        if ($Config.security.enabled -and $Config.security.blockOnMatch) {
            $blocked = Test-SmartSecretBlocking -SecurityConfig $Config.security
            if ($blocked.Count -gt 0) {
                Write-GSyncError "AutoCommit: Blocked - sensitive files detected: $($blocked -join ', ')"
                return $false
            }
        }
        
        # Step 3: Create commit
        $staged = & git diff --cached --name-only
        if (-not $staged) {
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.autocommit.noFiles') -Level Info
            return $true
        }
        
        $message = $CommitMessage
        if (-not $message) {
            $stagedNow = & git diff --cached --name-only
            # AI-powered concise summary when enabled; graceful-degrade otherwise
            if ((Get-Command New-AiCommitSummary -ErrorAction SilentlyContinue) -and $Config.autoCommit.ai -and $Config.autoCommit.ai.enabled -and ($Config.autoCommit.ai.locale)) {
                $message = New-AiCommitSummary -ChangedFiles @($stagedNow) -Locale $Config.autoCommit.ai.locale -Config $Config
            } else {
                $message = New-CommitMessageSuggestion -StagedFiles $stagedNow -AnalyzeDiff
            }
            if (-not $message) {
                $message = $Config.autoCommit.commitMessageTemplate -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
        }
        
        & git commit -m "$message" -m "Auto-committed by gsync"
        if ($LASTEXITCODE -eq 0) {
            Send-GSyncEventSafe -Name (Get-LocaleMessage -Key 'gsync.msg.autocommit.success' -MessageArgs @($($staged.Count))) -Data @{ files=$staged.Count } | Out-Null; Write-Log "AutoCommit: Success - $($staged.Count) files committed" -Level Success
            return $true
        } else {
            Write-GSyncError "AutoCommit: Commit failed"
            return $false
        }
    }
    finally {
        Pop-Location
    }
}

# Smart secret blocking - check staged files for secrets.
# Delegates content matching to canonical Invoke-SyncSecretScan (Security.psm1).
if (-not (Get-Command Invoke-SyncSecretScan -ErrorAction SilentlyContinue)) {
    $secPath = Join-Path $PSScriptRoot 'Security.psm1'
    if (Test-Path $secPath) { Import-Module $secPath -Force -DisableNameChecking -Scope Global -ErrorAction SilentlyContinue }
}
function Test-SmartSecretBlocking {
    param($SecurityConfig)

    $patterns = @()
    if ($SecurityConfig -and $SecurityConfig.secretPatterns) { $patterns += @($SecurityConfig.secretPatterns) }
    if ($patterns.Count -eq 0 -and (Get-Command Get-SyncSecretPatternCatalog -ErrorAction SilentlyContinue)) {
        $patterns = @(Get-SyncSecretPatternCatalog)
    }
    $staged = @(git diff --cached --name-only)

    if (Get-Command Invoke-SyncSecretScan -ErrorAction SilentlyContinue) {
        $findings = @(Invoke-SyncSecretScan -Files $staged -Patterns $patterns)
        $blocked = @($findings | Select-Object -ExpandProperty File -Unique)
        foreach ($file in $blocked) {
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.security.patternMatch' -MessageArgs @($file)) -Level Error
        }
        return $blocked
    }

    $blocked = @()
    foreach ($file in $staged) {
        if (Test-Path $file) {
            try {
                $content = Get-Content $file -Raw -ErrorAction SilentlyContinue
                foreach ($p in $patterns) {
                    if ($content -match $p) {
                        $blocked += $file
                        Write-Log (Get-LocaleMessage -Key 'gsync.msg.security.patternMatch' -MessageArgs @($file)) -Level Error
                        break
                    }
                }
            }
            catch { }
        }
    }

    return $blocked
}

# Get smart auto-stage changes - filter out excluded files (cross-platform)
function Get-SmartAutoStageChanges {
    param([string[]]$StagedFiles, $AutoConfig)
    
    $smart = @()
    $excludedDirs = $AutoConfig.excludedDirectories
    $excludedExts = $AutoConfig.excludedExtensions
    
    foreach ($file in $StagedFiles) {
        $rawExt = [System.IO.Path]::GetExtension($file)
        $dot = '.'
        $ext = if ($rawExt.StartsWith($dot)) { $rawExt } else { "$dot$rawExt" }


        # Check extension exclusion (normalize: config uses '.ext', GetExtension returns 'ext')
        $excluded = $false
        foreach ($xe in $excludedExts) {
            $normXe = if ([string]$xe -is [string] -and $xe.StartsWith('.')) { $xe } else { ".$xe" }
            if ($ext -eq $normXe) { $excluded = $true; break }
        }
        if ($excluded) { continue }
        
        # Check directory exclusion (normalize path for cross-platform)
        $isExcluded = $false
        $normalized = $file.Replace('\', '/')
        foreach ($d in $excludedDirs) {
            $dirName = $d.TrimEnd('/').TrimEnd('\')
            if ($normalized.StartsWith("$dirName/")) {
                $isExcluded = $true
                break
            }
        }
        if ($isExcluded) { continue }
        
        $smart += $file
    }
    
    return $smart
}

Export-ModuleMember -Function @('Start-AutoCommit', 'Test-SmartSecretBlocking', 'Get-SmartAutoStageChanges')



