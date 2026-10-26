#Requires -Version 5.1
# GitUtils.psm1

# Make the logger available when this module is imported on its own.

. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('UI')
function Initialize-SshKey {
    # ssh_id read from env var GSYNC_SSH_KEY_PATH -> fallback to _Sync/ssh_id
    $syncDir    = Split-Path -Parent $PSScriptRoot
    $sshKeyPath = if ($env:GSYNC_SSH_KEY_PATH) { $env:GSYNC_SSH_KEY_PATH } else { Join-Path $syncDir 'ssh_id' }
    if (-not (Test-Path $sshKeyPath)) { return }
    $resolved = (Resolve-Path $sshKeyPath).Path
    $escaped = $resolved -replace '"', '\"'
    $env:GIT_SSH_COMMAND = "ssh -i `"$escaped`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    Write-SubLog (Get-LocaleMessage -Key 'gsync.msg.step.sshKey') "Loaded ($resolved)" (Resolve-SafeColor -ColorName 'Succ' -Fallback 'Green')
}

function Test-GitVersion {
    param([string]$Minimum)

Set-StrictMode -Version 1.0
    $v = & git --version 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    if ($v -match '(\d+\.\d+\.\d+)') {
        $ver = [version]$matches[1]
        $min = [version]$Minimum
        return $ver -ge $min
    }
    return $false
}

function Test-GitRepository {
    param([string]$Path)
    if ($Path) { $null = & git -C $Path rev-parse --is-inside-work-tree 2>&1 }
    else { $null = & git rev-parse --is-inside-work-tree 2>&1 }
    return $LASTEXITCODE -eq 0
}

function Test-GitProjectRoot {
    <#
    .SYNOPSIS
        True when the directory looks like a project root, not a folder of
        other repositories.
    .DESCRIPTION
        A directory that CONTAINS git repositories but is not itself one is
        a folder of projects. Initialising git there creates a repository
        that wraps every project below it, and the folder is not a project
        at all. The git operations must go to the project, never to such a
        folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    if (Test-Path -LiteralPath (Join-Path $Path '.git')) { return $true }
    $childRepos = @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') })
    if ($childRepos.Count -gt 0) { return $false }
    return $true
}

function Initialize-GitRepository {
    <#
    .SYNOPSIS
        Initialises a git repository at an EXPLICIT path and syncs it from
        the given remote.
    .DESCRIPTION
        The function used to run "git init" in the process working
        directory. When the tool was started from a folder that merely
        CONTAINS repositories, that created a new repository around all of
        them - git state appearing outside the project the tool was pointed
        at. The target path is now explicit, every git command is run with
        -C against it, and a directory that holds other repositories is
        refused unless the caller insists.
    #>
    param(
        [string]$RepoUrl,
        [string]$Path,
        [switch]$Force
    )
    $target = if ($Path) { (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path } else { (Get-Location).Path }
    if (-not $target) { Write-GSyncError "Target path does not exist: $Path"; return $false }

    if (-not $Force -and -not (Test-GitProjectRoot -Path $target)) {
        Write-GSyncError "Refusing to initialise git in '$target': it contains other repositories and is not itself a project. Pass -Force if that is really what you want."
        return $false
    }

    Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.initializing' -MessageArgs @($target, $RepoUrl)) -Level Info
    & git -C $target init
    if ($LASTEXITCODE -ne 0) { Write-GSyncError "git init failed"; return $false }
    $null = & git -C $target remote get-url origin 2>$null
    if ($LASTEXITCODE -eq 0) {
        & git -C $target remote set-url origin $RepoUrl
    } else {
        & git -C $target remote add origin $RepoUrl
    }
    & git -C $target fetch origin --prune
    if ($LASTEXITCODE -ne 0) { Write-GSyncError "fetch failed - check URL/network"; return $false }
    $lsRemote = (& git -C $target ls-remote --symref origin HEAD 2>$null) -join "`n"
    $branch = "main"
    if ($lsRemote -match "ref: refs/heads/(?<b>\S+)\s+HEAD") { $branch = $Matches.b }
    & git -C $target checkout -B $branch "origin/$branch" -f
    if ($LASTEXITCODE -ne 0) { Write-GSyncError "checkout '$branch' failed"; return $false }
    & git -C $target branch --set-upstream-to="origin/$branch" $branch
    Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.synced') -Level Success
    return $true
}

