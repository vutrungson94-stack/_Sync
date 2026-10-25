# ========================================================================
# ModuleBootstrap.ps1 - single reusable import bootstrap (centralized).
#
# Dot-source from any _Sync module to declare its sibling dependencies:
#
#   . (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('UI')
#
# Why this exists: every _Sync module that emits a log line calls
# Write-Log / Write-SubLog / Write-Warn / Resolve-SafeColor, and several
# call into sibling modules (Config, Security, EventBus, UI, ...). Not one
# of those modules declared the dependency - they all relied on
# gsync.module.psm1 importing every module into the global scope first.
# Importing a module on its own (the test suite does exactly that) left
# Show-LargeFiles calling a missing Write-SubLog, and the test failed with
# "The term 'Write-SubLog' is not recognized".
#
# The guards mean the normal path is untouched: when a dependency is
# already visible (the production path) nothing is loaded, so there is no
# second module instance and no split state.
# ========================================================================
param(
    [string[]]$Dependencies = @()
)

# Guard against recursive re-entry while a module is still loading.
if ($global:GSyncBootstrapInProgress) { return }
$global:GSyncBootstrapInProgress = $true
try {

# ── The logger is used by every module ────────────────────────────────────
# The probe is Write-GSyncError, NOT Write-Log. Both tools export a
# Write-Log, so checking for that name was satisfied by the OTHER tool's
# logger: _Sync's modules then called a Write-GSyncError that only exists in
# _Sync's Logging.psm1, and the call failed with "The term
# 'Write-GSyncError' is not recognized". Write-GSyncError is unique to
# _Sync, so it is the correct probe for "_Sync's logger is loaded".
if (-not (Get-Command Write-GSyncError -ErrorAction SilentlyContinue)) {
    $loggingPath = Join-Path $PSScriptRoot 'Logging.psm1'
    if (Test-Path -LiteralPath $loggingPath) {
        # -Force only on a FIRST import: a nested -Force import on PS 5.1
        # orphans an already loaded instance (see the sibling-dependency
        # branch below for the full rationale).
        $alreadyLoaded = [bool](Get-Module -Name 'Logging' -ErrorAction SilentlyContinue)
        if ($alreadyLoaded) {
            Import-Module $loggingPath -Global -DisableNameChecking -ErrorAction SilentlyContinue
        } else {
            Import-Module $loggingPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }
}

# ── The locale resolver ──────────────────────────────────────────────────
# Every module that emits a user-facing message routes it through
# Get-LocaleMessage, so the resolver has to be reachable from all of them.
if (-not (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue)) {
    $localePath = Join-Path $PSScriptRoot 'Locale.psm1'
    if (Test-Path -LiteralPath $localePath) {
        # -Force only on a FIRST import (see the rationale above).
        $alreadyLoaded = [bool](Get-Module -Name 'Locale' -ErrorAction SilentlyContinue)
        if ($alreadyLoaded) {
            Import-Module $localePath -Global -DisableNameChecking -ErrorAction SilentlyContinue
        } else {
            Import-Module $localePath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        }
    }
}

# ── Declared sibling dependencies ─────────────────────────────────────────
foreach ($dep in $Dependencies) {
    $depPath = Join-Path $PSScriptRoot ($dep + '.psm1')
    if (-not (Test-Path -LiteralPath $depPath)) { continue }

    $loaded = Get-Module -Name $dep -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($loaded) {
        # Already loaded - but is it visible from here? A module imported
        # into another module's scope exports into that scope only.
        $visible = $false
        foreach ($fn in $loaded.ExportedFunctions.Keys) {
            if (Get-Command -Name $fn -ErrorAction SilentlyContinue) { $visible = $true; break }
        }
        if ($visible) { continue }
        # LOADED BUT NOT VISIBLE. Import it WITHOUT -Force. A nested
        # `Import-Module <mod> -Force` on PowerShell 5.1 orphans the already
        # loaded instance: the new copy replaces it in this scope while the
        # global one loses its exported commands, and every other module that
        # resolved the command from the global instance suddenly gets
        # CommandNotFoundException. -Global is still required (the caller's
        # scope must see it); -Force is not.
        Import-Module $depPath -Global -DisableNameChecking -ErrorAction SilentlyContinue
        continue
    }
    # NOT LOADED AT ALL: a first import. -Force is safe here (there is no
    # instance to orphan) and it makes the import idempotent.
    Import-Module $depPath -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
}

} finally {
    $global:GSyncBootstrapInProgress = $false
}
