# SmartCommit.Tests.ps1 - Unified test suite
#Requires -Version 5.1

# Load modules globally so Pester 5.x It blocks can see them
Import-Module (Join-Path $PSScriptRoot '../Modules/EventBus.psm1') -Force -DisableNameChecking -Scope Global
Import-Module (Join-Path $PSScriptRoot '../Modules/SecurityPlugin.psm1') -Force -DisableNameChecking -Scope Global
Import-Module (Join-Path $PSScriptRoot '../Modules/Metrics.psm1') -Force -DisableNameChecking -Scope Global

Describe "EventBus Module" {
    It "Add-BuildEvent and Send-BuildEvent work" {
        $global:testVar = "before"
        Add-BuildEvent -Name "test.event" -Handler { $global:testVar = "after" }
        Send-BuildEvent -Name "test.event" -Data $null
        $global:testVar | Should -Be "after"
    }

    It "Remove-BuildEvent clears handlers" {
        Remove-BuildEvent -Name "test.event"
        Get-SyncEventSubscribers -Name "test.event" | Should -BeNullOrEmpty
    }
}

Describe "SecurityPlugin Module" {
    It "Get-GitHubSecretPatterns returns patterns" {
        $patterns = Get-GitHubSecretPatterns
        $patterns.Count | Should -BeGreaterThan 0
    }

    It "Invoke-SecretScan detects pattern in file" {
        $temp = [IO.Path]::GetTempFileName()
        Set-Content $temp "api_key = sk-or-v1-test1234567890"
        $findings = @(Invoke-SecretScan -Files @($temp) -Patterns @("(?i)(sk-or-v1-[a-z0-9]+)"))
        $findings.Count | Should -Be 1
        Remove-Item $temp -Force
    }
}

Describe "Metrics Module" {
    It "Add-SyncMetric increments counter" {
        New-SyncMetricCounter -Name "test_counter"
        Add-SyncMetric -Name "test_counter" -Value 1
        Get-MetricCounterValue -Name "test_counter" | Should -Be 1
    }

    It "Get-MetricsAsPrometheus returns output" {
        New-SyncMetricCounter -Name "prometheus_test"
        $output = Get-MetricsAsPrometheus
        $output | Should -Not -BeNullOrEmpty
    }
}
