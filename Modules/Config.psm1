#Requires -Version 5.1
# Config.psm1
#
# Single owner for configuration access in _Sync.
#
# Get-ConfigValue is the ONE dotted-path reader used by every module that
# needs a config value (Security, Metrics, SupplyChain). It used to be
# referenced by three modules but defined nowhere, so every read of
# telemetry.* / supplyChain.* / security.secretPatterns silently fell back
# to a hardcoded default and the matching gsync.config.json sections were
# dead config. The function now lives here, next to Import-Config which
# owns the parsed configuration.

# Make the logger available when this module is imported on its own.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1')
# The configuration currently in effect. Import-Config owns it; Get-ConfigValue
# reads it when the caller does not carry the config on its state object.
$script:CurrentConfig = $null

function Write-ConfigError {
    <#
    .SYNOPSIS
        Reports a config error without assuming the logger is loaded.
    .DESCRIPTION
        Config.psm1 can be imported on its own (the test suite does), in which
        case the global Write-GSyncError from Logging.psm1 may not exist.
    #>
    param([string]$Message)

Set-StrictMode -Version 1.0
    $logger = Get-Command Write-GSyncError -ErrorAction SilentlyContinue
    if ($logger) { & $logger $Message } else { Write-Warning $Message }
}

function Get-DefaultConfig {
    $json = @'
{
  "_readme": "gsync config",
  "version": "2.1.0",
  "git": {
    "remoteName": "origin",
    "defaultBranchFallback": "main",
    "pullConflictPolicy": "ask",
    "stashWhenWorkingTreeDirty": true,
    "retryCount": 3,
    "minVersion": "2.20.0"
  },
  "gitignore": {
    "enabled": true,
    "rulesToAdd": [ "# === SECURITY ===", "ssh_id", "*.pfx", ".env", "bin/", "obj/", "node_modules/", ".vs/", "*.apk", "*.aab", "publish-output/" ]
  },
  "sensitive": {
    "enabled": true,
    "allowedPatterns": [ "\\.env\\.example$" ],
    "blockedPatterns": [ "\\.keystore$", "\\.env$", "secrets\\.json$" ]
  },
  "junkCleanup": {
    "enabled": true,
    "patterns": [ "*.tmp", "Thumbs.db" ],
    "restrictToDirs": [ "." ],
    "confirmBeforeDelete": false
  },
  "largeFiles": {
    "enabled": true,
    "excludeDirs": [ ".git", "node_modules" ]
  },
  "artifactUnstage": {
    "enabled": true,
    "patterns": [ "\\.(apk|aab|ipa|msix)$" ],
    "extraPatterns": [ "publish-output/" ]
  },
  "ui": {
    "largeFileThresholdMB": 90
  },
  "webhook": {
    "enabled": false,
    "url": "",
    "onSuccess": true,
    "onFailure": true
  },
  "logging": {
    "level": "Info",
    "enableFile": true,
    "enableConsoleColor": true,
    "enableJsonLog": true,
    "maxLogFiles": 10,
    "maxLogSizeMB": 50
  },
  "security": {
    "enabled": true,
    "blockOnMatch": true
  }
}
'@
    return ($json | ConvertFrom-Json)
}

