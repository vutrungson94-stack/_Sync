#Requires -Version 5.1
# File: _Sync/Core/SyncTypes.psm1
# Purpose: Constants and lightweight types for the Sync system.
# Convention: No hardcoding, portable, professional implementation.
# NOTE: Class definitions live in their own files (SyncContext.psm1, SyncEventManager.psm1, etc.)
# to avoid duplicate-type errors. This file provides constants only.


# â”€â”€ File Path Constants â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$script:SyncConstants = @{
    # File names
    DefaultStateFileName     = ".gsync.state"
    DefaultLogFileName       = ".gsync.log"
    DefaultConfigFileName    = "gsync.config.json"
    SnapshotsDirName         = ".sync_snapshots"
    LogsDirName              = "logs"

    # Version
    MinGitVersion            = "2.20.0"
    ConfigVersion            = "1.0.0"

    # Retry
    DefaultRetryCount        = 3
    DefaultRetryDelaySeconds = 5
    DefaultPushRetryDelaySeconds = 3
    MaxRetryCount            = 20

    # Parallel
    DefaultMaxThreads        = 4
    MaxMaxThreads            = 64
    MinMaxThreads            = 1

    # Logging
    DefaultLogLevel          = "Info"
    DefaultMaxLogFiles       = 10
    DefaultMaxLogSizeMB      = 50

    # Security
    DefaultBlockedPatterns = @(
        '\.keystore$',
        '\.env$',
        'secrets\.json$',
        'ssh_id$',
        '\.pfx$',
        'id_rsa$',
        'id_dsa$',
        'id_ecdsa$',
        'id_ed25519$'
    )
}

# â”€â”€ Error Categories (Code ranges) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Canonical log levels & colors (single source for all 3 logging stacks).
# Roles stay separate (facade / per-run / service), but shared DATA lives here:
#   Modules/Logging.psm1 (Write-Log facade),
#   Core/SyncLogger.psm1 (per-run structured logger),
#   Providers/LoggingProvider.psm1 (persistent service logger with rotation).
$script:SyncLogColors = @{
    'Error'  = 'Red'
    'Warn'   = 'Yellow'
    'Info'   = 'Cyan'
    'Debug'  = 'Gray'
    'Succ'   = 'Green'
    'Header' = 'Magenta'
}

$script:SyncLogLevels = @{
    'Error'  = 0
    'Warn'   = 1
    'Info'   = 2
    'Succ'   = 2
    'Header' = 2
    'Debug'  = 3
}

function Get-SyncLogColorMap {
    [CmdletBinding()]
    param()

Set-StrictMode -Version 1.0
    $clone = @{}
    foreach ($k in $script:SyncLogColors.Keys) { $clone[$k] = $script:SyncLogColors[$k] }
    return $clone
}

function Get-SyncLogColor {
    [CmdletBinding()]
    param([string]$Level = 'Info')
    if ($Level -and $script:SyncLogColors.ContainsKey($Level)) { return $script:SyncLogColors[$Level] }
    return 'White'
}

function Get-SyncLogLevelValue {
    [CmdletBinding()]
    param([string]$Level = 'Info')
    if ($Level -and $script:SyncLogLevels.ContainsKey($Level)) { return [int]$script:SyncLogLevels[$Level] }
    return 2
}

$script:SyncErrorCategories = @{
    GitError            = 1000
    NetworkError        = 2000
    ValidationError     = 3000
    ConfigurationError  = 4000
    PluginError         = 5000
    PipelineError       = 6000
    SecurityError       = 7000
    StateError          = 8000
    DependencyError     = 9000
    UnknownError        = 9999
}

if ($PSVersionTable.PSVersion.Major -ge 7) {
    # â”€â”€ SyncError class (lightweight, used for structured error reporting) â”€â”€â”€â”€â”€â”€â”€â”€â”€
    class SyncError {
        [string]$Message
        [string]$Category
        [int]$Code
        [object]$CorrelationId
        [string]$Timestamp

        SyncError([string]$message, [string]$category = 'UnknownError', [int]$code = 9999, [object]$correlationId = $null) {
            $this.Message = $message
            $this.Category = $category
            $this.Code = $code
            $this.CorrelationId = if ($correlationId) { $correlationId } else { $null }
            $this.Timestamp = (Get-Date).ToString('o')
        }
    }
}

<#
.SYNOPSIS
    New-SyncError - Factory function
#>
function New-SyncError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Category = 'UnknownError',
        [int]$Code = 9999,
        [string]$CorrelationId = $null
    )
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        return [SyncError]::new($Message, $Category, $Code, $CorrelationId)
    }
    return [PSCustomObject]@{
        Message       = $Message
        Category      = $Category
        Code          = $Code
        CorrelationId = $CorrelationId
        Timestamp     = (Get-Date).ToString('o')
    }
}

<#
.SYNOPSIS
    ConvertTo-Hashtable - Single source of truth for PSCustomObject -> hashtable conversion.
.DESCRIPTION
    Canonical home: Core\SyncTypes.psm1 (lowest layer). Modules that need it
    nest-import this module instead of re-defining their own copy.
#>
function ConvertTo-Hashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return @{} }
    if ($InputObject -is [hashtable]) { return $InputObject }
    if ($InputObject -is [PSCustomObject]) {
        $ht = @{}
        $InputObject.PSObject.Properties | ForEach-Object {
            $val = $_.Value
            if ($val -is [PSCustomObject]) {
                $ht[$_.Name] = ConvertTo-Hashtable -InputObject $val
            } elseif ($val -is [array]) {
                $ht[$_.Name] = $val | ForEach-Object { if ($_ -is [PSCustomObject]) { ConvertTo-Hashtable -InputObject $_ } else { $_ } }
            } else {
                $ht[$_.Name] = $val
            }
        }
        return $ht
    }
    return $InputObject
}

# â”€â”€ Interface definitions (documentation only â€” PS 5.1 cannot enforce) â”€â”€â”€â”€â”€â”€â”€â”€â”€
<#
    ISyncStrategy: Name(), InitEnv(), Execute()
    ISyncEnvironment: Name(), IsCI(), GetConfig(), CanSign()
    ISyncLogger: Log(), Info(), Warn(), Error(), Success(), Debug(), SetLevel()
#>

Export-ModuleMember -Function @('New-SyncError', 'ConvertTo-Hashtable', 'Get-SyncLogColorMap', 'Get-SyncLogColor', 'Get-SyncLogLevelValue')

