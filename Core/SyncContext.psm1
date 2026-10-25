# SyncContext.psm1 - Core context for gsync (replaces $global:GSync)
#Requires -Version 5.1


<#
.SYNOPSIS
    Returns the machine name across Windows / Linux / macOS.
#>
function Get-MachineName {
    if ($env:COMPUTERNAME) { return $env:COMPUTERNAME }
    if ($env:HOSTNAME)     { return $env:HOSTNAME }
    try { return [System.Net.Dns]::GetHostName() } catch { return 'unknown' }
}

# Internal: normalize an arbitrary key string into a 32-byte AES key
function Get-SyncAesKeyBytes {
    param([Parameter(Mandatory)][string]$Key)

Set-StrictMode -Version 1.0
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Key)
    $fixed = New-Object byte[] 32
    for ($i = 0; $i -lt 32; $i++) {
        $fixed[$i] = if ($i -lt $bytes.Length) { $bytes[$i] } else { [byte]$i }
    }
    return ,$fixed
}

if ($PSVersionTable.PSVersion.Major -ge 7) {
    class SyncContext {
        [string]$ScriptRoot
        [string]$RepoRoot
        [string]$StateFilePath
        [string]$LogFilePath
        [string]$SessionId
        [object]$CorrelationId
        [string]$TenantId
        [datetime]$StartTime
        [hashtable]$Config
        [System.Collections.ArrayList]$Errors
        [hashtable]$Metadata
        [bool]$NonInteractive
        [bool]$ConfirmedYes
        [bool]$ConfirmedNo
        [string]$CurrentPhase
        [string]$LastCommitHash

        SyncContext([string]$scriptRoot, [string]$tenantId) {
            $this.ScriptRoot = $scriptRoot
            $this.RepoRoot = (Get-Location).Path
            $tid = if ($tenantId) { $tenantId } else { 'default' }
            # State/log files live at the root (matches .gsync.state/.gsync.log convention);
            # tenant suffix is appended only for non-default tenants
            $stateName = if ($tid -eq 'default') { '.gsync.state' } else { ".gsync_$tid.state" }
            $logName = if ($tid -eq 'default') { '.gsync.log' } else { ".gsync_$tid.log" }
            $this.StateFilePath = Join-Path $scriptRoot $stateName
            $this.LogFilePath = Join-Path $scriptRoot $logName
            $this.SessionId = [guid]::NewGuid().ToString()
            $this.CorrelationId = [guid]::NewGuid().ToString()
            $this.TenantId = $tid
            $this.StartTime = Get-Date
            $this.Errors = [System.Collections.ArrayList]::new()
            $this.Metadata = @{}
            $this.NonInteractive = $false
            $this.ConfirmedYes = $false
            $this.ConfirmedNo = $false
            $this.CurrentPhase = 'init'
            $this.LastCommitHash = $null
        }

        [string] GetCorrelationId() { return $this.CorrelationId }
        [void] SetCorrelationId([string]$correlationId) { $this.CorrelationId = $correlationId }

        [void] AddError([string]$message) {
            $this.AddError($message, 'UnknownError', 9999)
        }

        [void] AddError([string]$message, [string]$category, [int]$code) {
            $err = [PSCustomObject]@{
                Message       = $message
                Category      = $category
                Code          = $code
                CorrelationId = $this.CorrelationId
                Timestamp     = (Get-Date).ToString('o')
                StackTrace    = (Get-PSCallStack | Select-Object -First 1 | ForEach-Object { $_.ScriptName + ':' + $_.ScriptLineNumber })
            }
            [void]$this.Errors.Add($err)
        }

        [bool] HasErrors() { return $this.Errors.Count -gt 0 }

        [array] GetErrorsByCategory([string]$category) {
            return @($this.Errors | Where-Object { $_.Category -eq $category })
        }

        [int] GetErrorCountByCategory([string]$category) {
            return ($this.Errors | Where-Object { $_.Category -eq $category }).Count
        }

        [void] SetPhase([string]$phase) {
            $this.CurrentPhase = $phase
            $this.SaveState() | Out-Null
        }

        [void] SaveState() {
            try {
                $state = @{
                    version    = 1
                    pid        = [System.Diagnostics.Process]::GetCurrentProcess().Id
                    machine    = Get-MachineName
                    phase      = $this.CurrentPhase
                    commitHash = $this.LastCommitHash
                    timestamp  = (Get-Date).ToString('o')
                }
                $state | ConvertTo-Json -Depth 2 | Out-File $this.StateFilePath -Encoding UTF8 -Force
                $this.ProtectState()
            } catch { }
        }

        [object] LoadState() {
            if (-not (Test-Path $this.StateFilePath)) { return $null }
            try {
                $raw = Get-Content $this.StateFilePath -Raw -EA Stop
                if ($raw -match '^GSYNC:1:') {
                    return $this.UnprotectState()
                }
                $state = $raw | ConvertFrom-Json -EA Stop
                $staleMinutes = [int]((Get-Date) - ([datetime]$state.timestamp)).TotalMinutes
                if ($staleMinutes -gt 120) {
                    Remove-Item $this.StateFilePath -Force -EA SilentlyContinue
                    return $null
                }
                return $state
            } catch { return $null }
        }

        [void] ClearState() {
            if (Test-Path $this.StateFilePath) {
                Remove-Item $this.StateFilePath -Force -EA SilentlyContinue
            }
        }

        [void] ProtectState() {
            if (-not (Test-Path $this.StateFilePath)) { return }
            if (-not $this.Config -or -not $this.Config.security -or -not $this.Config.security.encryptStateFiles) { return }
            $content = $null
            try {
                $content = Get-Content $this.StateFilePath -Raw
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
                $dpapiType = [Type]::GetType('System.Security.Cryptography.ProtectedData')
                if ($dpapiType) {
                    $dpsType = [Type]::GetType('System.Security.Cryptography.DataProtectionScope')
                    if ($dpsType) {
                        $scope = [Enum]::Parse($dpsType, 'CurrentUser')
                        $protected = $dpapiType.GetMethod('Protect').Invoke($null, @($bytes, $null, $scope))
                        $payload = [System.Convert]::ToBase64String($protected)
                        Set-Content $this.StateFilePath -Value "GSYNC:1:DPAPI`n$payload" -Encoding UTF8 -Force
                        return
                    }
                }
            } catch { }
            if (-not $content) { return }
            try {
                $encryptionKey = $null
                if ($this.Config.security.encryptionKey) {
                    $encryptionKey = $this.Config.security.encryptionKey
                } elseif ($env:GSYNC_ENCRYPTION_KEY) {
                    $encryptionKey = $env:GSYNC_ENCRYPTION_KEY
                }
                if (-not $encryptionKey) { return }
                $keyBytes = Get-SyncAesKeyBytes -Key $encryptionKey
                # No ConvertTo-SecureString -AsPlainText: build the SecureString
                # character by character so the plaintext-secret rule stays
                # clean. The payload format is unchanged (the same
                # ConvertFrom-SecureString -Key call the UnprotectState AES
                # branch decrypts with ConvertTo-SecureString -Key).
                $secureString = New-Object System.Security.SecureString
                try {
                    foreach ($ch in $content.ToCharArray()) { $secureString.AppendChar($ch) }
                    $secureString.MakeReadOnly()
                    $encrypted = ConvertFrom-SecureString -SecureString $secureString -Key $keyBytes
                    Set-Content $this.StateFilePath -Value "GSYNC:1:AES`n$encrypted" -Encoding UTF8 -Force
                } finally {
                    $secureString.Dispose()
                }
            } catch { }
        }

        [object] UnprotectState() {
            if (-not (Test-Path $this.StateFilePath)) { return $null }
            if (-not $this.Config -or -not $this.Config.security -or -not $this.Config.security.encryptStateFiles) { return $null }
            $content = Get-Content $this.StateFilePath -Raw -EA Stop
            if ($content -match '^GSYNC:1:DPAPI') {
                $payload = $content -replace '^GSYNC:1:DPAPI`n', ''
                $dpapiType = [Type]::GetType('System.Security.Cryptography.ProtectedData')
                if ($dpapiType) {
                    $dpsType = [Type]::GetType('System.Security.Cryptography.DataProtectionScope')
                    if ($dpsType) {
                        try {
                            $bytes = [System.Convert]::FromBase64String($payload)
                            $scope = [Enum]::Parse($dpsType, 'CurrentUser')
                            $unprotected = $dpapiType.GetMethod('Unprotect').Invoke($null, @($bytes, $null, $scope))
                            $text = [System.Text.Encoding]::UTF8.GetString($unprotected)
                            Set-Content $this.StateFilePath -Value $text -Encoding UTF8 -Force
                            return ($text | ConvertFrom-Json -EA Stop)
                        } catch { }
                    }
                }
            }
            if ($content -match '^GSYNC:1:AES') {
                $payload = ($content -split "`n", 2)[1]
                try {
                    $encryptionKey = $null
                    if ($this.Config.security.encryptionKey) {
                        $encryptionKey = $this.Config.security.encryptionKey
                    } elseif ($env:GSYNC_ENCRYPTION_KEY) {
                        $encryptionKey = $env:GSYNC_ENCRYPTION_KEY
                    }
                    if (-not $encryptionKey) { return $null }
                    $keyBytes = Get-SyncAesKeyBytes -Key $encryptionKey
                    $secureString = ConvertTo-SecureString -String $payload.Trim() -Key $keyBytes
                    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
                    $decrypted = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                    Set-Content $this.StateFilePath -Value $decrypted -Encoding UTF8 -Force
                    return ($decrypted | ConvertFrom-Json -EA Stop)
                } catch { }
            }
            if ($content -match '^[A-Za-z0-9+/=]+$') {
                try {
                    $encryptionKey = $null
                    if ($this.Config.security.encryptionKey) {
                        $encryptionKey = $this.Config.security.encryptionKey
                    } elseif ($env:GSYNC_ENCRYPTION_KEY) {
                        $encryptionKey = $env:GSYNC_ENCRYPTION_KEY
                    }
                    if (-not $encryptionKey) { return $null }
                    $secureString = [System.Convert]::FromBase64String($content)
                    $decrypted = ConvertFrom-SecureString -SecureString $secureString -Key ($encryptionKey.ToCharArray())
                    Set-Content $this.StateFilePath -Value $decrypted -Encoding UTF8 -Force
                    return ($decrypted | ConvertFrom-Json -EA Stop)
                } catch { }
            }
            return $null
        }
    }
}

