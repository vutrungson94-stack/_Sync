#Requires -Version 5.1
# Metrics.psm1 - Prometheus exposition + OTLP export for _Sync Platform.
# Convention: no external runtime deps, PS 5.1 safe.
#
# Native to _Sync: the public surface (New-SyncMetricCounter / Add-SyncMetric /
# Get-Metric / Get-MetricCounterValue / Get-MetricsAsPrometheus /
# Start-MetricsServer / Stop-MetricsServer / Push-MetricsOtlp) is the contract
# _Sync's own tests and plugins already rely on. The OTLP exporter emits a real
# OpenTelemetry metrics JSON payload (not a Prometheus text body POSTed to an
# OTLP endpoint, which the previous stub did and collectors reject).

# Make the logger available when this module is imported on its own.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('Config')

$script:MetricsCounter = @{}
$script:MetricsHistogram = @{}
$script:MetricsGauge = @{}
$script:MetricsHelp = @{}
$script:MetricsServer = $null
$script:MetricsServerPort = 0

# ── Config ───────────────────────────────────────────────────────────────────
function Get-SyncMetricConfigValue {
    param([string]$Path, [PSCustomObject]$State, $Default = $null)

Set-StrictMode -Version 1.0
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
        try { return Get-ConfigValue -Path $Path -State $State -Default $Default } catch { }
    }
    return $Default
}

function Get-SyncTelemetryConfig {
    # Single owner for the telemetry contract. The Prometheus and OTLP
    # endpoints, ports and paths all come from one config read so a retune
    # cannot leave the exposition port and the OTLP path disagreeing.
    param([PSCustomObject]$State = $null)
    $cfg = @{
        enabled = $true
        prometheus = @{ enabled = $false; port = 9090; bindAddress = '127.0.0.1'; altPorts = @(); metricsPath = '/metrics/' }
        otel       = @{ enabled = $false; endpoint = ''; metricsPath = '/v1/metrics'; tracesPath = '/v1/traces'; jsonDepth = 10 }
    }
    $telemetry = Get-SyncMetricConfigValue -Path 'telemetry' -State $State -Default $null
    if ($null -ne $telemetry) {
        $root = Get-SyncMetricConfigValue -Path 'telemetry.enabled' -State $State -Default $null
        if ($null -ne $root) { $cfg.enabled = [bool]$root }
        $prom = Get-SyncMetricConfigValue -Path 'telemetry.prometheus' -State $State -Default $null
        if ($null -ne $prom) {
            $v = Get-SyncMetricConfigValue -Path 'telemetry.prometheus.enabled' -State $State -Default $null
            if ($null -ne $v) { $cfg.prometheus.enabled = [bool]$v }
            $v = Get-SyncMetricConfigValue -Path 'telemetry.prometheus.port' -State $State -Default $null
            if ($null -ne $v) { $cfg.prometheus.port = [int]$v }
            $v = Get-SyncMetricConfigValue -Path 'telemetry.prometheus.bindAddress' -State $State -Default $null
            if ($null -ne $v) { $cfg.prometheus.bindAddress = [string]$v }
            $v = Get-SyncMetricConfigValue -Path 'telemetry.prometheus.altPorts' -State $State -Default $null
            if ($null -ne $v) { $cfg.prometheus.altPorts = @($v) }
            $v = Get-SyncMetricConfigValue -Path 'telemetry.prometheus.metricsPath' -State $State -Default $null
            if ($null -ne $v) { $cfg.prometheus.metricsPath = [string]$v }
        }
        $otel = Get-SyncMetricConfigValue -Path 'telemetry.otel' -State $State -Default $null
        if ($null -ne $otel) {
            $v = Get-SyncMetricConfigValue -Path 'telemetry.otel.enabled' -State $State -Default $null
            if ($null -ne $v) { $cfg.otel.enabled = [bool]$v }
            $v = Get-SyncMetricConfigValue -Path 'telemetry.otel.endpoint' -State $State -Default $null
            if ($null -ne $v) { $cfg.otel.endpoint = [string]$v }
            $v = Get-SyncMetricConfigValue -Path 'telemetry.otel.metricsPath' -State $State -Default $null
            if ($null -ne $v) { $cfg.otel.metricsPath = [string]$v }
            $v = Get-SyncMetricConfigValue -Path 'telemetry.otel.tracesPath' -State $State -Default $null
            if ($null -ne $v) { $cfg.otel.tracesPath = [string]$v }
            $v = Get-SyncMetricConfigValue -Path 'telemetry.otel.jsonDepth' -State $State -Default $null
            if ($null -ne $v) { $cfg.otel.jsonDepth = [int]$v }
        }
    }
    if (-not $cfg.enabled) { $cfg.prometheus.enabled = $false; $cfg.otel.enabled = $false }
    # Environment override mirrors the config: GSYNC_PROMETHEUS / GSYNC_OTEL.
    $envProm = [Environment]::GetEnvironmentVariable('GSYNC_PROMETHEUS')
    if ($envProm) { $cfg.prometheus.enabled = ($envProm -notin @('0', 'false', 'off', 'no')) }
    $envOtel = [Environment]::GetEnvironmentVariable('GSYNC_OTEL')
    if ($envOtel) { $cfg.otel.enabled = ($envOtel -notin @('0', 'false', 'off', 'no')) }
    return $cfg
}

