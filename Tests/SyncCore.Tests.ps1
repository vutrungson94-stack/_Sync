#Requires -Modules Pester
#Requires -Version 5.1

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "SKIP: $($PSScriptRoot) requires PowerShell 7+ (current: $($PSVersionTable.PSVersion))" -ForegroundColor Yellow
    exit 0
}

# Load test bootstrap
$bootstrapPath = Join-Path $PSScriptRoot '_TestBootstrap.ps1'
if (Test-Path $bootstrapPath) {
    . $bootstrapPath
} else {
    Write-Error "Cannot find _TestBootstrap.ps1 at $bootstrapPath"
    exit 1
}
# Additional: ensure SyncRollback is loaded for rollback-related test blocks
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Core/SyncRollback.psm1') -Force -DisableNameChecking -Scope Global -ErrorAction SilentlyContinue | Out-Null

<#PSScriptInfo
.VERSION 1.0.0
.GUID 5330393f-6b18-48b2-a8e1-7031448a8e8c
.AUTHOR Trung Son
.COMPANYNAME 
.COPYRIGHT Copyright (c) 2026
.TAGS PowerShell, Pester, Tests, _Sync
.LICENSEURI 
.PROJECTURI 
.ICONURI 
.EXTERNALMODULEDEPENDENCIES Pester
.RELEASENOTES Initial version
#>

