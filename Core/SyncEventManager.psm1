#Requires -Version 5.1


# SyncEventManager.psm1 - Event-driven architecture for gsync

# Hook type constants

# The shared bootstrap makes the logger and the locale resolver available.
. (Join-Path $PSScriptRoot '../Modules/ModuleBootstrap.ps1')
$script:SyncHookTypes = @{
    PreSync = 'PreSync'
    OnError = 'OnError'
    OnRetry = 'OnRetry'
    PostSync = 'PostSync'
    PreStep = 'PreStep'
    PostStep = 'PostStep'
}

# Standard event names
$script:SyncEventNames = @{
    SyncStart           = 'gsync.sync.start'
    SyncComplete        = 'gsync.sync.complete'
    SyncFailed          = 'gsync.sync.failed'
    StepStart           = 'gsync.step.start'
    StepComplete        = 'gsync.step.complete'
    FetchStart          = 'gsync.fetch.start'
    FetchComplete       = 'gsync.fetch.complete'
    PushStart           = 'gsync.push.start'
    PushComplete        = 'gsync.push.complete'
    CommitCreated       = 'gsync.commit.created'
    SecurityBlocked     = 'gsync.security.blocked'
    SecurityScanClean   = 'gsync.security.scan.clean'
    CleanupDone         = 'gsync.cleanup.done'
    SmartGitignoreApplied = 'gsync.gitignore.applied'
    PluginLoaded        = 'gsync.plugin.loaded'
}

