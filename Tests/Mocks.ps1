#Requires -Version 5.1

<#PSScriptInfo
.VERSION 1.0.0
.GUID a1234567-89ab-4cde-f012-3456789abcde
.AUTHOR Trung Son
.COMPANYNAME 
.COPYRIGHT Copyright (c) 2026
.TAGS PowerShell, Pester, Mocks, Testing, _Sync
.LICENSEURI 
.PROJECTURI 
.ICONURI 
.EXTERNALMODULEDEPENDENCIES 
.RELEASENOTES Initial version
#>

<#
.SYNOPSIS
    Mocking framework for git commands and external dependencies.

.DESCRIPTION
    Provides mock implementations of git commands and other external dependencies
    for testing the _Sync system without requiring actual git operations.

.NOTES
    Usage:
    1. Import this module in your test file
    2. Call Start-GitMock to enable git command mocking
    3. Call Stop-GitMock to restore original git commands
    4. Use Set-GitMockResponse to configure mock responses

.EXAMPLE
    # In your test file
    Import-Module .\Mocks.ps1
    
    BeforeEach {
        Start-GitMock
        Set-GitMockResponse -Command "git -version" -Output "git version 2.40.0"
    }
    
    AfterEach {
        Stop-GitMock
    }
    
    It "Should test git version" {
        $version = & git -version
        $version | Should -Be "git version 2.40.0"
    }
#>

Set-StrictMode -Version 1.0

# =============================================================================
# MOCK STATE MANAGEMENT
# =============================================================================

$global:OriginalGitCommand = $null
$global:GitMockResponses = @{}
$global:GitMockDefaults = @{}
$global:GitMockCallHistory = @()
$global:MockEnabled = $false
$global:GitMockExitCodes = @{}

# Default mock responses for common git commands
$global:GitMockDefaults = @{
    "git -version" = "git version 2.40.0"
    "git --version" = "git version 2.40.0"
    "git rev-parse --is-inside-work-tree" = "true"
    "git status" = @"
On branch main
Your branch is up to date with 'origin/main'.

nothing to commit, working tree clean
"@
    "git log --oneline -1" = "abc1234 Test commit"
    "git rev-parse HEAD" = "abc1234def567890"
    "git branch --show-current" = "main"
    "git remote -v" = @"
origin	git@github.com:user/repo.git (fetch)
origin	git@github.com:user/repo.git (push)
"@
    "git ls-remote --heads origin" = "abc1234	refs/heads/main"
    "git fetch origin --prune" = ""
    "git pull origin main" = "Already up to date."
    "git push origin main" = "Everything up-to-date"
    "git diff --stat" = ""
    "git add ." = ""
    "git commit -m" = @"
[main (root-commit) abc1234] Initial commit
 1 file changed, 1 insertion(+)
 create mode 100644 README.md
"@
}

# =============================================================================
# MOCK COMMAND HANDLERS
# =============================================================================

function Start-GitMock {
    <#
    .SYNOPSIS
        Enables git command mocking.
    
    .DESCRIPTION
        Overrides the 'git' command to use mock responses instead of actual git execution.
    #>
    
    if ($global:MockEnabled) {
        Write-Warning "Git mocking is already enabled"
        return
    }
    
    # Save original git command if available
    $global:OriginalGitCommand = Get-Command git -ErrorAction SilentlyContinue
    
    # Create mock git function
    function git {
        [CmdletBinding(DefaultParameterSetName = 'Default')]
        param(
            [Parameter(ValueFromRemainingArguments = $true)]
            [string[]]$ArgumentList
        )
        
        # Build command string
        $command = "git $($ArgumentList -join ' ')"
        
        # Record call history
        $callInfo = @{
            Command = $command
            Arguments = $ArgumentList
            Timestamp = Get-Date
        }
        $global:GitMockCallHistory += $callInfo
        
        # Check for custom response
        if ($global:GitMockResponses.ContainsKey($command)) {
            $response = $global:GitMockResponses[$command]
            
            # Check if response is a scriptblock
            if ($response -is [scriptblock]) {
                $result = & $response @ArgumentList
                if ($result -is [System.Management.Automation.ErrorRecord]) {
                    throw $result.Exception
                }
                if ($result -is [object]) {
                    # If result has Output property, use it
                    if ($result.PSObject.Properties.Name -contains 'Output') {
                        Write-Output $result.Output
                    } else {
                        Write-Output $result
                    }
                }
                $global:LASTEXITCODE = 0
                return
            }
            
            # Check for exit code configuration
            $exitCode = 0
            if ($global:GitMockExitCodes.ContainsKey($command)) {
                $exitCode = $global:GitMockExitCodes[$command]
            }
            
            # Write response to output
            if ($response -ne $null) {
                Write-Output $response
            }
            
            # Set exit code
            $global:LASTEXITCODE = $exitCode
            return
        }
        
        # Check defaults
        foreach ($key in $global:GitMockDefaults.Keys) {
            if ($command -like "$key*") {
                $response = $global:GitMockDefaults[$key]
                if ($response -ne $null) {
                    Write-Output $response
                }
                $exitCode = 0
                if ($global:GitMockExitCodes.ContainsKey($command)) {
                    $exitCode = $global:GitMockExitCodes[$command]
                }
                $global:LASTEXITCODE = $exitCode
                return
            }
        }
        
        # Fallback: return empty string
        $global:LASTEXITCODE = 0
    }
    
    if (Get-Item function:\git -ErrorAction SilentlyContinue) {
        $sb = (Get-Item function:\git).ScriptBlock
        Remove-Item function:\git -Force -ErrorAction SilentlyContinue
        Set-Item function:\global:git -Value $sb -Force -ErrorAction SilentlyContinue
    }
    
    $global:MockEnabled = $true
    Write-Verbose "Git mocking enabled"
}

