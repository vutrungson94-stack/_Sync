#Requires -Version 5.1
# gsync.module.psm1

$moduleRoot = $PSScriptRoot
$modulesDir = Join-Path $moduleRoot "Modules"
$corePath = Join-Path $moduleRoot "Core"

# ---------------------------------------------------------------------------
# SINGLE IMPORT REGISTRY
#
# The import list used to be eighteen hand-written Import-Module lines. Every
# one of them hardcoded the same three flags (-Force -Scope Global
# -DisableNameChecking -ErrorAction SilentlyContinue), so a module added
# later was either forgotten (silent CommandNotFound at runtime) or added
# with a different flag set (a second module instance, split state). The
# list is now DATA, imported by one loop, and Tests/Reachability.Tests.ps1
# asserts that every shipped module appears here - a new module that is not
# wired in fails the gate instead of rotting.
#
# -Scope Global is deliberate and documented: the sibling modules call each
# other's commands (Config -> Logging, Security -> EventBus, ...), and on
# PowerShell 5.1 a module imported into another module's scope exports into
# that scope ONLY. Without the global scope the cross-module calls fail with
# CommandNotFoundException. The pollution is bounded to THIS tool's own
# module names, and every module that needs a sibling declares it through
# Modules/ModuleBootstrap.ps1, which imports the dependency only when it is
# not already visible.
# ---------------------------------------------------------------------------
$script:GSyncCoreModules = @(
    'SyncTypes.psm1'
    'SyncContext.psm1'
    'SyncEventManager.psm1'
    'SyncRollback.psm1'
)
$script:GSyncModules = @(
    'SelfHeal.psm1'
    'SyncSafety.psm1'
    'Logging.psm1'
    'Config.psm1'
    'GitUtils.psm1'
    'Security.psm1'
    'Cleanup.psm1'
    'UI.psm1'
    'Container.psm1'
    'ErrorHandling.psm1'
    'EventBus.psm1'
    'PathNormalization.psm1'
    'SecurityPlugin.psm1'
    'AutoCommit.psm1'
    'SmartCommitRules.psm1'
    'Metrics.psm1'
    'Messages.psm1'
    'Alerting.psm1'
    'PluginRegistry.psm1'
    'AiCommit.psm1'
    'DependencyChecker.psm1'
    'Locale.psm1'
    'SmartGitignore.psm1'
    'YamlSanity.psm1'
)

foreach ($coreMod in $script:GSyncCoreModules) {
    $coreModPath = Join-Path $corePath $coreMod
    if (Test-Path -LiteralPath $coreModPath) { Import-Module $coreModPath -Force -DisableNameChecking -Scope Global -ErrorAction SilentlyContinue }
}
foreach ($mod in $script:GSyncModules) {
    $modPath = Join-Path $modulesDir $mod
    if (Test-Path -LiteralPath $modPath) { Import-Module $modPath -Force -DisableNameChecking -Scope Global -ErrorAction SilentlyContinue }
}

# Hook management
$hooksPath = Join-Path $modulesDir "gsync-Hooks.ps1"
if (Test-Path $hooksPath) { . $hooksPath }

$script:GSync = if (Get-Variable -Name GSync -Scope Script -ErrorAction SilentlyContinue) { $script:GSync } else { @{} }
$global:GSync = $script:GSync

function Invoke-GSyncFailureRecovery {
    <#
    .SYNOPSIS
        Undoes the working-tree changes of a failed sync.
    .DESCRIPTION
        The rollback machinery existed but was never engaged: the live path
        cleared the rollback stack on success and never registered an action
        or invoked the rollback on failure, and it took a working-tree
        snapshot without ever restoring it. A sync that failed after
        mutating the working tree left the tree in that state.
        This runs the registered rollback actions and then restores the
        snapshot, so the operator gets the tree back.
    #>
    [CmdletBinding()]
    param(
        [string]$Reason = 'unknown',
        [string]$SnapshotId,
        [string]$SnapshotsDir
    )

Set-StrictMode -Version 1.0
    Write-Log (Get-LocaleMessage -Key 'gsync.msg.recovery.from' -MessageArgs @($Reason)) -Level Warn

    if (Get-Command Invoke-GSyncRollback -ErrorAction SilentlyContinue) {
        try { Invoke-GSyncRollback } catch { Write-GSyncError "Rollback failed: $_" }
    }

    if ($SnapshotId -and (Get-Command Restore-SyncSnapshot -ErrorAction SilentlyContinue)) {
        try {
            $restored = Restore-SyncSnapshot -SnapshotId $SnapshotId -SnapshotsDir $SnapshotsDir
            if ($restored) { Write-Log (Get-LocaleMessage -Key 'gsync.msg.recovery.restored' -MessageArgs @($SnapshotId)) -Level Success }
            else { Write-Log (Get-LocaleMessage -Key 'gsync.msg.recovery.snapshotFailed' -MessageArgs @($SnapshotId)) -Level Warn }
        } catch { Write-GSyncError "Snapshot restore failed: $_" }
    }
}

