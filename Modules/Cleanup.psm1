#Requires -Version 5.1
# Cleanup.psm1

# Make the logger available when this module is imported on its own.

. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('UI')
function Get-JunkPatterns {
    [CmdletBinding()]
    param()

Set-StrictMode -Version 1.0
    # NOTE: '*.log' is deliberately NOT a junk pattern. The shipped config
    # matched '*.log' under restrictToDirs ['.'] and the cleanup pass deleted
    # the log file the tool was actively writing to, plus the audit trail.
    return @('*~', '*.tmp', 'Thumbs.db', '*.bak', 'test-*.txt', 'test-out*.txt', '*-output.txt', 'test-final.txt')
}

function Get-CleanupPatterns {
    [CmdletBinding()]
    param(
        [hashtable]$Config = @{}
    )
    if ($Config -and $Config.ContainsKey('patterns')) {
        return @($Config.patterns)
    }
    if ($Config -and $Config.ContainsKey('junkCleanup') -and $Config.junkCleanup -is [hashtable] -and $Config.junkCleanup.ContainsKey('patterns')) {
        return @($Config.junkCleanup.patterns)
    }
    return @('*.tmp', 'Thumbs.db', '*.cache', 'test-*.txt', 'test-out*.txt', '*-output.txt', 'test-final.txt')
}

function Test-GSyncProtectedPath {
    <#
    .SYNOPSIS
        True when a path must never be deleted by the cleanup pass.
    .DESCRIPTION
        The cleanup pass walks the working tree and deletes whatever matches
        the configured patterns. Without a protected set it deleted the tool's
        own log file, its state file and its snapshots - the files the run
        depends on. These paths are the tool's own state and are excluded.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full = $Path
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { }

    $leaf = [System.IO.Path]::GetFileName($full)
    # The tool's own runtime state.
    if ($leaf -eq '.gsync.log' -or $leaf -eq '.gsync.log.json' -or $leaf -eq '.gsync.state') { return $true }
    if ($leaf -like '.gsync_*.state' -or $leaf -like '.gsync_*.log') { return $true }

    # Anything inside these directories is tool state, not junk.
    $segments = ($full -replace '\\', '/') -split '/'
    foreach ($protected in @('.git', '.sync_snapshots', 'logs', 'TestResults', 'build-reports', '.gbuildcache')) {
        if ($segments -contains $protected) { return $true }
    }
    return $false
}

function Remove-JunkFiles {
    param([string[]]$Patterns, [string[]]$RestrictDirs, [bool]$Confirm, [switch]$DryRun)
    $junk = @()
    foreach ($dir in $RestrictDirs) {
        if (-not (Test-Path $dir)) { continue }
        foreach ($pat in $Patterns) {
            $junk += Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like $pat -and -not (Test-GSyncProtectedPath -Path $_.FullName) }
        }
    }
    $junk = $junk | Sort-Object FullName -Unique
    if ($junk.Count -eq 0) { return }
    Write-Log (Get-LocaleMessage -Key 'gsync.msg.cleanup.detected' -MessageArgs @($($junk.Count))) -Level Warn
    if ($Confirm -and (-not $DryRun)) {
        if (-not (Confirm-YesNo "Delete $($junk.Count) junk files?" -Default "n")) { return }
    }
    foreach ($f in $junk) {
        if ($DryRun) {
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.dryRun.wouldDelete' -MessageArgs @($($f.FullName))) -Level Info
        } else {
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.cleanup.deletedFile' -MessageArgs @($f.Name)) -Level Info
        }
    }
    if (-not $DryRun) { Write-Log (Get-LocaleMessage -Key 'gsync.msg.cleanup.deleted' -MessageArgs @($($junk.Count))) -Level Success }
}

function Find-LargeFiles {
    param([double]$ThresholdMB, [string[]]$ExcludeDirs)
    $thresholdBytes = $ThresholdMB * 1MB
    $allFiles = Get-ChildItem -Path . -Recurse -File -ErrorAction SilentlyContinue
    # Parallel filtering for PS7+
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $largeFiles = $allFiles | ForEach-Object -Parallel {
            $f = $_
            $exclude = $using:ExcludeDirs
            $threshold = $using:thresholdBytes
            $excluded = $false
            foreach ($d in $exclude) {
                if ($f.FullName -match "(^|[$([regex]::Escape([IO.Path]::DirectorySeparatorChar))])$([regex]::Escape($d))($|[$([regex]::Escape([IO.Path]::DirectorySeparatorChar))])") {
                    $excluded = $true; break
                }
            }
            if (-not $excluded -and $f.Length -gt $threshold) { $f }
        }
    } else {
        $largeFiles = @()
        foreach ($f in $allFiles) {
            $excluded = $false
            foreach ($d in $ExcludeDirs) {
                if ($f.FullName -match "(^|[$([regex]::Escape([IO.Path]::DirectorySeparatorChar))])$([regex]::Escape($d))($|[$([regex]::Escape([IO.Path]::DirectorySeparatorChar))])") {
                    $excluded = $true; break
                }
            }
            if (-not $excluded -and $f.Length -gt $thresholdBytes) { $largeFiles += $f }
        }
    }
    return $largeFiles
}

function Show-LargeFiles {
    param([object[]]$Files, [int]$MaxDisplay = 25)
    $count = $Files.Count
    for ($i = 0; $i -lt [Math]::Min($count, $MaxDisplay); $i++) {
        $f = $Files[$i]
        Write-SubLog (Get-LocaleMessage -Key 'gsync.msg.cleanup.largeFile' -MessageArgs @($($f.Name))) "$([Math]::Round($f.Length/1MB,2)) MB" (Resolve-SafeColor -ColorName 'Warn' -Fallback 'Yellow')
    }
    if ($count -gt $MaxDisplay) {
        Write-Host (Get-LocaleMessage -Key 'gsync.msg.cleanup.moreFiles' -MessageArgs @($($count - $MaxDisplay))) -ForegroundColor (Resolve-SafeColor -ColorName 'Gray' -Fallback 'DarkGray')
    }
}

Export-ModuleMember -Function @('Remove-JunkFiles', 'Find-LargeFiles', 'Show-LargeFiles', 'Get-JunkPatterns', 'Get-CleanupPatterns', 'Test-GSyncProtectedPath')


