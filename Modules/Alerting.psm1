#Requires -Version 5.1
# Alerting.psm1 - Config-driven alerting for _Sync platform
# Requires -Version 5.1


# Make the logger available when this module is imported on its own.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('EventBus')

$script:AlertingEnabled = $false
$script:AlertingInitialized = $false

function Initialize-Alerting {
    [CmdletBinding()]
    param([PSCustomObject]$Config)

Set-StrictMode -Version 1.0
    if (-not $Config -or -not $Config.alerting -or -not $Config.alerting.enabled) {
        $script:AlertingEnabled = $false
        return
    }
    $script:AlertingEnabled = $true
    $script:AlertingInitialized = $true
    $script:CurrentConfig = $Config
    $cfg = $Config.alerting
    # Default: alert on error unless explicitly disabled
    if ($cfg -is [PSCustomObject] -and $null -eq $cfg.PSObject.Properties['onError']) {
        $cfg | Add-Member -NotePropertyName onError -NotePropertyValue $true
    } elseif ($cfg -is [hashtable] -and -not $cfg.ContainsKey('onError')) {
        $cfg.onError = $true
    }
    if ($cfg.onError -or $cfg.onRollback) {
        if (Get-Command Add-BuildEvent -ErrorAction SilentlyContinue) {
            Add-BuildEvent -Name 'gsync.sync.failed' -Handler {
                param($Data)
                if ($script:AlertingEnabled) { Send-Alert -Status 'error' -Data $Data }
            } | Out-Null
            Add-BuildEvent -Name 'gsync.rollback.started' -Handler {
                param($Data)
                if ($script:AlertingEnabled) { Send-Alert -Status 'rollback' -Data $Data }
            } | Out-Null
            Add-BuildEvent -Name 'gsync.commit.failed' -Handler {
                param($Data)
                if ($script:AlertingEnabled) { Send-Alert -Status 'error' -Data $Data }
            } | Out-Null
            Add-BuildEvent -Name 'gsync.push.failed' -Handler {
                param($Data)
                if ($script:AlertingEnabled) { Send-Alert -Status 'error' -Data $Data }
            } | Out-Null
        }
        if (Get-Command Add-SyncEventListener -ErrorAction SilentlyContinue -ErrorAction SilentlyContinue) {
            $mgr = $script:EventManager
            if ($mgr) {
                Add-SyncEventListener -Manager $mgr -EventName 'gsync.sync.failed' -Handler {
                    param($src, $data)
                    if ($script:AlertingEnabled) { Send-Alert -Status 'error' -Data $data }
                }
                Add-SyncEventListener -Manager $mgr -EventName 'gsync.rollback.started' -Handler {
                    param($src, $data)
                    if ($script:AlertingEnabled) { Send-Alert -Status 'rollback' -Data $data }
                }
            }
        }
    }
    if ($cfg.onSuccess) {
        if (Get-Command Add-BuildEvent -ErrorAction SilentlyContinue) {
            Add-BuildEvent -Name 'gsync.sync.complete' -Handler {
                param($Data)
                if ($script:AlertingEnabled) { Send-Alert -Status 'success' -Data $Data }
            } | Out-Null
            Add-BuildEvent -Name 'gsync.push.success' -Handler {
                param($Data)
                if ($script:AlertingEnabled) { Send-Alert -Status 'success' -Data $Data }
            } | Out-Null
        }
        if (Get-Command Add-SyncEventListener -ErrorAction SilentlyContinue) {
            $mgr = $script:EventManager
            if ($mgr) {
                Add-SyncEventListener -Manager $mgr -EventName 'gsync.sync.complete' -Handler {
                    param($src, $data)
                    if ($script:AlertingEnabled) { Send-Alert -Status 'success' -Data $data }
                }
            }
        }
    }
}

function Send-Alert {
    [CmdletBinding()]
      param(
          # Optional on purpose: the other tool calls this command with
          # -Message and -Severity, and the two tools export the same
          # command name into one namespace. A call written for either tool
          # must bind against either implementation.
            [Alias('Message')][Alias('Severity')][string]$Status = '',
            [hashtable]$Data = @{}
        )
        if ([string]::IsNullOrWhiteSpace($Status)) {
            $fallbackStatus = 'info'
            if ($Data -and $Data.ContainsKey('status')) { $fallbackStatus = [string]$Data['status'] }
            $Status = $fallbackStatus
        }
    if (-not $script:AlertingEnabled) { return }
    $cfg = if ($script:CurrentConfig -and $script:CurrentConfig.alerting) { $script:CurrentConfig.alerting } else { return }
    if (-not $cfg.webhookUrl) { return }
    if ($Status -eq 'error' -and -not $cfg.onError) { return }
    if ($Status -eq 'rollback' -and -not $cfg.onRollback) { return }
    if ($Status -eq 'success' -and -not $cfg.onSuccess) { return }
    $payload = @{
        status     = $Status
        repo       = (Get-Location).Path
        timestamp  = (Get-Date).ToString('o')
        correlationId = if ($script:CorrelationId) { $script:CorrelationId } else { '' }
    }
    if ($Data) {
        foreach ($k in $Data.Keys) { $payload[$k] = $Data[$k] }
    }
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($cfg.token) {
        $headers['Authorization'] = "Bearer $($cfg.token)"
    }
    Invoke-SyncHttpPost -Uri $cfg.webhookUrl -Body ($payload | ConvertTo-Json -Compress -Depth 3) -Headers $headers -OkLog "Alert sent ($Status)"
}

