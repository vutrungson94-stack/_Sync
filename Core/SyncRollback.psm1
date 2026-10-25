#Requires -Version 5.1

if ($PSVersionTable.PSVersion.Major -ge 7) {
    class SyncRollback {
        [string]$SnapshotsDir

        SyncRollback([string]$snapshotsDir) {
            $this.SnapshotsDir = $snapshotsDir
            if (-not (Test-Path $snapshotsDir)) { New-Item -ItemType Directory -Path $snapshotsDir -Force | Out-Null }
        }

        [hashtable] CreateSnapshot([string]$label) {
            $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $snapshotId = "sync_${timestamp}_$([System.IO.Path]::GetRandomFileName().Replace('.',''))"
            $snapshotDir = Join-Path $this.SnapshotsDir $snapshotId
            New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null

            $branch = & git rev-parse --abbrev-ref HEAD 2>$null
            $commitHash = & git rev-parse HEAD 2>$null
            $stashResult = & git stash create 2>$null

            $snapshot = @{
                Id = $snapshotId
                Timestamp = $timestamp
                Label = $label
                Branch = $branch
                CommitHash = $commitHash
                StashHash = $stashResult
                WorkingDir = (Get-Location).Path
            }

            $snapshot | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $snapshotDir 'snapshot.json') -Encoding utf8

            & git diff HEAD > (Join-Path $snapshotDir 'working.diff') 2>$null

            # UNTRACKED FILES. `git diff HEAD` only captures TRACKED changes,
            # so a file the failed sync created (and never committed) was
            # invisible to the snapshot and survived the restore. The list of
            # untracked files AT SNAPSHOT TIME is recorded, so the restore can
            # tell "this file existed before the snapshot" from "this file
            # appeared after it" and remove only the latter.
            try {
                $untracked = @(& git ls-files --others --exclude-standard 2>$null)
                Set-Content -LiteralPath (Join-Path $snapshotDir 'untracked.txt') -Value $untracked -Encoding utf8
            } catch { }

            return $snapshot
        }

        [bool] RestoreSnapshot([string]$snapshotId, [object]$logger) {
            $snapshotDir = Join-Path $this.SnapshotsDir $snapshotId
            if (-not (Test-Path $snapshotDir)) { return $false }

            $snapshotPath = Join-Path $snapshotDir 'snapshot.json'
            if (-not (Test-Path $snapshotPath)) { return $false }

            $snapshot = Get-Content $snapshotPath -Raw | ConvertFrom-Json

            if ($logger) { $logger.Header((Format-Message -Category Rollback -Key Restoring -Arguments $snapshot.Id, $snapshot.Label)) }

            if ($logger) {
                $logger.Warn((Format-Message -Category Rollback -Key DestructiveWarn -Arguments $snapshot.CommitHash))
            }

            # ORDER MATTERS. The snapshot captures BOTH the committed state
            # (CommitHash) and the uncommitted working-tree diff
            # (working.diff). The restore must put the commit back FIRST and
            # then re-apply the diff. The previous order applied the diff and
            # then ran `git reset --hard`, which DISCARDS the working tree the
            # diff had just restored: the uncommitted work the snapshot
            # existed to preserve was silently destroyed, and the restore
            # only ever brought back the last commit.
            if ($snapshot.CommitHash) {
                $resetErr = & git reset --hard $snapshot.CommitHash 2>&1
                if ($LASTEXITCODE -ne 0) {
                    if ($logger) { $logger.Error("git reset --hard failed: $resetErr") }
                    return $false
                }
                if ($logger) { $logger.Info((Format-Message -Category Rollback -Key ResetDone -Arguments $snapshot.CommitHash)) }
            }

            $diffFile = Join-Path $snapshotDir 'working.diff'
            if (Test-Path $diffFile) {
                $diffContent = Get-Content $diffFile -Raw
                if ($diffContent -and $diffContent.Trim()) {
                    $stashErr = & git stash 2>&1
                    if ($LASTEXITCODE -ne 0 -and $logger) { $logger.Warn("Stash before restore failed: $stashErr") }
                    $applyErr = & git apply $diffFile 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        if ($logger) { $logger.Error("Failed to apply snapshot diff: $applyErr") }
                        return $false
                    }
                    if ($logger) { $logger.Info((Get-Message -Category Rollback -Key DiffApplied)) }
                }
            }

            if ($snapshot.Branch) {
                $checkoutErr = & git checkout $snapshot.Branch 2>&1
                if ($LASTEXITCODE -ne 0) {
                    if ($logger) { $logger.Warn((Format-Message -Category Rollback -Key BranchFail -Arguments $checkoutErr)) }
                } else {
                    if ($logger) { $logger.Info((Format-Message -Category Rollback -Key BranchDone -Arguments $snapshot.Branch)) }
                }
            }

            # Remove the untracked files that appeared AFTER the snapshot.
            $removed = Remove-GSyncPostSnapshotUntracked -SnapshotDir $snapshotDir -WorkingDir ([string]$snapshot.WorkingDir)
            if ($removed.Count -gt 0 -and $logger) {
                $logger.Info((Format-Message -Category Rollback -Key DiffApplied))
            }

            if ($logger) { $logger.Success((Format-Message -Category Rollback -Key Restored -Arguments $snapshotId)) }
            return $true
        }

        [array] ListSnapshots() {
            $result = @()
            if (-not (Test-Path $this.SnapshotsDir)) { return $result }
            foreach ($dir in (Get-ChildItem $this.SnapshotsDir -Directory)) {
                $snapPath = Join-Path $dir.FullName 'snapshot.json'
                if (Test-Path $snapPath) {
                    $snap = Get-Content $snapPath -Raw | ConvertFrom-Json
                    $result += $snap
                }
            }
            return $result
        }

        [bool] RemoveSnapshot([string]$snapshotId) {
            $snapshotDir = Join-Path $this.SnapshotsDir $snapshotId
            if (-not (Test-Path $snapshotDir)) { return $false }
            Remove-Item -Path $snapshotDir -Recurse -Force
            return $true
        }
    }
}