if ($PSVersionTable.PSVersion.Major -ge 7) {
    class SyncEventManager {
        [string]$LogPath
        [hashtable]$Subscribers = @{}
        [System.Collections.ArrayList]$Errors = [System.Collections.ArrayList]::new()

        SyncEventManager() {
            $currentPath = $PSScriptRoot
            if ($currentPath -match '_Sync[\\\\/]Core') {
                $scriptRoot = Split-Path $currentPath -Parent
            } else {
                $scriptRoot = $currentPath
            }
            $logDir = Join-Path $scriptRoot 'logs'
            if (-not (Test-Path $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            $this.LogPath = Join-Path $logDir 'SyncEvents.log'
            $this.Subscribers = @{}
            $this.Errors = [System.Collections.ArrayList]::new()
        }

        [void] TriggerEvent([string]$eventName, [object]$data) {
            $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $logDir = Split-Path $this.LogPath -Parent
            if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            $logEntry = "[$timestamp] EVENT: $eventName | DATA: $($data | ConvertTo-Json -Compress)"
            $logEntry | Out-File -FilePath $this.LogPath -Append -Encoding utf8
        }

        [void] TriggerEvent([string]$eventName, [object]$data, [object]$eventSource) {
            $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $logDir = Split-Path $this.LogPath -Parent
            if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            $srcText = if ($null -ne $eventSource) { $eventSource.ToString() } else { '' }
            $dataJson = $($data | ConvertTo-Json -Compress)
            $logEntry = "[$timestamp] EVENT: $eventName | SOURCE: $srcText | DATA: $dataJson"
            $logEntry | Out-File -FilePath $this.LogPath -Append -Encoding utf8
        }

        [void] Subscribe([string]$eventName, [scriptblock]$handler) {
            if (-not $this.Subscribers.ContainsKey($eventName)) {
                $this.Subscribers[$eventName] = [System.Collections.ArrayList]::new()
            }
            [void]$this.Subscribers[$eventName].Add($handler)
        }

        [void] Unsubscribe([string]$eventName, [scriptblock]$handler) {
            if ($this.Subscribers.ContainsKey($eventName)) {
                $this.Subscribers[$eventName] = @($this.Subscribers[$eventName] | Where-Object { $_ -ne $handler })
            }
        }

        [void] Publish([string]$eventName, [object]$eventSource, [hashtable]$eventData) {
            if ($this.Subscribers.ContainsKey($eventName)) {
                foreach ($handler in $this.Subscribers[$eventName]) {
                    try {
                        & $handler $eventSource $eventData
                    } catch {
                        $errInfo = @{
                            Time        = (Get-Date).ToString('o')
                            EventName   = $eventName
                            Handler     = $handler.ToString().Substring(0, [Math]::Min(200, $handler.ToString().Length))
                            Exception   = $_.Exception.Message
                            ScriptStackTrace = $_.ScriptStackTrace
                            PositionMessage  = if ($_.InvocationInfo) { $_.InvocationInfo.PositionMessage } else { '' }
                            SourceFile  = if ($_.InvocationInfo) { $_.InvocationInfo.MyCommand.Definition } else { '' }
                            LineNumber   = if ($_.InvocationInfo) { $_.InvocationInfo.ScriptLineNumber } else { 0 }
                            Category    = 'EventHandlerFailure'
                        }
                        [void]$this.Errors.Add($errInfo)
                        $this.TriggerEvent('EventHandlerError', $errInfo)
                        Write-Warning (Get-LocaleMessage -Key 'gsync.msg.event.handlerFailedWithSource' -MessageArgs @($eventName, $($errInfo.SourceFile), $($errInfo.LineNumber), $($_.Exception.Message)))
                    }
                }
                # Persist event to log file (with source), regardless of subscriber count
                $this.TriggerEvent($eventName, $eventData, $eventSource)
            }
        }

        [object] GetErrors() {
            return $this.Errors
        }
    }
}

function New-SyncEventManager {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        return [SyncEventManager]::new()
    }
    $manager = New-Object PSObject
    $manager | Add-Member -MemberType NoteProperty -Name LogPath -Value ''
    $manager | Add-Member -MemberType NoteProperty -Name Subscribers -Value @{}
    $manager | Add-Member -MemberType NoteProperty -Name Errors -Value ([System.Collections.ArrayList]::new())
    $null = $manager.PSObject.TypeNames.Insert(0, 'SyncEventManager')
    $manager | Add-Member -MemberType ScriptMethod -Name Subscribe -Value {
        param($eventName, $handler)

Set-StrictMode -Version 1.0
        if (-not $this.Subscribers.ContainsKey($eventName)) { $this.Subscribers[$eventName] = [System.Collections.ArrayList]::new() }
        [void]$this.Subscribers[$eventName].Add($handler)
    }
    $manager | Add-Member -MemberType ScriptMethod -Name Unsubscribe -Value {
        param($eventName, $handler)
        if ($this.Subscribers.ContainsKey($eventName)) {
            $this.Subscribers[$eventName] = @($this.Subscribers[$eventName] | Where-Object { $_ -ne $handler })
        }
    }
    $manager | Add-Member -MemberType ScriptMethod -Name Publish -Value {
        param($eventName, $eventSource, $eventData)
        if ($this.Subscribers.ContainsKey($eventName)) {
            foreach ($handler in $this.Subscribers[$eventName]) {
                try { & $handler $eventSource $eventData } catch { Write-Warning (Get-LocaleMessage -Key 'gsync.msg.event.handlerFailed' -MessageArgs @($eventName, $($_.Exception.Message))) }
            }
        }
    }
    $manager | Add-Member -MemberType ScriptMethod -Name TriggerEvent -Value { param($eventName, $data) }
    $manager | Add-Member -MemberType ScriptMethod -Name GetErrors -Value { $this.Errors }
    return $manager
}

function Add-SyncEventListener {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Manager,
        [Parameter(Mandatory)][string]$EventName,
        [Parameter(Mandatory)][scriptblock]$Handler
    )
    if (-not $Manager -or -not (Get-Member -InputObject $Manager -Name Subscribe -MemberType Method -ErrorAction SilentlyContinue)) {
        Write-Warning (Get-LocaleMessage -Key 'gsync.msg.event.invalidManager')
        return
    }
    $Manager.Subscribe($EventName, $Handler)
}

function Publish-GSyncEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Manager,
        [Parameter(Mandatory)][string]$EventName,
        [object]$EventSource,
        [hashtable]$EventData
    )
    if (-not $Manager) { return }
    $Manager.Publish($EventName, $EventSource, $EventData)
    if ($Manager.PSTypeName -eq 'SyncEventManager') {
        $Manager.TriggerEvent($EventName, $EventData, $EventSource)
    }
}

Export-ModuleMember -Function @('New-SyncEventManager', 'Add-SyncEventListener', 'Publish-GSyncEvent')