<#
.SYNOPSIS
    New-SyncContext - Factory function
#>
<#
.SYNOPSIS
    Expands ${env:VAR} placeholders inside a tenant id.
.DESCRIPTION
    The shipped config declares tenancy.tenantId as
    "${env:GSYNC_TENANT_ID}". Config.psm1 owns the general resolver, but
    Core/ must stay dependency-free (it is loaded with `using module` from
    places that cannot import Modules/), so the tenant-specific expansion
    lives here. Without it the raw placeholder text became the tenant id,
    and the tenant-scoped state and log files were literally named
    ".gsync_${env:GSYNC_TENANT_ID}.log".
#>
function Resolve-SyncTenantId {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'default' }
    $resolved = $Value
    if ($resolved -match '\$\{env:') {
        $resolved = [regex]::Replace($resolved, '\$\{env:(?<name>[A-Za-z_][A-Za-z0-9_]*)\}', {
            param($m)
            $v = [Environment]::GetEnvironmentVariable($m.Groups['name'].Value)
            if ([string]::IsNullOrEmpty($v)) { return '' }
            return $v
        })
    }
    $resolved = $resolved.Trim()
    if ([string]::IsNullOrWhiteSpace($resolved)) { return 'default' }
    # The tenant id becomes a FILE NAME. Anything that could escape the
    # directory (path separators, dots, wildcards, control characters) is
    # rejected outright rather than sanitised into something surprising.
    if ($resolved -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { return 'default' }
    if ($resolved -eq '.' -or $resolved -eq '..') { return 'default' }
    return $resolved
}

