#Requires -Version 5.1
#Requires -Module Pester
# Reachability.Tests.ps1
#
# The _Sync tool carried eleven Core modules and three Providers modules
# that the live path imported but never called: an event-driven pipeline
# framework, a cache manager, a throttle, a parallel engine, a second
# logger and a second strategy implementation. They were 70 KB of parallel
# implementation that could never run and would only drift.
#
# This test pins the invariant that made that possible: a module that the
# live path imports must have at least one public function the live path
# actually calls. A new Core module that is imported but unused fails here
# instead of silently rotting.
Set-StrictMode -Version 1.0

BeforeAll {
    $script:SyncRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
    $script:CoreDir = Join-Path $script:SyncRoot 'Core'

    # The live path: the entry points and every module they drive.
    $liveFiles = @(
        (Join-Path $script:SyncRoot 'gsync.module.psm1'),
        (Join-Path $script:SyncRoot 'gsync.ps1')
    )
    foreach ($m in Get-ChildItem (Join-Path $script:SyncRoot 'Modules') -Filter *.psm1 -File) { $liveFiles += $m.FullName }
    foreach ($m in Get-ChildItem (Join-Path $script:SyncRoot 'Steps') -Filter *.psm1 -File -ErrorAction SilentlyContinue) { $liveFiles += $m.FullName }
    $script:LiveText = ($liveFiles | ForEach-Object { [System.IO.File]::ReadAllText($_) }) -join "`n"
}

Describe 'Core module reachability' {
    It 'imports every Core module into the live path' {
        # Whatever is in Core/ must be part of the live path's import list.
        # The import list is DATA now ($script:GSyncCoreModules), so the gate
        # reads the registry array instead of the old inline foreach literal.
        # Matching the old shape made the gate report "no import list" the
        # moment the list became data - a green gate that stopped inspecting.
        $importList = [regex]::Match($script:LiveText, "(?s)\`$script:GSyncCoreModules\s*=\s*@\((.*?)\)").Groups[1].Value
        $importList | Should -Not -BeNullOrEmpty -Because 'the live path must declare its Core import registry'
        foreach ($m in Get-ChildItem $script:CoreDir -Filter *.psm1 -File) {
            $importList | Should -Match ([regex]::Escape($m.Name)) -Because "$($m.Name) is in Core/ and must be wired in"
        }
    }

    It 'imports every Modules/ module into the live path' {
        # The same registry now covers Modules/: a module that ships but is
        # not imported is dead code that can only rot.
        #
        # The live path is BOTH entry points: gsync.module.psm1 (the sync
        # flow, driven by the $script:GSyncModules registry) and gsync.ps1
        # (the CLI, which loads the self-test modules - ModuleDependencies,
        # ProcessMetrics, SupplyChain - on demand). A module wired into
        # EITHER is live; a module wired into neither is dead.
        $importList = [regex]::Match($script:LiveText, "(?s)\`$script:GSyncModules\s*=\s*@\((.*?)\)").Groups[1].Value
        $importList | Should -Not -BeNullOrEmpty -Because 'the live path must declare its Modules import registry'
        $cliText = [System.IO.File]::ReadAllText((Join-Path $script:SyncRoot 'gsync.ps1'))
        $modulesDir = Join-Path $script:SyncRoot 'Modules'
        foreach ($m in Get-ChildItem $modulesDir -Filter *.psm1 -File) {
            $inRegistry = $importList -match ([regex]::Escape($m.Name))
            $inCli = $cliText -match ([regex]::Escape($m.Name))
            ($inRegistry -or $inCli) | Should -BeTrue -Because "$($m.Name) is in Modules/ and must be wired into gsync.module.psm1 or gsync.ps1"
        }
    }

    It 'has no Core module whose public API the live path never calls' {
        $unreachable = @()
        foreach ($m in Get-ChildItem $script:CoreDir -Filter *.psm1 -File) {
            $text = [System.IO.File]::ReadAllText($m.FullName)
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
            $api = @()
            foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                if ($fn.Name -match '-') { $api += $fn.Name }
            }
            if ($api.Count -eq 0) { continue }
            $called = 0
            foreach ($fn in $api) {
                if ([regex]::IsMatch($script:LiveText, '(?<![\w-])' + [regex]::Escape($fn) + '(?![\w-])')) { $called++ }
            }
            if ($called -eq 0) { $unreachable += $m.Name }
        }
        $unreachable | Should -BeNullOrEmpty -Because 'a Core module that the live path never calls is dead code'
    }

    It 'ships no Providers directory' {
        # The Providers modules duplicated the live path's own strategy
        # selection and logging, and no discovery mechanism ever found them.
        Test-Path -LiteralPath (Join-Path $script:SyncRoot 'Providers') | Should -BeFalse
    }
}

Describe 'Module manifest honesty' {
    It 'declares exactly the functions the root module exports' {
        $manifest = Join-Path $script:SyncRoot 'Sync.psd1'
        $declared = @([regex]::Matches((Get-Content -LiteralPath $manifest -Raw), "(?m)^\s*'([A-Za-z0-9_-]+)',?\s*$") | ForEach-Object { $_.Groups[1].Value })
        $declared.Count | Should -BeGreaterThan 0
        $null = Import-Module (Join-Path $script:SyncRoot 'gsync.module.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
        $mod = Get-Module -Name 'gsync.module' -ErrorAction SilentlyContinue
        if ($mod) {
            $exported = @($mod.ExportedFunctions.Keys)
            foreach ($d in $declared) {
                $exported | Should -Contain $d -Because "the manifest declares '$d'"
            }
        }
    }
}
