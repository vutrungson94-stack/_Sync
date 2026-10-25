#Requires -Version 5.1
# ==================================================================================================
# Modules/Logging.psm1 (Configuration-Driven, Portable, Professional)
# ==================================================================================================

# ── Module Configuration (Single Source of Truth) ─────────────────────────────


# The shared bootstrap makes the logger and the locale resolver available.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1')
$script:LogConfig = [PSCustomObject]@{
    # Terminal settings
    MinWindowWidth      = 80
    MaxWindowWidth      = 120
    DefaultWindowWidth  = 100
    ContentWidthRatio   = 0.60
    ProgressBarWidth    = 20

    # Log file settings
    DefaultLogFileName  = ".gsync.log"
    DefaultLogEncoding  = [System.Text.Encoding]::UTF8
    FileRetryDelayMs    = 50
    FileRetryAttempts   = 2

    # UI settings
    BoxPaddingSmall     = "   "
    BoxPaddingLarge     = "      "
    SeparatorChar       = "─"

    # Messages (internationalizable)
    Messages = [PSCustomObject]@{
        Done             = "Completed"
        DoneWithTime     = "Completed in {0}s"
        Fail             = "Failed"
        FailWithTime     = "Failed in {0}s"
        Processing       = "Processing: {0}..."
        LoggingEnabled   = "Logging enabled: {0}"
    }

    # Default colors
    DefaultColors = [PSCustomObject]@{
        Header = 'Magenta'
        Info   = 'Cyan'
        Warn   = 'Yellow'
        Err    = 'Red'
        Succ   = 'Green'
        Gray   = 'DarkGray'
        White  = 'White'
    }
}

# ── Runtime State (Computed from Config) ─────────────────────────────────────
$script:GW = try {
    $w = [Console]::WindowWidth
    if ($w -le 0) { throw (Get-LocaleMessage -Key 'gsync.msg.logging.invalidWidth') }
    [Math]::Min([Math]::Max($w, $script:LogConfig.MinWindowWidth), $script:LogConfig.MaxWindowWidth)
} catch {
    $script:LogConfig.DefaultWindowWidth
}
$script:GCL = [int]($script:GW * $script:LogConfig.ContentWidthRatio)

# Variable storing log file path (Module scope)
$script:LogFilePath = $null
$script:LogLevel = "Info"

# ── Expose color variables for backward compatibility ────────────────────────

# ==================================================================================
# LOG LEVEL & FILE MANAGEMENT FUNCTIONS
# ==================================================================================

function Set-LogLevel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('Error', 'Warn', 'Info', 'Debug')]
        [string]$Level
    )

Set-StrictMode -Version 1.0
    $script:LogLevel = $Level
    $levelNum = switch ($Level) { 'Error' { 0 }; 'Warn' { 1 }; 'Info' { 2 }; 'Debug' { 3 } }
    $global:CurrentLogLevel = $levelNum
}

function Start-Log {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$Level = "Info",
        [PSCustomObject]$State = $null
    )

    if (-not $Path) {
        $root = if ($State -and $State.ScriptRoot) { $State.ScriptRoot } else { $PSScriptRoot }
        $Path = Join-Path $root $script:LogConfig.DefaultLogFileName
    }
    $script:LogFilePath = $Path
    $script:LogLevel = $Level

    if (Test-Path $Path) { Remove-Item $Path -Force -EA SilentlyContinue }
    New-Item -Path $Path -ItemType File -Force | Out-Null

    $msg = $script:LogConfig.Messages.LoggingEnabled -f $Path
    Write-Host $msg -ForegroundColor $script:LogConfig.DefaultColors.Gray
}

function Stop-Log {
    if ($script:LogFilePath) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.logging.endedAt' -MessageArgs @((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))) -Level Info
    }
}