function Save-GSyncStash {
    <#
    .SYNOPSIS
        Stashes a dirty working tree when the configured policy allows it.
    .DESCRIPTION
        The stash policy used to be repeated at each call site, so the safety
        path and the pull path could drift. The policy is owned here;
        Invoke-StashIfDirty owns the git operation and records the stash name
        that Restore-GSyncStash consumes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config
    )
    if (-not $Config.git.stashWhenWorkingTreeDirty) { return }
    $null = Invoke-StashIfDirty
}

function Restore-GSyncStash {
    <#
    .SYNOPSIS
        Restores the stash and stops the sync when git cannot apply it.
    .DESCRIPTION
        Invoke-PopStash returns $false when `git stash pop` leaves conflicts.
        The callers used to ignore that result and continued into `git add -A`,
        which committed the conflict markers. A failed restore is a hard stop:
        the stash entry and the conflicted working tree are preserved so the
        operator can resolve them, then run gsync again.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config
    )
    if (-not $Config.git.stashWhenWorkingTreeDirty) { return }
    if (Invoke-PopStash) { return }

    $message = Get-LocaleMessage -Key 'gsync.msg.git.stashPopAborted'
    Write-GSyncError $message
    Send-WebhookNotification -Config $Config -Status 'failure' -Message $message
    exit 1
}

function Invoke-EnabledSyncPlugins {
    <#
    .SYNOPSIS
        Runs the sync plugins the operator enabled.
    .DESCRIPTION
        _Sync ships five plugins (Git, GPG, LFS, Node, Python). The plugin
        gate validated their contract, but the live path never registered or
        executed them, so they were shipped capability that never ran.
        A plugin failure is reported and the sync continues - a plugin is
        auxiliary, it must not abort the run.
    #>
    [CmdletBinding()]
    param(
        [object]$Config,
        [string]$WorkingDir
    )
    if (-not (Get-Command Register-Plugins -ErrorAction SilentlyContinue)) { return }
    $pluginRoot = Join-Path $PSScriptRoot 'Plugins'
    if (-not (Test-Path -LiteralPath $pluginRoot)) { return }

    $enabled = @(); $disabled = @()
    try {
        if ($Config -and $Config.plugins) {
            if ($null -ne $Config.plugins.enabledPlugins) { $enabled = @($Config.plugins.enabledPlugins) }
            if ($null -ne $Config.plugins.disabledPlugins) { $disabled = @($Config.plugins.disabledPlugins) }
        }
    } catch { }

    try {
        $null = Register-Plugins -Root $pluginRoot -Enabled $enabled -Disabled $disabled
    } catch {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.plugin.registrationFailed' -MessageArgs @($_)) -Level Warn
        return
    }
    if (-not (Get-Command Get-RegisteredPlugins -ErrorAction SilentlyContinue)) { return }

    foreach ($p in @(Get-RegisteredPlugins)) {
        $command = 'InvokePluginSync'
        if (-not (Get-Command Invoke-PluginCommand -ErrorAction SilentlyContinue)) { break }
        # Only transport plugins implement the sync contract. Language plugins
        # (Node, Python) satisfy the Flat contract and have no sync action, so
        # calling InvokePluginSync on them only produces noise.
        if (Get-Command Resolve-PluginCommand -ErrorAction SilentlyContinue) {
            $resolved = Resolve-PluginCommand -PluginName $p.Name -CommandName $command
            if (-not $resolved) { continue }
        }
        try {
            $null = Invoke-PluginCommand -PluginName $p.Name -CommandName $command -WorkingDir $WorkingDir
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.plugin.completed' -MessageArgs @($($p.Name))) -Level Info
        } catch {
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.plugin.failed' -MessageArgs @($($p.Name), $($_.Exception.Message))) -Level Warn
        }
    }
}

