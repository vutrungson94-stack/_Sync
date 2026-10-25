#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Load core cross-cutting modules
Import-Module (Join-Path $root 'Modules/PluginRegistry.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'Modules/SmartGitignore.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'Modules/PathNormalization.psm1') -Force -DisableNameChecking

# Keyboard test: plugin registry
Register-Plugins -Root (Join-Path $root 'Plugins') | Out-Null
$plugs = Get-RegisteredPlugins
Write-Host ("PluginRegistry: {0} plugins loaded" -f $plugs.Count)
foreach ($p in $plugs) { Write-Host ("  - {0} ({1} funcs)" -f $p.Name, $p.Exported.Count) }

# Keyboard test: smart gitignore
$proj = Get-DetectedProjectType -Root $root
$rules = Get-SmartGitignoreRules -ProjectType $proj
Write-Host ("SmartGitignore: projectType={0}, rules={1}" -f $proj, $rules.Count)

# Keyboard test: path normalization
$p = Join-RepoPath -Paths @('src', 'app', 'file.cs')
Write-Host ("Join-RepoPath: {0}" -f $p)