# ── Registry ─────────────────────────────────────────────────────────────────
function New-SyncMetricCounter {
    param([string]$Name, [string]$Help = "", [hashtable]$Labels = @{})
    if (-not $script:MetricsCounter.ContainsKey($Name)) { $script:MetricsCounter[$Name] = 0 }
    if ($Help) { $script:MetricsHelp[$Name] = $Help }
}

function New-SyncMetricHistogram {
    param([string]$Name, [string]$Help = "", [hashtable]$Labels = @{})
    if (-not $script:MetricsHistogram.ContainsKey($Name)) { $script:MetricsHistogram[$Name] = @() }
    if ($Help) { $script:MetricsHelp[$Name] = $Help }
}

function Add-SyncMetric {
    [CmdletBinding()]
    param(
        [string]$Name,
        [double]$Value = 1,
        [hashtable]$Labels = $null
    )
    if (-not $Name) { return }
    if ($script:MetricsCounter.ContainsKey($Name)) { $script:MetricsCounter[$Name] += $Value }
    if ($Labels) {
        $labelStr = ($Labels.Keys | Sort-Object | ForEach-Object { "$_=$($Labels[$_])" }) -join ','
        $obsName = "${Name}{$labelStr}"
        if (-not $script:MetricsHistogram.ContainsKey($obsName)) { $script:MetricsHistogram[$obsName] = @() }
        $script:MetricsHistogram[$obsName] += $Value
    }
}

function Get-Metric {
    [CmdletBinding()]
    param(
        [string]$Name,
        [double]$Value,
        [hashtable]$Labels = $null
    )
    if (-not $Name) { return }
    if ($script:MetricsHistogram.ContainsKey($Name)) { $script:MetricsHistogram[$Name] += $Value }
    if ($Labels) {
        $labelStr = ($Labels.Keys | Sort-Object | ForEach-Object { "$_=$($Labels[$_])" }) -join ','
        $obsName = "${Name}{$labelStr}"
        if (-not $script:MetricsHistogram.ContainsKey($obsName)) { $script:MetricsHistogram[$obsName] = @() }
        $script:MetricsHistogram[$obsName] += $Value
    }
}

function Set-MetricGauge {
    [CmdletBinding()]
    param([string]$Name, [double]$Value = 0, [hashtable]$Labels = $null)
    if (-not $Name) { return }
    $key = $Name
    if ($Labels) {
        $labelStr = ($Labels.Keys | Sort-Object | ForEach-Object { "$_=$($Labels[$_])" }) -join ','
        $key = "${Name}{$labelStr}"
    }
    $script:MetricsGauge[$key] = $Value
}

function Get-MetricCounterValue {
    param([string]$Name)
    if ($script:MetricsCounter.ContainsKey($Name)) { return $script:MetricsCounter[$Name] }
    return 0
}

function Get-MetricGaugeValue {
    param([string]$Name)
    if ($script:MetricsGauge.ContainsKey($Name)) { return $script:MetricsGauge[$Name] }
    return 0
}

