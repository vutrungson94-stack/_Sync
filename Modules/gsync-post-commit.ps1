#Requires -Version 5.1
param($Config)

# The shared bootstrap makes the logger and the locale resolver available.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1')
Set-StrictMode -Version 1.0

# Post-commit hook: notifications after successful commit
Write-Debug (Get-LocaleMessage -Key 'gsync.msg.hook.postCommitStarted')

$commitHash = & git rev-parse --short HEAD 2>$null
$branch = & git rev-parse --abbrev-ref HEAD 2>$null

Write-Host (Get-LocaleMessage -Key 'gsync.msg.hook.postCommitRef' -MessageArgs @($branch, $commitHash)) -ForegroundColor DarkGray

# Webhook notification if configured (canonical transport; webhook.* config kept)
$whCfg = $Config.webhook
if ($whCfg -and $whCfg.url) {
    if (-not (Get-Command Invoke-SyncHttpPost -ErrorAction SilentlyContinue)) {
        $alertingPath = Join-Path $PSScriptRoot 'Alerting.psm1'
        if (Test-Path $alertingPath) { Import-Module $alertingPath -Force -DisableNameChecking -Scope Global -ErrorAction SilentlyContinue }
    }
    $body = @{
        event  = 'post-commit'
        branch = $branch
        commit = $commitHash
        repo   = (Split-Path (Get-Location) -Leaf)
    } | ConvertTo-Json -Depth 3
    if (Get-Command Invoke-SyncHttpPost -ErrorAction SilentlyContinue) {
        [void](Invoke-SyncHttpPost -Uri $whCfg.url -Body $body)
    } else {
        try { Invoke-RestMethod -Uri $whCfg.url -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null } catch { }
    }
}

return $true
