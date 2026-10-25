#Requires -Version 5.1
param($Config)

# The shared bootstrap makes the logger and the locale resolver available.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1')
Set-StrictMode -Version 1.0
$script:EmDash = if ($PSVersionTable.PSVersion -ge [Version]'5.1') { [char]0x2014 } else { '-' }

# Pre-commit hook: validate commit before allowing it (Non-Interactive Auto-Smart)
Write-Debug (Get-LocaleMessage -Key 'gsync.msg.hook.preCommitStarted')

# --- Auto Smart Commit Integration ---
if ($Config.autoCommit -and $Config.autoCommit.enabled) {
    # Step 1: Smart auto-staging
    if ($Config.autoCommit.smartStaging) {
        $staged = & git diff --cached --name-only
        if ($staged) {
            # Unstage all
            & git reset HEAD $staged 2>$null
            
            # Re-stage only smart changes
            foreach ($file in $staged) {
                $ext = [System.IO.Path]::GetExtension($file)
                $excludedExts = $Config.autoCommit.excludedExtensions
                
                # Check extension
                if ($excludedExts -contains $ext) { continue }
                
                # Check directory exclusion
                $excludedDirs = $Config.autoCommit.excludedDirectories
                $isExcluded = $false
                $normalized = $file.Replace('\', '/')
                foreach ($d in $excludedDirs) {
                    $dirName = $d.TrimEnd('/').TrimEnd('\')
                    if ($normalized.StartsWith("$dirName/")) {
                        $isExcluded = $true; break
                    }
                }
                if (-not $isExcluded) { & git add $file 2>$null }
            }
        }
    }
    
    # Step 2: Smart secret blocking (canonical scanner in Security.psm1)
    if ($Config.security -and $Config.security.enabled -and $Config.security.blockOnMatch) {
        $patterns = @($Config.security.secretPatterns)
        if ($patterns.Count -eq 0 -and (Get-Command Get-SyncSecretPatternCatalog -ErrorAction SilentlyContinue)) {
            $patterns = @(Get-SyncSecretPatternCatalog)
        }
        $staged = @(git diff --cached --name-only)
        $blocked = @()
        if (Get-Command Invoke-SyncSecretScan -ErrorAction SilentlyContinue) {
            $blocked = @((Invoke-SyncSecretScan -Files $staged -Patterns $patterns) | Select-Object -ExpandProperty File -Unique)
        } else {
            foreach ($file in $staged) {
                if (Test-Path $file) {
                    try {
                        $content = Get-Content $file -Raw -ErrorAction SilentlyContinue
                        foreach ($p in $patterns) {
                            if ($content -match $p) {
                                $blocked += $file
                                break
                            }
                        }
                    } catch { }
                }
            }
        }
        
        if ($blocked.Count -gt 0) {
            Write-Warning (Get-LocaleMessage -Key 'gsync.msg.hook.autoBlock' -MessageArgs @($($blocked.Count)))
            $blocked | ForEach-Object { Write-Warning "  - $_ " }
              if (Get-Command Send-SyncNotification -ErrorAction SilentlyContinue) {
                  Send-SyncNotification -Config $Config -Status "blocked" -Message "Sensitive files detected" | Out-Null
              }
            
            # Emit security event
            if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
                Send-BuildEvent -Name 'gsync.security.secret-detected' -Data @{
                    blockedFiles = $blocked
                    count = $blocked.Count
                    timestamp = (Get-Date).ToString('o')
                }
            }
            return $false
        }
    }
}

# --- Backward Compatible Legacy Checks ---
# 3. Junk cleanup if enabled (legacy)
if ($Config.junkCleanup -and $Config.junkCleanup.enabled) {
    $patterns = $Config.junkCleanup.patterns
    if ($patterns) {
        $staged = & git diff --cached --name-only
        foreach ($file in $staged) {
            foreach ($pattern in $patterns) {
                if ($file -like $pattern) {
                    Write-Warning (Get-LocaleMessage -Key 'gsync.msg.hook.stagedJunk' -MessageArgs @($file))
                    if ($Config.junkCleanup.confirmBeforeDelete) {
                        return $false
                    }
                }
            }
        }
    }
}

# 4. Secret scan if enabled (legacy) — same canonical catalog as Step 2
if ($Config.secretScan -and $Config.secretScan.enabled) {
    $staged = @(git diff --cached --name-only)
    if (Get-Command Get-SyncSecretPatternCatalog -ErrorAction SilentlyContinue) {
        $legacyPatterns = @(Get-SyncSecretPatternCatalog)
    } else {
        $legacyPatterns = @('(?i)(sk-or-v1-|ghp_|gho_|ghu_|ghs_|ghr_|npm_[a-z0-9]{36}|token.*=.*[A-Za-z0-9]{20,})')
    }
    $legacyBlocked = $false
    if (Get-Command Invoke-SyncSecretScan -ErrorAction SilentlyContinue) {
        $legacyBlocked = @((Invoke-SyncSecretScan -Files $staged -Patterns $legacyPatterns) | Select-Object -ExpandProperty File -Unique)
    } else {
        foreach ($file in $staged) {
            if (Test-Path $file) {
                $content = Get-Content $file -Raw -ErrorAction SilentlyContinue
                foreach ($lp in $legacyPatterns) {
                    if ($content -match $lp) { $legacyBlocked = @($file); break }
                }
                if ($legacyBlocked) { break }
            }
        }
    }
    foreach ($file in @($legacyBlocked)) {
        Write-Warning (Get-LocaleMessage -Key 'gsync.msg.hook.secretDetected' -MessageArgs @($file))
        return $false
    }
}

# Emit event for commit preparation
if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
    $stagedFiles = & git diff --cached --name-only
    Send-BuildEvent -Name 'gsync.commit.started' -Data @{
        stagedFiles = ($stagedFiles | Measure-Object).Count
        timestamp = (Get-Date).ToString('o')
    }
}

Write-Debug (Get-LocaleMessage -Key 'gsync.msg.hook.preCommitPassed')
return $true
