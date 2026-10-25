#Requires -Version 5.1
# EventBus.psm1 - Pub/Sub Event Bus for _Sync Platform
# Requires -Version 5.1


# Make the logger available when this module is imported on its own.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1')
# Static event storage
$script:EventHandlers = @{}

# Subscribe to an event
function Add-BuildEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Alias('EventName')][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Handler,
        [string]$Label = '',
        [string]$TenantId = 'default'
    )

Set-StrictMode -Version 1.0
    
    if (-not $script:EventHandlers[$Name]) {
        $script:EventHandlers[$Name] = @()
    }
    $script:EventHandlers[$Name] += $Handler
}

# Remove event subscription
function Remove-BuildEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Alias('EventName')][string]$Name, [scriptblock]$Handler, [string]$TenantId = '')
    if ($null -ne $Handler) {
        # Remove just the given subscription, the way the other tool's
        # version of this command does.
        $script:EventHandlers[$Name] = @($script:EventHandlers[$Name] | Where-Object { $_ -ne $Handler })
        if (@($script:EventHandlers[$Name]).Count -eq 0) { $script:EventHandlers[$Name] = @() }
        return
    }
    # No handler: every subscription to the event goes.
    $script:EventHandlers[$Name] = @()
}

# Emit an event with data
function Send-BuildEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Alias('EventName')][string]$Name,
        $Data,
        [object]$Source = $null,
        [string]$TenantId = '',
        [string]$Label = ''
    )
    
    if ($script:EventHandlers[$Name]) {
        foreach ($handler in $script:EventHandlers[$Name]) {
            try {
                & $handler $Data
            } catch {
                $errMsg = "Event handler error for '$Name': $_"
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log $errMsg -Level Warn
                } else {
                    Write-Warning $errMsg
                }
            }
        }
    }
}

# Get subscribers for an event
function Get-SyncEventSubscribers {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Alias('EventName')][string]$Name, [scriptblock]$Handler, [string]$TenantId = '')
    return $script:EventHandlers[$Name]
}

# Clear all events
function Clear-BuildEvents {
    param([string]$TenantId = '')
    $script:EventHandlers = @{}
}

function Get-GSyncEventConstants {
    return $script:EventConstants
}

# 17 Event Constants (align with enterprise EventBus standard)
$script:EventConstants = @{
    SyncStart           = 'gsync.sync.start'
    SyncComplete        = 'gsync.sync.complete'
    SyncFailed          = 'gsync.sync.failed'
    StepStart           = 'gsync.step.start'
    StepComplete        = 'gsync.step.complete'
    FetchStart          = 'gsync.fetch.start'
    FetchComplete       = 'gsync.fetch.complete'
    PushStart           = 'gsync.push.start'
    PushComplete        = 'gsync.push.complete'
    CommitStarted       = 'gsync.commit.started'
    CommitSuccess       = 'gsync.commit.success'
    CommitFailed        = 'gsync.commit.failed'
    SecurityBlocked     = 'gsync.security.blocked'
    SecurityScanClean   = 'gsync.security.scan.clean'
    CleanupDone         = 'gsync.cleanup.done'
    SmartGitignoreApplied = 'gsync.gitignore.applied'
    PluginLoaded        = 'gsync.plugin.loaded'
    PluginError         = 'gsync.plugin.error'
    CacheHit            = 'gsync.cache.hit'
    CacheMiss           = 'gsync.cache.miss'
    RollbackStarted     = 'gsync.rollback.started'
    RollbackComplete    = 'gsync.rollback.complete'
    TelemetryRecorded   = 'gsync.telemetry.recorded'
}

<#
.SYNOPSIS
    Send-GSyncEventSafe - Canonical safe event publisher (EventBus layer).
.DESCRIPTION
    Single source of truth. Bridges EventBus to SyncEventManager when one is
    registered. Never throws: event emission is best-effort telemetry.
#>
function Send-GSyncEventSafe {
    param([string]$Name, [hashtable]$Data)
    try {
        if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
            Send-BuildEvent -Name $Name -Data $Data | Out-Null
        }
        if ($script:EventManager) {
            Publish-GSyncEvent -Manager $script:EventManager -EventName $Name -EventSource 'gsync' -EventData $Data | Out-Null
        }
    } catch { }
}

Export-ModuleMember -Function @(
    'Add-BuildEvent', 'Remove-BuildEvent', 'Send-BuildEvent',
    'Get-SyncEventSubscribers', 'Clear-BuildEvents', 'Get-GSyncEventConstants',
    'Send-GSyncEventSafe'
)

