#Requires -Version 5.1
# PluginRegistry.psm1 - dynamic plugin discovery, validation and invocation
# for _Sync Platform.
# Convention: no external runtime deps, PS 5.1 safe.
#
# Two plugin contracts coexist in _Sync and the registry supports both:
#   - Prefixed (transport plugins): <Name>-GetPluginInfo / -InvokePluginValidate /
#     -InvokePluginSync            (GitPlugin, GPGPlugin, LFSPlugin)
#   - Flat (language plugins):      Get-PluginInfo / Invoke-PluginBuild /
#     Invoke-PluginTest / Invoke-PluginLint / Invoke-PluginPreflight
#                                    (Node, Python)
# A plugin is valid when it exports the commands of at least one contract and
# declares its info object. The registry is the single owner of that decision.

# Make the logger available when this module is imported on its own.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1')
$script:RegisteredPlugins = @{}
$script:PluginContracts = @{
    Prefixed = @('GetPluginInfo', 'InvokePluginValidate', 'InvokePluginSync')
    Flat     = @('GetPluginInfo', 'InvokePluginBuild', 'InvokePluginTest', 'InvokePluginLint')
}

function Get-PluginDirs {
    [CmdletBinding()]
    param([string]$Root = (Join-Path $PSScriptRoot 'Plugins'))

Set-StrictMode -Version 1.0
    if (-not (Test-Path -LiteralPath $Root)) { return @() }

    $dirs = @()
    # Nested plugin directories (Name/Name.psm1)
    Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
        Test-Path (Join-Path $_.FullName "$($_.Name).psm1")
    } | ForEach-Object { $dirs += $_.FullName }

    # Flat plugin files (Plugins/*.psm1)
    Get-ChildItem -LiteralPath $Root -File -Filter '*.psm1' -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $base = [IO.Path]::GetFileNameWithoutExtension($_.Name)
        $pseudoDir = Join-Path $Root $base
        if ($dirs -notcontains $pseudoDir) { $dirs += $pseudoDir }
    }
    return $dirs
}

function Get-AvailablePlugins {
    [CmdletBinding()]
    param([string]$Root = (Join-Path $PSScriptRoot 'Plugins'))
    $paths = Get-PluginDirs -Root $Root
    $found = @()
    foreach ($path in $paths) {
        $name = Split-Path $path -Leaf
        $modulePath = Join-Path $path "$name.psm1"
        if (-not (Test-Path -LiteralPath $modulePath)) {
            # flat file fallback
            $modulePath = Join-Path $Root "$name.psm1"
        }
        if (Test-Path -LiteralPath $modulePath) {
            $found += [PSCustomObject]@{
                Name = $name
                Path = $modulePath
                Dir  = $path
            }
        }
    }
    return $found
}

function ConvertTo-PluginCommandName {
    <#
    .SYNOPSIS
        Normalizes a command name for contract comparison.
    .DESCRIPTION
        The same command is spelled two ways in _Sync: 'Get-PluginInfo' (flat)
        and 'GitPlugin-GetPluginInfo' (prefixed). Comparing them literally
        made the flat contract unmatchable. Hyphens are dropped so the
        contract list can be written once.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Name)
    if (-not $Name) { return '' }
    return ($Name -replace '-', '')
}

function Test-SyncPluginContract {
    <#
    .SYNOPSIS
        Returns the contract a plugin satisfies, or $null.
    .DESCRIPTION
        Both contracts are checked: a plugin that exports the prefixed commands
        is a transport plugin, one that exports the flat commands is a language
        plugin. The first contract that is fully satisfied wins.

        The two contracts match names differently:
          - Flat: the command is exported under its own name
            ('Get-PluginInfo').
          - Prefixed: the command is exported under a plugin-prefixed name
            ('GitPlugin-GetPluginInfo'), so the name must END WITH the
            contract command.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]]$Exported = @())
    if (-not $Exported -or $Exported.Count -eq 0) { return $null }
    $normalized = @($Exported | ForEach-Object { ConvertTo-PluginCommandName $_ })
    foreach ($contract in @('Prefixed', 'Flat')) {
        $required = $script:PluginContracts[$contract]
        $ok = $true
        foreach ($cmd in $required) {
            $needle = ConvertTo-PluginCommandName $cmd
            if ($contract -eq 'Prefixed') {
                $hit = $false
                foreach ($e in $normalized) {
                    if ($e.EndsWith($needle) -and $e.Length -gt $needle.Length) { $hit = $true; break }
                }
                if (-not $hit) { $ok = $false; break }
            } else {
                if ($normalized -notcontains $needle) { $ok = $false; break }
            }
        }
        if ($ok) { return $contract }
    }
    return $null
}

