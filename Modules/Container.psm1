# Container.psm1 - Lightweight DI container for _Sync platform
#Requires -Version 5.1



# The shared bootstrap makes the logger and the locale resolver available.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1')
$script:GSyncServices = @{}
$script:GSyncServiceScopes = @{}

function Register-GSyncService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Factory,
        [ValidateSet('Singleton','Transient')][string]$Scope = 'Singleton'
    )

Set-StrictMode -Version 1.0
    $script:GSyncServices[$Name] = $Factory
    $script:GSyncServiceScopes[$Name] = $Scope
}

function Resolve-GSyncService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$ScopeState = $null,
        [object[]]$ArgumentList = @()
    )
    if (-not $script:GSyncServices.ContainsKey($Name)) {
        throw (Get-LocaleMessage -Key 'gsync.msg.container.notRegistered' -MessageArgs @($Name))
    }
    $scope = $script:GSyncServiceScopes[$Name]
    if ($scope -eq 'Singleton') {
        if ($null -eq $script:GSyncSingletonCache) { $script:GSyncSingletonCache = @{} }
        if ($script:GSyncSingletonCache.ContainsKey($Name)) {
            return $script:GSyncSingletonCache[$Name]
        }
        $instance = & $script:GSyncServices[$Name] @ArgumentList
        $script:GSyncSingletonCache[$Name] = $instance
        return $instance
    }
    return & $script:GSyncServices[$Name] @ArgumentList
}

function Test-GSyncServiceRegistered {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    return $script:GSyncServices.ContainsKey($Name)
}

function Clear-GSyncServices {
    $script:GSyncServices = @{}
    $script:GSyncServiceScopes = @{}
    $script:GSyncSingletonCache = @{}
}

Export-ModuleMember -Function @('Register-GSyncService','Resolve-GSyncService','Test-GSyncServiceRegistered','Clear-GSyncServices')