# ==================================================================================
# UTILITY FUNCTIONS: CALCULATE DISPLAY WIDTH (FIX UNICODE / EMOJI)
# ==================================================================================
function Get-VisualLength {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    # 1. Strip ANSI escape sequences (terminal color codes)
    $clean = $Text -replace '\x1b\[[0-9;]*m', ''
    # 2. Strip Zero-width characters (ZWJ, ZWNJ, Variation Selectors)
    $clean = $clean -replace '[\u200B-\u200D\uFE00-\uFE0F\u2060\uFEFF]', ''
    return $clean.Length
}

function Resolve-SafeColor {
    [CmdletBinding()]
    param(
        [string]$ColorName,
        [PSCustomObject]$State,
        [string]$Fallback = 'White'
    )

    # Try to get color from State, then default config, then parameter
    $raw = $null
    $colorSources = @($State)

    foreach ($source in $colorSources) {
        if ($source -and $source.Colors -and $source.Colors.$ColorName) {
            $raw = $source.Colors.$ColorName
            break
        }
    }

    if (-not $raw -and $script:LogConfig.DefaultColors.$ColorName) {
        $raw = $script:LogConfig.DefaultColors.$ColorName
    }

    # Canonical shared map (Core/SyncTypes.psm1) — single source with the
    # Core/SyncLogger and Providers/LoggingProvider stacks.
    if (-not $raw -and (Get-Command Get-SyncLogColor -ErrorAction SilentlyContinue)) {
        $canonical = Get-SyncLogColor -Level $ColorName
        if ($canonical -and $canonical -ne 'White') { $raw = $canonical }
    }

    if (-not $raw) {
        $raw = if ($ColorName) { $ColorName } else { $Fallback }
    }

    # Parse to ConsoleColor with robust error handling
    try {
        return [System.ConsoleColor]([System.Enum]::Parse([System.ConsoleColor], [string]$raw, $true))
    }
    catch {
        try { return [System.ConsoleColor]$Fallback }
        catch { return [System.ConsoleColor]::White }
    }
}

# ==================================================================================
# CORE LOG WRITING FUNCTION (ANTI FILE-LOCK)
# ==================================================================================
function Protect-GSyncLogMessage {
    <#
    .SYNOPSIS
        Applies the config-driven redactPatterns to a log message.
    .DESCRIPTION
        security.redactPatterns is a config knob that previously shipped
        without a consumer (the config-key-is-read gate's defect class). This
        function is the single owner of the redaction pipeline: it reads the
        patterns (name/pattern/replacement) and applies them in order. A
        missing or invalid pattern is skipped, never fatal. Returns the
        message unchanged when no patterns are configured.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][string]$Message,
        $State = $null
    )
    if ([string]::IsNullOrEmpty($Message)) { return $Message }
    $patterns = @()
    try {
        if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
            $rp = Get-ConfigValue -Path 'security.redactPatterns' -State $State -Default @()
            if ($rp) { $patterns += @($rp) }
        }
    } catch { }
    foreach ($p in $patterns) {
        if ($null -eq $p) { continue }
        $pat = $null
        $repl = '***REDACTED***'
        try { $pat = [string]$p.pattern } catch { $pat = $null }
        try { if ($p.replacement) { $repl = [string]$p.replacement } } catch { }
        if ([string]::IsNullOrWhiteSpace($pat)) { continue }
        try { $Message = [regex]::Replace($Message, $pat, $repl) } catch { }
    }
    return $Message
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)] [string]$Message,
        [Parameter(Position=1)] [string]$Color = "White",
        [Parameter(Position=2)] [PSCustomObject]$State = $null,
        [string]$Level = "INFO"
    )
    # Secret redaction: the build/sync log must never carry a secret value,
    # even when a caller passes one in a message. Apply before any output.
    $Message = Protect-GSyncLogMessage -Message $Message -State $State

    # Normalize level (canonical values live in Core/SyncTypes.psm1 Get-SyncLogLevelValue)
    $levelNum = switch ($Level) {
        'ERROR'   { 0 }
        'WARN'    { 1 }
        'INFO'    { 2 }
        'SUCC'    { 2 }
        'SUCCESS' { 2 }
        'HEADER'  { 2 }
        'DEBUG'   { 3 }
        default   { 2 }
    }

    # Get current log level with type safety
    $rawLevel = if ($null -ne $global:CurrentLogLevel) {
        $global:CurrentLogLevel
    } elseif ($script:LogLevel) {
        switch ($script:LogLevel) {
            'Error' { 0 }; 'Warn' { 1 }; 'Info' { 2 }; 'Debug' { 3 }; default { 2 }
        }
    } else {
        2
    }

    $currentLevel = if ($rawLevel -is [int]) { $rawLevel } else { 2 }

    if ($levelNum -gt $currentLevel) { return }

    if ([string]::IsNullOrWhiteSpace($Color)) { $Color = "White" }

    # Resolve color using centralized function
    $fg = Resolve-SafeColor -ColorName $Color -State $State -Fallback 'White'

    # 1. Console output with error handling
    try { Write-Host $Message -ForegroundColor $fg } catch { Write-Host $Message }

    # 2. File output with retry logic using .NET API
    if ($script:LogFilePath) {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $logLine = "[$timestamp] [$Level] $Message$([System.Environment]::NewLine)"
        $encoding = $script:LogConfig.DefaultLogEncoding

        for ($i = 0; $i -lt $script:LogConfig.FileRetryAttempts; $i++) {
            try {
                [System.IO.File]::AppendAllText($script:LogFilePath, $logLine, $encoding)
                break
            } catch {
                if ($i -lt ($script:LogConfig.FileRetryAttempts - 1)) {
                    Start-Sleep -Milliseconds $script:LogConfig.FileRetryDelayMs
                }
            }
        }
    }
}