function Register-Plugins {
    [CmdletBinding()]
    param(
        [string]$Root = (Join-Path $PSScriptRoot 'Plugins'),
        [string[]]$Enabled = @(),
        [string[]]$Disabled = @()
    )
    $available = Get-AvailablePlugins -Root $Root
    $script:RegisteredPlugins = @{}
    foreach ($p in $available) {
        if ($Disabled -contains $p.Name) { continue }
        if ($Enabled.Count -gt 0 -and $Enabled -notcontains $p.Name) { continue }
        try {
            Remove-Module $p.Name -ErrorAction SilentlyContinue
            Import-Module $p.Path -Force -DisableNameChecking -ErrorAction Stop
            $module = Get-Module $p.Name -ErrorAction SilentlyContinue
            $exported = @()
            if ($module) { $exported = @($module.ExportedFunctions.Keys) }
            $info = [PSCustomObject]@{}
            if (Get-Command -Name "$($p.Name)-GetPluginInfo" -ErrorAction SilentlyContinue) {
                $info = & "$($p.Name)-GetPluginInfo"
            } elseif (Get-Command 'Get-PluginInfo' -ErrorAction SilentlyContinue) {
                $info = Get-PluginInfo
            }
            $script:RegisteredPlugins[$p.Name] = [PSCustomObject]@{
                Name      = $p.Name
                Path      = $p.Path
                Dir       = $p.Dir
                Exported  = $exported
                Info      = $info
                Contract  = (Test-SyncPluginContract -Exported $exported)
                LoadedAt  = (Get-Date).ToString('o')
            }
        } catch {
            Write-Warn (Get-LocaleMessage -Key 'gsync.msg.plugin.loadFailed' -MessageArgs @([string]$p.Name, [string]$_))
        }
    }
    return @($script:RegisteredPlugins.Values)
}

function Resolve-PluginCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PluginName,
        [Parameter(Mandatory)][string]$CommandName
    )
    if (-not $script:RegisteredPlugins.ContainsKey($PluginName)) {
        throw (Get-LocaleMessage -Key 'gsync.msg.plugin.notRegistered' -MessageArgs @($PluginName))
    }
    $candidate = "$PluginName-$CommandName"
    if ($script:RegisteredPlugins[$PluginName].Exported -contains $candidate) {
        return $candidate
    }
    if ($script:RegisteredPlugins[$PluginName].Exported -contains $CommandName) {
        return $CommandName
    }
    return $null
}

function Invoke-PluginCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PluginName,
        [Parameter(Mandatory)][string]$CommandName,
        [object[]]$ArgumentList = @(),
        [string]$WorkingDir
    )
    $fn = Resolve-PluginCommand -PluginName $PluginName -CommandName $CommandName
    if (-not $fn) {
        throw (Get-LocaleMessage -Key 'gsync.msg.plugin.noCommand' -MessageArgs @($PluginName, $CommandName))
    }
    $prev = Get-Location
    try {
        if ($WorkingDir) { Set-Location $WorkingDir }
        return & $fn @ArgumentList
    } finally {
        Set-Location $prev
    }
}

function Get-RegisteredPlugins {
    return @($script:RegisteredPlugins.Values)
}

function Clear-RegisteredPlugins {
    $script:RegisteredPlugins = @{}
}

function Write-PluginGateError {
    <#
    .SYNOPSIS
        Reports a plugin gate finding without assuming the logger is loaded.
    .DESCRIPTION
        PluginRegistry.psm1 can be imported on its own (the test suite does),
        in which case the global Write-GSyncError from Logging.psm1 is not
        present. Calling it anyway raised CommandNotFoundException, which is
        terminating, and the gate died instead of reporting the finding. The
        fallback records a non-terminating error so the gate always returns
        its verdict.
    #>
    param([string]$Message)
    $logger = Get-Command Write-GSyncError -ErrorAction SilentlyContinue
    if ($logger) { & $logger $Message; return }
    Write-Error -Message $Message -ErrorAction Continue
}