function Import-Config {
    param([string]$Path)
    # Resolve relative paths against the TOOL root, never the process CWD. This
    # function bootstrap-writes a default config when the path is missing, so a
    # CWD-relative 'gsync.config.json' used to materialise a stray copy in
    # whatever folder gsync was launched from (typically the workspace root that
    # holds _Build/_Sync/_Tests). $PSScriptRoot here is <tool>/Modules.
    $toolRoot = Split-Path -Parent $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Join-Path $toolRoot 'gsync.config.json' }
    elseif (-not [System.IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $toolRoot $Path }
    if (-not (Test-Path $Path)) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.config.notFound') -Level Info
        $cfg = Get-DefaultConfig
        try {
            # Never CREATE a config outside the tool root or the project being
            # synced: those are the files nobody owns. Existing files are still
            # read normally; only the bootstrap write is constrained.
            $parent = Split-Path -Parent $Path
            $projectRoot = (Get-Location).Path
            $sep = [System.IO.Path]::DirectorySeparatorChar
            $insideTool = $parent -and ($parent -eq $toolRoot -or $parent.StartsWith($toolRoot + $sep))
            $insideProject = $parent -and ($parent -eq $projectRoot -or $parent.StartsWith($projectRoot + $sep))
            if (-not ($insideTool -or $insideProject)) {
                Write-Warn ("Refusing to create config outside the tool/project root: {0}" -f $Path)
                $script:CurrentConfig = $cfg
                return $cfg
            }
            $jsonOut = $cfg | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($Path, $jsonOut, [System.Text.UTF8Encoding]::new($false))
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.config.created' -MessageArgs @($Path)) -Level Success
        } catch {
            Write-Warn (Get-LocaleMessage -Key 'gsync.msg.config.cannotWrite' -MessageArgs @([string]$_))
        }
        $script:CurrentConfig = $cfg
        return $cfg
    }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $cfg = ($raw | ConvertFrom-Json)
        # Merge the default sections UNDER the loaded config so a config file
        # written before a section existed still gets that section. Without
        # this, shipping a new section (gitignore, webhook, artifactUnstage)
        # never reached operators who already had a config file on disk.
        $cfg = Merge-ConfigDefaults -Config $cfg -Defaults (Get-DefaultConfig)
        $script:CurrentConfig = $cfg
        return $cfg
    } catch {
        Write-ConfigError "Config parse error: $($_.Exception.Message)"
        return $null
    }
}

function Merge-ConfigDefaults {
    <#
    .SYNOPSIS
        Fills in top-level sections that the loaded config does not define.
    .DESCRIPTION
        Existing values always win. Only sections that are entirely absent
        are added, so an operator who deliberately writes an empty section
        keeps it. The merge is one level deep on purpose: nested values inside
        a present section stay owned by the config file.
    #>
    [CmdletBinding()]
    param($Config, $Defaults)
    if (-not $Defaults) { return $Config }
    if (-not $Config) { return $Defaults }
    foreach ($p in $Defaults.PSObject.Properties) {
        if ($null -eq $Config.PSObject.Properties[$p.Name]) {
            $Config | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        }
    }
    return $Config
}

function Find-ConfigNode {
    <#
    .SYNOPSIS
        Resolves a dotted path inside a configuration object.
    .DESCRIPTION
        Supports both nested objects (a.b -> { a = { b = ... } }) and flat
        keys that already contain the dots (the locale catalogs use the flat
        form, and some config sections were authored that way).
    #>
    [CmdletBinding()]
    param($Root, [Parameter(Mandatory)][string]$Path)
    if ($null -eq $Root) { return $null }

    # Flat key wins: "a.b" as a literal property name.
    if ($Root -is [System.Collections.IDictionary]) {
        if ($Root.Contains($Path)) { return $Root[$Path] }
    } elseif ($Root.PSObject.Properties[$Path]) {
        return $Root.PSObject.Properties[$Path].Value
    }

    $current = $Root
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $null }
            $current = $current[$segment]
        } else {
            $prop = $current.PSObject.Properties[$segment]
            if (-not $prop) { return $null }
            $current = $prop.Value
        }
    }
    return $current
}

function Resolve-ConfigEnvironmentValue {
    <#
    .SYNOPSIS
        Expands ${env:VAR} placeholders inside a configuration value.
    .DESCRIPTION
        The shipped config uses "${env:GSYNC_TENANT_ID}" and
        "${env:OTEL_EXPORTER_OTLP_ENDPOINT}". Import-Config used to return the
        raw text, so those literals reached the consumer verbatim. Expansion
        happens here, in one place, for every reader.
    #>
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -isnot [string]) { return $Value }
    if ($Value -notmatch '\$\{env:') { return $Value }
    return [regex]::Replace($Value, '\$\{env:(?<name>[A-Za-z_][A-Za-z0-9_]*)\}', {
        param($m)
        $v = [Environment]::GetEnvironmentVariable($m.Groups['name'].Value)
        if ([string]::IsNullOrEmpty($v)) { return '' }
        return $v
    })
}

