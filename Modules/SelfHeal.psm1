#Requires -Version 5.1
# SelfHeal.psm1 - Self-healing for _Sync (modeled on _Build patterns, scoped to git-sync)
# Requires -Version 5.1
#
# Three mechanisms (same trio as _Build, minimal sync-domain scope):
#   1. Invoke-SyncSelfBootstrap : single-owner sentinel bootstrap for Steps/Hooks.
#      Dot-source standalone scripts stay usable without a prior gsync.module import.
#   2. Import-SyncModuleOnDemand : guarded lazy import (-Scope Global) so a missing
#      module is healed instead of crashing the caller.
#   3. Test-SyncHealth / Invoke-SyncAutoFix / Invoke-SyncDoctor : tiny health suite
#      (toolchain, repo, config, stale lock, hooks) with SAFE auto-fixes only.
#      Never runs destructive git commands (no reset/checkout/clean); anything
#      unsafe is reported with a Suggestion for manual action.
#
# Design rules (mirrors _Build hook policy):
#   * Absence degrades to no-op with a reason, never a crash.
#   * AutoFix only touches regenerable state (lock files, default config).
#   * Every check returns Pass/Warn/Fail + Suggestion; callers decide.


# Make the logger available when this module is imported on its own.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('Config')

function New-SyncHealthResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Pass', 'Warn', 'Fail')][string]$Status,
        [string]$Message = '',
        [string]$Suggestion = ''
    )

Set-StrictMode -Version 1.0
    return [PSCustomObject]@{
        Name       = $Name
        Status     = $Status
        Message    = $Message
        Suggestion = $Suggestion
    }
}

function Invoke-SyncSelfBootstrap {
    <#
    .SYNOPSIS
        Single-owner sentinel bootstrap (port of _Build StepBootstrap, sync scope).
    .DESCRIPTION
        If ANY sentinel command is missing, walks up (max 6 levels) to the _Sync
        root (marked by the Modules/ directory) and imports the base set plus
        any extra -Modules with -Scope Global. Cheap no-op when already loaded.
        Cleans up its temp variables so dot-sourcing never pollutes the caller.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Sentinels = @('Write-Log', 'Get-DefaultConfig', 'Send-BuildEvent'),
        [string[]]$Modules = @()
    )
    $__syncHealBase = @('Logging', 'Config', 'EventBus', 'Messages')
    $__syncHealAll = @($__syncHealBase + $Modules | Select-Object -Unique | Where-Object { $_ })
    $__syncHealNeed = $false
    foreach ($__syncHealSentinel in $Sentinels) {
        if (-not (Get-Command $__syncHealSentinel -ErrorAction SilentlyContinue)) {
            $__syncHealNeed = $true
            break
        }
    }
    if ($__syncHealNeed) {
        $__syncHealRoot = $PSScriptRoot
        if (-not $__syncHealRoot) { $__syncHealRoot = (Get-Location).Path }
        # If this module itself is loaded, root is its parent (Modules -> _Sync).
        if ((Split-Path $__syncHealRoot -Leaf) -eq 'Modules') {
            $__syncHealRoot = Split-Path $__syncHealRoot -Parent
        } else {
            $__syncHealDepth = 0
            while ($__syncHealRoot -and $__syncHealDepth -lt 6 -and
                   -not (Test-Path -LiteralPath (Join-Path $__syncHealRoot 'Modules') -PathType Container)) {
                $__syncHealRoot = Split-Path $__syncHealRoot -Parent
                $__syncHealDepth++
            }
        }
        if ($__syncHealRoot -and (Test-Path -LiteralPath (Join-Path $__syncHealRoot 'Modules') -PathType Container)) {
            foreach ($__syncHealModule in $__syncHealAll) {
                $__syncHealPath = Join-Path (Join-Path $__syncHealRoot 'Modules') "$__syncHealModule.psm1"
                if (Test-Path -LiteralPath $__syncHealPath -PathType Leaf) {
                    Import-Module $__syncHealPath -Force -Scope Global -DisableNameChecking -ErrorAction SilentlyContinue
                }
            }
        }
    }
    Remove-Variable -Name __syncHealBase, __syncHealAll, __syncHealNeed, `
        __syncHealSentinel, __syncHealRoot, __syncHealDepth, `
        __syncHealModule, __syncHealPath -ErrorAction SilentlyContinue
}

