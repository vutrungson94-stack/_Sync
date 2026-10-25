#Requires -Version 5.1
# Messages.psm1 - the _Sync message catalog.
#
# The messages used to live in this file as an English-only hashtable, and
# the JSON catalogs under Locales/ held a copy of _BUILD's message keys -
# 268 keys that _Sync never read. Two catalogs, neither authoritative.
#
# The catalog now lives in Locales/<lang>.json under the gsync.* namespace,
# in all seven languages, and this module is the single accessor for it.
# The key map below is explicit on purpose: it is the contract between the
# call sites and the catalog, and it is what makes an unreferenced catalog
# key visible to the adoption metric.

# Make the locale resolver available when this module is imported on its own.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('Locale')

$script:MessageKeys = @{
    Strategy = @{
        FetchFailed    = 'gsync.strategy.fetchFailed'
        FetchOk        = 'gsync.strategy.fetchOk'
        UpToDate       = 'gsync.strategy.upToDate'
        Staging        = 'gsync.strategy.staging'
        AddFailed      = 'gsync.strategy.addFailed'
        NothingStaged  = 'gsync.strategy.nothingStaged'
        Committed      = 'gsync.strategy.committed'
        CleanWt        = 'gsync.strategy.cleanWt'
        RebaseOk       = 'gsync.strategy.rebaseOk'
        RebaseFailed   = 'gsync.strategy.rebaseFailed'
        PushOk         = 'gsync.strategy.pushOk'
        PushFailed     = 'gsync.strategy.pushFailed'
        FullDone       = 'gsync.strategy.fullDone'
        QuickDone      = 'gsync.strategy.quickDone'
        DryRunHeader   = 'gsync.strategy.dryRunHeader'
        DryRunNotRepo  = 'gsync.strategy.dryRunNotRepo'
        DryRunSummary  = 'gsync.strategy.dryRunSummary'
        DryRunChanges  = 'gsync.strategy.dryRunChanges'
        DryRunClean    = 'gsync.strategy.dryRunClean'
        DryRunDone     = 'gsync.strategy.dryRunDone'
        Rebasing       = 'gsync.strategy.rebasing'
        CommitFailed   = 'gsync.strategy.commitFailed'
        StrategyInit   = 'gsync.strategy.strategyInit'
        SshKeyLoaded   = 'gsync.strategy.sshKeyLoaded'
        SslBackend     = 'gsync.strategy.sslBackend'
        RemoteUrl      = 'gsync.strategy.remoteUrl'
        PushHint       = 'gsync.strategy.pushHint'
        QuickHeader    = 'gsync.strategy.quickHeader'
        FullHeader     = 'gsync.strategy.fullHeader'
        RemoteAhead    = 'gsync.strategy.remoteAhead'
    }
    Rollback = @{
        Restoring       = 'gsync.rollback.restoring'
        DestructiveWarn = 'gsync.rollback.destructiveWarn'
        DiffApplied     = 'gsync.rollback.diffApplied'
        ResetDone       = 'gsync.rollback.resetDone'
        BranchFail      = 'gsync.rollback.branchFail'
        BranchDone      = 'gsync.rollback.branchDone'
        Restored        = 'gsync.rollback.restored'
        SnapshotCreated = 'gsync.rollback.snapshotCreated'
        SnapshotList    = 'gsync.rollback.snapshotList'
    }
}

function Get-Message {
    <#
    .SYNOPSIS
        Returns the message template for a category and key.
    .DESCRIPTION
        The template comes from the locale catalog, so it is returned in the
        operator's language. When the catalog has no entry - or the locale
        resolver is not loaded - the key itself is returned, which keeps the
        caller working and makes the gap visible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Key
    )

Set-StrictMode -Version 1.0
    $localeKey = $null
    if ($script:MessageKeys.ContainsKey($Category) -and $script:MessageKeys[$Category].ContainsKey($Key)) {
        $localeKey = $script:MessageKeys[$Category][$Key]
    }
    if ($localeKey -and (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue)) {
        $message = Get-LocaleMessage -Key $localeKey
        if ($message -and $message -ne $localeKey) { return $message }
    }
    return "[{0}] {1}" -f $Category, $Key
}

function Format-Message {
    <#
    .SYNOPSIS
        Returns the message template for a category and key, with its
        arguments substituted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Key,
        [object[]]$Arguments
    )
    $template = Get-Message -Category $Category -Key $Key
    if ($Arguments -and $Arguments.Count -gt 0) {
        return $template -f $Arguments
    }
    return $template
}

Export-ModuleMember -Function @('Get-Message', 'Format-Message')
