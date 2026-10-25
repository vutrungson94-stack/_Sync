#Requires -Version 5.1
# Modules/DependencyChecker.psm1 - dependency pre-flight for the live path.
#
# This module used to expose exactly one function, Test-Dependency, whose
# only caller was the OLD class-based pipeline. It took a $Context object
# with $Context.Metadata['Logger'] exposing Header/Debug/Warn/Info methods,
# and it returned a list of [DependencyResult] CLASS instances. The live
# path builds no such context and never called it, so the module shipped as
# dead code: 130 lines of a capability that could never run.
#
# It is now the live path's dependency gate. The contract is the same shape
# the rest of _Sync uses (plain objects, function-based, PS 5.1 safe) and the
# live path calls it before touching the repository.
#
# No class: the module previously declared `class DependencyResult`, which
# forces the whole file to be parsed as class-capable code and makes the
# result set unusable from a function-only caller. The record is a plain
# PSCustomObject now.

Set-StrictMode -Version 1.0

function Get-GSyncCommandVersion {
    <#
    .SYNOPSIS
        Returns the version reported by a command, or $null when absent.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([string]$Command, [string]$Arg = '--version')
    try {
        $result = & $Command $Arg 2>&1
        if ($LASTEXITCODE -eq 0) {
            if ($result -match '(\d+\.\d+(\.\d+)?)') { return [version]$matches[1] }
            return $result
        }
    } catch { }
    return $null
}

function Get-GSyncDependencyReport {
    <#
    .SYNOPSIS
        Checks the external tools a sync depends on and reports the result.
    .DESCRIPTION
        Every record carries Name, Required, Passed, Message and Category:
          - Required = $true  -> the sync cannot run without it
          - Required = $false -> optional (GPG, Git LFS), reported only
        The caller decides what to do with a failed required dependency; this
        function never throws and never mutates anything.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [object]$Config = $null,
        [string]$WorkingDir = ''
    )
    $results = [System.Collections.ArrayList]::new()
    $add = {
        param([string]$Name, [bool]$Required, [bool]$Passed, [string]$Message, [string]$Category = 'General')
        [void]$results.Add([PSCustomObject]@{
            Name     = $Name
            Required = $Required
            Passed   = $Passed
            Message  = $Message
            Category = $Category
        })
    }

    # -- Git (required) --
    $minVer = [version]'2.20.0'
    if ($Config -and $Config.git -and $Config.git.minVersion) {
        try { $minVer = [version]$Config.git.minVersion } catch { $minVer = [version]'2.20.0' }
    }
    $gitVersion = Get-GSyncCommandVersion -Command 'git'
    if ($gitVersion -is [version]) {
        & $add 'Git' $true ($gitVersion -ge $minVer) ("v$($gitVersion.ToString()) (required >= v$($minVer.ToString()))") 'Runtime'
    } elseif ($gitVersion) {
        & $add 'Git' $true $true ([string]$gitVersion) 'Runtime'
    } else {
        & $add 'Git' $true $false 'Not found - install git from https://git-scm.com' 'Runtime'
    }

    # -- SSH (required for remote operations) --
    $sshOk = $false
    $sshDetail = 'Not found - SSH client required for remote operations'
    try {
        $null = Get-Command ssh -ErrorAction Stop
        $sshOut = & ssh -V 2>&1
        $sshOk = ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1)
        if ($sshOk) { $sshDetail = if ($sshOut -match 'OpenSSH') { $matches[0] } else { 'Found' } }
    } catch { }
    & $add 'SSH' $true $sshOk $sshDetail 'Runtime'

    # -- GPG (optional: commit signing) --
    $gpgCmd = Get-Command gpg -ErrorAction SilentlyContinue
    if ($gpgCmd) {
        $gpgVer = Get-GSyncCommandVersion -Command 'gpg'
        & $add 'GPG' $false $true $(if ($gpgVer -is [version]) { "v$($gpgVer.ToString())" } else { 'Found' }) 'Optional'
    } else {
        & $add 'GPG' $false $true 'Not installed (optional - skip commit signing)' 'Optional'
    }

    # -- Git LFS (optional) --
    $lfsCmd = Get-Command git-lfs -ErrorAction SilentlyContinue
    if ($lfsCmd) {
        $lfsVer = Get-GSyncCommandVersion -Command 'git-lfs'
        & $add 'Git LFS' $false $true $(if ($lfsVer -is [version]) { "v$($lfsVer.ToString())" } else { 'Found' }) 'Optional'
    } else {
        & $add 'Git LFS' $false $true 'Not installed (optional)' 'Optional'
    }

    # -- Environment --
    $sshKeyPath = $env:GSYNC_SSH_KEY_PATH
    if ($sshKeyPath) {
        $keyExists = Test-Path $sshKeyPath
        & $add 'GSYNC_SSH_KEY_PATH' $false $keyExists $(if ($keyExists) { "Resolved: $sshKeyPath" } else { "Path not found: $sshKeyPath" }) 'Configuration'
    }

    $gitSslVerify = & git config --global http.sslVerify 2>$null
    if ($gitSslVerify -eq 'false') {
        & $add 'SSL Verify' $false $false 'DISABLED (http.sslVerify=false) - security risk' 'Security'
    }

    return @($results.ToArray())
}

function Test-GSyncDependency {
    <#
    .SYNOPSIS
        Returns $true when every REQUIRED dependency is present.
    .DESCRIPTION
        The live-path gate. Optional dependencies never fail the check; a
        missing required dependency does. The report is returned so the caller
        can log it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [object]$Config = $null,
        [string]$WorkingDir = ''
    )
    $report = @(Get-GSyncDependencyReport -Config $Config -WorkingDir $WorkingDir)
    $blocked = @($report | Where-Object { $_.Required -and -not $_.Passed })
    return ($blocked.Count -eq 0)
}

Export-ModuleMember -Function @('Get-GSyncDependencyReport','Test-GSyncDependency','Get-GSyncCommandVersion')