function Import-SyncModuleOnDemand {
    <#
    .SYNOPSIS
        Guarded lazy import (port of _Build Import-ModuleOnDemand, sync scope).
    .DESCRIPTION
        Imports each named Modules/<Name>.psm1 only if not already loaded.
        A same-named module from a DIFFERENT _Sync copy is replaced so every run
        uses the active copy. Uses -Scope Global (the _Sync convention) so the
        exports stay visible to the caller. Never throws: absence is skipped.
    #>
    [CmdletBinding()]
    param([string[]]$ModuleNames = @())
    foreach ($name in $ModuleNames) {
        if (-not $name) { continue }
        $modRoot = $PSScriptRoot
        if (-not $modRoot) { $modRoot = (Get-Location).Path }
        if ((Split-Path $modRoot -Leaf) -ne 'Modules') {
            $candidate = Join-Path $modRoot 'Modules'
            if (Test-Path -LiteralPath $candidate -PathType Container) { $modRoot = $candidate }
        }
        $path = Join-Path $modRoot "$name.psm1"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $loaded = Get-Module -Name $name -ErrorAction SilentlyContinue
        if ($loaded -and (($loaded.Path -and $loaded.Path -ne $path) -or -not $loaded.Path)) {
            Remove-Module -Name $name -Force -ErrorAction SilentlyContinue
            $loaded = $null
        }
        if ($loaded) { continue }
        Import-Module $path -Force -Scope Global -DisableNameChecking -ErrorAction SilentlyContinue
    }
}