# ==================================================================================
# DISPLAY FUNCTIONS (UNICODE ALIGNMENT FIXED)
# ==================================================================================

function _2Col {
    [CmdletBinding()]
    param(
        [string]$L,
        [string]$R = "",
        [string]$LC = "White",
        [string]$RC = "DarkGray",
        [PSCustomObject]$State
    )
    $visualLen = Get-VisualLength -Text $L
    $pad = [Math]::Max($script:GCL - $visualLen, 1)

    $fgL = Resolve-SafeColor -ColorName $LC -State $State -Fallback 'White'
    $fgR = Resolve-SafeColor -ColorName $RC -State $State -Fallback 'DarkGray'

    Write-Host $L -NoNewline -ForegroundColor $fgL
    Write-Host (' ' * $pad) -NoNewline
    if ($R) { Write-Host $R -ForegroundColor $fgR }
    else    { Write-Host "" }
}

function Show-ProgressBar {
    [CmdletBinding()]
    param(
        [int]$Current,
        [int]$Total,
        [string]$Label
    )
    if ($Total -le 0) { $Total = 1 }
    $pct  = [int][Math]::Min([Math]::Ceiling($Current / $Total * 100), 100)
    $barWidth = $script:LogConfig.ProgressBarWidth
    $fill = [int][Math]::Min([Math]::Floor($pct / 100.0 * $barWidth), $barWidth)
    $bar  = ("█" * $fill) + ("░" * ($barWidth - $fill))

    $infoColor = Resolve-SafeColor -ColorName 'Info' -Fallback 'Cyan'
    $grayColor = Resolve-SafeColor -ColorName 'Gray' -Fallback 'DarkGray'

    Write-Host ""
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.progress.bar' -MessageArgs @($($pct.ToString('D2')), $bar, $Label)) -ForegroundColor $infoColor
    Write-Host ($script:LogConfig.SeparatorChar * $script:GW) -ForegroundColor $grayColor
}

function Write-Done {
    [CmdletBinding()]
    param(
        [string]$msg,
        [double]$secs = -1,
        [PSCustomObject]$State
    )
    $r = if ($secs -ge 0) {
        "[✅] $($script:LogConfig.Messages.DoneWithTime -f $secs.ToString('F1'))"
    } else {
        "[✅] $($script:LogConfig.Messages.Done)"
    }
    _2Col "  ✅ $msg" $r "Succ" "Gray" -State $State
}

