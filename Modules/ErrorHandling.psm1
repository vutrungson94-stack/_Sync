# ErrorHandling.psm1 - Structured errors, retry, rollback for _Sync platform
#Requires -Version 5.1


# Make the logger available when this module is imported on its own.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1')
$script:GSyncRollbackStack = [System.Collections.ArrayList]::new()

function New-GSyncError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Category = 'UnknownError',
        [int]$Code = 9999,
        [string]$CorrelationId = $null,
        [object]$Context = $null
    )

Set-StrictMode -Version 1.0
    $cid = $CorrelationId
    if (-not $cid -and $Context -and $Context.CorrelationId) { $cid = $Context.CorrelationId }
    $st = @()
    if ($Context) {
        $st += "Context.Phase=$($Context.CurrentPhase)"
        $st += "Context.ScriptRoot=$($Context.ScriptRoot)"
    }
    return [PSCustomObject]@{
        Message       = $Message
        Category      = $Category
        Code          = $Code
        CorrelationId = $cid
        Timestamp     = (Get-Date).ToString('o')
        StackTrace    = ((Get-PSCallStack | Select-Object -First 1 | ForEach-Object { $_.ScriptName + ':' + $_.ScriptLineNumber }) -join '; ')
        Context       = ($st -join '; ')
    }
}

function Invoke-GSyncRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$BaseDelayMs = 300,
        [int]$MaxDelayMs = 5000,
        [string]$OperationName = 'operation',
        [object]$Context = $null
    )
    $attempt = 0
    $lastError = $null
    while ($attempt -le $MaxRetries) {
        $attempt++
        try {
            $result = & $ScriptBlock
            return $result
        } catch {
            $lastError = $_
            if ($attempt -lt $MaxRetries) {
                $delay = [Math]::Min($BaseDelayMs * [Math]::Pow(2, $attempt - 1), $MaxDelayMs)
                Write-Log (Get-LocaleMessage -Key 'gsync.msg.retry.waiting' -MessageArgs @($attempt, $MaxRetries, $OperationName, $($_.Exception.Message), ${delay})) -Level Warn
                Start-Sleep -Milliseconds $delay
            }
        }
    }
    $err = New-GSyncError -Message "$OperationName failed after $MaxRetries retries: $($lastError.Exception.Message)" -Category 'NetworkError' -Code 2001 -Context $Context
    throw $err
}

function Register-GSyncRollbackAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Label = 'unnamed'
    )
    $entry = [PSCustomObject]@{
        Label    = $Label
        Action   = $Action
        Timestamp = (Get-Date).ToString('o')
    }
    [void]$script:GSyncRollbackStack.Add($entry)
}

function Invoke-GSyncRollback {
    [CmdletBinding()]
    param([object]$Logger = $null)
    if ($script:GSyncRollbackStack.Count -eq 0) { return }
    if ($Logger) { $Logger.Warn("Rolling back $($script:GSyncRollbackStack.Count) action(s)...") }
    while ($script:GSyncRollbackStack.Count -gt 0) {
        $entry = $script:GSyncRollbackStack[-1]
        $script:GSyncRollbackStack.RemoveAt($script:GSyncRollbackStack.Count - 1) | Out-Null
        try {
            if ($Logger) { $Logger.Info("Rollback: $($entry.Label)") }
            & $entry.Action
        } catch {
            if ($Logger) { $Logger.Error("Rollback failed for $($entry.Label): $_") }
        }
    }
}

function Clear-GSyncRollbackStack {
    $script:GSyncRollbackStack = [System.Collections.ArrayList]::new()
}

Export-ModuleMember -Function @('New-GSyncError','Invoke-GSyncRetry','Register-GSyncRollbackAction','Invoke-GSyncRollback','Clear-GSyncRollbackStack')