function Test-SyncHealth {
    <#
    .SYNOPSIS
        Lightweight sync health suite (toolchain + repo + config + lock + hooks).
    .DESCRIPTION
        Returns an array of Pass/Warn/Fail results with Suggestion text.
        Never throws; every probe is guarded. Read-only except for probes.
    #>
    [CmdletBinding()]
    param(
        [string]$RepoRoot = (Get-Location).Path,
        [string]$ConfigPath = '',
        [string[]]$Checks = @('GitTool', 'GitRepo', 'ConfigFile', 'StaleLock', 'Hooks')
    )
    $results = @()
    $want = { param($n) ($Checks -contains $n) }.GetNewClosure()

    if (& $want 'GitTool') {
        $gitCmd = Get-Command git -ErrorAction SilentlyContinue
        if ($gitCmd) {
            $ver = ''
            try { $ver = (& git --version 2>$null | Out-String).Trim() } catch { $ver = '' }
            $results += New-SyncHealthResult -Name 'Git Tool' -Status 'Pass' -Message $ver
        } else {
            $results += New-SyncHealthResult -Name 'Git Tool' -Status 'Fail' `
                -Message 'git not found on PATH' -Suggestion 'Install git from https://git-scm.com'
        }
    }

    if (& $want 'GitRepo') {
        $inside = ''
        try {
            if ($RepoRoot -and (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
                $inside = (& git -C $RepoRoot rev-parse --is-inside-work-tree 2>$null | Out-String).Trim()
            }
        } catch { $inside = '' }
        if ($inside -eq 'true') {
            $results += New-SyncHealthResult -Name 'Git Repo' -Status 'Pass' -Message $RepoRoot
        } else {
            $results += New-SyncHealthResult -Name 'Git Repo' -Status 'Warn' `
                -Message "Not a git work tree: $RepoRoot" -Suggestion 'Run git init or pass -RepoUrl to clone'
        }
    }

    if (& $want 'ConfigFile') {
        $cfgPath = $ConfigPath
        if (-not $cfgPath) {
            $cfgPath = if ($RepoRoot) { Join-Path $RepoRoot 'gsync.config.json' } else { '' }
        }
        if ($cfgPath -and (Test-Path -LiteralPath $cfgPath -PathType Leaf)) {
            $parseOk = $true
            try { $null = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $parseOk = $false }
            if ($parseOk) {
                $results += New-SyncHealthResult -Name 'Config' -Status 'Pass' -Message $cfgPath
            } else {
                $results += New-SyncHealthResult -Name 'Config' -Status 'Fail' `
                    -Message "Unparseable JSON: $cfgPath" -Suggestion 'Restore from backup or delete to regenerate defaults'
            }
        } else {
            $results += New-SyncHealthResult -Name 'Config' -Status 'Warn' `
                -Message "Missing (regenerable): $cfgPath" -Suggestion 'AutoFix can recreate defaults'
        }
    }

    if (& $want 'StaleLock') {
        $lockPath = ''
        try {
            if ($RepoRoot -and (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
                $gitDir = (& git -C $RepoRoot rev-parse --git-dir 2>$null | Out-String).Trim()
                if ($gitDir) {
                    if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $RepoRoot $gitDir }
                    $lockPath = Join-Path $gitDir 'index.lock'
                }
            }
        } catch { $lockPath = '' }
        if ($lockPath -and (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
            $ageMin = 0
            try { $ageMin = ((Get-Date) - (Get-Item -LiteralPath $lockPath).LastWriteTime).TotalMinutes } catch { $ageMin = 0 }
            if ($ageMin -ge 30) {
                $results += New-SyncHealthResult -Name 'Stale Lock' -Status 'Fail' `
                    -Message "Stale lock ($([int]$ageMin) min): $lockPath" -Suggestion 'AutoFix can remove locks older than 30 min'
            } else {
                $results += New-SyncHealthResult -Name 'Stale Lock' -Status 'Warn' `
                    -Message "Lock present ($([int]$ageMin) min): $lockPath" -Suggestion 'Another git process may be running; retry later'
            }
        } else {
            $results += New-SyncHealthResult -Name 'Stale Lock' -Status 'Pass' -Message 'No index.lock'
        }
    }

    if (& $want 'Hooks') {
        try {
            $hookCount = 0
            if ($RepoRoot) {
                $hooksDir = Join-Path (Join-Path $RepoRoot '.git') 'hooks'
                if (Test-Path -LiteralPath $hooksDir -PathType Container) {
                    $hookCount = @(Get-ChildItem -LiteralPath $hooksDir -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -in @('pre-commit', 'pre-push', 'post-commit') }).Count
                }
            }
            if ($hookCount -gt 0) {
                $results += New-SyncHealthResult -Name 'Hooks' -Status 'Pass' -Message "$hookCount hook(s) installed"
            } else {
                $results += New-SyncHealthResult -Name 'Hooks' -Status 'Warn' `
                    -Message 'No gsync hooks installed' -Suggestion 'Run Install-GSyncHooks when hooks are desired'
            }
        } catch {
            $results += New-SyncHealthResult -Name 'Hooks' -Status 'Warn' -Message 'Hook probe failed'
        }
    }

    return $results
}

function Invoke-SyncAutoFix {
    <#
    .SYNOPSIS
        Applies SAFE auto-fixes only (regenerable state; never destructive git ops).
    .DESCRIPTION
        Fixes: stale index.lock (>=30 min old), missing config (recreate defaults
        when Get-DefaultConfig is available). Everything else is reported for
        manual action. Returns @{ Fixed = <int>; Failed = <int> }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [array]$Results = @(),
        [string]$RepoRoot = (Get-Location).Path,
        [string]$ConfigPath = ''
    )
    $fixed = 0
    $failed = 0
    foreach ($r in @($Results | Where-Object { $_.Status -eq 'Fail' })) {
        switch ($r.Name) {
            'Stale Lock' {
                try {
                    $gitDir = (& git -C $RepoRoot rev-parse --git-dir 2>$null | Out-String).Trim()
                    if ($gitDir) {
                        if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $RepoRoot $gitDir }
                        $lockPath = Join-Path $gitDir 'index.lock'
                        if ((Test-Path -LiteralPath $lockPath -PathType Leaf)) {
                            $ageMin = ((Get-Date) - (Get-Item -LiteralPath $lockPath).LastWriteTime).TotalMinutes
                            if ($ageMin -ge 30) {
                                if ($PSCmdlet.ShouldProcess($lockPath, 'Remove stale git lock')) {
                                    Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
                                }
                                $fixed++
                            }
                        }
                    }
                } catch { $failed++ }
            }
            'Config' {
                if ($r.Message -match '^Missing') {
                    $target = $ConfigPath
                    if (-not $target -and $RepoRoot) { $target = Join-Path $RepoRoot 'gsync.config.json' }
                    if ($target -and (Get-Command Get-DefaultConfig -ErrorAction SilentlyContinue)) {
                        try {
                            if ($PSCmdlet.ShouldProcess($target, 'Recreate default config')) {
                                $cfg = Get-DefaultConfig
                                $dir = Split-Path $target -Parent
                                if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
                                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                                }
                                $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $target -Encoding UTF8 -Force
                            }
                            $fixed++
                        } catch { $failed++ }
                    } else { $failed++ }
                }
            }
            default { }
        }
    }
    return [PSCustomObject]@{ Fixed = $fixed; Failed = $failed }
}

function Show-SyncHealthReport {
    [CmdletBinding()]
    param([array]$Results = @())
    $pass = @($Results | Where-Object { $_.Status -eq 'Pass' }).Count
    $warn = @($Results | Where-Object { $_.Status -eq 'Warn' }).Count
    $fail = @($Results | Where-Object { $_.Status -eq 'Fail' }).Count
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        foreach ($r in $Results) {
            $level = if ($r.Status -eq 'Pass') { 'Info' } elseif ($r.Status -eq 'Warn') { 'Warn' } else { 'Error' }
            Write-Log ((Get-LocaleMessage -Key 'gsync.msg.health.entry' -MessageArgs @([string]$r.Name, [string]$r.Status, [string]$r.Message))) -Level $level
            if ($r.Suggestion) { Write-Log ((Get-LocaleMessage -Key 'gsync.msg.health.tip' -MessageArgs @([string]$r.Suggestion))) -Level Info }
        }
        Write-Log ((Get-LocaleMessage -Key 'gsync.msg.health.summary' -MessageArgs @([string]$pass, [string]$warn, [string]$fail))) -Level Info
    } else {
        foreach ($r in $Results) { Write-Host ((Get-LocaleMessage -Key 'gsync.msg.health.entry' -MessageArgs @([string]$r.Name, [string]$r.Status, [string]$r.Message))) }
        Write-Host ("  Summary: {0} PASS | {1} WARN | {2} FAIL" -f $pass, $warn, $fail)
    }
    return ($fail -eq 0)
}

function Invoke-SyncDoctor {
    <#
    .SYNOPSIS
        Check -> report -> (opt-in) autofix -> recheck.
    #>
    [CmdletBinding()]
    param(
        [string]$RepoRoot = (Get-Location).Path,
        [string]$ConfigPath = '',
        [switch]$AutoFix
    )
    $results = @(Test-SyncHealth -RepoRoot $RepoRoot -ConfigPath $ConfigPath)
    $ok = Show-SyncHealthReport -Results $results
    if ($AutoFix -and @($results | Where-Object { $_.Status -eq 'Fail' }).Count -gt 0) {
        $fix = Invoke-SyncAutoFix -Results $results -RepoRoot $RepoRoot -ConfigPath $ConfigPath
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log ((Get-LocaleMessage -Key 'gsync.msg.health.autoFix' -MessageArgs @([string]$fix.Fixed, [string]$fix.Failed))) -Level Info
        }
        $results = @(Test-SyncHealth -RepoRoot $RepoRoot -ConfigPath $ConfigPath)
        $ok = Show-SyncHealthReport -Results $results
    }
    return $ok
}

Export-ModuleMember -Function @(
    'New-SyncHealthResult', 'Invoke-SyncSelfBootstrap', 'Import-SyncModuleOnDemand',
    'Test-SyncHealth', 'Invoke-SyncAutoFix', 'Show-SyncHealthReport', 'Invoke-SyncDoctor'
)
