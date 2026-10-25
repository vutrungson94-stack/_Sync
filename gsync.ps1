#Requires -Version 5.1
#!/usr/bin/env pwsh
# ==============================================================================
# gsync.ps1 — Git Sync VIP PRO  |  Entry Point
# Supports: MAUI · Blazor · ASP.NET · Angular · React · Vue · Python · Go · Java
# Runs on: Windows · Linux · macOS  |  PowerShell 5.1+ / pwsh 7+
# ==============================================================================
# USAGE:
#   ./gsync.ps1                       – Normal run (with prompts)
#   ./gsync.ps1 -Yes                  – Auto "yes" to all prompts (CI/CD)
#   ./gsync.ps1 -No                   – Auto "no" to all prompts (dry-run)
#   ./gsync.ps1 -NonInteractive       – Use defaults for each prompt, no questions
#   ./gsync.ps1 -DryRun               – Dry run, no changes made
#   ./gsync.ps1 -ConfigPath ./my.json – Specify custom config
#   ./gsync.ps1 -RepoUrl <url>        – Clone/init repo if not exists
# ==============================================================================

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0, HelpMessage = 'Target project/repo root to sync')]
    [string]$Project = '',
    [Alias('h')][switch]$Help,
    [switch]$SelfTest,
    [switch]$NonInteractive,
    [switch]$Yes,
    [switch]$No,
    [switch]$DryRun,
    [string]$ConfigPath = (Join-Path (Get-Location) 'gsync.config.json'),
    [string]$RepoUrl    = '',
    [string]$RemoteName = '',
    [string]$Locale     = 'en'
)

Set-StrictMode -Version 1.0

# ── The locale resolver ──────────────────────────────────────────────────────────
# The early parameter validation below already speaks the operator's language,
# so the resolver is loaded before anything else. It is imported from the
# tool's own Modules folder, never from the current directory.
$localeModuleFile = Join-Path (Join-Path $PSScriptRoot 'Modules') 'Locale.psm1'
if (Test-Path -LiteralPath $localeModuleFile) {
    Import-Module $localeModuleFile -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
}

# ── Early parameter validation (before importing module) ───────────────────────────
if ($Yes -and $No) {
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.cli.yesAndNo') -ForegroundColor Red
    exit 1
}

# ── Import module ─────────────────────────────────────────────────────────────────────
$moduleFile = Join-Path $PSScriptRoot 'gsync.module.psm1'
if (-not (Test-Path $moduleFile)) {
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.cli.moduleNotFound' -MessageArgs @($moduleFile)) -ForegroundColor Red
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.cli.moduleHint') -ForegroundColor Yellow
    exit 1
}

if ($Help) {
    Write-Host @"
gsync.ps1 - Git Sync platform
Usage:
  .\gsync.ps1 [-Project <path>] [-NonInteractive] [-Yes] [-No] [-DryRun] [-ConfigPath <json>] [-RepoUrl <url>] [-RemoteName <name>] [-Help/-h/help]

Options:
  -Project <path>      target repo/project root to sync (changes working directory)
  -NonInteractive       use defaults without prompts
  -Yes                 auto-approve prompts
  -No                   auto-decline prompts
  -DryRun              simulate, no changes
  -ConfigPath <json>    custom config file
  -RepoUrl <url>       clone/init repo if missing
  -RemoteName <name>    override remote
  -Help|-h              show this help and exit
"@
    exit 0
}

# Self-heal: keep an in-memory copy of this script.
$script:GsyncSelfBytes = $null
try { $script:GsyncSelfBytes = [System.IO.File]::ReadAllBytes($PSCommandPath) } catch { }

# If a target project was supplied, run from that directory.
if ($Project) {
    if (-not (Test-Path -LiteralPath $Project -PathType Container)) {
        Write-Host (Get-LocaleMessage -Key 'gsync.msg.cli.projectNotFound' -MessageArgs @($Project)) -ForegroundColor Red
        exit 1
    }
    Set-Location -LiteralPath $Project
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.cli.targetProject' -MessageArgs @($Project)) -ForegroundColor DarkGray
}

