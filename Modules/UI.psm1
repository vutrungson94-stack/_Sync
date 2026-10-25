#Requires -Version 5.1
# UI.psm1

# Make the logger available when this module is imported on its own.

. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1')
function Get-ConsoleWidth {
    try {
        $w = (Get-Host).UI.RawUI.WindowSize.Width
        if ($w -and $w -gt 20) { return $w }
    } catch { }
    if ($env:COLUMNS -and [int]::TryParse($env:COLUMNS, [ref]$null)) { return [int]$env:COLUMNS }
    return 80
}

function Show-Header {
    Write-Host @"
`n╔══════════════════════════════════════════════════════════════════════╗
║           GIT SYNC VIP PRO — Smart & safe synchronization            ║
╚══════════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor (Resolve-SafeColor -ColorName 'Header' -Fallback 'Cyan')
}

function Write-StepTitle([string]$Title, [string]$Color = "Cyan") {
    $w = Get-ConsoleWidth
    $padding = [Math]::Max(0, $w - $Title.Length - 12)
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.ui.header' -MessageArgs @($Title, $('─' * $padding))) -ForegroundColor $Color
}

function Write-SubLog([string]$Label, [string]$Value, [string]$Color = "White") {
    Write-Host (Get-LocaleMessage -Key 'gsync.msg.ui.label' -MessageArgs @($Label)) -NoNewline -ForegroundColor (Resolve-SafeColor -ColorName 'Gray' -Fallback 'DarkGray')
    Write-Host (": $Value") -ForegroundColor $Color
}

function Test-InteractiveSession {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

Set-StrictMode -Version 1.0
    if ($global:GSync.No -or $global:GSync.Yes -or $global:GSync.NonInteractive) { return $false }
    $cmdLine = [Environment]::GetCommandLineArgs()
    if ($cmdLine -match '-NonInteractive|/NonInteractive') { return $false }
    try { if ([System.Console]::IsInputRedirected) { return $false } } catch { }
    try { $null = $Host.UI.RawUI.CursorSize; return $true } catch { return $false }
}

function Confirm-YesNo {
    param([string]$Question, [string]$Default = "y")
    if ($global:GSync.No) { return $false }
    if ($global:GSync.Yes) { return $true }
    if (-not (Test-InteractiveSession)) { return ($Default -eq "y") }
    $suffix = if ($Default -eq "y") { "(y/n) [Default: y]" } else { "(y/n) [Default: n]" }
    $ans = Read-Host "$Question $suffix"
    if ([string]::IsNullOrWhiteSpace($ans)) { return ($Default -eq "y") }
    return ($ans.Trim().ToLowerInvariant() -eq "y")
}

Export-ModuleMember -Function @('Get-ConsoleWidth', 'Show-Header', 'Write-StepTitle', 'Write-SubLog', 'Confirm-YesNo', 'Test-InteractiveSession')