function Clear-GitLock {
    param([string]$Path)
    $base = if ($Path) { $Path } else { (Get-Location).Path }
    $lockFile = Join-Path $base ".git/index.lock"
    if (Test-Path $lockFile) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.lockDetected') -Level Warn
        Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
        if (Test-Path $lockFile) {
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.lockDeleteFailed') -Level Error
            return $false   # ← Don't throw; caller handles $false
        }
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.lockDeleted') -Level Success
    }
    return $true
}

function Get-GitConflictType {
    $gitDir = & git rev-parse --git-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $gitDir) { return $null }
    if ((Test-Path (Join-Path $gitDir "rebase-merge")) -or (Test-Path (Join-Path $gitDir "rebase-apply"))) { return "rebase" }
    if (Test-Path (Join-Path $gitDir "MERGE_HEAD")) { return "merge" }
    if (Test-Path (Join-Path $gitDir "CHERRY_PICK_HEAD")) { return "cherry-pick" }
    return $null
}

function Invoke-GitAbort {
    param([string]$ConflictType)
    try {
        switch ($ConflictType) {
            "rebase"      { & git rebase --abort }
            "merge"       { & git merge --abort }
            "cherry-pick" { & git cherry-pick --abort }
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.cannotAbort' -MessageArgs @($ConflictType)) -Level Error
            return $false
        }
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.aborted' -MessageArgs @($ConflictType)) -Level Success
        return $true
    } catch { return $false }
}

function Invoke-GitConflictHandler {
    param([string]$ConflictType)
    try {
        $typeLabel = if ($ConflictType) { $ConflictType } else { "git operation" }
        Write-Host (Get-LocaleMessage -Key 'gsync.msg.git.conflict' -MessageArgs @($typeLabel)) -ForegroundColor (Resolve-SafeColor -ColorName 'Warn' -Fallback 'Yellow')
        Write-Host (Get-LocaleMessage -Key 'gsync.msg.git.resolutionGuide') -ForegroundColor (Resolve-SafeColor -ColorName 'Info' -Fallback 'Cyan')
        Write-Host (Get-LocaleMessage -Key 'gsync.msg.git.conflictViewFiles')
        Write-Host (Get-LocaleMessage -Key 'gsync.msg.git.conflictEditFiles')
        if ($ConflictType) { Write-Host (Get-LocaleMessage -Key 'gsync.msg.git.conflictContinue' -MessageArgs @($typeLabel)) }
        Write-Host (Get-LocaleMessage -Key 'gsync.msg.git.conflictAbort' -MessageArgs @($typeLabel))
        if (Confirm-YesNo "Show conflict file list?" -Default "y") {
            $files = & git diff --name-only --diff-filter=U 2>$null
            if ($files) { $files | ForEach-Object { Write-Host "      $_" -ForegroundColor (Resolve-SafeColor -ColorName 'Warn' -Fallback 'Yellow') } }
        }
        return $false
    } catch { return $false }
}

function Get-CurrentBranch {
    param([Object]$Config)
    $branch = & git branch --show-current 2>$null
    if (-not $branch) {
        $branch = & git rev-parse --abbrev-ref HEAD 2>$null
    }
    if (-not $branch -or $branch -eq 'HEAD') {
        $fallback = 'main'
        try { if ($Config -and $Config.git -and $Config.git.defaultBranchFallback) { $fallback = $Config.git.defaultBranchFallback } } catch { }
        if (-not (Test-InteractiveSession)) { $branch = $fallback }
        else {
            $inp = Read-Host "Enter branch name (Enter = $fallback)"
            $branch = if ([string]::IsNullOrWhiteSpace($inp)) { $fallback } else { $inp }
        }
    }
    return $branch
}