function Start-GSync {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$NonInteractive,
        [switch]$Yes,
        [switch]$No,
        [string]$ConfigPath,
        [string]$RepoUrl,
        [string]$RemoteName,
        [switch]$DryRun,
        [string]$Locale = 'en'
    )

    # Run state. The CorrelationId, TenantId, SessionId and the state/log
    # paths come from the Core SyncContext (New-SyncContext) - the module
    # that owns tenant isolation and the state file. It used to be imported
    # and never called: the live path minted its own correlation id and used
    # a fixed ".gsync.log" for every tenant, so two tenants on one machine
    # wrote to the same log and the same state file. The context is created
    # before the config is loaded (it needs the config for the tenant id),
    # so it is created with the default tenant here and re-keyed below once
    # the config is known.
    $ctx = $null
    try { if (Get-Command New-SyncContext -ErrorAction SilentlyContinue) { $ctx = New-SyncContext -ScriptRoot $moduleRoot } } catch { $ctx = $null }
    $correlationId = if ($ctx -and $ctx.CorrelationId) { [string]$ctx.CorrelationId } else { [guid]::NewGuid().ToString('N').Substring(0,12) }
    $script:GSync = @{
        NonInteractive  = $NonInteractive
        Yes             = $Yes
        No              = $No
        StartTime       = Get-Date
        CorrelationId   = $correlationId
        TenantId        = if ($ctx) { [string]$ctx.TenantId } else { 'default' }
        SessionId       = if ($ctx) { [string]$ctx.SessionId } else { [guid]::NewGuid().ToString() }
        Context         = $ctx
    }
    $global:GSync = $script:GSync

    # Multi-language support (de, en, es, fr, ja, vi, zh)
    # The module lives in Modules/, not at the tool root. The previous path
    # ('$PSScriptRoot\Locale.psm1') did not exist, so the Test-Path guard
    # always failed, Set-CurrentLocale was never called and the -Locale
    # switch was inert. The module is now in the import registry too, so the
    # lazy import below only has to run when the registry load did not
    # provide the command.
    try {
        if (-not (Get-Command Set-CurrentLocale -ErrorAction SilentlyContinue)) {
            $localeModule = Join-Path $modulesDir 'Locale.psm1'
            if (Test-Path -LiteralPath $localeModule) {
                Import-Module $localeModule -Force -ErrorAction SilentlyContinue
            }
        }
        if (Get-Command Set-CurrentLocale -ErrorAction SilentlyContinue) { Set-CurrentLocale -Locale $Locale }
    } catch { }

    if ($Yes -and $No) {
        Write-GSyncError "❌ Cannot use -Yes and -No together."
        exit 1
    }

    # Initialize logging
    $logFile = Join-Path $moduleRoot ".gsync.log"
    Start-Log -Path $logFile -Level "Info"

    # Load config
    # Validate the config against its schema BEFORE converting to a hashtable:
    # Test-GSyncConfig existed but was never invoked, so a malformed config
    # sailed through and broke later with a cryptic error. Fail-closed here.
    $cfgPathForValidation = $ConfigPath
    if (-not (Test-Path -LiteralPath $cfgPathForValidation -PathType Leaf)) {
        $cfgPathForValidation = Join-Path $moduleRoot 'gsync.config.json'
    }
    if (Test-Path -LiteralPath $cfgPathForValidation -PathType Leaf) {
        try {
            $rawCfg = Get-Content -LiteralPath $cfgPathForValidation -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if (-not (Test-GSyncConfig -Config $rawCfg)) {
                Write-GSyncError "Config validation failed; aborting."
                exit 1
            }
        } catch {
            Write-GSyncError "Config parse/validation error: $($_.Exception.Message)"
            exit 1
        }
    }
    $cfg = Import-Config -Path $ConfigPath
    if (-not $cfg) { exit 1 }

    # Re-key the context with the resolved config so the tenant id, the
    # tenant-scoped state file and the tenant-scoped log file are the real
    # ones. The first context (created before the config was known) carried
    # the default tenant, which is what made every tenant share one log.
    if (Get-Command New-SyncContext -ErrorAction SilentlyContinue) {
        try {
            $ctx2 = New-SyncContext -ScriptRoot $moduleRoot -Config $cfg
            if ($ctx2) {
                $script:GSync.Context = $ctx2
                $script:GSync.TenantId = [string]$ctx2.TenantId
                $script:GSync.SessionId = [string]$ctx2.SessionId
                $global:GSync = $script:GSync
                # The log file follows the tenant when the context owns one.
                $tenantLog = [string]$ctx2.LogFilePath
                if (-not [string]::IsNullOrWhiteSpace($tenantLog) -and (Test-Path -LiteralPath (Split-Path -Parent $tenantLog) -PathType Container)) {
                    Start-Log -Path $tenantLog -Level "Info"
                }
            }
        } catch { }
    }

    # DI container: register the core services so modules resolve dependencies
    # through the container instead of reaching for globals. Previously the
    # container existed but nothing registered anything, so it was dead code.
    # Best-effort: a registration failure must never abort the sync.
    if (Get-Command Register-GSyncService -ErrorAction SilentlyContinue) {
        try {
            if (-not (Test-GSyncServiceRegistered -Name 'Config')) {
                Register-GSyncService -Name 'Config' -Factory { $cfg } -Scope Singleton
            }
            if (-not (Test-GSyncServiceRegistered -Name 'Logger')) {
                Register-GSyncService -Name 'Logger' -Factory { (Get-Command Write-GSyncError -ErrorAction SilentlyContinue) } -Scope Singleton
            }
        } catch { }
    }

    Show-Header
    Initialize-SshKey

    # Smart .gitignore. The SmartGitignore module ships per-project-type
    # ignore rules (dotnet/node/python/java templates) and a security rule
    # set, and the live path never called it: the only .gitignore writer in
    # production was the inline block in gsync.ps1, which writes the
    # platform's own patterns. The smart rules were shipped capability that
    # could never run. Call the owner now.
    if (Get-Command Update-SmartGitignore -ErrorAction SilentlyContinue) {
        try {
            $gitignoreCfg = [PSCustomObject]@{
                gitignore = [PSCustomObject]@{
                    enabled    = $true
                    rulesToAdd = @()
                }
                security   = [PSCustomObject]@{
                    secretPatterns = @()
                }
            }
            if ($cfg -and $cfg.gitignore) {
                if ($null -ne $cfg.gitignore.enabled) { $gitignoreCfg.gitignore.enabled = [bool]$cfg.gitignore.enabled }
                if ($cfg.gitignore.rulesToAdd) { $gitignoreCfg.gitignore.rulesToAdd = @($cfg.gitignore.rulesToAdd) }
            }
            if ($cfg -and $cfg.security -and $cfg.security.secretPatterns) {
                $gitignoreCfg.security.secretPatterns = @($cfg.security.secretPatterns)
            }
            Update-SmartGitignore -Config $gitignoreCfg -WorkingDir (Get-Location).Path
        } catch { }
    }

    # Dependency pre-flight. The DependencyChecker module shipped a
    # capability (verify git / ssh / gpg / lfs before syncing) that the live
    # path never called, so a machine without git or without SSH discovered
    # it only when the sync was already half-done. Fail fast, before any
    # repository state is touched.
    if (Get-Command Test-GSyncDependency -ErrorAction SilentlyContinue) {
        try {
            $depReport = @(Get-GSyncDependencyReport -Config $cfg -WorkingDir (Get-Location).Path)
            foreach ($d in $depReport) {
                if ($d.Passed) { continue }
                if ($d.Required) {
                    Write-GSyncError (Get-LocaleMessage -Key 'gsync.msg.dependency.failed' -MessageArgs @($d.Name, $d.Message))
                } else {
                    Write-Log (Get-LocaleMessage -Key 'gsync.msg.dependency.warning' -MessageArgs @($d.Name, $d.Message)) -Level Warn
                }
            }
            if (-not (Test-GSyncDependency -Config $cfg -WorkingDir (Get-Location).Path)) {
                Write-GSyncError (Get-LocaleMessage -Key 'gsync.msg.dependency.requiredMissing')
                exit 1
            }
        } catch { }
    }

    # Check git version
    if (-not (Test-GitVersion -Minimum "2.20")) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.versionTooOld') -Level Warn
    }

    # Check Git environment.
    # Every git operation targets the project directory explicitly. The
    # project is the directory the tool was pointed at; the git state must
    # go THERE and never appear outside the project.
    $projectDir = (Get-Location).Path
    if (-not (Test-GitRepository -Path $projectDir)) {
        if (-not (Test-GitProjectRoot -Path $projectDir)) {
            Write-GSyncError "'$projectDir' contains other repositories and is not itself a project. Point gsync at a project directory; refusing to create git state outside a project."
            exit 1
        }
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.notARepo') -Level Warn
        if (-not (Confirm-YesNo "Do you want to initialize and OVERWRITE data from GitHub to this machine?" -Default "n")) {
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.aborted') -Level Error
            exit 1
        }
        $repoUrl = if (-not [string]::IsNullOrWhiteSpace($RepoUrl)) { $RepoUrl }
                   elseif (-not (Test-InteractiveSession)) { Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.needRepoUrl') -Level Error; exit 1 }
                   else { Read-Host "🔗 Enter URL" }
        $initOk = Initialize-GitRepository -RepoUrl $repoUrl -Path $projectDir
        if (-not $initOk) { exit 1 }
    }

    # Release lock if any
    # Clearing .git/index.lock deletes a file, so it is a mutating action and
    # must not happen in a dry run.
    if ($DryRun) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.dryRun.skipLock') -Level Info
    } else {
        Clear-GitLock -Path $projectDir
    }

    # Handle incomplete rebase/merge
    $inProgress = Get-GitConflictType
    if ($inProgress) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.incompleteState' -MessageArgs @($inProgress)) -Level Warn
        if (Confirm-YesNo "Abort $inProgress?" -Default "y") {
            Invoke-GitAbort -ConflictType $inProgress
        } else {
            Invoke-GitConflictHandler -ConflictType $inProgress
            exit 1
        }
    }

    # Get branch information
    $localBranch = Get-CurrentBranch -Config $cfg
    $remoteName = if ($RemoteName) { $RemoteName } else { [string]$cfg.git.remoteName }
    $upstream = Get-UpstreamBranch -RemoteName $remoteName -LocalBranch $localBranch
    $remoteExists = Test-RemoteBranch -RemoteName $remoteName -Branch $upstream

    Write-SubLog (Get-LocaleMessage -Key 'gsync.msg.step.localBranch') $localBranch (Resolve-SafeColor -ColorName 'Info' -Fallback 'Cyan')
    Write-SubLog (Get-LocaleMessage -Key 'gsync.msg.step.remoteTracking') "$remoteName/$upstream" (Resolve-SafeColor -ColorName 'Gray' -Fallback 'DarkGray')
    if (-not $remoteExists) {
        Write-SubLog (Get-LocaleMessage -Key 'gsync.msg.step.remoteBranch') "Does not exist — will be created on push" (Resolve-SafeColor -ColorName 'Warn' -Fallback 'Yellow')
    }

    # Step 1: .gitignore & cleanup
    Write-StepTitle "PROTECT & CLEANUP"
    if ($cfg.gitignore.enabled) {
        if ($DryRun) {
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.dryRun.skipGitignore') -Level Info
        } else {
            Update-Gitignore -Rules $cfg.gitignore.rulesToAdd -WorkingDir (Get-Location).Path
        }
    }
    if ($cfg.junkCleanup.enabled) {
        Remove-JunkFiles -Patterns $cfg.junkCleanup.patterns -RestrictDirs $cfg.junkCleanup.restrictToDirs -Confirm:$cfg.junkCleanup.confirmBeforeDelete -DryRun:$DryRun
    }

    # Step 2: Detect large files
    if ($cfg.largeFiles.enabled) {
        $thresholdMB = 50
        if ($cfg.largeFiles.thresholdMB) { $thresholdMB = [double]$cfg.largeFiles.thresholdMB }
        elseif ($cfg.ui.largeFileThresholdMB) { $thresholdMB = [double]$cfg.ui.largeFileThresholdMB }
        $excludeDirs = @($cfg.largeFiles.excludeDirs) + @('.git','node_modules','.gbuildcache','.sync_snapshots','logs')
        $largeFiles = Find-LargeFiles -ThresholdMB $thresholdMB -ExcludeDirs $excludeDirs
        if ($largeFiles.Count -gt 0) {
            Show-LargeFiles -Files $largeFiles -MaxDisplay 25
            # A dry run reports and stops; it must never abort the preview.
            if (-not $DryRun -and -not (Confirm-YesNo "Continue?" -Default "n")) { exit 1 }
        }
    }

    # Step 3: Fetch and analyze ahead/behind
    Write-StepTitle "CHANGE ANALYSIS"
    Write-Progress -Activity "Fetching from remote..." -Status "Connecting to $remoteName"
    $fetchResult = Invoke-GitFetch -RemoteName $remoteName -Retry $cfg.git.retryCount
    Write-Progress -Activity "Fetching from remote..." -Completed
    if (-not $fetchResult) { exit 1 }

    $commitsAhead, $commitsBehind = Get-AheadBehind -LocalBranch $localBranch -RemoteBranch "$remoteName/$upstream"
    Write-SubLog (Get-LocaleMessage -Key 'gsync.msg.step.localAhead') "$commitsAhead commit(s)" $(if ($commitsAhead -gt 0) { (Resolve-SafeColor -ColorName 'Warn' -Fallback 'Yellow') } else { (Resolve-SafeColor -ColorName 'Succ' -Fallback 'Green') })
    Write-SubLog (Get-LocaleMessage -Key 'gsync.msg.step.remoteBehind') "$commitsBehind commit(s)" $(if ($commitsBehind -gt 0) { (Resolve-SafeColor -ColorName 'Warn' -Fallback 'Yellow') } else { (Resolve-SafeColor -ColorName 'Succ' -Fallback 'Green') })

    # Safety: compare quality when diverged before mutating
    $script:GSyncPreferredLocalForcePush = $false
    try {
        if ($commitsAhead -gt 0 -and $commitsBehind -gt 0 -and (Get-Command Compare-GitSyncSides -ErrorAction SilentlyContinue)) {
            Write-StepTitle "SYNC SAFETY"
            $decision = Compare-GitSyncSides -LocalRef HEAD -RemoteRef "$remoteName/$upstream" -RepoRoot (Get-Location).Path
            if ($decision) {
                Write-Log ((Get-LocaleMessage -Key 'gsync.msg.quality.decision' -MessageArgs @([string]$decision.Recommendation, [string]$decision.Reason))) -Level Info
                if ($decision.Recommendation -eq 'prefer-remote') {
                    Save-GSyncStash -Config $cfg
                    if (Get-Command New-SyncSnapshot -ErrorAction SilentlyContinue) { try { $snapDir = Join-Path $moduleRoot '.sync_snapshots'; $null = New-SyncSnapshot -Label "pre-remote-prefer-$localBranch" -SnapshotsDir $snapDir } catch { } }
                    if ($DryRun) {
                        # git reset --hard discards the working tree. A dry run
                        # must not destroy local work.
                        Write-Log (Get-LocaleMessage -Key 'gsync.msg.dryRun.skipReset' -MessageArgs @($remoteName/$upstream)) -Level Info
                    } else {
                        $null = & git reset --hard "$remoteName/$upstream" 2>&1
                        if ($LASTEXITCODE -ne 0) { Write-GSyncError "Remote-prefer reset failed."; exit 1 }
                    }
                    Restore-GSyncStash -Config $cfg
                    Write-SubLog (Get-LocaleMessage -Key 'gsync.msg.step.safety') "Local fast-forwarded to higher-quality remote side" (Resolve-SafeColor -ColorName 'Warn' -Fallback 'Yellow')
                } elseif ($decision.Recommendation -eq 'prefer-local') {
                    Write-Log (Get-LocaleMessage -Key 'gsync.msg.safety.forcePush') -Level Info
                    $script:GSyncPreferredLocalForcePush = $true
                } elseif ($decision.Relationship -eq 'Diverged') {
                    Write-GSyncError "Diverged commits with unclear quality winner. Aborting to protect repository."
                    Send-WebhookNotification -Config $cfg -Status "failure" -Message "Quality tie on diverged sync - manual review"
                    Restore-GSyncStash -Config $cfg
                    exit 1
                }
            }
        }
    } catch { Write-Log (Get-LocaleMessage -Key 'gsync.msg.safety.skipped' -MessageArgs @($_)) -Level Debug }

    # Step 4: Pull if needed (with retry)
    if ($commitsBehind -gt 0) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.remoteAhead' -MessageArgs @($commitsBehind)) -Level Warn
        $policy = [string]$cfg.git.pullConflictPolicy
        $shouldPull = switch ($policy) {
            "always" { $true }
            "never" { $false }
            "ask" { Confirm-YesNo "Pull new code?" -Default "y" }
            default { Confirm-YesNo "Pull new code?" -Default "y" }
        }
        if ($shouldPull) {
            Save-GSyncStash -Config $cfg
            Write-Progress -Activity "Pulling from remote..." -Status "Fetching changes"
            if ($DryRun) {
                # Pull rewrites the working tree. A dry run only reports.
                Write-Progress -Activity "Pulling from remote..." -Completed
                Write-Log (Get-LocaleMessage -Key 'gsync.msg.dryRun.skipPull' -MessageArgs @($remoteName/$upstream)) -Level Info
                $pullSuccess = $true
            } else {
                $pullSuccess = Invoke-GitPull -RemoteName $remoteName -Branch $upstream -Retry $cfg.git.retryCount
            }
            Write-Progress -Activity "Pulling from remote..." -Completed
            if (-not $pullSuccess) {
                Restore-GSyncStash -Config $cfg
                Invoke-GitConflictHandler
                Invoke-GSyncFailureRecovery -Reason 'git pull failed'
                exit 1
            }
            Restore-GSyncStash -Config $cfg
            Write-SubLog (Get-LocaleMessage -Key 'gsync.msg.step.pull') "Success" (Resolve-SafeColor -ColorName 'Succ' -Fallback 'Green')
        } else {
            Write-SubLog (Get-LocaleMessage -Key 'gsync.msg.step.pull') "Skipped" (Resolve-SafeColor -ColorName 'Gray' -Fallback 'DarkGray')
        }
    }

    # Step 5: Check local changes
    $status = Get-GitStatus
    if ($status.Count -eq 0) {
        if ($commitsAhead -gt 0) {
            Write-StepTitle "DEPLOY PENDING COMMITS"
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.pendingCommits' -MessageArgs @($commitsAhead)) -Level Info
            if ($DryRun) {
                Write-Log (Get-LocaleMessage -Key 'gsync.msg.dryRun.skipPendingPush' -MessageArgs @($commitsAhead)) -Level Info
                $script:GSync.EndTime = Get-Date
                Stop-Log
                Clear-GSyncRollbackStack
                exit 0
            }
            $pushSuccess = if ($script:GSyncPreferredLocalForcePush) { & git push --force-with-lease $remoteName $localBranch; ($LASTEXITCODE -eq 0) }
                    else { Invoke-GitPush -RemoteName $remoteName -Branch $localBranch -Upstream $upstream -RemoteExists $remoteExists -Retry $cfg.git.retryCount }
            if (-not $pushSuccess) {
                Write-GSyncError "Push failed."
                Send-WebhookNotification -Config $cfg -Status "failure" -Message "Push failed"
                Restore-GSyncStash -Config $cfg
                Invoke-GSyncFailureRecovery -Reason 'push of pending commits failed' -SnapshotId $script:GSyncSnapshotId -SnapshotsDir $script:GSyncSnapshotDir
                exit 1
            }
            Write-SubLog (Get-LocaleMessage -Key 'gsync.msg.step.push') "Success" (Resolve-SafeColor -ColorName 'Succ' -Fallback 'Green')
            $script:GSync.EndTime = Get-Date
            Send-WebhookNotification -Config $cfg -Status "success" -Message "Deployed pending local commits"
            Stop-Log
            Clear-GSyncRollbackStack
            exit 0
        }
        Write-StepTitle "COMPLETE"
        Write-Host (Get-LocaleMessage -Key 'gsync.msg.git.alreadySynced') -ForegroundColor (Resolve-SafeColor -ColorName 'Succ' -Fallback 'Green')
        Send-WebhookNotification -Config $cfg -Status "success" -Message "No local changes"
        Stop-Log
        exit 0
    }
    # Step 6: Detect sensitive files
    Write-StepTitle "LOCAL CHANGES"
    $blocked = Test-SensitiveFiles -Status ($status -join "`n") -Config $cfg
    if ($blocked.Count -gt 0) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.blocked' -MessageArgs @($($blocked.Count))) -Level Error
        $blocked | ForEach-Object { Write-Host "   · $_" -ForegroundColor (Resolve-SafeColor -ColorName 'Err' -Fallback 'Red') }
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.git.unblockHint') -Level Warn
        Send-WebhookNotification -Config $cfg -Status "failure" -Message "Sensitive files blocked"
        exit 1
    }

    # Step 7: Commit
    if ($DryRun) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.dryRun.skipCommit') -Level Info
        Stop-Log
        exit 0
    }

    # Take a working-tree snapshot before the first mutating step and
    # register it as a rollback action, so a failure below can put the
    # operator's tree back the way it was.
    $script:GSyncSnapshotId = $null
    $script:GSyncSnapshotDir = Join-Path $moduleRoot '.sync_snapshots'
    if (Get-Command New-SyncSnapshot -ErrorAction SilentlyContinue) {
        try {
            $snap = New-SyncSnapshot -Label 'pre-commit' -SnapshotsDir $script:GSyncSnapshotDir
            if ($snap -and $snap.Id) {
                $script:GSyncSnapshotId = $snap.Id
                if (Get-Command Register-GSyncRollbackAction -ErrorAction SilentlyContinue) {
                    Register-GSyncRollbackAction -Label 'restore pre-commit snapshot' -Action {
                        if ($script:GSyncSnapshotId -and (Get-Command Restore-SyncSnapshot -ErrorAction SilentlyContinue)) {
                            $null = Restore-SyncSnapshot -SnapshotId $script:GSyncSnapshotId -SnapshotsDir $script:GSyncSnapshotDir
                        }
                    }.GetNewClosure()
                }
            }
        } catch { Write-Log (Get-LocaleMessage -Key 'gsync.msg.snapshot.failed' -MessageArgs @($_)) -Level Warn }
    }

    # The shipped plugins (Git, GPG, LFS, Node, Python) run here, between
    # the pull and the commit.
    Invoke-EnabledSyncPlugins -Config $cfg -WorkingDir (Get-Location).Path

    if (-not (Confirm-YesNo "Commit changes?" -Default "y")) {
        Write-SubLog (Get-LocaleMessage -Key 'gsync.msg.step.commit') "Skipped" (Resolve-SafeColor -ColorName 'Gray' -Fallback 'DarkGray')
        Stop-Log
        exit 0
    }

    & git add -A
    if ($LASTEXITCODE -ne 0) { Write-GSyncError "git add failed"; Invoke-GSyncFailureRecovery -Reason 'git add failed' -SnapshotId $script:GSyncSnapshotId -SnapshotsDir $script:GSyncSnapshotDir; exit 1 }

    if ($cfg.artifactUnstage.enabled) {
        Undo-Artifacts -Patterns $cfg.artifactUnstage.patterns -ExtraPatterns $cfg.artifactUnstage.extraPatterns
    }

    $staged = & git diff --cached --name-only
    if ($staged.Count -eq 0) {
        Write-Host (Get-LocaleMessage -Key 'gsync.msg.git.noFilesRemaining') -ForegroundColor (Resolve-SafeColor -ColorName 'Succ' -Fallback 'Green')
        Stop-Log
        exit 0
    }

    $aiEnabled = $false
    $aiLocale = 'en'
    if (-not (Get-Command New-AiCommitSummary -ErrorAction SilentlyContinue)) {
        # The module lives in Modules/, NOT in the tool root. The old path
        # (Join-Path $PSScriptRoot 'AiCommit.psm1') never existed, so the
        # Test-Path guard always failed, the AI commit module was never
        # loaded, and the feature silently fell back to the plain commit
        # message. The path now comes from the same $modulesDir every other
        # module uses.
        $aiPath = Join-Path $modulesDir 'AiCommit.psm1'
        if (Test-Path -LiteralPath $aiPath) { Import-Module $aiPath -Force -DisableNameChecking -Scope Global -ErrorAction SilentlyContinue }
    }
    # AI commit is ON by default when the module is available: it degrades to
    # a deterministic heuristic when no provider (GitHub Models / Ollama) is
    # reachable, so it never makes a commit worse. An explicit
    # autoCommit.ai.enabled = false in the config opts out.
    $explicitlyDisabled = $false
    try {
        if ($cfg.autoCommit -and $cfg.autoCommit.ai -and ($cfg.autoCommit.ai.PSObject.Properties.Name -contains 'enabled') -and -not $cfg.autoCommit.ai.enabled) {
            $explicitlyDisabled = $true
        }
        if ($cfg.autoCommit -and $cfg.autoCommit.ai -and $cfg.autoCommit.ai.locale) { $aiLocale = [string]$cfg.autoCommit.ai.locale }
    } catch { }
    if (-not $explicitlyDisabled -and (Get-Command New-AiCommitSummary -ErrorAction SilentlyContinue)) {
        $aiEnabled = $true
        if ([string]::IsNullOrWhiteSpace($aiLocale)) { $aiLocale = 'en' }
    }
    if ($aiEnabled -and (Get-Command New-AiCommitSummary -ErrorAction SilentlyContinue)) {
        $suggestion = New-AiCommitSummary -ChangedFiles @($staged) -Locale $aiLocale -Config $cfg
    } else {
        $suggestion = New-CommitMessageSuggestion -StagedFiles $staged
    }
    if (-not (Test-InteractiveSession)) {
        $msg = $suggestion
    } else {
        $inp = Read-Host "✍️ Commit message (Enter = $suggestion)"
        $msg = if ([string]::IsNullOrWhiteSpace($inp)) { $suggestion } else { $inp }
    }
    if ($PSCmdlet.ShouldProcess("local repository", "Commit changes")) {
        & git commit -m "$msg"
        if ($LASTEXITCODE -ne 0) { Write-GSyncError "Commit failed"; Invoke-GSyncFailureRecovery -Reason 'git commit failed' -SnapshotId $script:GSyncSnapshotId -SnapshotsDir $script:GSyncSnapshotDir; exit 1 }
        Write-SubLog (Get-LocaleMessage -Key 'gsync.msg.step.commit') "Success" (Resolve-SafeColor -ColorName 'Succ' -Fallback 'Green')
    }

    # Step 8: Push (retry, force-with-lease)
    if (-not (Confirm-YesNo "Push to remote?" -Default "y")) {
        Write-Host (Get-LocaleMessage -Key 'gsync.msg.git.pushSkipped') -ForegroundColor (Resolve-SafeColor -ColorName 'Gray' -Fallback 'DarkGray')
        Stop-Log
        exit 0
    }

    Write-Progress -Activity "Pushing to remote..." -Status "Pushing $localBranch → $remoteName"
    if ($DryRun) {
        Write-Progress -Activity "Pushing to remote..." -Completed
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.dryRun.skipPush' -MessageArgs @($remoteName/$localBranch)) -Level Info
    } elseif ($PSCmdlet.ShouldProcess("remote repository", "Push changes")) {
        $pushSuccess = Invoke-GitPush -RemoteName $remoteName -Branch $localBranch -Upstream $upstream -RemoteExists $remoteExists -Retry $cfg.git.retryCount
        if (-not $pushSuccess) {
            Write-GSyncError "Push failed after multiple attempts."
            Send-WebhookNotification -Config $cfg -Status "failure" -Message "Push failed"
            Invoke-GSyncFailureRecovery -Reason 'push failed' -SnapshotId $script:GSyncSnapshotId -SnapshotsDir $script:GSyncSnapshotDir
            exit 1
        }
    }
    Write-Progress -Activity "Pushing to remote..." -Completed

    $script:GSync.EndTime = Get-Date
    $duration = $script:GSync.EndTime - $script:GSync.StartTime
    # Observability: record the sync outcome as a metric so the OTLP/Prometheus
    # pipeline (already shipped by Modules/Metrics.psm1) actually receives data.
    # Previously the module was imported and never used, so every metric export
    # was empty. Best-effort: a metrics failure must never fail the sync.
    if (Get-Command New-SyncMetricCounter -ErrorAction SilentlyContinue) {
        try {
            if (-not (Get-Metric -Name 'gsync_sync_total' -ErrorAction SilentlyContinue)) {
                New-SyncMetricCounter -Name 'gsync_sync_total' -Help 'Total gsync runs' | Out-Null
            }
            Add-SyncMetric -Name 'gsync_sync_total' -Value 1 -Labels @{ status = 'success' } | Out-Null
        } catch { }
    }
    Write-StepTitle "COMPLETED IN $($duration.TotalSeconds.ToString('F1')) SECONDS" (Resolve-SafeColor -ColorName 'Succ' -Fallback 'Green')
    Send-WebhookNotification -Config $cfg -Status "success" -Message "Sync completed"
    Stop-Log

    # Cleanup environment variables
    Remove-Item Env:GIT_SSH_COMMAND -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_PAGER -ErrorAction SilentlyContinue
    Remove-Item Env:PAGER -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_CONFIG_PARAMETERS -ErrorAction SilentlyContinue
    }

Export-ModuleMember -Function @('Start-GSync', 'Invoke-GSyncFailureRecovery', 'Invoke-EnabledSyncPlugins')
