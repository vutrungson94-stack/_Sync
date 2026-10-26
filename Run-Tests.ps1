#Requires -Version 5.1

<#
.SYNOPSIS
    Run-Tests.ps1 — Full Pester batch runner for _Sync platform.
#>
param(
    [string]$TestPath = (Join-Path $PSScriptRoot 'Tests'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'TestResults'),
    [string]$LogLevel = 'Info'
)

# The locale resolver: the tool speaks the operator's language.
$localeModuleFile = Join-Path (Join-Path $PSScriptRoot 'Modules') 'Locale.psm1'
if (Test-Path -LiteralPath $localeModuleFile) {
    Import-Module $localeModuleFile -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
}

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0

$Root = $PSScriptRoot

function Clear-TestArtifacts {
    param([string]$Root)
    $patterns = @('coverage.xml', 'results-junit.xml', 'gsync_tests_*.json', '*.test.log', '*.run.log')
    foreach ($pat in $patterns) {
        Get-ChildItem -LiteralPath $Root -Filter $pat -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'process-baseline.json' -and $_.Name -ne 'gtest.config.json' } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    $tr = Join-Path $Root 'TestResults'
    if (Test-Path -LiteralPath $tr -PathType Container) {
        Get-ChildItem -LiteralPath $tr -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}
Clear-TestArtifacts -Root $Root
Clear-TestArtifacts -Root (Split-Path $Root -Parent)

$corePath = Join-Path $Root 'Core'
$modulesPath = Join-Path $Root 'Modules'

$coreModules = @(
    'SyncTypes.psm1',
    'SyncContext.psm1',
    'SyncEventManager.psm1',
    'SyncRollback.psm1'
)

foreach ($mod in $coreModules) {
    $path = Join-Path $corePath $mod
    if (Test-Path $path) {
        Import-Module $path -Force -DisableNameChecking -Scope Global -ErrorAction SilentlyContinue
    }
}

$syncTypes = Join-Path $corePath 'SyncTypes.psm1'
if (Test-Path $syncTypes) {
    $st = Import-Module $syncTypes -Force -PassThru -DisableNameChecking -ErrorAction SilentlyContinue
    if ($st) {
        $constants = $st.SessionState.PSVariable.Get('SyncConstants')
        if ($constants) {
            $global:SyncConstants = $constants.Value
        }
        $errorCats = $st.SessionState.PSVariable.Get('SyncErrorCategories')
        if ($errorCats) {
            $global:SyncErrorCategories = $errorCats.Value
        }
    }
}

$mocksPath = Join-Path $Root 'Tests/Mocks.ps1'
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

if (-not (Get-Module Pester -ListAvailable)) {
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.test.pesterMissing') -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $TestPath)) {
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.test.pathNotFound' -MessageArgs @($TestPath)) -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$xmlPath = Join-Path $OutputPath "gsync_tests_${timestamp}.xml"
$jsonPath = Join-Path $OutputPath "gsync_tests_${timestamp}.json"

$testFiles = Get-ChildItem -Path $TestPath -Filter '*.Tests.ps1' | Sort-Object FullName
if ($testFiles.Count -eq 0) {
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.test.noTestFiles' -MessageArgs @($TestPath)) -ForegroundColor Yellow
    exit 0
}

Write-Host (Get-LocaleMessage -Key 'gsync.msg.test.running' -MessageArgs @($($testFiles.Count))) -ForegroundColor Cyan
Write-Host (Get-LocaleMessage -Key 'gsync.msg.test.paths' -MessageArgs @($($testFiles.FullName -join ', '))) -ForegroundColor DarkGray

$testPaths = $testFiles.FullName

Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop

$cfg = [PesterConfiguration]::Default
$cfg.Run.Path        = $testPaths
$cfg.Run.PassThru    = $true
$cfg.Run.Exit        = $false
$cfg.Output.Verbosity = 'Normal'

$result = Invoke-Pester -Configuration $cfg

$passCount = $result.PassedCount
$failCount = $result.FailedCount
$skipCount = $result.SkippedCount

$total = $passCount + $failCount + $skipCount
$summary = [PSCustomObject]@{
    Timestamp        = (Get-Date).ToString('o')
    TotalFiles       = $testFiles.Count
    TotalTests       = $total
    Passed           = $passCount
    Failed           = $failCount
    Skipped          = $skipCount
    PassRatePercent  = if ($total -gt 0) { [math]::Round(($passCount / $total) * 100, 1) } else { 0 }
}

$summary | ConvertTo-Json -Depth 5 | Out-File $jsonPath -Encoding UTF8
Write-Host (Get-LocaleMessage -Key 'gsync.msg.test.resultsSaved') -ForegroundColor Cyan
Write-Host (Get-LocaleMessage -Key 'gsync.msg.test.jsonPath' -MessageArgs @($jsonPath))
Write-Host (Get-LocaleMessage -Key 'gsync.msg.test.summary' -MessageArgs @($passCount, $failCount, $skipCount, $($summary.PassRatePercent))) -ForegroundColor $(if($failCount -gt 0){'Red'}else{'Green'})

Write-Host (Get-LocaleMessage -Key 'gsync.msg.test.done') -ForegroundColor Cyan
exit $(if ($failCount -gt 0) { 1 } else { 0 })
