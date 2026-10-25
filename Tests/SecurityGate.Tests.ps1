#Requires -Version 5.1
#Requires -Module Pester
# SecurityGate.Tests.ps1 - covers the _Sync security gate, the plugin registry
# gate, the metrics/OTLP contract and the SBOM/supply-chain gate.
Set-StrictMode -Version 1.0

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$modDir = Join-Path $root 'Modules'

Import-Module (Join-Path $modDir 'Security.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $modDir 'PluginRegistry.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $modDir 'Metrics.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $modDir 'SupplyChain.psm1') -Force -Global -DisableNameChecking

# Pester 5 executes a test file in two phases. The file-level code above runs
# during discovery; the It bodies run later, in a scope that does NOT inherit
# the file's variables. A file-level $root was therefore null inside every
# test, so the plugin-gate tests failed under a plain
# "Invoke-Pester -Path ./Tests" and only passed when Run-Tests.ps1 happened
# to have a $Root of its own in an outer scope. The "passes the gate on the
# tool root" test was scanning a null root, not the tool root.
#
# A file-level BeforeAll is the Pester 5 contract for shared state: it runs
# before every test and its script-scoped variables are visible in It.
BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:modDir = Join-Path $script:root 'Modules'
}

Describe "Security gate" {
    It "exposes a non-empty secret pattern catalog" {
        @(Get-SyncSecretPatternCatalog).Count | Should -BeGreaterThan 0
    }

    It "detects a token-shaped secret in content" {
        # The fixture is assembled at run time on purpose: a literal token in
        # the test source is itself a secret-shaped string and the security
        # gate would (correctly) flag this file.
        $token = 'ghp' + '_' + ('abcdefghijklmnopqrstuvwxyz0123456789')
        Test-SyncSecretContent -Content "const k = `"$token`"" -Patterns @(Get-SyncSecretPatternCatalog) | Should -BeTrue
    }

    It "does not flag ordinary content" {
        Test-SyncSecretContent -Content 'function Get-Thing { return 42 }' -Patterns @(Get-SyncSecretPatternCatalog) | Should -BeFalse
    }

    It "does not treat a pattern definition as a secret" {
        Test-SyncPatternDefinitionLine -Line "  '(?i)(ghp_[a-z0-9]{36})'," | Should -BeTrue
        Test-SyncPatternDefinitionLine -Line '  "replacement": "password=***REDACTED***"' | Should -BeTrue
        $token = 'ghp' + '_' + ('abcdefghijklmnopqrstuvwxyz0123456789')
        Test-SyncPatternDefinitionLine -Line "  const token = `"$token`"" | Should -BeFalse
    }

    It "blocks a sensitive file listed in git status" {
        @(Test-SensitiveFiles -Status ' M  server.pem').Count | Should -Be 1
    }

    It "does not block an ordinary file listed in git status" {
        @(Test-SensitiveFiles -Status ' M  src/app.ts').Count | Should -Be 0
    }

    It "passes the gate on the tool root" {
        $gate = Invoke-SyncSecurityScan -Root $script:root
        $gate.Passed | Should -BeTrue
        @($gate.Checks).Count | Should -BeGreaterThan 0
    }
}

Describe "Plugin registry gate" {
    It "discovers the bundled plugins" {
        @(Get-AvailablePlugins -Root (Join-Path $script:root 'Plugins')).Count | Should -BeGreaterThan 0
    }

    It "accepts every bundled plugin" {
        $gate = Invoke-SyncPluginGate -Root (Join-Path $script:root 'Plugins')
        $gate.Passed | Should -BeTrue
        @($gate.Findings).Count | Should -Be 0
    }

    It "classifies the plugin contracts" {
        $gate = Invoke-SyncPluginGate -Root (Join-Path $script:root 'Plugins')
        foreach ($p in @($gate.Plugins)) {
            $p.Contract | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Metrics and OTLP" {
    It "increments a counter" {
        New-SyncMetricCounter -Name 'pester_counter' -Help 'pester'
        Add-SyncMetric -Name 'pester_counter' -Value 1
        Get-MetricCounterValue -Name 'pester_counter' | Should -BeGreaterThan 0
    }

    It "exposes the counter in the Prometheus text format" {
        New-SyncMetricCounter -Name 'pester_prom_counter' -Help 'pester'
        Get-MetricsAsPrometheus | Should -Match 'pester_prom_counter'
    }

    It "builds a valid OTLP metrics payload" {
        $body = New-SyncOtlpMetricsBody -ServiceName 'gsync'
        $json = $body | ConvertTo-Json -Depth 12 -Compress
        $json | Should -Match 'resourceMetrics'
        $json | Should -Match 'scopeMetrics'
    }

    It "reports failure when no OTLP endpoint is configured" {
        Push-MetricsOtlp -Endpoint '' | Should -BeFalse
    }
}

Describe "Supply chain / SBOM" {
    It "builds a CycloneDX 1.5 document" {
        $sbom = New-SyncSbom -Root $script:root -ToolName 'gsync'
        $sbom.bomFormat | Should -Be 'CycloneDX'
        $sbom.specVersion | Should -Be '1.5'
        $sbom.metadata.component.name | Should -Be 'gsync'
    }

    It "writes the SBOM to disk" {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("gsync-sbom-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $path = Write-SyncSbom -Root $script:root -ToolName 'gsync' -OutputPath (Join-Path $tmp 'sbom.json')
            Test-Path $path | Should -BeTrue
            $doc = Get-Content $path -Raw | ConvertFrom-Json
            $doc.bomFormat | Should -Be 'CycloneDX'
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "blocks a component on the deny-list" {
        $sbom = @{
            bomFormat   = 'CycloneDX'
            specVersion = '1.5'
            components  = @(@{ type = 'library'; name = 'lodash'; version = '4.17.0'; purl = 'pkg:npm/lodash@4.17.0' })
        }
        $gate = Invoke-SyncSbomPolicyGate -Sbom $sbom -Root $script:root -DenyList @('npm:lodash:4.17.0')
        $gate.Passed | Should -BeFalse
        @($gate.Violations).Count | Should -Be 1
    }

    It "allows a component on the allow-list" {
        $sbom = @{
            bomFormat   = 'CycloneDX'
            specVersion = '1.5'
            components  = @(@{ type = 'library'; name = 'lodash'; version = '4.17.0'; purl = 'pkg:npm/lodash@4.17.0' })
        }
        $gate = Invoke-SyncSbomPolicyGate -Sbom $sbom -Root $script:root -DenyList @('npm:lodash:4.17.0') -AllowList @('npm:lodash:4.17.0')
        $gate.Passed | Should -BeTrue
    }

    It "produces a provenance record" {
        $prov = New-SyncProvenance -Root $script:root -ToolName 'gsync'
        $prov.predicateType | Should -Not -BeNullOrEmpty
        $prov.subject[0].digest.value | Should -Not -BeNullOrEmpty
    }
}