function Get-UpstreamBranch {
    param([string]$RemoteName, [string]$LocalBranch)   # ← Fix: declare param (previously missing)
    $upstream = & git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $upstream) {
        # "@{u}" returns "origin/main" → extract only branch part "main"
        return ($upstream -split '/', 2)[-1]
    }
    return $LocalBranch   # ← Now $LocalBranch is valid since it's a param
}

function Test-RemoteBranch {
    param([string]$RemoteName, [string]$Branch)
    # Must check "$RemoteName/$Branch" (e.g.: "origin/main"), not just "$Branch"
    # If only using "$Branch" → git rev-parse "main" → checks local branch, not remote
    $null = & git rev-parse "$RemoteName/$Branch" 2>$null
    return $LASTEXITCODE -eq 0
}

function Invoke-GitFetch {
    param([string]$RemoteName, [int]$Retry = 3)
    for ($i = 1; $i -le $Retry; $i++) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.fetchAttempt' -MessageArgs @($RemoteName, $i, $Retry)) -Level Info
        & git fetch $RemoteName --prune
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($i -lt $Retry) { Start-Sleep -Seconds 5 }
    }
    Write-GSyncError "Fetch failed after $Retry attempts."
    return $false
}

function Get-AheadBehind {
    param([string]$LocalBranch, [string]$RemoteBranch)
    $localCommit = & git rev-parse HEAD 2>$null
    $remoteCommit = & git rev-parse $RemoteBranch 2>$null
    if (-not $localCommit -or -not $remoteCommit -or $localCommit -eq $remoteCommit) { return 0,0 }
    $ab = & git rev-list --left-right --count "$localCommit...$remoteCommit" 2>$null
    if ($ab -match '(\d+)\s+(\d+)') { return [int]$Matches[1], [int]$Matches[2] }
    return 0,0
}

function Invoke-GitPull {
    param([string]$RemoteName, [string]$Branch, [int]$Retry = 3)
    for ($i = 1; $i -le $Retry; $i++) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.pullAttempt' -MessageArgs @($RemoteName, $Branch, $i, $Retry)) -Level Info
        & git pull $RemoteName $Branch
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($i -lt $Retry) { Start-Sleep -Seconds 5 }
    }
    return $false
}

function Invoke-GitPush {
    param([string]$RemoteName, [string]$Branch, [string]$Upstream, [bool]$RemoteExists, [int]$Retry = 3)
    for ($i = 1; $i -le $Retry; $i++) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.pushAttempt' -MessageArgs @($Branch, $RemoteName, $i, $Retry)) -Level Info
        if (-not $RemoteExists) {
            & git push --set-upstream $RemoteName $Branch
        } else {
            & git push $RemoteName $Branch
        }
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($i -lt $Retry) {
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.pushFailedRebase') -Level Warn
            & git pull --rebase $RemoteName $Upstream
            if ($LASTEXITCODE -ne 0) {
                Write-GSyncError "Pull --rebase failed, cannot retry push."
                return $false
            }
            Start-Sleep -Seconds 3
        }
    }
    return $false
}

function Invoke-StashIfDirty {
    $dirty = & git status --porcelain 2>$null
    if ($dirty.Count -eq 0) { return $false }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $stashName = "gsync-auto-$stamp"
    & git stash push -u -m $stashName
    if ($LASTEXITCODE -eq 0) {
        Write-SubLog (Get-LocaleMessage -Key 'gsync.msg.step.stash') "Saved ($stashName)" (Resolve-SafeColor -ColorName 'Info' -Fallback 'Cyan')
        $script:StashName = $stashName
        return $true
    }
    Write-Warn (Get-LocaleMessage -Key 'gsync.msg.git.cannotStash')
    return $false
}

