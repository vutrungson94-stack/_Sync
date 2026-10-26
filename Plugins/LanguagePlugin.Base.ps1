# Shared scaffold for flat language plugins (Node, Python, ...).
# Each concrete plugin sets the $script:Plugin* variables below and then
# dot-sources this file. Keeping one copy here removes the byte-identical
# duplication between Node.psm1 and Python.psm1.

if (-not $script:PluginName) { $script:PluginName = 'Language' }
if (-not $script:SupportedLanguages) { $script:SupportedLanguages = @() }
if (-not $script:PluginDescription) { $script:PluginDescription = "$($script:PluginName) plugin" }
if (-not $script:ManifestFile) { $script:ManifestFile = '' }
if (-not $script:PreflightWarning) { $script:PreflightWarning = "$($script:PluginName.ToLower()) plugin preflight" }
if (-not $script:BuildCommand) { $script:BuildCommand = '' }
if (-not $script:TestCommand) { $script:TestCommand = '' }
if (-not $script:LintCommand) { $script:LintCommand = '' }

function Get-PluginInfo {
    return @{
        Name               = $script:PluginName
        SupportedLanguages = $script:SupportedLanguages
        PluginType         = 'MultiLanguage'
        Description        = $script:PluginDescription
    }
}

function Get-PluginManifest {
    param([object]$ProjectPath)
    if ([string]::IsNullOrWhiteSpace($script:ManifestFile)) { return $null }
    $m = Join-Path $ProjectPath $script:ManifestFile
    if (Test-Path $m) { return (Get-Content $m -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue) }
    return $null
}

function Invoke-PluginBuild {
    param([object]$ProjectPath, [string]$Configuration = 'Release', [object]$Context = $null)
    Set-StrictMode -Version 1.0
    if (-not $script:BuildCommand) { return @{ ExitCode = 0; Output = "$($script:PluginName.ToLower()) plugin: build skipped (no build command)"; Errors = @() } }
    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) { return @{ ExitCode = 0; Output = "$($script:PluginName.ToLower()) plugin: build skipped (no project dir)"; Errors = @() } }
    $manifest = Get-PluginManifest -ProjectPath $ProjectPath
    if ($null -eq $manifest) { return @{ ExitCode = 0; Output = "$($script:PluginName.ToLower()) plugin: build skipped (no manifest)"; Errors = @() } }
    # Execute the build command
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { 'cmd.exe' } else { '/bin/sh' }
        $psi.Arguments = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { "/c $($script:BuildCommand)" } else { "-c `"$($script:BuildCommand)`"" }
        $psi.WorkingDirectory = $ProjectPath
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        $output = if ($stdout) { $stdout } else { '' }
        if ($stderr) { $output += "`n$stderr" }
        return @{ ExitCode = $exitCode; Output = $output.Trim(); Errors = @() }
    } catch {
        return @{ ExitCode = 1; Output = ''; Errors = @($_.Exception.Message) }
    }
}

function Invoke-PluginTest {
    param([object]$ProjectPath, [object]$Context = $null)
    if (-not $script:TestCommand) { return @{ ExitCode = 0; Output = "$($script:PluginName.ToLower()) plugin: test skipped (no test command)"; Errors = @() } }
    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) { return @{ ExitCode = 0; Output = "$($script:PluginName.ToLower()) plugin: test skipped (no project dir)"; Errors = @() } }
    $manifest = Get-PluginManifest -ProjectPath $ProjectPath
    if ($null -eq $manifest) { return @{ ExitCode = 0; Output = "$($script:PluginName.ToLower()) plugin: test skipped (no manifest)"; Errors = @() } }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { 'cmd.exe' } else { '/bin/sh' }
        $psi.Arguments = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { "/c $($script:TestCommand)" } else { "-c `"$($script:TestCommand)`"" }
        $psi.WorkingDirectory = $ProjectPath
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        $output = if ($stdout) { $stdout } else { '' }
        if ($stderr) { $output += "`n$stderr" }
        return @{ ExitCode = $exitCode; Output = $output.Trim(); Errors = @() }
    } catch {
        return @{ ExitCode = 1; Output = ''; Errors = @($_.Exception.Message) }
    }
}

function Invoke-PluginLint {
    param([object]$ProjectPath, [object]$Context = $null)
    if (-not $script:LintCommand) { return @{ ExitCode = 0; Output = "$($script:PluginName.ToLower()) plugin: lint skipped (no lint command)"; Errors = @() } }
    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) { return @{ ExitCode = 0; Output = "$($script:PluginName.ToLower()) plugin: lint skipped (no project dir)"; Errors = @() } }
    $manifest = Get-PluginManifest -ProjectPath $ProjectPath
    if ($null -eq $manifest) { return @{ ExitCode = 0; Output = "$($script:PluginName.ToLower()) plugin: lint skipped (no manifest)"; Errors = @() } }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { 'cmd.exe' } else { '/bin/sh' }
        $psi.Arguments = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { "/c $($script:LintCommand)" } else { "-c `"$($script:LintCommand)`"" }
        $psi.WorkingDirectory = $ProjectPath
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        $output = if ($stdout) { $stdout } else { '' }
        if ($stderr) { $output += "`n$stderr" }
        return @{ ExitCode = $exitCode; Output = $output.Trim(); Errors = @() }
    } catch {
        return @{ ExitCode = 1; Output = ''; Errors = @($_.Exception.Message) }
    }
}

function Invoke-PluginPreflight {
    param([object]$ProjectPath, [object]$Context = $null)
    $warnings = @($script:PreflightWarning)
    $ready = $true
    if ($ProjectPath -and (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
        $manifest = Get-PluginManifest -ProjectPath $ProjectPath
        if ($null -eq $manifest) { $warnings += "no $($script:ManifestFile) found" }
    }
    return @{ Ready = $ready; Warnings = @($warnings); Errors = @() }
}

Export-ModuleMember -Function @('Get-PluginInfo','Invoke-PluginBuild','Invoke-PluginTest','Invoke-PluginLint','Invoke-PluginPreflight','Get-PluginManifest')