#Requires -Version 5.1
param([string]$ConfigPath, [switch]$DryRun, [switch]$Force, [switch]$Sequential)

# The locale resolver: the tool speaks the operator's language.
# This script lives in Steps/, so the tool's Modules folder is one level up.
$localeModuleFile = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules') 'Locale.psm1'
if (Test-Path -LiteralPath $localeModuleFile) {
    Import-Module $localeModuleFile -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
}
Set-StrictMode -Version 1.0

# Self-healing bootstrap (standalone-safe). Single owner: Modules/SelfHeal.psm1.
# When run directly (not via gsync.module), heals missing base modules on demand.
$__syncStepBootstrap = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/SelfHeal.psm1'
if (Test-Path -LiteralPath $__syncStepBootstrap -PathType Leaf) {
    Import-Module $__syncStepBootstrap -Force -Scope Global -DisableNameChecking -ErrorAction SilentlyContinue
    if (Get-Command Invoke-SyncSelfBootstrap -ErrorAction SilentlyContinue) {
        Invoke-SyncSelfBootstrap -Sentinels @('Write-Log', 'Get-DefaultConfig', 'Send-BuildEvent') -Modules @()
    }
}
Remove-Variable -Name __syncStepBootstrap -ErrorAction SilentlyContinue

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "../../.gsync-multi.json" }
if (-not (Test-Path $ConfigPath)) { Write-Host (Get-LocaleMessage -Key 'gsync.msg.multiRepo.configNotFound' -MessageArgs @($ConfigPath)) -ForegroundColor Red; exit 1 }

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $config.repos) { Write-Host (Get-LocaleMessage -Key 'gsync.msg.multiRepo.noRepos') -ForegroundColor Red; exit 1 }

# Build argument string for gsync.ps1
$gsyncArgs = @()
if ($DryRun) { $gsyncArgs += '-DryRun' }
if ($Force)   { $gsyncArgs += '-Yes' }

# Determine parallel vs sequential
$useParallel = -not $Sequential -and $config.sync -and $config.sync.enableParallelSync -eq $true
$maxParallel = if ($config.sync -and $config.sync.maxParallelRepos) { [int]$config.sync.maxParallelRepos } else { 4 }

# Filter valid repos
$validRepos = @()
foreach ($repo in $config.repos) {
    $repoPath = $repo.path
    if (-not $repoPath) { Write-Warning (Get-LocaleMessage -Key 'gsync.msg.multiRepo.skipNoPath'); continue }
    if (-not (Test-Path $repoPath)) { Write-Warning (Get-LocaleMessage -Key 'gsync.msg.multiRepo.pathNotFound' -MessageArgs @($repoPath)); continue }
    $gsyncScript = $null
    foreach ($candidate in @((Join-Path $repoPath 'gsync.ps1'), (Join-Path (Join-Path $repoPath '_Sync') 'gsync.ps1'))) {
        if (Test-Path -LiteralPath $candidate) { $gsyncScript = $candidate; break }
    }
    if (-not $gsyncScript) {
        Write-Host (Get-LocaleMessage -Key 'gsync.msg.multiRepo.noGsync' -MessageArgs @($repoPath)) -ForegroundColor DarkGray
        continue
    }
    $validRepos += @{
        Name = Split-Path $repoPath -Leaf
        Path = $repoPath
        Script = $gsyncScript
    }
}

if ($validRepos.Count -eq 0) {
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.multiRepo.noValidRepos') -ForegroundColor Yellow
    exit 0
}

# --- Sequential sync (fallback or explicit) ---
if (-not $useParallel -or $validRepos.Count -eq 1) {
    foreach ($repo in $validRepos) {
        Write-Host (Get-LocaleMessage -Key 'gsync.msg.multiRepo.processing' -MessageArgs @($($repo.Name))) -ForegroundColor Cyan
        & $repo.Script @gsyncArgs
    }
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.multiRepo.sequentialComplete' -MessageArgs @($($validRepos.Count))) -ForegroundColor Green
    exit 0
}

# --- Parallel sync via RunspacePool (PS 5.1 compatible) ---
Write-Host (Get-LocaleMessage -Key 'gsync.msg.multiRepo.parallelStart' -MessageArgs @($($validRepos.Count), $maxParallel)) -ForegroundColor Cyan

$runspacePool = [RunspaceFactory]::CreateRunspacePool(1, $maxParallel)
$runspacePool.Open()

$jobs = @()
foreach ($repo in $validRepos) {
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $runspacePool
    $script = $repo.Script
    $argList = $gsyncArgs
    $ps.AddScript({
        param($Script, $Args)
        & $Script @Args
    }).AddArgument($script).AddArgument($argList) | Out-Null
    $jobs += [PSCustomObject]@{
        Name = $repo.Name
        PowerShell = $ps
        Handle = $ps.BeginInvoke()
    }
}

$failed = @()
foreach ($job in $jobs) {
    try {
        $result = $job.PowerShell.EndInvoke($job.Handle)
    } catch {
        $failed += $job.Name
        Write-Host (Get-LocaleMessage -Key 'gsync.msg.multiRepo.jobFailed' -MessageArgs @($($job.Name), $_)) -ForegroundColor Red
    }
    if ($job.PowerShell.Streams.Error.Count -gt 0) {
        $failed += $job.Name
        foreach ($err in $job.PowerShell.Streams.Error) {
            Write-Host (Get-LocaleMessage -Key 'gsync.msg.multiRepo.jobError' -MessageArgs @($($job.Name), $($err.Exception.Message))) -ForegroundColor Red
        }
    }
    $job.PowerShell.Dispose()
}

$runspacePool.Close()
$runspacePool.Dispose()

if ($failed.Count -gt 0) {
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.multiRepo.parallelFailed' -MessageArgs @($($failed.Count), $($failed -join ', '))) -ForegroundColor Yellow
    exit 1
} else {
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.multiRepo.parallelComplete' -MessageArgs @($($validRepos.Count))) -ForegroundColor Green
}
