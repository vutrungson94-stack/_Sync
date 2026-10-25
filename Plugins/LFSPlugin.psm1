#Requires -Version 5.1


# The shared bootstrap makes the logger and the locale resolver available.
. (Join-Path $PSScriptRoot '../Modules/ModuleBootstrap.ps1')
$script:LfsPluginInfo = [PSCustomObject]@{
    Name    = 'LFSPlugin'
    Version = '1.1.0'
    Enabled = $true
}

function LfsPlugin-GetPluginInfo {
    return $script:LfsPluginInfo
}

function Get-PluginInfo {
    return $script:LfsPluginInfo
}

function LfsPlugin-InvokePluginValidate {
    [CmdletBinding()]
    param()

Set-StrictMode -Version 1.0
    $lfsCmd = Get-Command git-lfs -ErrorAction SilentlyContinue
    if (-not $lfsCmd) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.lfsPlugin.unavailable') -Level Warn
        return $false
    }
    Write-Log (Get-LocaleMessage -Key 'gsync.msg.lfsPlugin.available') -Level Info
    return $true
}

function LfsPlugin-InvokePluginSync {
    [CmdletBinding()]
    param([object]$Context)
    $logger = if ($Context -and $Context.Metadata -and $Context.Metadata.Logger) { $Context.Metadata.Logger } else { $null }
    if ($logger) { $logger.Debug("LFSPlugin sync: checking Git LFS") }
    
    $lfsCmd = Get-Command git-lfs -ErrorAction SilentlyContinue
    if (-not $lfsCmd) {
        if ($logger) { $logger.Debug("LFSPlugin sync: Git LFS not available") }
        return $true
    }
    
    $lfsEnv = & git lfs env 2>$null
    if ($lfsEnv) {
        if ($logger) { $logger.Debug("LFSPlugin sync: LFS enabled") }
        
        if ($logger) { $logger.Debug("LFSPlugin sync: pulling LFS files") }
        $pullResult = & git lfs pull 2>&1
        if ($LASTEXITCODE -eq 0) {
            if ($logger) { $logger.Debug("LFSPlugin sync: LFS pull completed") }
        } else {
            if ($logger) { $logger.Warn("LFSPlugin sync: LFS pull failed") }
        }
        
        $lfsCfg = if ($Context -and $Context.Config -and $Context.Config.lfs) { $Context.Config.lfs } else { $null }
        $patterns = if ($lfsCfg) { $lfsCfg.patterns } else { $null }
        if ($patterns -and $patterns.Count -gt 0) {
            if ($logger) { $logger.Debug("LFSPlugin sync: verifying tracking patterns") }
            foreach ($pattern in $patterns) {
                if ($pattern) {
                    $tracked = & git lfs track 2>&1
                    if ($tracked -match [regex]::Escape($pattern)) {
                        if ($logger) { $logger.Debug("LFSPlugin sync: pattern tracked: $pattern") }
                    } else {
                        if ($logger) { $logger.Warn("LFSPlugin sync: pattern not tracked: $pattern") }
                    }
                }
            }
        }
        
        $lfsFiles = & git lfs ls-files 2>$null
        if ($lfsFiles) {
            $fileCount = ($lfsFiles -split "`n").Count
            if ($logger) { $logger.Debug("LFSPlugin sync: $fileCount LFS file(s) in repository") }
        } else {
            if ($logger) { $logger.Debug("LFSPlugin sync: no LFS files found") }
        }
        
        $lfsStatus = & git lfs status 2>$null
        if ($lfsStatus) {
            if ($logger) { $logger.Debug("LFSPlugin sync: LFS status checked") }
        }
    } else {
        if ($logger) { $logger.Warn("LFSPlugin sync: LFS not properly configured") }
    }
    
    return $true
}

Export-ModuleMember -Function @('LfsPlugin-GetPluginInfo', 'Get-PluginInfo', 'LfsPlugin-InvokePluginValidate', 'LfsPlugin-InvokePluginSync')