function Test-GSyncPlugin {
    <#
    .SYNOPSIS
        Validates a single registered plugin against the plugin contracts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PluginName,
        [string]$Root = (Join-Path $PSScriptRoot 'Plugins')
    )
    if (-not $script:RegisteredPlugins.ContainsKey($PluginName)) {
        Write-PluginGateError "Plugin '$PluginName' is not registered."
        return $false
    }
    $reg = $script:RegisteredPlugins[$PluginName]
    $contract = $reg.Contract
    if (-not $contract) {
        Write-PluginGateError "Plugin '$PluginName' does not satisfy any known plugin contract."
        return $false
    }
    $required = $script:PluginContracts[$contract]
    $missing = @()
    $normalized = @($reg.Exported | ForEach-Object { ConvertTo-PluginCommandName $_ })
    foreach ($cmd in $required) {
        $needle = ConvertTo-PluginCommandName $cmd
        if ($contract -eq 'Prefixed') {
            $hit = $false
            foreach ($e in $normalized) {
                if ($e.EndsWith($needle) -and $e.Length -gt $needle.Length) { $hit = $true; break }
            }
            if (-not $hit) { $missing += $cmd }
        } else {
            if ($normalized -notcontains $needle) { $missing += $cmd }
        }
    }
    if ($missing.Count -gt 0) {
        Write-PluginGateError "Plugin '$PluginName' is missing required commands: $($missing -join ', ')"
        return $false
    }
    if (-not $reg.Info -or $reg.Info.PSObject.Properties.Count -eq 0) {
        Write-Warn (Get-LocaleMessage -Key 'gsync.msg.plugin.noInfoSchema' -MessageArgs @([string]$PluginName))
    }
    return $true
}

function Invoke-SyncPluginGate {
    <#
    .SYNOPSIS
        Runs the plugin registry gate over every discovered plugin.
    .DESCRIPTION
        The gate loads the plugins, checks each one against the plugin
        contracts and reports the plugins that failed to load. A plugin that
        cannot be loaded is an error: the registry would silently ship a
        feature that is not there.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$Root = (Join-Path $PSScriptRoot 'Plugins'),
        [string[]]$Enabled = @(),
        [string[]]$Disabled = @()
    )
    $available = @(Get-AvailablePlugins -Root $Root)
    $registered = @(Register-Plugins -Root $Root -Enabled $Enabled -Disabled $Disabled)
    $findings = @()
    $checks = @()
    foreach ($p in $available) {
        $reg = $script:RegisteredPlugins[$p.Name]
        if (-not $reg) {
            $checks += [PSCustomObject]@{ Plugin = $p.Name; Passed = $false; Reason = 'load failed' }
            $findings += [PSCustomObject]@{ Plugin = $p.Name; Severity = 'error'; Detail = 'plugin failed to load' }
            continue
        }
        $ok = $true
        $reason = ''
        if (-not $reg.Contract) { $ok = $false; $reason = 'no known contract' }
        elseif (-not $reg.Info -or $reg.Info.PSObject.Properties.Count -eq 0) { $ok = $false; $reason = 'missing Get-PluginInfo' }
        $checks += [PSCustomObject]@{ Plugin = $p.Name; Passed = $ok; Reason = $reason; Contract = $reg.Contract }
        if (-not $ok) {
            $findings += [PSCustomObject]@{ Plugin = $p.Name; Severity = 'error'; Detail = $reason }
        }
    }
    $errors = @($findings | Where-Object { $_.Severity -eq 'error' })
    return [PSCustomObject]@{
        Passed     = ($errors.Count -eq 0)
        Plugins    = @($checks)
        Findings   = @($findings)
        Registered = @($registered | ForEach-Object { $_.Name })
        Discovered = @($available | ForEach-Object { $_.Name })
    }
}

Export-ModuleMember -Function @(
    'Get-PluginDirs', 'Get-AvailablePlugins', 'Register-Plugins', 'Resolve-PluginCommand',
    'Invoke-PluginCommand', 'Get-RegisteredPlugins', 'Clear-RegisteredPlugins',
    'Test-GSyncPlugin', 'Test-SyncPluginContract', 'Invoke-SyncPluginGate'
)