Describe "SyncContext" {
    BeforeEach {
        $testScriptRoot = Join-Path $env:TEMP "gsync_test_$(Get-Random)"
        New-Item -ItemType Directory -Path $testScriptRoot -Force | Out-Null
    }
    
    AfterEach {
        if (Test-Path $testScriptRoot) {
            Remove-Item $testScriptRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    Context "Constructor and Properties" {
        It "Should create context with correct script root" {
            $ctx = New-SyncContext -ScriptRoot $testScriptRoot -Config @{}
            $ctx.ScriptRoot | Should -Be $testScriptRoot
            $ctx.RepoRoot | Should -Not -Be $null
            $ctx.SessionId | Should -Not -Be $null
            $ctx.CorrelationId | Should -Not -Be $null
            $ctx.StartTime | Should -Not -Be $null
            ($ctx.Errors -is [System.Collections.ArrayList]) | Should -Be $true
            ($ctx.Metadata -is [hashtable]) | Should -Be $true
        }
        
        It "Should initialize CorrelationId as GUID" {
            $ctx = New-SyncContext -ScriptRoot $testScriptRoot -Config @{}
            $ctx.CorrelationId | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        }
        
        It "Should initialize CurrentPhase as 'init'" {
            $ctx = New-SyncContext -ScriptRoot $testScriptRoot -Config @{}
            $ctx.CurrentPhase | Should -Be 'init'
        }
    }
    
    Context "State Management" {
        It "Should save and load state" {
            $ctx = New-SyncContext -ScriptRoot $testScriptRoot -Config @{}
            $ctx.SetPhase("test_phase")
            $ctx.LastCommitHash = "abc123def456"
            
            $ctx.SaveState()
            
            $loadedState = $ctx.LoadState()
            $loadedState | Should -Not -Be $null
            $loadedState.phase | Should -Be "test_phase"
            $loadedState.commitHash | Should -Be "abc123def456"
        }
        
        It "Should return null for non-existent state file" {
            $ctx = New-SyncContext -ScriptRoot $testScriptRoot -Config @{}
            $stateFile = Join-Path $testScriptRoot ".gsync.state"
            if (Test-Path $stateFile) { Remove-Item $stateFile -Force }
            
            $loadedState = $ctx.LoadState()
            $loadedState | Should -Be $null
        }
        
        It "Should delete state file on ClearState" {
            $ctx = New-SyncContext -ScriptRoot $testScriptRoot -Config @{}
            $ctx.SaveState()
            
            $stateFile = Join-Path $testScriptRoot ".gsync.state"
            Test-Path $stateFile | Should -Be $true
            
            $ctx.ClearState()
            Test-Path $stateFile | Should -Be $false
        }
        
        It "Should delete stale state files (older than 120 minutes)" {
            $ctx = New-SyncContext -ScriptRoot $testScriptRoot -Config @{}
            
            # Create a stale state file
            $staleState = @{
                version = 1
                timestamp = (Get-Date).AddMinutes(-150).ToString('o')
            }
            $stateFile = Join-Path $testScriptRoot ".gsync.state"
            $staleState | ConvertTo-Json -Depth 2 | Out-File $stateFile -Encoding UTF8 -Force
            
            $loadedState = $ctx.LoadState()
            $loadedState | Should -Be $null
            
            # State file should be deleted
            Test-Path $stateFile | Should -Be $false
        }
    }
    
    Context "Error Management" {
        It "Should add errors with default category" {
            $ctx = New-SyncContext -ScriptRoot $testScriptRoot -Config @{}
            $ctx.AddError("Test error message")
            
            $ctx.Errors.Count | Should -Be 1
            ($ctx.Errors[0] -is [PSCustomObject]) | Should -Be $true
            $ctx.Errors[0].Message | Should -Be "Test error message"
            $ctx.Errors[0].Category | Should -Be "UnknownError"
            $ctx.Errors[0].Code | Should -Be 9999
            $ctx.Errors[0].CorrelationId | Should -Be $ctx.CorrelationId
        }
        
        It "Should add errors with custom category and code" {
            $ctx = New-SyncContext -ScriptRoot $testScriptRoot -Config @{}
            $ctx.AddError("Git error", "GitError", 1001)
            
            $ctx.Errors.Count | Should -Be 1
            $ctx.Errors[0].Category | Should -Be "GitError"
            $ctx.Errors[0].Code | Should -Be 1001
        }
        
        It "Should report HasErrors correctly" {
            $ctx = New-SyncContext -ScriptRoot $testScriptRoot -Config @{}
            $ctx.HasErrors() | Should -Be $false
            
            $ctx.AddError("Test error")
            $ctx.HasErrors() | Should -Be $true
        }
        
        It "Should filter errors by category" {
            $ctx = New-SyncContext -ScriptRoot $testScriptRoot -Config @{}
            $ctx.AddError("Git error 1", "GitError", 1001)
            $ctx.AddError("Network error 1", "NetworkError", 2001)
            $ctx.AddError("Git error 2", "GitError", 1002)
            
            $gitErrors = $ctx.GetErrorsByCategory("GitError")
            $gitErrors.Count | Should -Be 2
            
            $networkErrors = $ctx.GetErrorsByCategory("NetworkError")
            $networkErrors.Count | Should -Be 1
        }
        
        It "Should count errors by category" {
            $ctx = New-SyncContext -ScriptRoot $testScriptRoot -Config @{}
            $ctx.AddError("Git error 1", "GitError", 1001)
            $ctx.AddError("Network error 1", "NetworkError", 2001)
            $ctx.AddError("Git error 2", "GitError", 1002)
            
            $ctx.GetErrorCountByCategory("GitError") | Should -Be 2
            $ctx.GetErrorCountByCategory("NetworkError") | Should -Be 1
            $ctx.GetErrorCountByCategory("NonExistent") | Should -Be 0
        }
    }
    
    Context "CorrelationId Management" {
        It "Should get correlation ID" {
            $ctx = New-SyncContext -ScriptRoot $testScriptRoot -Config @{}
            $originalId = $ctx.GetCorrelationId()
            $originalId | Should -Be $ctx.CorrelationId
        }
        
        It "Should set new correlation ID" {
            $ctx = New-SyncContext -ScriptRoot $testScriptRoot -Config @{}
            $newId = [guid]::NewGuid().ToString()
            $ctx.SetCorrelationId($newId)
            $ctx.GetCorrelationId() | Should -Be $newId
        }
    }
    
    Context "State Encryption" {
        BeforeEach {
            $env:GSYNC_ENCRYPTION_KEY = "TestEncryptionKey1234567890123456"
        }
        
        AfterEach {
            $env:GSYNC_ENCRYPTION_KEY = $null
        }
        
        It "Should encrypt state file when enabled in config" {
            $config = @{
                security = @{
                    encryptStateFiles = $true
                    encryptionKey = "TestEncryptionKey1234567890123456"
                }
            }
            $ctx = New-SyncContext -ScriptRoot $testScriptRoot -Config $config
            $ctx.SetPhase("test_phase")
            $ctx.SaveState()
            
            # The file should exist
            $stateFile = Join-Path $testScriptRoot ".gsync.state"
            Test-Path $stateFile | Should -Be $true
            
            # Content should be encrypted (GSYNC envelope), never plaintext JSON
            $content = Get-Content $stateFile -Raw
            $content | Should -Match '^GSYNC:1:'
            $content | Should -Not -Match '"phase"'
        }
        
        It "Should decrypt state file when encrypted" {
            $config = @{
                security = @{
                    encryptStateFiles = $true
                    encryptionKey = "TestEncryptionKey1234567890123456"
                }
            }
            $ctx = New-SyncContext -ScriptRoot $testScriptRoot -Config $config
            $ctx.SetPhase("test_phase")
            $ctx.SaveState()
            
            # Decrypt and load
            $ctx.UnprotectState()
            $loadedState = $ctx.LoadState()
            $loadedState.phase | Should -Be "test_phase"
        }
    }
}


Describe "SyncEventManager" {
    BeforeEach {
        $testEventLogDir = Join-Path $env:TEMP "gsync_events_$(Get-Random)"
        New-Item -ItemType Directory -Path $testEventLogDir -Force | Out-Null
    }
    
    AfterEach {
        if (Test-Path $testEventLogDir) {
            Remove-Item $testEventLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    Context "Constructor" {
        It "Should create event manager with correct path" {
            $manager = New-SyncEventManager
            $manager.LogPath | Should -Not -Be $null
            ($manager.Subscribers -is [hashtable]) | Should -Be $true
            ($manager.Errors -is [System.Collections.ArrayList]) | Should -Be $true
        }
    }
    
    Context "Subscribe and Publish" {
        It "Should subscribe and publish events" {
            $manager = New-SyncEventManager
            # Handlers mutate a shared hashtable (scalar assignment cannot escape handler scope)
            $captured = @{ source = $null; data = $null }
            
            $handler = {
                param($source, $data)
                $captured.source = $source
                $captured.data = $data
            }
            
            $manager.Subscribe("TestEvent", $handler)
            $manager.Publish("TestEvent", "TestSource", @{ Key = "Value" })
            
            $captured.source | Should -Be "TestSource"
            $captured.data.Key | Should -Be "Value"
        }
        
        It "Should handle multiple subscribers for same event" {
            $manager = New-SyncEventManager
            $counter = @{ value = 0 }
            
            $handler1 = { param($s, $d) $counter.value++ }
            $handler2 = { param($s, $d) $counter.value++ }
            
            $manager.Subscribe("TestEvent", $handler1)
            $manager.Subscribe("TestEvent", $handler2)
            $manager.Publish("TestEvent", "TestSource", @{})
            
            $counter.value | Should -Be 2
        }
        
        It "Should capture handler errors" {
            $manager = New-SyncEventManager
            
            $handler = {
                throw "Test handler error"
            }
            
            $manager.Subscribe("TestEvent", $handler)
            $manager.Publish("TestEvent", "TestSource", @{})
            
            $manager.Errors.Count | Should -Be 1
            $manager.Errors[0].Exception | Should -Match ([regex]::Escape("Test handler error"))
            $manager.Errors[0].Category | Should -Be "EventHandlerFailure"
        }
    }
    
    Context "Unsubscribe" {
        It "Should unsubscribe handlers" {
            $manager = New-SyncEventManager
            $counter = @{ value = 0 }
            
            $handler = { param($s, $d) $counter.value++ }
            
            $manager.Subscribe("TestEvent", $handler)
            $manager.Publish("TestEvent", "TestSource", @{})
            $counter.value | Should -Be 1
            
            $manager.Unsubscribe("TestEvent", $handler)
            $manager.Publish("TestEvent", "TestSource", @{})
            $counter.value | Should -Be 1
        }
    }
    
    Context "Event Logging" {
        It "Should log events to file" {
            $manager = New-SyncEventManager
            $manager.Publish("TestEvent", "TestSource", @{ Data = "Test" })
            
            Test-Path $manager.LogPath | Should -Be $true
            
            $logContent = Get-Content $manager.LogPath -Raw
            $logContent | Should -Match ([regex]::Escape("TestEvent"))
            $logContent | Should -Match ([regex]::Escape("TestSource"))
        }
    }
}



Describe "SyncError" {
    Context "Constructor" {
        It "Should create error with all properties" {
            $err = New-SyncError -Message "Test message" -Category "GitError" -Code 1001 -CorrelationId "test-corr-id"
            
            $err.Message | Should -Be "Test message"
            $err.Category | Should -Be "GitError"
            $err.Code | Should -Be 1001
            $err.CorrelationId | Should -Be "test-corr-id"
            $err.Timestamp | Should -Not -Be $null
            $err.Timestamp | Should -Not -Be $null
        }
        
        It "Should create error with default correlation ID" {
$err = New-SyncError -Message "Test message" -Category "NetworkError" -Code 2001
            
            $err.Message | Should -Be "Test message"
            $err.Category | Should -Be "NetworkError"
            $err.Code | Should -Be 2001
            $err.CorrelationId | Should -Be $null
        }
    }
}

Describe "SyncTypes Constants" {
    Context "File Path Constants" {
        It "Should have correct file path constants" {
            $global:SyncConstants.DefaultStateFileName | Should -Be ".gsync.state"
            $global:SyncConstants.DefaultLogFileName | Should -Be ".gsync.log"
            $global:SyncConstants.DefaultConfigFileName | Should -Be "gsync.config.json"
            $global:SyncConstants.SnapshotsDirName | Should -Be ".sync_snapshots"
            $global:SyncConstants.LogsDirName | Should -Be "logs"
        }
    }
    
    Context "Version Constants" {
        It "Should have correct version constants" {
            $global:SyncConstants.MinGitVersion | Should -Be "2.20.0"
            $global:SyncConstants.ConfigVersion | Should -Be "1.0.0"
        }
    }
    
    Context "Retry Constants" {
        It "Should have correct retry constants" {
            $global:SyncConstants.DefaultRetryCount | Should -Be 3
            $global:SyncConstants.DefaultRetryDelaySeconds | Should -Be 5
            $global:SyncConstants.DefaultPushRetryDelaySeconds | Should -Be 3
            $global:SyncConstants.MaxRetryCount | Should -Be 20
        }
    }
    
    Context "Parallel Constants" {
        It "Should have correct parallel constants" {
            $global:SyncConstants.DefaultMaxThreads | Should -Be 4
            $global:SyncConstants.MaxMaxThreads | Should -Be 64
            $global:SyncConstants.MinMaxThreads | Should -Be 1
        }
    }
    
    Context "Logging Constants" {
        It "Should have correct logging constants" {
            $global:SyncConstants.DefaultLogLevel | Should -Be "Info"
            $global:SyncConstants.DefaultMaxLogFiles | Should -Be 10
            $global:SyncConstants.DefaultMaxLogSizeMB | Should -Be 50
        }
    }
    
    Context "Security Constants" {
        It "Should have default blocked patterns" {
            $global:SyncConstants.DefaultBlockedPatterns | Should -Not -Be $null
            ($global:SyncConstants.DefaultBlockedPatterns -is [System.Array]) | Should -Be $true
            ($global:SyncConstants.DefaultBlockedPatterns.Count -ge 1) | Should -Be $true
        }
    }
    
    Context "Error Categories" {
        It "Should have correct error category codes" {
            $global:SyncErrorCategories.GitError | Should -Be 1000
            $global:SyncErrorCategories.NetworkError | Should -Be 2000
            $global:SyncErrorCategories.ValidationError | Should -Be 3000
            $global:SyncErrorCategories.ConfigurationError | Should -Be 4000
            $global:SyncErrorCategories.PluginError | Should -Be 5000
            $global:SyncErrorCategories.PipelineError | Should -Be 6000
            $global:SyncErrorCategories.SecurityError | Should -Be 7000
            $global:SyncErrorCategories.StateError | Should -Be 8000
            $global:SyncErrorCategories.DependencyError | Should -Be 9000
            $global:SyncErrorCategories.UnknownError | Should -Be 9999
        }
    }
}