# Canonical outbound-notification sender (single source for all alert-style posts).
# Unifies: GitUtils.Send-WebhookNotification (webhook.*) · Alerting.Send-Alert
# (alerting.*) · gsync-post-commit inline post. Metrics.Push-MetricsOtlp stays
# separate: it exports Prometheus payloads (metrics transport, not alerting).
# Config precedence: alerting.* (canonical) first, webhook.* (legacy) as fallback.
# Status normalization: success->success, failure/blocked->error, else passthrough.
function Send-SyncNotification {
    [CmdletBinding()]
    param(
        $Config,
        [Parameter(Mandatory)][string]$Status,
        [string]$Message = '',
        [hashtable]$Data = @{}
    )
    if (-not $Config) { return }
    $norm = switch ($Status.ToLowerInvariant()) {
        'success'  { 'success' }
        'failure'  { 'error' }
        'blocked'  { 'error' }
        'rollback' { 'rollback' }
        default    { $Status }
    }
    $payload = @{
        status    = $norm
        message   = $Message
        repo      = (Get-Location).Path
        timestamp = (Get-Date).ToString('o')
    }
    if ($Data) { foreach ($k in $Data.Keys) { $payload[$k] = $Data[$k] } }

    $alerting = $Config.alerting
    if ($alerting -and $alerting.webhookUrl) {
        if ($norm -eq 'error' -and -not $alerting.onError) { return }
        if ($norm -eq 'rollback' -and -not $alerting.onRollback) { return }
        if ($norm -eq 'success' -and -not $alerting.onSuccess) { return }
        $headers = @{ 'Content-Type' = 'application/json' }
        if ($alerting.token) { $headers['Authorization'] = "Bearer $($alerting.token)" }
        Invoke-SyncHttpPost -Uri $alerting.webhookUrl -Body ($payload | ConvertTo-Json -Compress -Depth 3) -Headers $headers -OkLog "Notification sent ($norm)"
        return
    }

    $webhook = $Config.webhook
    if (-not $webhook -or -not $webhook.enabled -or -not $webhook.url) { return }
    if ($Status -eq 'success' -and -not $webhook.onSuccess) { return }
    if (($Status -eq 'failure' -or $norm -eq 'error') -and -not $webhook.onFailure) { return }
    Invoke-SyncHttpPost -Uri $webhook.url -Body ($payload | ConvertTo-Json -Compress -Depth 3) -Headers @{'Content-Type' = 'application/json' } -OkLog "Notification sent ($Status)"
}

# Shared HTTP POST transport (best-effort; never throws).
function Invoke-SyncHttpPost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Body,
        [hashtable]$Headers = @{'Content-Type' = 'application/json' },
        [string]$OkLog = '',
        [int]$TimeoutSec = 10
    )
    if (-not $Uri) { return $false }
    try {
        Invoke-RestMethod -Uri $Uri -Method Post -Body $Body -Headers $Headers -TimeoutSec $TimeoutSec -ErrorAction Stop | Out-Null
        if ($OkLog -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
            Write-Log $OkLog -Level Info
        }
        return $true
    } catch {
        $msg = "Cannot send notification: $_"
        if (Get-Command Write-Warn -ErrorAction SilentlyContinue) { Write-Warn $msg }
        elseif (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log $msg -Level Warn }
        return $false
    }
}

function Test-Alerting {
    [CmdletBinding()]
    param([PSCustomObject]$Config)
    if (-not $Config -or -not $Config.alerting -or -not $Config.alerting.webhookUrl) {
        Write-GSyncError "Alerting is not configured in config."
        return $false
    }
    $script:AlertingEnabled = $true
    try {
        Send-Alert -Status 'test' -Data @{ message = 'Configuration test from _Sync' }
        return $true
    } catch {
        Write-GSyncError "Alerting test failed: $_"
        $script:AlertingEnabled = $false
        return $false
    }
}

function Clear-Alerting {
    $script:AlertingEnabled = $false
    $script:AlertingInitialized = $false
}

    Export-ModuleMember -Function @('Initialize-Alerting', 'Send-Alert', 'Test-Alerting', 'Clear-Alerting', 'Send-SyncNotification', 'Invoke-SyncHttpPost')