function Clear-Metrics {
    $script:MetricsCounter.Clear()
    $script:MetricsHistogram.Clear()
    $script:MetricsGauge.Clear()
    $script:MetricsHelp.Clear()
}

function ConvertTo-MetricLabelString {
    param([hashtable]$Labels)
    if (-not $Labels -or $Labels.Count -eq 0) { return '' }
    return ($Labels.Keys | Sort-Object | ForEach-Object { "$_=$($Labels[$_])" }) -join ','
}

function Get-MetricsAsPrometheus {
    $output = @()
    foreach ($kvp in ($script:MetricsCounter.GetEnumerator() | Sort-Object Name)) {
        if ($script:MetricsHelp.ContainsKey($kvp.Key)) { $output += "# HELP $($kvp.Key) $($script:MetricsHelp[$kvp.Key])" }
        $output += "# TYPE $($kvp.Key) counter"
        $output += "$($kvp.Key) $($kvp.Value)"
    }
    foreach ($kvp in ($script:MetricsGauge.GetEnumerator() | Sort-Object Name)) {
        $output += "# TYPE $($kvp.Key) gauge"
        $output += "$($kvp.Key) $($kvp.Value)"
    }
    foreach ($kvp in ($script:MetricsHistogram.GetEnumerator() | Sort-Object Name)) {
        $total = ($kvp.Value | Measure-Object -Sum).Sum
        $count = $kvp.Value.Count
        if ($count -gt 0) {
            $output += "# TYPE $($kvp.Key) histogram"
            $output += "$($kvp.Key)_sum $total"
            $output += "$($kvp.Key)_count $count"
        }
    }
    return ($output -join "`n") + "`n"
}

# ── Prometheus endpoint ──────────────────────────────────────────────────────
function Start-MetricsServer {
    [CmdletBinding()]
    param([int]$Port = 0, [string]$BindAddress = '', [string]$MetricsPath = '/metrics/')
    if ($script:MetricsServer) {
        try { if ($script:MetricsServer.IsListening) { return } } catch { }
    }
    if ($Port -le 0) {
        $cfg = Get-SyncTelemetryConfig
        $Port = $cfg.prometheus.port
        if (-not $BindAddress) { $BindAddress = $cfg.prometheus.bindAddress }
    }
    if (-not $BindAddress) { $BindAddress = '127.0.0.1' }
    try {
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://${BindAddress}:${Port}$($MetricsPath)")
        $listener.Start()
        $script:MetricsServer = $listener
        $script:MetricsServerPort = $Port
    } catch { }
}

function Stop-MetricsServer {
    if ($script:MetricsServer) {
        try { $script:MetricsServer.Stop() } catch { }
        $script:MetricsServer = $null
        $script:MetricsServerPort = 0
    }
}

function Get-MetricsServerPort {
    return $script:MetricsServerPort
}

# ── OTLP export ──────────────────────────────────────────────────────────────
function ConvertTo-OtlpNumber {
    param($Value)
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [string]$Value
    }
    return [string]$Value
}