function Stop-GitMock {
    <#
    .SYNOPSIS
        Disables git command mocking.
    
    .DESCRIPTION
        Restores the original git command if it was available before mocking.
    #>
    
    if (-not $global:MockEnabled) {
        Write-Warning "Git mocking is not enabled"
        return
    }
    
    # Remove mock git function
    Remove-Item function:\git -ErrorAction SilentlyContinue
    
    # Restore original git command if available
    if ($global:OriginalGitCommand -ne $null) {
        $functionPath = "function:\git"
        if (Test-Path $functionPath) {
            Remove-Item $functionPath -Force -ErrorAction SilentlyContinue
        }
    }
    
    # Clear mock state
    $global:GitMockResponses.Clear()
    $global:GitMockExitCodes.Clear()
    $global:GitMockCallHistory.Clear()
    $global:MockEnabled = $false
    $global:OriginalGitCommand = $null
    
    Write-Verbose "Git mocking disabled"
}

function Set-GitMockResponse {
    <#
    .SYNOPSIS
        Sets a mock response for a specific git command.
    
    .PARAMETER Command
        The git command to mock (e.g., "git log --oneline")
    
    .PARAMETER Output
        The output to return when the command is called
    
    .PARAMETER ExitCode
        The exit code to return (default: 0)
    
    .PARAMETER ScriptBlock
        A scriptblock that will be executed when the command is called
    
    .EXAMPLE
        Set-GitMockResponse -Command "git log --oneline" -Output "abc123 Commit message"
        Set-GitMockResponse -Command "git push" -ExitCode 1 -Output "Error: failed to push"
        Set-GitMockResponse -Command "git status" -ScriptBlock { throw "Repository not found" }
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string]$Output,
        [int]$ExitCode = 0,
        [scriptblock]$ScriptBlock
    )
    
    if (-not $global:MockEnabled) {
        Write-Warning "Git mocking is not enabled. Call Start-GitMock first."
        return
    }
    
    if ($ScriptBlock -ne $null) {
        $global:GitMockResponses[$Command] = $ScriptBlock
    } elseif ($Output -ne $null) {
        $global:GitMockResponses[$Command] = $Output
    }
    
    if ($ExitCode -ne 0) {
        $global:GitMockExitCodes[$Command] = $ExitCode
    }
}

function Clear-GitMockResponse {
    <#
    .SYNOPSIS
        Clears a mock response for a specific git command.
    
    .PARAMETER Command
        The git command to clear the mock for
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command
    )
    
    if ($global:GitMockResponses.ContainsKey($Command)) {
        $global:GitMockResponses.Remove($Command)
    }
    
    if ($global:GitMockExitCodes.ContainsKey($Command)) {
        $global:GitMockExitCodes.Remove($Command)
    }
}

function Clear-AllGitMocks {
    <#
    .SYNOPSIS
        Clears all configured mock responses.
    #>
    
    $global:GitMockResponses.Clear()
    $global:GitMockExitCodes.Clear()
    $global:GitMockCallHistory.Clear()
}

function Get-GitMockCallHistory {
    <#
    .SYNOPSIS
        Gets the history of git command calls during mocking.
    
    .PARAMETER Clear
        If specified, clears the call history after retrieving it
    
    .EXAMPLE
        $calls = Get-GitMockCallHistory
        $calls | Should -HaveCount 1
        $calls[0].Command | Should -Be "git log --oneline"
    #>
    
    [CmdletBinding()]
    param(
        [switch]$Clear
    )
    
    $result = $global:GitMockCallHistory.Clone()
    if ($Clear) {
        $global:GitMockCallHistory.Clear()
    }
    return $result
}