function Invoke-PopStash {
    if (-not $script:StashName) { return $true }
    $stashLine = & git stash list --format='%gd %s' | Where-Object { $_ -match [regex]::Escape($script:StashName) } | Select-Object -First 1
    if (-not $stashLine) {
        Write-Warn (Get-LocaleMessage -Key 'gsync.msg.git.stashNotFound' -MessageArgs @([string]$script:StashName))
        $script:StashName = $null
        return $true
    }
    $stashRef = ($stashLine -split ' ')[0]
    & git stash pop $stashRef
    if ($LASTEXITCODE -ne 0) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.stashPopConflict' -MessageArgs @($stashRef)) -Level Warn
        $script:StashName = $null
        return $false   # ← Don't throw; caller checks return value
    }
    Write-SubLog (Get-LocaleMessage -Key 'gsync.msg.step.stash') "Restored" (Resolve-SafeColor -ColorName 'Succ' -Fallback 'Green')
    $script:StashName = $null
    return $true
}

function Get-GitStatus {
    @(& git status --porcelain 2>$null)
}

function Undo-Artifacts {
    param([string[]]$Patterns, [string[]]$ExtraPatterns)
    $allPatterns = $Patterns + $ExtraPatterns
    $staged = @(& git diff --cached --name-only 2>$null)
    foreach ($f in $staged) {
        foreach ($pat in $allPatterns) {
            if ($f -match $pat) {
                & git restore --staged -- $f 2>$null
                Write-SubLog (Get-LocaleMessage -Key 'gsync.msg.step.removeArtifact') $f (Resolve-SafeColor -ColorName 'Warn' -Fallback 'Yellow')
                break
            }
        }
    }
}

function New-CommitMessageSuggestion {
    param([string[]]$StagedFiles, [switch]$AnalyzeDiff)
    $hasWorkflow = $StagedFiles | Where-Object { $_ -match '\.ya?ml$|\.github[/\\]' }
    $hasProj = $StagedFiles | Where-Object { $_ -match '\.(csproj|sln|gradle|pom\.xml)$' }
    $hasCode = $StagedFiles | Where-Object { $_ -match '\.(cs|js|ts|py|go|java|kt|swift|rs|ps1|sh)$' }
    if ($hasWorkflow) { return "ci: update workflows" }
    if ($hasProj) { return "build: update project files" }
    if ($AnalyzeDiff -and $StagedFiles.Count -eq 1 -and $hasCode) {
        return 'feat: ' + ([System.IO.Path]::GetFileName($StagedFiles[0]))
    }
    if ($hasCode) { return 'feat: update ' + $hasCode.Count + ' code files' }
    return "chore: update at $(Get-Date -Format 'HH:mm dd/MM/yyyy')"
}

function Send-WebhookNotification {
    param($Config, [string]$Status, [string]$Message)
    if (-not $Config.webhook.enabled) { return }
    if ($Status -eq "success" -and -not $Config.webhook.onSuccess) { return }
    if ($Status -eq "failure" -and -not $Config.webhook.onFailure) { return }
    $body = @{
        status = $Status
        message = $Message
        repo = (Get-Location).Path
        timestamp = (Get-Date).ToString("o")
    } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri $Config.webhook.url -Method Post -Body $body -ContentType "application/json" -ErrorAction SilentlyContinue
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.webhookSent' -MessageArgs @($Status)) -Level Info
    } catch {
        Write-Warn (Get-LocaleMessage -Key 'gsync.msg.git.cannotSendWebhook' -MessageArgs @([string]$_))
    }
}

Export-ModuleMember -Function @('Initialize-SshKey', 'Test-GitVersion', 'Test-GitRepository', 'Test-GitProjectRoot', 'Initialize-GitRepository', 'Clear-GitLock', 'Get-GitConflictType', 'Invoke-GitAbort', 'Invoke-GitConflictHandler', 'Get-CurrentBranch', 'Get-UpstreamBranch', 'Test-RemoteBranch', 'Invoke-GitFetch', 'Get-AheadBehind', 'Invoke-GitPull', 'Invoke-GitPush', 'Invoke-StashIfDirty', 'Invoke-PopStash', 'Get-GitStatus', 'Undo-Artifacts', 'New-CommitMessageSuggestion', 'Send-WebhookNotification')
