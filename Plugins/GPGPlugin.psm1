#Requires -Version 5.1


# The shared bootstrap makes the logger and the locale resolver available.
. (Join-Path $PSScriptRoot '../Modules/ModuleBootstrap.ps1')
$script:GpgPluginInfo = [PSCustomObject]@{
    Name    = 'GPGPlugin'
    Version = '1.1.0'
    Enabled = $true
}

function GpgPlugin-GetPluginInfo {
    return $script:GpgPluginInfo
}

function Get-PluginInfo {
    return $script:GpgPluginInfo
}

function GpgPlugin-InvokePluginValidate {
    [CmdletBinding()]
    param()

Set-StrictMode -Version 1.0
    $key = & git config --get user.signingkey 2>$null
    if ($key) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.gpgPlugin.keyConfigured' -MessageArgs @($key)) -Level Info
        return $true
    }
    Write-Log (Get-LocaleMessage -Key 'gsync.msg.gpgPlugin.noKey') -Level Warn
    return $true
}

function GpgPlugin-InvokePluginSync {
    [CmdletBinding()]
    param([object]$Context)
    $logger = if ($Context -and $Context.Metadata -and $Context.Metadata.Logger) { $Context.Metadata.Logger } else { $null }
    if ($logger) { $logger.Debug("GPGPlugin sync: checking GPG configuration") }
    
    $key = & git config --get user.signingkey 2>$null
    if ($key) {
        if ($logger) { $logger.Debug("GPGPlugin sync: signing key configured ($key)") }
        
        $gpgAvailable = Get-Command gpg -ErrorAction SilentlyContinue
        if ($gpgAvailable) {
            $keyInfo = & gpg --list-keys $key 2>$null
            if ($keyInfo) {
                if ($logger) { $logger.Debug("GPGPlugin sync: key verified in keyring") }
                
                $keyLines = $keyInfo -split "`n"
                foreach ($line in $keyLines) {
                    if ($line -match 'uid.*\[(?:ultimate|full)\].*<(.+)>') {
                        $email = $matches[1]
                        if ($logger) { $logger.Debug("GPGPlugin sync: key owner: $email") }
                    }
                }
                
                $secretKey = & gpg --list-secret-keys $key 2>$null
                if ($secretKey) {
                    if ($logger) { $logger.Debug("GPGPlugin sync: secret key available for signing") }
                } else {
                    if ($logger) { $logger.Warn("GPGPlugin sync: secret key not found - cannot sign commits") }
                }
            } else {
                if ($logger) { $logger.Warn("GPGPlugin sync: key $key not found in keyring") }
            }
        } else {
            if ($logger) { $logger.Debug("GPGPlugin sync: GPG not available - skipping key verification") }
        }
    } else {
        if ($logger) { $logger.Debug("GPGPlugin sync: no signing key configured") }
    }
    
    $commitSign = & git config --get commit.gpgsign 2>$null
    if ($commitSign -eq 'true') {
        if ($logger) { $logger.Debug("GPGPlugin sync: commit signing enabled in git config") }
    } else {
        if ($logger) { $logger.Debug("GPGPlugin sync: commit signing not enabled in git config") }
    }
    
    return $true
}

Export-ModuleMember -Function @('GpgPlugin-GetPluginInfo', 'Get-PluginInfo', 'GpgPlugin-InvokePluginValidate', 'GpgPlugin-InvokePluginSync')
