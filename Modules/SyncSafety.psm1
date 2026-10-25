#Requires -Version 5.1
# SyncSafety.psm1

# Declare the sibling modules this one calls into.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('Security')
# safe divergent-sync decision for _Sync
# Determines code-quality preference when local and remote have diverged.
# Requires -Version 5.1

function Get-GitCommitSnapshot {
    [CmdletBinding()]
    param(
        [Parameter()][string]$Ref = 'HEAD',
        [Parameter()][string]$RepoRoot = ''
    )

Set-StrictMode -Version 1.0
    $restore = $false
    if ($RepoRoot -and (Test-Path -LiteralPath $RepoRoot -PathType Container)) { Push-Location -LiteralPath $RepoRoot; $restore = $true }
    try {
        $hash = (& git rev-parse $Ref 2>$null | Out-String).Trim()
        if (-not $hash) { return $null }
        $short = (& git rev-parse --short $hash 2>$null | Out-String).Trim()
        $subject = (& git log -1 --format=%s $hash 2>$null | Out-String).Trim()
        $authorDate = (& git log -1 --format=%ci $hash 2>$null | Out-String).Trim()

        $fileLines = @(& git diff-tree --no-commit-id --name-only -r $hash 2>$null)
        $files = @($fileLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
        $numstatLines = @(& git show --format='' --numstat $hash 2>$null)
        $insertions = 0; $deletions = 0
        foreach ($n in $numstatLines) {
            if ($n -match '^(\d+)\s+(\d+)\s+') {
                $insertions += [int]$Matches[1]
                $deletions += [int]$Matches[2]
            }
        }
        $testFiles = @($files | Where-Object {
            $_ -match '(^|/)(test|tests|spec|__tests__)(/|$)' -or $_ -match '(^|/).*\.(test|spec)\.[^.]+$'
        })
        $buildFiles = @($files | Where-Object { $_ -match '(^|/)(package\.json|pyproject\.toml|csproj|sln|Cargo\.toml|go\.mod|pom\.xml|build\.gradle)$' -or $_ -match '\.github/' })

        $conventional = $false
        try { $conventional = ($subject -match '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?:\s+\S') } catch { $conventional = $false }

        $score = 0
        if ($conventional) { $score += 2 }
        $score += [Math]::Min(3, $testFiles.Count)
        $score += [Math]::Max(0, (8 - [Math]::Min(8, $files.Count)))
        $score += [Math]::Min(2, $buildFiles.Count)
        if (($insertions + $deletions) -gt 800) { $score -= 2 }
        try {
            $diffText = (& git show --format='' $hash 2>$null | Out-String)
            if (Get-Command Test-SyncSecretContent -ErrorAction SilentlyContinue) {
                if (Test-SyncSecretContent -Content $diffText -Patterns @(Get-SyncSecretPatternCatalog)) { $score -= 5 }
            }
        } catch { }

        return [PSCustomObject]@{
            Hash          = $hash
            ShortHash     = $short
            Subject       = $subject
            AuthorDate    = $authorDate
            FileCount     = $files.Count
            Insertions    = $insertions
            Deletions     = $deletions
            Files         = $files
            TestFiles     = $testFiles
            BuildFiles    = $buildFiles
            Conventional  = $conventional
            Score         = $score
        }
    } catch {
        return $null
    } finally {
        if ($restore) { Pop-Location }
    }
}

function Compare-GitSyncSides {
    [CmdletBinding()]
    param(
        [string]$LocalRef = 'HEAD',
        [Parameter(Mandatory)][string]$RemoteRef,
        [int]$QualityThreshold = 2,
        [string]$RepoRoot = ''
    )
    $result = [PSCustomObject]@{
        MergeBase         = ''
        LocalAheadCount   = 0
        RemoteAheadCount  = 0
        Relationship      = 'Unknown'
        LocalSnapshot     = $null
        RemoteSnapshot    = $null
        QualityDifference = 0
        QualityWinner     = 'None'
        Recommendation    = 'Unknown'
        Reason            = ''
    }
    $restore = $false
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        if ($RepoRoot -and (Test-Path -LiteralPath $RepoRoot -PathType Container)) { Push-Location -LiteralPath $RepoRoot; $restore = $true }
        $base = (& git merge-base $LocalRef $RemoteRef 2>$null | Out-String).Trim()
        $result.MergeBase = $base
        if (-not $base) {
            $result.Relationship = 'Unrelated'
            $result.Recommendation = 'uncertain'
            $result.Reason = 'No common ancestor / uninitialized side.'
            return $result
        }
        $la = (& git rev-list --count "$base..$LocalRef" 2>$null | Out-String).Trim()
        $ra = (& git rev-list --count "$base..$RemoteRef" 2>$null | Out-String).Trim()
        $result.LocalAheadCount = if ($la -match '^\d+$') { [int]$la } else { 0 }
        $result.RemoteAheadCount = if ($ra -match '^\d+$') { [int]$ra } else { 0 }

        if ($result.LocalAheadCount -eq 0 -and $result.RemoteAheadCount -eq 0) {
            $result.Relationship = 'Equal'
            $result.Recommendation = 'Equal'
            $result.Reason = 'Local and remote are at the same commit.'
            return $result
        }
        if ($result.LocalAheadCount -gt 0 -and $result.RemoteAheadCount -eq 0) {
            $result.Relationship = 'LocalAhead'
            $result.Recommendation = 'LocalAhead'
            $result.Reason = 'Local is ahead; safe fast-forward push.'
            return $result
        }
        if ($result.RemoteAheadCount -gt 0 -and $result.LocalAheadCount -eq 0) {
            $result.Relationship = 'RemoteAhead'
            $result.Recommendation = 'RemoteAhead'
            $result.Reason = 'Remote is ahead; safe fast-forward pull.'
            return $result
        }

        $result.Relationship = 'Diverged'
        $snapL = Get-GitCommitSnapshot -Ref $LocalRef
        $snapR = Get-GitCommitSnapshot -Ref $RemoteRef
        $result.LocalSnapshot = $snapL
        $result.RemoteSnapshot = $snapR
        if (-not $snapL -or -not $snapR) {
            $result.Recommendation = 'uncertain'
            $result.Reason = 'Could not read one side metrics.'
            return $result
        }
        $diff = $snapL.Score - $snapR.Score
        $result.QualityDifference = $diff
        if ([Math]::Abs($diff) -lt $QualityThreshold) {
            $result.QualityWinner = 'Tie'
            $result.Recommendation = 'uncertain'
            $result.Reason = "Quality scores tied (local=$($snapL.Score), remote=$($snapR.Score)); refusing to auto-resolve."
            return $result
        }
        if ($diff -gt 0) {
            $result.QualityWinner = 'Local'
            $result.Recommendation = 'prefer-local'
            $result.Reason = "Local side scored higher (local=$($snapL.Score), remote=$($snapR.Score)); keep local and force-with-lease push."
        } else {
            $result.QualityWinner = 'Remote'
            $result.Recommendation = 'prefer-remote'
            $result.Reason = "Remote side scored higher (remote=$($snapR.Score), local=$($snapL.Score)); fast-forward local to remote."
        }
        return $result
    } catch {
        $result.Recommendation = 'uncertain'
        $result.Reason = "Comparison error: $($_.Exception.Message)"
        return $result
    } finally {
        $ErrorActionPreference = $oldEap
        if ($restore) { Pop-Location }
    }
}

Export-ModuleMember -Function @('Get-GitCommitSnapshot', 'Compare-GitSyncSides')