<#
.SYNOPSIS
    Removes the untracked files that appeared after a snapshot was taken.
.DESCRIPTION
    The snapshot records the untracked files it saw (untracked.txt). On
    restore, the CURRENT untracked set is compared with that record and only
    the files that are new are deleted - the ones the failed sync created and
    never committed. Files that existed when the snapshot was taken are left
    alone, so the restore never removes something it cannot prove the sync
    created.

    Every candidate is checked to be inside the repository root before it is
    deleted: a path that escapes the root is skipped, never followed.
#>
function Remove-GSyncPostSnapshotUntracked {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$SnapshotDir,
        [string]$WorkingDir = ''
    )
    $removed = [System.Collections.Generic.List[string]]::new()
    $snapshotUntrackedFile = Join-Path $SnapshotDir 'untracked.txt'
    if (-not (Test-Path -LiteralPath $snapshotUntrackedFile -PathType Leaf)) { return @() }
    $root = if ($WorkingDir) { $WorkingDir } else { (Get-Location).Path }
    try { $root = [System.IO.Path]::GetFullPath($root) } catch { return @() }
    $known = @()
    try { $known = @(Get-Content -LiteralPath $snapshotUntrackedFile -ErrorAction SilentlyContinue | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) } catch { $known = @() }
    $current = @()
    try { $current = @(& git ls-files --others --exclude-standard 2>$null | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) } catch { $current = @() }
    foreach ($f in $current) {
        if ($known -contains $f) { continue }
        $full = $f
        try { $full = [System.IO.Path]::GetFullPath((Join-Path $root $f)) } catch { continue }
        # CONTAINMENT: never delete anything outside the repository root.
        if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        try {
            Remove-Item -LiteralPath $full -Force -ErrorAction Stop
            $removed.Add($f) | Out-Null
        } catch { }
    }
    return @($removed.ToArray())
}

function New-SyncSnapshot {
    [CmdletBinding()]
    param(
        [string]$Label = "manual",
        [string]$SnapshotsDir
    )

Set-StrictMode -Version 1.0
    if (-not $SnapshotsDir) {
        $scriptRoot = if ($PSScriptRoot -match '_Sync[\\/]Core') {
            (Split-Path $PSScriptRoot -Parent)
        } else {
            (Split-Path $PSScriptRoot -Parent)
        }
        $SnapshotsDir = Join-Path $scriptRoot $script:SyncConstants.SnapshotsDirName
    }
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $rb = [SyncRollback]::new($SnapshotsDir)
        return $rb.CreateSnapshot($Label)
    }
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $snapshotId = "sync_${timestamp}_$([System.IO.Path]::GetRandomFileName().Replace('.',''))"
    $snapshotDir = Join-Path $SnapshotsDir $snapshotId
    if (-not (Test-Path $SnapshotsDir)) { New-Item -ItemType Directory -Path $SnapshotsDir -Force | Out-Null }
    New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
    $branch = & git rev-parse --abbrev-ref HEAD 2>$null
    $commitHash = & git rev-parse HEAD 2>$null
    $stashResult = & git stash create 2>$null
    $snapshot = @{
        Id = $snapshotId
        Timestamp = $timestamp
        Label = $Label
        Branch = $branch
        CommitHash = $commitHash
        StashHash = $stashResult
        WorkingDir = (Get-Location).Path
    }
    $snapshot | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $snapshotDir 'snapshot.json') -Encoding utf8
    & git diff HEAD > (Join-Path $snapshotDir 'working.diff') 2>$null
    # UNTRACKED FILES - see the comment in the PS 7 branch above.
    try {
        $untracked = @(& git ls-files --others --exclude-standard 2>$null)
        Set-Content -LiteralPath (Join-Path $snapshotDir 'untracked.txt') -Value $untracked -Encoding utf8
    } catch { }
    return $snapshot
}