function Get-ConfigValue {
    <#
    .SYNOPSIS
        Reads a dotted configuration path.
    .PARAMETER Path
        Dotted path, e.g. 'telemetry.prometheus.port'.
    .PARAMETER State
        Optional state object carrying the configuration. Supported carriers
        are SyncConfig, BuildConfig and Config; when none is present the
        configuration loaded by Import-Config is used.
    .PARAMETER Default
        Returned when the path does not resolve.
    .PARAMETER ResolveEnv
        Expand ${env:VAR} placeholders in the resolved value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        $State,
        $Default = $null,
        [switch]$ResolveEnv
    )
    $cfg = $null
    if ($State) {
        foreach ($carrier in @('SyncConfig','BuildConfig','Config')) {
            if ($State.PSObject.Properties[$carrier]) {
                $candidate = $State.PSObject.Properties[$carrier].Value
                if ($null -ne $candidate) { $cfg = $candidate; break }
            }
        }
    }
    if ($null -eq $cfg) { $cfg = $script:CurrentConfig }
    # DI migration: when no state and no script-level config, resolve the
    # config through the container (the single source of truth registered at
    # startup). Modules that previously reached for the global
    # $script:CurrentConfig directly can now call Get-ConfigValue with no
    # state and still get the container-managed config. This makes the DI
    # container load-bearing instead of decorative.
    if ($null -eq $cfg -and (Get-Command Resolve-GSyncService -ErrorAction SilentlyContinue)) {
        try {
            $diCfg = $null
            try { $diCfg = Resolve-GSyncService -Name 'Config' -ErrorAction Stop } catch { $diCfg = $null }
            if ($null -ne $diCfg) { $cfg = $diCfg }
        } catch { }
    }
    if ($null -eq $cfg) { return $Default }

    $value = Find-ConfigNode -Root $cfg -Path $Path
    if ($null -eq $value) { return $Default }
    if ($ResolveEnv) { return Resolve-ConfigEnvironmentValue -Value $value }
    return $value
}

function Test-GSyncConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [string]$SchemaPath
    )

    if (-not $SchemaPath) {
        $SchemaPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'gsync.config.schema.json'
    }
    
    if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
        try {
            $json = $Config | ConvertTo-Json -Depth 10
            $null = $json | Test-Json -SchemaFile $SchemaPath -ErrorAction Stop
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.config.schemaPassed') -Level Info
            return $true
        } catch {
            Write-ConfigError "Config validation failed: $($_.Exception.Message)"
            return $false
        }
    }
    
    Write-Log (Get-LocaleMessage -Key 'gsync.msg.config.testJsonUnavailable') -Level Warn
    $errors = @()
    if (-not $Config.version) { $errors += "Missing 'version'" }
    if (-not $Config.git) { $errors += "Missing 'git'" }
    if (-not $Config.logging) { $errors += "Missing 'logging'" }
    if (-not $Config.security) { $errors += "Missing 'security'" }
    if ($Config.git) {
        if (-not $Config.git.remoteName) { $errors += "git.remoteName is required" }
        if (-not $Config.git.retryCount) { $errors += "git.retryCount is required" }
    }
    if ($errors.Count -gt 0) {
        Write-ConfigError "Config validation failed: $($errors -join '; ')"
        return $false
    }
    Write-Log (Get-LocaleMessage -Key 'gsync.msg.config.lightweightPassed') -Level Info
    return $true
}

function Load-SyncConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [string]$Path
    )
    if (-not $Path) {
        $Path = Join-Path $ScriptRoot 'gsync.config.json'
    }
    if (-not (Test-Path $Path)) {
        return ConvertTo-Hashtable -InputObject (Get-DefaultConfig)
    }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    try {
        $cfg = $raw | ConvertFrom-Json
        return ConvertTo-Hashtable -InputObject $cfg
    } catch {
        Write-ConfigError "Config parse error: $($_.Exception.Message)"
        return ConvertTo-Hashtable -InputObject (Get-DefaultConfig)
    }
}

function Validate-SyncConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )
    if (-not $Config) { return $false }
    if (-not $Config.ContainsKey('version')) { return $false }
    if (-not $Config.ContainsKey('git')) { return $false }
    return $true
}

Export-ModuleMember -Function @('Get-DefaultConfig', 'Import-Config', 'Test-GSyncConfig', 'Load-SyncConfig', 'Validate-SyncConfig', 'Get-ConfigValue', 'Find-ConfigNode', 'Merge-ConfigDefaults', 'Resolve-ConfigEnvironmentValue')