# Ensure project .gitignore covers gsync/gbuild runtime artifacts. Patterns come
# from config (project.gitignorePatterns), never hardcoded here.
try {
    $cfgPath = $ConfigPath
    if (-not (Test-Path -LiteralPath $cfgPath -PathType Leaf)) {
        $cfgPath = Join-Path $PSScriptRoot 'gsync.config.json'
    }
    if (Test-Path -LiteralPath $cfgPath -PathType Leaf) {
        $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
        $patterns = @()
          if ($cfg -and $cfg.project -and $cfg.project.gitignorePatterns) { $patterns = @($cfg.project.gitignorePatterns) }
          # The project patterns include the platform tool folders (_Build/,
          # _Sync/, _Tests/). Writing them into a TOOL's own .gitignore makes
          # the tool ignore its own source, and the repository then commits
          # none of the code. The auto-add therefore only runs for a real
          # project directory, never for a platform tool folder or for the
          # workspace root that holds them.
          $toolFolderNames = @('_Build', '_Sync', '_Tests')
          $targetDir = (Get-Location).Path
          $resolvedTarget = $null
          try { $resolvedTarget = (Resolve-Path -LiteralPath $targetDir -ErrorAction Stop).Path } catch { }
          $targetSegments = @()
          if ($resolvedTarget) { $targetSegments = @(($resolvedTarget -replace '\\', '/') -split '/') }
          $isPlatformFolder = @($targetSegments | Where-Object { $_ -in $toolFolderNames }).Count -gt 0
          $holdsPlatformFolders = @($toolFolderNames | Where-Object { Test-Path -LiteralPath (Join-Path $targetDir $_) -PathType Container }).Count -gt 0
          if ($holdsPlatformFolders -and -not $isPlatformFolder) {
              $patterns = @($patterns | Where-Object { ([string]$_).Trim().TrimEnd('/') -notin $toolFolderNames })
          }
          if ($patterns.Count -gt 0 -and -not $isPlatformFolder) {
              $gi = Join-Path $targetDir '.gitignore'
              $existingText = ''
              if (Test-Path -LiteralPath $gi -PathType Leaf) { $existingText = [System.IO.File]::ReadAllText($gi) }
              $existing = @($existingText -split "`r?`n")
              $set = @{}
              foreach ($e in $existing) { $t = $e.Trim(); if ($t) { $set[$t] = $true } }
              $toAdd = @()
              foreach ($p in $patterns) { $pt = [string]$p; if (-not $set.ContainsKey($pt)) { $toAdd += $pt } }
              if ($toAdd.Count -gt 0) {
                  $newline = if ($existingText -match "`r`n") { "`r`n" } else { "`n" }
                  $block = @('', '# Auto-added by gsync (project gitignore patterns)') + $toAdd
                  $addition = ($block -join $newline) + $newline
                  $utf8 = New-Object System.Text.UTF8Encoding($false)
                  # AppendOnly: the existing content is never rewritten.
                  $stream = [System.IO.File]::Open($gi, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
                  try { $bytes = $utf8.GetBytes($addition); $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
              }
          }
    }
} catch { }

try {
    Import-Module $moduleFile -Force -ErrorAction Stop
} catch {
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.cli.cannotLoadModule' -MessageArgs @($($_.Exception.Message))) -ForegroundColor Red
    exit 1
}

if ($SelfTest.IsPresent) {
    $fail = 0
    $files = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Force | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') })
    foreach ($f in $files) {
        $tk = $null; $er = $null
        try { $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tk, [ref]$er) } catch { $fail++; Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.parseError' -MessageArgs @($f.Name)); continue }
        if ($er -and $er.Count -gt 0) { $fail++; Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.parseError' -MessageArgs @($f.Name)) }
    }
    if ($fail -gt 0) { Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.parseFailed' -MessageArgs @($fail)); exit 1 }
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.parseOk' -MessageArgs @($($files.Count)))
    $cfgPath = Join-Path $PSScriptRoot 'gsync.config.json'
    if (Test-Path -LiteralPath $cfgPath) {
        try { $null = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json; Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.configOk') }
        catch { Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.configFailed'); exit 1 }
    }
    $modFile = Join-Path $PSScriptRoot 'gsync.module.psm1'
    try { Import-Module $modFile -Force -ErrorAction Stop; Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.moduleOk') }
    catch { Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.moduleFailed' -MessageArgs @($($_.Exception.Message))); exit 1 }
      $depFile = Join-Path (Join-Path $PSScriptRoot 'Modules') 'ModuleDependencies.psm1'
    if (Test-Path $depFile) {
        try {
            Import-Module $depFile -ErrorAction Stop
            $verdict = Test-ModuleDependencies -ModulesRoot (Join-Path $PSScriptRoot 'Modules')
            if ($verdict.Passed) { Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.depsOk' -MessageArgs @($($verdict.ModuleCount))) }
            else { Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.depsFailed' -MessageArgs @($($verdict.Summary))); exit 1 }
        } catch { Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.depsFailedEx' -MessageArgs @($($_.Exception.Message))); exit 1 }
    }
    # Process metrics (CMMI L5) gate
    $pmFile = Join-Path (Join-Path $PSScriptRoot 'Modules') 'ProcessMetrics.psm1'
    if (Test-Path -LiteralPath $pmFile -PathType Leaf) {
        try {
            if (Get-Module -Name 'ProcessMetrics' -ErrorAction SilentlyContinue) { Import-Module $pmFile -Global -DisableNameChecking -ErrorAction Stop } else { Import-Module $pmFile -Force -Global -DisableNameChecking -ErrorAction Stop }
            $pm = Get-SyncProcessMetrics -ToolRoot $PSScriptRoot
            if (-not $pm -or @($pm.Classes).Count -lt 7) { throw (Get-LocaleMessage -Key 'gsync.msg.selftest.adoptionClasses' -MessageArgs @(7, @($pm.Classes).Count)) }
            $cmp = Compare-SyncProcessTrend -Metrics $pm -ToolRoot $PSScriptRoot
            if (-not $cmp.HasFloor) { throw (Get-LocaleMessage -Key 'gsync.msg.selftest.noAdoptionFloor') }
            if (@($cmp.Regressions).Count -gt 0) {
                foreach ($r in @($cmp.Regressions)) { Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.metricsClassFailed' -MessageArgs @($($r.Class))) -ForegroundColor Red }
                exit 1
            }
            Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.metricsOk' -MessageArgs @($($pm.ClassesAtParity), $($pm.ClassCount), $($pm.MeanAdoption), $($pm.TotalRemaining)))
        } catch { Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.metricsFailedEx' -MessageArgs @($($_.Exception.Message))) -ForegroundColor Red; exit 1 }
    }
    # Security gate (secret scan + sensitive files + dependency audit).
    $secFile = Join-Path (Join-Path $PSScriptRoot 'Modules') 'Security.psm1'
    if (Test-Path -LiteralPath $secFile -PathType Leaf) {
        try {
            if (Get-Module -Name 'Security' -ErrorAction SilentlyContinue) { Import-Module $secFile -Global -DisableNameChecking -ErrorAction Stop } else { Import-Module $secFile -Force -Global -DisableNameChecking -ErrorAction Stop }
            $sec = Invoke-SyncSecurityScan -Root $PSScriptRoot
            if (-not $sec.Passed) {
                foreach ($f in @($sec.Findings)) { Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.securityFailed' -MessageArgs @($($f.Check), $($f.File), $($f.Line), $($f.Detail))) -ForegroundColor Red }
                exit 1
            }
            $sec.Checks | ForEach-Object { Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.securityCheckOk' -MessageArgs @($($_.Check))) }
        } catch { Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.securityFailedEx' -MessageArgs @($($_.Exception.Message))) -ForegroundColor Red; exit 1 }
    }
    # Plugin registry gate (discovery + contract validation).
    $prFile = Join-Path (Join-Path $PSScriptRoot 'Modules') 'PluginRegistry.psm1'
    if (Test-Path -LiteralPath $prFile -PathType Leaf) {
        try {
            if (Get-Module -Name 'PluginRegistry' -ErrorAction SilentlyContinue) { Import-Module $prFile -Global -DisableNameChecking -ErrorAction Stop } else { Import-Module $prFile -Force -Global -DisableNameChecking -ErrorAction Stop }
            # plugins.enabledPlugins / plugins.disabledPlugins come from the config
            # so the registry has one owner for what is allowed to load.
            $enabledPlugins = @(); $disabledPlugins = @()
            $cfgFile = Join-Path $PSScriptRoot 'gsync.config.json'
            if (Test-Path -LiteralPath $cfgFile -PathType Leaf) {
                try {
                    $pcfg = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json
                    if ($pcfg -and $pcfg.plugins) {
                        if ($null -ne $pcfg.plugins.enabledPlugins) { $enabledPlugins = @($pcfg.plugins.enabledPlugins) }
                        if ($null -ne $pcfg.plugins.disabledPlugins) { $disabledPlugins = @($pcfg.plugins.disabledPlugins) }
                    }
                } catch { }
            }
            $pgate = Invoke-SyncPluginGate -Root (Join-Path $PSScriptRoot 'Plugins') -Enabled $enabledPlugins -Disabled $disabledPlugins
            if (-not $pgate.Passed) {
                foreach ($f in @($pgate.Findings)) { Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.pluginFailed' -MessageArgs @($($f.Plugin), $($f.Detail))) -ForegroundColor Red }
                exit 1
            }
            Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.pluginsOk' -MessageArgs @(@($pgate.Registered).Count, (@($pgate.Plugins) | Where-Object { $_.Contract -eq 'Prefixed' }).Count, (@($pgate.Plugins) | Where-Object { $_.Contract -eq 'Flat' }).Count))
        } catch { Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.pluginsFailedEx' -MessageArgs @($($_.Exception.Message))) -ForegroundColor Red; exit 1 }
    }
    # Metrics / OTLP contract (exposition + export payload shape).
    $mxFile = Join-Path (Join-Path $PSScriptRoot 'Modules') 'Metrics.psm1'
    if (Test-Path -LiteralPath $mxFile -PathType Leaf) {
        try {
            if (Get-Module -Name 'Metrics' -ErrorAction SilentlyContinue) { Import-Module $mxFile -Global -DisableNameChecking -ErrorAction Stop } else { Import-Module $mxFile -Force -Global -DisableNameChecking -ErrorAction Stop }
            New-SyncMetricCounter -Name 'gsync_selftest_total' -Help 'self-test counter'
            Add-SyncMetric -Name 'gsync_selftest_total' -Value 1
            # The metric NAME is the contract, not the human message. The
            # previous check passed the localized text of
            # 'gsync.msg.selftest.counterNotIncremented' to
            # Get-MetricCounterValue, so it looked up a counter called
            # "counter did not increment", found nothing, and failed the gate
            # on a metric that HAD been incremented. The gate was checking the
            # wrong thing and could never pass.
            if ((Get-MetricCounterValue -Name 'gsync_selftest_total') -lt 1) { throw (Get-LocaleMessage -Key 'gsync.msg.selftest.counterNotIncremented') }
            $prom = Get-MetricsAsPrometheus
            # The exposition must CONTAIN the counter, not the error message.
            if ($prom -notmatch 'gsync_selftest_total') { throw (Get-LocaleMessage -Key 'gsync.msg.selftest.prometheusMissing') }
            $otlp = New-SyncOtlpMetricsBody -ServiceName 'gsync'
            $otlpJson = $otlp | ConvertTo-Json -Depth 12 -Compress
            # The payload must CONTAIN the OTLP shape and the counter. The
            # previous check asserted the body did NOT contain the error
            # message - i.e. it threw precisely when the body was VALID, so
            # the gate could never pass.
            if ($otlpJson -notmatch 'scopeMetrics' -or $otlpJson -notmatch 'gsync_selftest_total') { throw (Get-LocaleMessage -Key 'gsync.msg.selftest.otlpInvalid') }
            Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.metricsOkShort')
        } catch { Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.metricsFailedShort' -MessageArgs @($($_.Exception.Message))) -ForegroundColor Red; exit 1 }
    }
    # Supply chain (SBOM + provenance + policy gate).
    $scFile = Join-Path (Join-Path $PSScriptRoot 'Modules') 'SupplyChain.psm1'
    if (Test-Path -LiteralPath $scFile -PathType Leaf) {
        try {
            if (Get-Module -Name 'SupplyChain' -ErrorAction SilentlyContinue) { Import-Module $scFile -Global -DisableNameChecking -ErrorAction Stop } else { Import-Module $scFile -Force -Global -DisableNameChecking -ErrorAction Stop }
            $sbom = New-SyncSbom -Root $PSScriptRoot -ToolName 'gsync'
            # The FORMAT is a machine contract: 'CycloneDX' / '1.5'. Comparing
            # it with the localized MESSAGE text could never succeed, so the
            # gate failed on a document that was in fact a valid CycloneDX
            # SBOM.
            if ($sbom.bomFormat -ne 'CycloneDX' -or $sbom.specVersion -ne '1.5') { throw (Get-LocaleMessage -Key 'gsync.msg.selftest.sbomNotCycloneDx') }
            $sbomJson = $sbom | ConvertTo-Json -Depth 12 -Compress
            if ($sbomJson -notmatch '"components"') { throw (Get-LocaleMessage -Key 'gsync.msg.selftest.sbomNoComponents') }
            $pgate = Invoke-SyncSbomPolicyGate -Sbom $sbom -Root $PSScriptRoot
            if (-not $pgate.Passed) {
                foreach ($v in @($pgate.Violations)) { Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.sbomDenied' -MessageArgs @($($v.Component), $($v.Version), $($v.Rule))) -ForegroundColor Red }
                exit 1
            }
            $prov = New-SyncProvenance -Root $PSScriptRoot -ToolName 'gsync'
            if (-not $prov.predicateType) { throw (Get-LocaleMessage -Key 'gsync.msg.selftest.provenanceMissing') }
            Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.sbomOk' -MessageArgs @($($sbom.specVersion), @($sbom.components).Count, $($pgate.Enforcement)))
        } catch { Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.sbomFailedEx' -MessageArgs @($($_.Exception.Message))) -ForegroundColor Red; exit 1 }
    }
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.selftest.passed')
    exit 0
}

# ── Call main function ────────────────────────────────────────────────────────────────
$params = @{
    NonInteractive = $NonInteractive
    Yes            = $Yes
    No             = $No
    DryRun         = $DryRun
    ConfigPath     = $ConfigPath
    WhatIf         = $WhatIfPreference
}
if ($RepoUrl)    { $params['RepoUrl']    = $RepoUrl }
if ($RemoteName) { $params['RemoteName'] = $RemoteName }
if ($Locale)     { $params['Locale']     = $Locale }

Start-GSync @params | Out-Null