function Restore-SyncSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SnapshotId,
        [string]$SnapshotsDir,
        [object]$Logger = $null
    )
    if (-not $SnapshotsDir) {
        $scriptRoot = if ($PSScriptRoot -match '_Sync[\\/]Core') {
            (Split-Path $PSScriptRoot -Parent)
        } else {
            (Split-Path $PSScriptRoot -Parent)
        }
        $SnapshotsDir = Join-Path $scriptRoot $script:SyncConstants.SnapshotsDirName
    }
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $rb = [SyncRollback]::new($SnapshotsDir)
        return $rb.RestoreSnapshot($SnapshotId, $Logger)
    }
    $snapshotDir = Join-Path $SnapshotsDir $SnapshotId
    if (-not (Test-Path $snapshotDir)) { return $false }
    $snapshotPath = Join-Path $snapshotDir 'snapshot.json'
    if (-not (Test-Path $snapshotPath)) { return $false }
    $snapshot = Get-Content $snapshotPath -Raw | ConvertFrom-Json
    if ($Logger) { $Logger.Header("Restoring snapshot: $($snapshot.Id) - $($snapshot.Label)") }
    if ($Logger) { $Logger.Warn("This will reset the repo to commit $($snapshot.CommitHash)") }
    # ORDER MATTERS - see the comment in the PS 7 branch above: the commit is
    # restored FIRST, the working-tree diff is applied AFTER it. Applying the
    # diff first and resetting afterwards destroyed the uncommitted work.
    if ($snapshot.CommitHash) {
        $resetErr = & git reset --hard $snapshot.CommitHash 2>&1
        if ($LASTEXITCODE -ne 0) {
            if ($Logger) { $Logger.Error("git reset --hard failed: $resetErr") }
            return $false
        }
        if ($Logger) { $Logger.Info("Reset to $($snapshot.CommitHash)") }
    }
    $diffFile = Join-Path $snapshotDir 'working.diff'
    if (Test-Path $diffFile) {
        $diffContent = Get-Content $diffFile -Raw
        if ($diffContent -and $diffContent.Trim()) {
            $stashErr = & git stash 2>&1
            if ($LASTEXITCODE -ne 0 -and $Logger) { $Logger.Warn("Stash before restore failed: $stashErr") }
            $applyErr = & git apply $diffFile 2>&1
            if ($LASTEXITCODE -ne 0) {
                if ($Logger) { $Logger.Error("Failed to apply snapshot diff: $applyErr") }
                return $false
            }
            if ($Logger) { $Logger.Info("Working diff applied") }
        }
    }
    if ($snapshot.Branch) {
        $checkoutErr = & git checkout $snapshot.Branch 2>&1
        if ($LASTEXITCODE -ne 0) {
            if ($Logger) { $Logger.Warn("git checkout failed: $checkoutErr") }
        } else {
            if ($Logger) { $Logger.Info("Checked out branch $($snapshot.Branch)") }
        }
    }
    # Remove the untracked files that appeared AFTER the snapshot.
    $null = Remove-GSyncPostSnapshotUntracked -SnapshotDir $snapshotDir -WorkingDir ([string]$snapshot.WorkingDir)
    if ($Logger) { $Logger.Success("Restored snapshot: $SnapshotId") }
    return $true
}

function Get-SyncSnapshots {
    [CmdletBinding()]
    param(
        [string]$SnapshotsDir
    )
    if (-not $SnapshotsDir) {
        $scriptRoot = if ($PSScriptRoot -match '_Sync[\\/]Core') {
            (Split-Path $PSScriptRoot -Parent)
        } else {
            (Split-Path $PSScriptRoot -Parent)
        }
        $SnapshotsDir = Join-Path $scriptRoot $script:SyncConstants.SnapshotsDirName
    }
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $rb = [SyncRollback]::new($SnapshotsDir)
        return $rb.ListSnapshots()
    }
    $result = @()
    if (-not (Test-Path $SnapshotsDir)) { return $result }
    foreach ($dir in (Get-ChildItem $SnapshotsDir -Directory)) {
        $snapPath = Join-Path $dir.FullName 'snapshot.json'
        if (Test-Path $snapPath) {
            $snap = Get-Content $snapPath -Raw | ConvertFrom-Json
            $result += $snap
        }
    }
    return $result
}

function Remove-SyncSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SnapshotId,
        [string]$SnapshotsDir
    )
    if (-not $SnapshotsDir) {
        $scriptRoot = if ($PSScriptRoot -match '_Sync[\\/]Core') {
            (Split-Path $PSScriptRoot -Parent)
        } else {
            (Split-Path $PSScriptRoot -Parent)
        }
        $SnapshotsDir = Join-Path $scriptRoot $script:SyncConstants.SnapshotsDirName
    }
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $rb = [SyncRollback]::new($SnapshotsDir)
        return $rb.RemoveSnapshot($SnapshotId)
    }
    $snapshotDir = Join-Path $SnapshotsDir $SnapshotId
    if (-not (Test-Path $snapshotDir)) { return $false }
    Remove-Item -Path $snapshotDir -Recurse -Force
    return $true
}

Export-ModuleMember -Function @('New-SyncSnapshot', 'Restore-SyncSnapshot', 'Get-SyncSnapshots', 'Remove-SyncSnapshot', 'Remove-GSyncPostSnapshotUntracked')


