#Requires -Version 5.1


# The shared bootstrap makes the logger and the locale resolver available.
. (Join-Path $PSScriptRoot '../Modules/ModuleBootstrap.ps1')
$script:GitPluginInfo = [PSCustomObject]@{
    Name    = 'GitPlugin'
    Version = '1.1.0'
    Enabled = $true
}

function GitPlugin-GetPluginInfo {
    return $script:GitPluginInfo
}

function Get-PluginInfo {
    return $script:GitPluginInfo
}

function GitPlugin-InvokePluginValidate {
    [CmdletBinding()]
    param()

Set-StrictMode -Version 1.0
    $gitDir = & git rev-parse --git-dir 2>$null
    if (-not $gitDir) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.gitPlugin.notARepo') -Level Warn
        return $false
    }
    $head = & git symbolic-ref --short HEAD 2>$null
    if (-not $head) {
        $detached = & git rev-parse HEAD 2>$null
        if ($detached) {
            Write-Log (Get-LocaleMessage -Key 'gsync.msg.gitPlugin.detachedHead' -MessageArgs @($detached)) -Level Warn
        }
    }
    $status = @(& git status --porcelain 2>$null)
    Write-Log (Get-LocaleMessage -Key 'gsync.msg.gitPlugin.uncommitted' -MessageArgs @($($status.Count))) -Level Info
    return $true
}

function GitPlugin-InvokePluginSync {
    [CmdletBinding()]
    param([object]$Context)
    $logger = if ($Context -and $Context.Metadata -and $Context.Metadata.Logger) { $Context.Metadata.Logger } else { $null }
    if ($logger) { $logger.Debug("GitPlugin sync: verifying git state") }
    
    $gitDir = & git rev-parse --git-dir 2>$null
    if (-not $gitDir) {
        if ($logger) { $logger.Warn("GitPlugin sync: not in a git repository") }
        return $true
    }
    
    $status = @(& git status --porcelain 2>$null)
    if ($logger) { $logger.Info("GitPlugin sync: $($status.Count) uncommitted change(s)") }
    
    $remoteName = if ($Context -and $Context.Config -and $Context.Config.git -and $Context.Config.git.remoteName) { $Context.Config.git.remoteName } else { 'origin' }
    $remoteUrl = & git remote get-url $remoteName 2>$null
    if ($remoteUrl) {
        if ($logger) { $logger.Debug("GitPlugin sync: remote '$remoteName' verified ($remoteUrl)") }
    } else {
        if ($logger) { $logger.Warn("GitPlugin sync: remote '$remoteName' not found") }
    }
    
    $gitDirSize = 0
    if ($gitDir) {
        $gitDirSize = (Get-ChildItem -Path $gitDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
    }
    if ($gitDirSize -gt 100) {
        if ($logger) { $logger.Debug("GitPlugin sync: .git size is $($gitDirSize.ToString('0.00'))MB - consider garbage collection") }
    }
    
    return $true
}

Export-ModuleMember -Function @('GitPlugin-GetPluginInfo', 'Get-PluginInfo', 'GitPlugin-InvokePluginValidate', 'GitPlugin-InvokePluginSync')