function Write-Fail {
    [CmdletBinding()]
    param(
        [string]$msg,
        [double]$secs = -1,
        [PSCustomObject]$State
    )
    $r = if ($secs -ge 0) {
        "[❌] $($script:LogConfig.Messages.FailWithTime -f $secs.ToString('F1'))"
    } else {
        "[❌] $($script:LogConfig.Messages.Fail)"
    }
    _2Col "  ❌ $msg" $r "Err" "Gray" -State $State
}

function Write-Info {
    [CmdletBinding()]
    param([string]$msg, [PSCustomObject]$State)
    _2Col "  ℹ  $msg" "" "Info" "" -State $State
}

function Write-Warn {
    [CmdletBinding()]
    param([string]$msg, [PSCustomObject]$State)
    _2Col "  ⚠️  $msg" "" "Warn" "" -State $State
}

function Write-Success {
    [CmdletBinding()]
    param([string]$msg, [PSCustomObject]$State)
    _2Col "  ✅ $msg" "" "Succ" "" -State $State
}

function Write-Sep {
    [CmdletBinding()]
    param()
    $grayColor = Resolve-SafeColor -ColorName 'Gray' -Fallback 'DarkGray'
    Write-Host ($script:LogConfig.SeparatorChar * $script:GW) -ForegroundColor $grayColor
}

    # ── Error logging ──────────────────────────────────────────────────────────
    # This used to be a function literally named 'Write-Error', exported into
    # the global scope. It shadowed the built-in cmdlet for the WHOLE session,
    # so $ErrorActionPreference='Stop' stopped raising terminating errors and
    # nothing reached $Error. The logger now owns a distinct name and the
    # built-in keeps its real semantics.
    function Write-GSyncError {
        [CmdletBinding()]
        param([string]$Message)
        Write-Log $Message -Level ERROR -Color 'Err'
    }

function Set-LogSyncConfig {
    [CmdletBinding()]
    param([PSCustomObject]$Config)
    $script:LogSyncConfig = $Config
}

function Set-LogCorrelationId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    $script:LogCorrelationId = $Id
}

function Get-LogCorrelationId {
    [CmdletBinding()]
    param()
    return $script:LogCorrelationId
}

function Write-JsonLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Level = 'Info',
        [hashtable]$Data = @{}
    )
    try {
        $Message = Protect-GSyncLogMessage -Message $Message -State $null
        $logFile = if ($script:CurrentLogFile) { "$($script:CurrentLogFile).json" } else { Join-Path $PSScriptRoot "../.gsync.log.json" }
        $entry = @{
            timestamp     = (Get-Date).ToString('o')
            level         = $Level.ToUpper()
            message       = $Message
            correlationId = if ($script:LogCorrelationId) { $script:LogCorrelationId } else { '' }
            data          = $Data
        } | ConvertTo-Json -Compress -Depth 3
        $entry | Out-File -FilePath $logFile -Append -Encoding utf8
    } catch { }
}

function Remove-GSyncCredentials {
    # Clear credential-bearing environment variables after sync completes
    foreach ($name in @('GIT_SSH_COMMAND', 'GIT_PAGER', 'PAGER', 'GIT_CONFIG_PARAMETERS', 'GSYNC_SSH_KEY_PATH')) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
}

    Export-ModuleMember -Function @('Set-LogLevel', 'Set-LogSyncConfig', 'Set-LogCorrelationId', 'Get-LogCorrelationId', 'Write-Log', '_2Col', 'Show-ProgressBar', `
      'Write-Done', 'Write-Fail', 'Write-Info', 'Write-Warn', `
      'Write-GSyncError', 'Write-Success', 'Write-Sep', 'Start-Log', 'Stop-Log', 'Get-VisualLength', 'Resolve-SafeColor', `
      'Write-JsonLog', 'Remove-GSyncCredentials', 'Protect-GSyncLogMessage'
  )