function New-SyncOtlpMetricsBody {
    <#
    .SYNOPSIS
        Builds an OpenTelemetry metrics export payload (OTLP/HTTP JSON).
    .DESCRIPTION
        OTLP JSON uses resourceMetrics[].scopeMetrics[].metrics[] with a
        data oneof. The previous _Sync stub POSTed a Prometheus text body to
        the OTLP endpoint; collectors reject that shape, so the payload is
        built here from the same registry that feeds the Prometheus text.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$ServiceName = 'gsync',
        [string]$ServiceVersion = '',
        [string]$ScopeName = 'gsync.platform',
        [long]$TimestampUnixNano = 0
    )
    if ($TimestampUnixNano -le 0) {
        $TimestampUnixNano = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000000
    }
    $metrics = @()
    foreach ($kvp in ($script:MetricsCounter.GetEnumerator() | Sort-Object Name)) {
        $metrics += @{
            name = $kvp.Key
            help = if ($script:MetricsHelp.ContainsKey($kvp.Key)) { $script:MetricsHelp[$kvp.Key] } else { '' }
            unit = ''
            sum  = @{ aggregationTemporality = 2; isMonotonic = $true; dataPoints = @(@{ asInt = [string][long]$kvp.Value; timeUnixNano = [string]$TimestampUnixNano }) }
        }
    }
    foreach ($kvp in ($script:MetricsGauge.GetEnumerator() | Sort-Object Name)) {
        $metrics += @{
            name = $kvp.Key
            help = ''
            unit = ''
            gauge = @{ dataPoints = @(@{ asDouble = (ConvertTo-OtlpNumber $kvp.Value); timeUnixNano = [string]$TimestampUnixNano }) }
        }
    }
    foreach ($kvp in ($script:MetricsHistogram.GetEnumerator() | Sort-Object Name)) {
        $count = $kvp.Value.Count
        if ($count -le 0) { continue }
        $total = ($kvp.Value | Measure-Object -Sum).Sum
        $metrics += @{
            name = $kvp.Key
            help = ''
            unit = ''
            histogram = @{ aggregationTemporality = 2; dataPoints = @(@{ count = [string][long]$count; sum = (ConvertTo-OtlpNumber $total); timeUnixNano = [string]$TimestampUnixNano }) }
        }
    }
    $resource = @{
        attributes = @(@{ key = 'service.name'; value = @{ stringValue = $ServiceName } })
    }
    if ($ServiceVersion) {
        $resource.attributes += @(@{ key = 'service.version'; value = @{ stringValue = $ServiceVersion } })
    }
    return @{
        resourceMetrics = @(@{
            resource = @{ attributes = $resource.attributes }
            scopeMetrics = @(@{
                scope = @{ name = $ScopeName }
                metrics = $metrics
            })
        })
    }
}

function Push-MetricsOtlp {
    <#
    .SYNOPSIS
        Exports the current registry to an OTLP/HTTP JSON endpoint.
    .DESCRIPTION
        Failure to reach the collector is non-fatal: a telemetry outage must
        never fail a sync. The function reports success/failure so callers
        that care (CI, self-test) can assert on it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$Endpoint = '',
        [string]$ServiceName = 'gsync',
        [int]$TimeoutSec = 10
    )
    if (-not $Endpoint) {
        $cfg = Get-SyncTelemetryConfig
        $Endpoint = $cfg.otel.endpoint
        if ($Endpoint -and -not $Endpoint.EndsWith('/')) { $Endpoint = "$Endpoint$($cfg.otel.metricsPath)" }
    }
    if (-not $Endpoint) { return $false }
    $body = New-SyncOtlpMetricsBody -ServiceName $ServiceName
    $json = $body | ConvertTo-Json -Depth 12 -Compress
    try {
        Invoke-RestMethod -Uri $Endpoint -Method Post -Body $json -ContentType 'application/json' -TimeoutSec $TimeoutSec -ErrorAction Stop | Out-Null
        return $true
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.metrics.otlpFailed' -MessageArgs @($($_.Exception.Message))) -Level Warn
        }
        return $false
    }
}

function Submit-SyncMetric {
    [CmdletBinding()]
    param(
        [string]$Name,
        [double]$Value = 1,
        [hashtable]$Labels = $null,
        [ValidateSet('counter', 'gauge', 'histogram')][string]$Type = 'counter'
    )
    switch ($Type) {
        'counter'   { Add-SyncMetric -Name $Name -Value $Value -Labels $Labels }
        'gauge'     { Set-MetricGauge -Name $Name -Value $Value -Labels $Labels }
        'histogram' { Get-Metric -Name $Name -Value $Value -Labels $Labels }
    }
}

Export-ModuleMember -Function @(
    'New-SyncMetricCounter', 'New-SyncMetricHistogram', 'Add-SyncMetric', 'Get-Metric',
    'Set-MetricGauge', 'Get-MetricCounterValue', 'Get-MetricGaugeValue', 'Clear-Metrics',
    'Get-MetricsAsPrometheus', 'Start-MetricsServer', 'Stop-MetricsServer', 'Get-MetricsServerPort',
    'New-SyncOtlpMetricsBody', 'Push-MetricsOtlp', 'Get-SyncTelemetryConfig', 'Submit-SyncMetric'
)
