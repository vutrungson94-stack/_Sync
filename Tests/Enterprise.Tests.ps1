#Requires -Version 5.1
#Requires -Module Pester

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "SKIP: $($PSScriptRoot) requires PowerShell 7+ (current: $($PSVersionTable.PSVersion))" -ForegroundColor Yellow
    exit 0
}

$bootstrapPath = Join-Path $PSScriptRoot '_TestBootstrap.ps1'
if (Test-Path $bootstrapPath) {
    . $bootstrapPath
} else {
    Write-Error "Cannot find _TestBootstrap.ps1 at $bootstrapPath"
    exit 1
}

Set-StrictMode -Version 1.0

Describe "GSync Container" {
    BeforeAll { Clear-GSyncServices }
    AfterAll { Clear-GSyncServices }

    It "Registers and resolves singleton" {
        $global:testCalls = 0
        Register-GSyncService -Name 'TestSingleton' -Factory { $global:testCalls++; return "instance" } -Scope Singleton
        $a = Resolve-GSyncService -Name 'TestSingleton'
        $b = Resolve-GSyncService -Name 'TestSingleton'
        $a | Should -Be 'instance'
        $b | Should -Be 'instance'
        $global:testCalls | Should -Be 1
    }

    It "Resolves transient twice" {
        $global:txCalls = 0
        Register-GSyncService -Name 'TestTransient' -Factory { $global:txCalls++; return [guid]::NewGuid().ToString() } -Scope Transient
        $a = Resolve-GSyncService -Name 'TestTransient'
        $b = Resolve-GSyncService -Name 'TestTransient'
        $a | Should -Not -Be $b
        $global:txCalls | Should -Be 2
    }

    It "Throws on missing service" {
        { Resolve-GSyncService -Name 'Missing' } | Should -Throw
    }

    It "Tests registration" {
        Test-GSyncServiceRegistered -Name 'TestSingleton' | Should -Be $true
        Test-GSyncServiceRegistered -Name 'Missing' | Should -Be $false
    }
}

Describe "GSync ErrorHandling" {
    It "Creates structured error" {
        $err = New-GSyncError -Message "fail" -Category 'GitError' -Code 1001
        $err.Message | Should -Be 'fail'
        $err.Category | Should -Be 'GitError'
        $err.Code | Should -Be 1001
        $err.Timestamp | Should -Not -BeNullOrEmpty
    }

    It "Retries and succeeds on second attempt" {
        $global:attempts = 0
        $result = Invoke-GSyncRetry -ScriptBlock {
            $global:attempts++
            if ($global:attempts -lt 2) { throw "transient" }
            return "ok"
        } -MaxRetries 3 -BaseDelayMs 10 -OperationName 'op'
        $result | Should -Be 'ok'
        $global:attempts | Should -Be 2
    }

    It "Throws after max retries" {
        { Invoke-GSyncRetry -ScriptBlock { throw "fail" } -MaxRetries 2 -BaseDelayMs 10 -OperationName 'op' } | Should -Throw
    }

    It "Rollback stack executes LIFO" {
        Clear-GSyncRollbackStack
        $order = [System.Collections.ArrayList]@()
        Register-GSyncRollbackAction -Label 'first' -Action { [void]$order.Add(1) }
        Register-GSyncRollbackAction -Label 'second' -Action { [void]$order.Add(2) }
        Invoke-GSyncRollback
        $order.Count | Should -Be 2
        $order[0] | Should -Be 2
        $order[1] | Should -Be 1
        Clear-GSyncRollbackStack
    }
}

Describe "GSync EventBus" {
    It "Subscribe and send event" {
        Clear-BuildEvents
        $state = @{ received = $false }
        Add-BuildEvent -Name 'test.evt' -Handler { param($d) $state.received = $true }
        Send-BuildEvent -Name 'test.evt' -Data $null
        $state.received | Should -Be $true
    }

    It "Clears events" {
        Clear-BuildEvents
        Add-BuildEvent -Name 'test.evt2' -Handler { }
        Clear-BuildEvents
        (Get-SyncEventSubscribers -Name 'test.evt2').Count | Should -Be 0
    }

    It "Has 20+ constants" {
        $count = (Get-GSyncEventConstants).Count
        $count | Should -BeGreaterThan 19
    }
}

Describe "GSync Config" {
    It "Test-GSyncConfig validates good config" {
        $cfg = Get-DefaultConfig
        $cfg | Add-Member -NotePropertyName 'version' -NotePropertyValue '1.0.0' -Force
        $cfg | Add-Member -NotePropertyName 'logging' -NotePropertyValue @{ level='Info' } -Force
        $cfg | Add-Member -NotePropertyName 'security' -NotePropertyValue @{ enabled=$true; blockOnMatch=$true } -Force
        $cfg | Add-Member -NotePropertyName 'git' -NotePropertyValue @{ remoteName='origin'; minVersion='2.20.0'; retryCount=3 } -Force
        Test-GSyncConfig -Config $cfg | Should -Be $true
    }

    It "Test-GSyncConfig rejects missing version" {
        $cfg = Get-DefaultConfig
        $cfg | Add-Member -NotePropertyName 'version' -NotePropertyValue $null
        $cfg | Add-Member -NotePropertyName 'logging' -NotePropertyValue @{ level='Info' } -Force
        $cfg | Add-Member -NotePropertyName 'security' -NotePropertyValue @{ enabled=$true; blockOnMatch=$true } -Force
        $cfg | Add-Member -NotePropertyName 'git' -NotePropertyValue @{ remoteName='origin'; retryCount=3 } -Force
        Test-GSyncConfig -Config $cfg | Should -Be $false
    }
}