function Get-GitMockCallCount {
    <#
    .SYNOPSIS
        Gets the number of times a specific git command was called.
    
    .PARAMETER Command
        The git command to check
    
    .EXAMPLE
        Get-GitMockCallCount -Command "git log" | Should -Be 3
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command
    )
    
    return ($global:GitMockCallHistory | Where-Object { $_.Command -like "*$Command*" }).Count
}

# =============================================================================
# MOCK FILE SYSTEM HELPERS
# =============================================================================

function New-MockGitRepository {
    <#
    .SYNOPSIS
        Creates a mock git repository structure for testing.
    
    .PARAMETER Path
        The path to create the mock repository
    
    .PARAMETER Config
        Optional configuration for the mock repository
    
    .EXAMPLE
        $repoPath = New-MockGitRepository -Path "C:\Temp\TestRepo"
        cd $repoPath
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Config = @{}
    )
    
    # Create directory
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    
    # Create .git directory
    $gitDir = Join-Path $Path ".git"
    New-Item -ItemType Directory -Path $gitDir -Force | Out-Null
    
    # Create basic git config
    $configFile = Join-Path $gitDir "config"
    @"
[core]
    repositoryformatversion = 0
    filemode = false
    bare = false
    logallrefupdates = true
[remote "origin"]
    url = git@github.com:user/repo.git
    fetch = +refs/heads/*:refs/remotes/origin/*
"@ | Out-File $configFile -Encoding UTF8
    
    # Create HEAD file
    $headFile = Join-Path $gitDir "HEAD"
    "ref: refs/heads/main" | Out-File $headFile -Encoding UTF8
    
    # Create refs/heads/main
    $refsDir = Join-Path $gitDir "refs\heads"
    New-Item -ItemType Directory -Path $refsDir -Force | Out-Null
    $mainRef = Join-Path $refsDir "main"
    $config.GetProviderHash() | Out-File $mainRef -Encoding UTF8
    
    # Create some test files
    $readmeFile = Join-Path $Path "README.md"
    "# Test Repository" | Out-File $readmeFile -Encoding UTF8
    
    # Create .gitignore
    $gitignoreFile = Join-Path $Path ".gitignore"
    @"
*.log
*.tmp
.DS_Store
"@ | Out-File $gitignoreFile -Encoding UTF8
    
    return $Path
}

function Set-MockGitConfig {
    <#
    .SYNOPSIS
        Sets mock configuration values for git operations.
    
    .PARAMETER Key
        The configuration key (e.g., "user.name", "user.email")
    
    .PARAMETER Value
        The configuration value
    
    .EXAMPLE
        Set-MockGitConfig -Key "user.name" -Value "Test User"
        Set-MockGitConfig -Key "user.email" -Value "test@example.com"
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )
    
    # This config will be used by mock git config command
    if ($global:GitMockResponses.ContainsKey("git config --get $Key")) {
        $global:GitMockResponses["git config --get $Key"] = $Value
    } else {
        $global:GitMockResponses.Add("git config --get $Key", $Value)
    }
}

# =============================================================================
# MOCK ENVIRONMENT HELPERS
# =============================================================================

function Start-EnvironmentMock {
    <#
    .SYNOPSIS
        Starts mocking environment variables.
    
    .DESCRIPTION
        Saves original environment variable values and allows setting mock values.
    #>
    
    $global:OriginalEnvironment = @{}
    $global:EnvironmentMocks = @{}
}

function Set-EnvironmentMock {
    <#
    .SYNOPSIS
        Sets a mock environment variable value.
    
    .PARAMETER Name
        The environment variable name
    
    .PARAMETER Value
        The mock value to set
    
    .EXAMPLE
        Set-EnvironmentMock -Name "GSYNC_ENCRYPTION_KEY" -Value "test-key-1234567890"
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Value
    )
    
    # Save original value if not already saved
    if (-not $global:OriginalEnvironment.ContainsKey($Name)) {
        $global:OriginalEnvironment[$Name] = ${env:$Name}
    }
    
    # Set mock value
    $global:EnvironmentMocks[$Name] = $Value
    ${env:$Name} = $Value
}

function Stop-EnvironmentMock {
    <#
    .SYNOPSIS
        Stops environment variable mocking and restores original values.
    #>
    
    # Restore original values
    foreach ($key in $global:OriginalEnvironment.Keys) {
        if ($global:OriginalEnvironment[$key] -ne $null) {
            ${env:$key} = $global:OriginalEnvironment[$key]
        } else {
            Remove-Item Env:\$key -ErrorAction SilentlyContinue
        }
    }
    
    # Clear mock state
    $global:OriginalEnvironment.Clear()
    $global:EnvironmentMocks.Clear()
}

# =============================================================================
# CONVENIENCE FUNCTIONS FOR TESTING
# =============================================================================

function Assert-GitCalled {
    <#
    .SYNOPSIS
        Asserts that a git command was called a specific number of times.
    
    .PARAMETER Command
        The git command to check
    
    .PARAMETER Times
        The expected number of times the command was called (default: 1)
    
    .EXAMPLE
        Assert-GitCalled -Command "git push" -Times 1
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [int]$Times = 1
    )
    
    $actualCount = Get-GitMockCallCount -Command $Command
    
    if ($actualCount -ne $Times) {
        throw "Expected git command '$Command' to be called $Times time(s), but it was called $actualCount time(s)"
    }
}

function Assert-GitNotCalled {
    <#
    .SYNOPSIS
        Asserts that a git command was NOT called.
    
    .PARAMETER Command
        The git command to check
    
    .EXAMPLE
        Assert-GitNotCalled -Command "git push"
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command
    )
    
    $actualCount = Get-GitMockCallCount -Command $Command
    
    if ($actualCount -gt 0) {
        throw "Expected git command '$Command' NOT to be called, but it was called $actualCount time(s)"
    }
}

function Assert-GitCalledWith {
    <#
    .SYNOPSIS
        Asserts that a git command was called with specific arguments.
    
    .PARAMETER Command
        The git command to check
    
    .PARAMETER Arguments
        Expected arguments (can be string or array)
    
    .EXAMPLE
        Assert-GitCalledWith -Command "git commit" -Arguments "-m", "Test commit"
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )
    
    $calls = Get-GitMockCallHistory | Where-Object { $_.Command -like "*$Command*" }
    
    if ($calls.Count -eq 0) {
        throw "Git command '$Command' was not called"
    }
    
    $found = $false
    foreach ($call in $calls) {
        $argsMatch = $true
        foreach ($expectedArg in $Arguments) {
            if ($call.Arguments -notcontains $expectedArg) {
                $argsMatch = $false
                break
            }
        }
        if ($argsMatch) {
            $found = $true
            break
        }
    }
    
    if (-not $found) {
        throw "Git command '$Command' was not called with expected arguments: $($Arguments -join ' ')"
    }
}

# =============================================================================
# MOCK SYNC CONTEXT HELPERS
# =============================================================================

function New-MockSyncContext {
    <#
    .SYNOPSIS
        Creates a mock SyncContext for testing.
    
    .PARAMETER ScriptRoot
        The script root path
    
    .PARAMETER Config
        Optional configuration
    
    .PARAMETER MockGit
        If true, automatically starts git mocking
    
    .EXAMPLE
        $ctx = New-MockSyncContext -ScriptRoot "C:\Temp\TestRepo" -MockGit $true
    #>
    
    [CmdletBinding()]
    param(
        [string]$ScriptRoot = (Join-Path $env:TEMP "gsync_test_$(Get-Random)"),
        [hashtable]$Config = @{},
        [switch]$MockGit
    )
    
    # Create temp directory if it doesn't exist
    if (-not (Test-Path $ScriptRoot)) {
        New-Item -ItemType Directory -Path $ScriptRoot -Force | Out-Null
    }
    
    # Import SyncContext module
    $syncCorePath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "Core/_SyncCore.psm1"
    if (Test-Path $syncCorePath) {
        Import-Module $syncCorePath -Force -ErrorAction SilentlyContinue -Scope Global
    }
    
    # Start git mocking if requested
    if ($MockGit) {
        Start-GitMock
    }
    
    # Create context
    $ctx = New-SyncContext -ScriptRoot $ScriptRoot -Config $Config
    
    return $ctx
}

# =============================================================================
# CLEANUP HELPERS
# =============================================================================

function Remove-MockTestDirectory {
    <#
    .SYNOPSIS
        Removes a test directory and all its contents.
    
    .PARAMETER Path
        The path to remove
    
    .EXAMPLE
        Remove-MockTestDirectory -Path $testDir
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )
    
    if (Test-Path $Path) {
        try {
            Remove-Item $Path -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warning "Failed to remove test directory $Path : $_"
        }
    }
}

# =============================================================================
# EXPORT
# =============================================================================

# Export all mock functions
Get-Command -CommandType Function | ForEach-Object {
    $name = $_.Name
    $src = Get-Item -Path ("function:\{0}" -f $name) -ErrorAction SilentlyContinue
    if ($src) {
        $sb = $src.ScriptBlock
        Set-Content -Path ("function:\global:{0}" -f $name) -Value $sb
    }
}