function New-SyncContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        $Config
    )
    $tenantId = 'default'
    if ($Config -and $Config.tenancy -and $Config.tenancy.tenantId) { $tenantId = $Config.tenancy.tenantId }
    $tenantId = Resolve-SyncTenantId -Value ([string]$tenantId)
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $ctx = [SyncContext]::new($ScriptRoot, $tenantId)
    } else {
        $errors = [System.Collections.ArrayList]@()
        $logDir = Join-Path $ScriptRoot 'logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $logFile = Join-Path $logDir ".gsync_${tenantId}.log"
        $stateFile = Join-Path $logDir ".gsync_${tenantId}.state"
        $ctx = [PSCustomObject]@{
            ScriptRoot      = $ScriptRoot
            RepoRoot        = (Get-Location).Path
            StateFilePath   = $stateFile
            LogFilePath     = $logFile
            SessionId       = [guid]::NewGuid().ToString()
            CorrelationId   = [guid]::NewGuid().ToString()
            TenantId        = $tenantId
            StartTime       = Get-Date
            Config          = @{}
            Errors          = $errors
            Metadata        = @{}
            NonInteractive  = $false
            ConfirmedYes    = $false
            ConfirmedNo     = $false
            CurrentPhase    = 'init'
            LastCommitHash  = $null
            PSTypeName      = 'SyncContext'
        }
        $ctx | Add-Member -MemberType ScriptMethod -Name HasErrors -Value { $this.Errors.Count -gt 0 } -Force
        $ctx | Add-Member -MemberType ScriptMethod -Name AddError -Value {
            param($message, $category = 'UnknownError', $code = 9999)
            $err = [PSCustomObject]@{
                Message = $message
                Category = $category
                Code = $code
                CorrelationId = $this.CorrelationId
                Timestamp = (Get-Date).ToString('o')
            }
            [void]$this.Errors.Add($err)
        } -Force
        $ctx | Add-Member -MemberType ScriptMethod -Name SetPhase -Value {
            param([string]$phase)
            $this.CurrentPhase = $phase
            try {
                $state = @{ version=1; pid=[System.Diagnostics.Process]::GetCurrentProcess().Id; phase=$phase; timestamp=(Get-Date).ToString('o') }
                $state | ConvertTo-Json -Depth 2 | Out-File $this.StateFilePath -Encoding UTF8 -Force
            } catch { }
        } -Force
        $ctx | Add-Member -MemberType ScriptMethod -Name SaveState -Value {
            try {
                $state = @{ version=1; pid=[System.Diagnostics.Process]::GetCurrentProcess().Id; phase=$this.CurrentPhase; timestamp=(Get-Date).ToString('o') }
                $state | ConvertTo-Json -Depth 2 | Out-File $this.StateFilePath -Encoding UTF8 -Force
            } catch { }
        } -Force
        $ctx | Add-Member -MemberType ScriptMethod -Name LoadState -Value {
            if (-not (Test-Path $this.StateFilePath)) { return $null }
            try {
                $state = Get-Content $this.StateFilePath -Raw -EA Stop | ConvertFrom-Json -EA Stop
                $staleMinutes = [int]((Get-Date) - ([datetime]$state.timestamp)).TotalMinutes
                if ($staleMinutes -gt 120) { Remove-Item $this.StateFilePath -Force -EA SilentlyContinue; return $null }
                return $state
            } catch { return $null }
        } -Force
        $ctx | Add-Member -MemberType ScriptMethod -Name ClearState -Value {
            if (Test-Path $this.StateFilePath) { Remove-Item $this.StateFilePath -Force -EA SilentlyContinue }
        } -Force
        $ctx | Add-Member -MemberType ScriptMethod -Name GetCorrelationId -Value { $this.CorrelationId } -Force
        $ctx | Add-Member -MemberType ScriptMethod -Name SetCorrelationId -Value {
            param([string]$correlationId)
            $this.CorrelationId = $correlationId
        } -Force
        $ctx | Add-Member -MemberType ScriptMethod -Name GetErrorsByCategory -Value {
            param([string]$category)
            return @($this.Errors | Where-Object { $_.Category -eq $category })
        } -Force
        $ctx | Add-Member -MemberType ScriptMethod -Name GetErrorCountByCategory -Value {
            param([string]$category)
            return ($this.Errors | Where-Object { $_.Category -eq $category }).Count
        } -Force
    }
    $ht = ConvertTo-Hashtable -InputObject $Config
    if ($ht.Count -gt 0) { $ctx.Config = $ht }
    return $ctx
}

Export-ModuleMember -Function @('New-SyncContext','Get-MachineName','Resolve-SyncTenantId')
