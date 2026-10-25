#Requires -Version 5.1
# Test bootstrap for _Sync Pester 5 test suite.
# Dot-source this file in test files to load shared dependencies.
# This script intentionally uses dot-sourcing so all imports land in the caller's scope.

# Portable temp dir: $env:TEMP is null on Linux/macOS — fall back to .NET temp path.
if (-not $env:TEMP -or -not (Test-Path $env:TEMP)) { $env:TEMP = [System.IO.Path]::GetTempPath() }

$Root = (Split-Path $PSScriptRoot -Parent)

$coreModules = @(
    'SyncTypes.psm1',
    'SyncContext.psm1',
    'SyncEventManager.psm1',
    'SyncRollback.psm1'
)

$appModules = @(
    '../Modules/Logging.psm1',
    '../Modules/UI.psm1',
    '../Modules/Config.psm1',
    '../Modules/Messages.psm1',
    '../Modules/EventBus.psm1',
    '../Modules/Container.psm1',
    '../Modules/ErrorHandling.psm1',
    '../Modules/GitUtils.psm1',
    '../Modules/Security.psm1',
    '../Modules/SecurityPlugin.psm1',
    '../Modules/Cleanup.psm1',
    '../Modules/DependencyChecker.psm1',
    '../Modules/Alerting.psm1',
    '../Modules/Metrics.psm1',
    '../Modules/PathNormalization.psm1',
    '../Modules/PluginRegistry.psm1',
    '../Modules/AutoCommit.psm1',
    '../Modules/SmartCommitRules.psm1',
    '../Modules/SmartGitignore.psm1',
    '../Modules/SelfHeal.psm1',
    '../Modules/SyncSafety.psm1'
)

$providerModules = @()

foreach ($mod in $coreModules) {
    $path = Join-Path (Join-Path $Root 'Core') $mod
    if (Test-Path $path) {
        Import-Module $path -Force -DisableNameChecking -Scope Global -ErrorAction SilentlyContinue
        $cmds = Import-Module $path -Force -DisableNameChecking -PassThru -ErrorAction SilentlyContinue
        if ($cmds) {
            $cmds.ExportedFunctions.Keys | ForEach-Object {
                $fn = Get-Item -Path ("function:\{0}" -f $_) -ErrorAction SilentlyContinue
                if ($fn) {
                    $sb = $fn.ScriptBlock
                    Set-Content -Path ("function:\global:{0}" -f $_) -Value $sb
                }
            }
        }
    }
}

foreach ($mod in $appModules) {
    $path = Join-Path $PSScriptRoot $mod
    if (Test-Path $path) {
        Import-Module $path -Force -DisableNameChecking -Scope Global -ErrorAction SilentlyContinue
        $cmds = Import-Module $path -Force -DisableNameChecking -PassThru -ErrorAction SilentlyContinue
        if ($cmds) {
            $cmds.ExportedFunctions.Keys | ForEach-Object {
                $fn = Get-Item -Path ("function:\{0}" -f $_) -ErrorAction SilentlyContinue
                if ($fn) {
                    $sb = $fn.ScriptBlock
                    Set-Content -Path ("function:\global:{0}" -f $_) -Value $sb
                }
            }
        }
    }
}

foreach ($mod in $providerModules) {
    $path = Join-Path $PSScriptRoot $mod
    if (Test-Path $path) {
        Import-Module $path -Force -DisableNameChecking -Scope Global -ErrorAction SilentlyContinue
        $cmds = Import-Module $path -Force -DisableNameChecking -PassThru -ErrorAction SilentlyContinue
        if ($cmds) {
            $cmds.ExportedFunctions.Keys | ForEach-Object {
                $fn = Get-Item -Path ("function:\{0}" -f $_) -ErrorAction SilentlyContinue
                if ($fn) {
                    $sb = $fn.ScriptBlock
                    Set-Content -Path ("function:\global:{0}" -f $_) -Value $sb
                }
            }
        }
    }
}

$syncTypes = Join-Path $Root 'Core/SyncTypes.psm1'
if (Test-Path $syncTypes) {
    $st = Import-Module $syncTypes -Force -PassThru -DisableNameChecking -ErrorAction SilentlyContinue
    if ($st) {
        $constants = $st.SessionState.PSVariable.Get('SyncConstants')
        if ($constants) {
            $val = $constants.Value
            if ($val.DefaultBlockedPatterns -and $val.DefaultBlockedPatterns -isnot [System.Array]) {
                $val.DefaultBlockedPatterns = @($val.DefaultBlockedPatterns)
            }
            $global:SyncConstants = $val
        }
        $errorCats = $st.SessionState.PSVariable.Get('SyncErrorCategories')
        if ($errorCats) {
            $global:SyncErrorCategories = $errorCats.Value
        }
    }
}

$mocksPath = Join-Path $PSScriptRoot 'Mocks.ps1'
if (Test-Path $mocksPath) {
    . $mocksPath
    Get-Command -CommandType Function | ForEach-Object {
        $name = $_.Name
        $fn = Get-Item -Path ("function:\{0}" -f $name) -ErrorAction SilentlyContinue
        if ($fn) {
            $sb = $fn.ScriptBlock
            Set-Content -Path ("function:\global:{0}" -f $name) -Value $sb
        }
    }
}
