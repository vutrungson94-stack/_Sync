#Requires -Version 5.1
param($Config)

# The shared bootstrap makes the logger and the locale resolver available.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1')
Set-StrictMode -Version 1.0
$script:EmDash = if ($PSVersionTable.PSVersion -ge [Version]'5.1') { [char]0x2014 } else { '-' }

# Pre-push hook: branch protection + size check + webhook notification
Write-Debug (Get-LocaleMessage -Key 'gsync.msg.hook.prePushStarted')

# 1. Branch protection
$bpCfg = if ($Config.branchProtection) { $Config.branchProtection } else { $null }
if ($bpCfg) {
    . (Join-Path $PSScriptRoot 'gsync-BranchProtection.ps1')
    $currentBranch = & git rev-parse --abbrev-ref HEAD 2>$null
    $status = Get-BranchProtectionStatus -RepoPath (Get-Location) -Config $bpCfg
    if ($status.Protected) {
        $protected = Test-BranchProtected -BranchName $currentBranch -ProtectionRules $bpCfg
        if ($protected) {
            Write-Warning (Get-LocaleMessage -Key 'gsync.msg.hook.branchProtected' -MessageArgs @($currentBranch))
            if (Get-Command Send-WebhookNotification -ErrorAction SilentlyContinue) {
                Send-WebhookNotification -Config $Config -Status "blocked" -Message "Protected branch push"
            }
            return $false
        }
    }
}

# 2. Large file check
if ($Config.largeFiles -and $Config.largeFiles.enabled) {
    $threshold = $Config.largeFiles.thresholdMB * 1MB
    $pending = & git diff --stat --cached HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $pending) {
        $largeFiles = & git diff --cached --name-only | ForEach-Object {
            $fullPath = Join-Path (Get-Location) $_
            if (Test-Path $fullPath) {
                $len = (Get-Item $fullPath).Length
                if ($len -gt $threshold) { $_ }
            }
        }
        if ($largeFiles) {
            Write-Warning (Get-LocaleMessage -Key 'gsync.msg.hook.largeFilesPending' -MessageArgs @($($largeFiles -join ', ')))
            if (Get-Command Send-WebhookNotification -ErrorAction SilentlyContinue) {
                Send-WebhookNotification -Config $Config -Status "warning" -Message "Large files detected"
            }
        }
    }
}

# 3. Auto push notification webhook
if (Get-Command Send-WebhookNotification -ErrorAction SilentlyContinue) {
    Send-WebhookNotification -Config $Config -Status "success" -Message "Push prepared"
}

# 4. Content gate: a file that cannot parse must not leave this machine.
#
#    Two failure classes reach GitHub as a red run and produce nothing here,
#    because a byte-level sync cannot see either (see YamlSanity.psm1):
#     - a UTF-16 writer touching a UTF-8 text file - PowerShell's `>>`,
#       Out-File and Add-Content default to UTF-16 when no -Encoding is
#       given, and the damage is truly invisible until GitHub fails;
#     - a YAML file that cannot start a run - duplicate keys inside one
#       mapping, or tab indentation.
#
#    Files examined: everything this push would publish - the diff from the
#    remote-tracking ref to HEAD plus anything still staged or modified (the
#    auto-commit flow commits right before pushing, so the range alone can
#    be empty while the push still carries files).
#
#    Disabled with contentGate.enabled = $false in gsync.config.json;
#    textExtensions and projectGates (the repo's own syntax checker, e.g.
#    `npm run workflow`) are configurable the same way.

$contentGateCfg = $null
if ($Config -and $Config.PSObject.Properties.Name -contains 'contentGate') { $contentGateCfg = $Config.contentGate }
$gateEnabled = $true
if ($contentGateCfg) { $gateEnabled = ($contentGateCfg.enabled -ne $false) }

if ($gateEnabled) {
    $sanityModule = Join-Path $PSScriptRoot 'YamlSanity.psm1'
    $null = Import-Module $sanityModule -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue

    if (Get-Command Get-DefaultTextExtension -ErrorAction SilentlyContinue) {
        $gateTextExt = Get-DefaultTextExtension
    } else {
        $gateTextExt = @('.ps1', '.psm1', '.psd1', '.yml', '.yaml', '.json', '.xml', '.md', '.txt', '.html', '.css', '.js', '.mjs', '.cjs', '.ts', '.sh', '.cs', '.py')
    }
    if ($contentGateCfg -and $contentGateCfg.PSObject.Properties.Name -contains 'textExtensions' -and @($contentGateCfg.textExtensions).Count -gt 0) {
        $gateTextExt = @($contentGateCfg.textExtensions)
    }

    $pushRangeFiles = @(& git diff --name-only '@{push}..HEAD' 2>$null)
    if ($LASTEXITCODE -ne 0) { $pushRangeFiles = @() }   # nothing to compare against yet
    $stagedFiles = @(& git diff --cached --name-only 2>$null)
    $dirtyFiles  = @(& git diff --name-only HEAD 2>$null)
    $candidates  = @(@($pushRangeFiles) + @($stagedFiles) + @($dirtyFiles) | Where-Object { $_ } | Select-Object -Unique)

    $repoRootForGate = (& git rev-parse --show-toplevel 2>$null)
    $fatalIssues = New-Object System.Collections.Generic.List[object]
    $warnIssues  = New-Object System.Collections.Generic.List[object]

    foreach ($rel in $candidates) {
        if (-not $rel) { continue }
        $fullPath = Join-Path $repoRootForGate ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }   # deletion or rename source

        $fileLeaf = (Split-Path $rel -Leaf)
        $isText = $false
        foreach ($e in $gateTextExt) {
            if ($fileLeaf -like "*$e" -or $fileLeaf -eq $e.TrimStart('.')) { $isText = $true; break }
        }
        # YAML is always worth a structural look, whatever the extension list says.
        $extLower = [System.IO.Path]::GetExtension($fileLeaf).ToLowerInvariant()
        if (-not $isText -and $extLower -notin @('.yml', '.yaml')) { continue }

        if ($extLower -in @('.yml', '.yaml')) {
            foreach ($issue in @(Find-YamlSanityIssue -Path $fullPath)) {
                if ($issue.Severity -eq 'Error') { $fatalIssues.Add($issue) } else { $warnIssues.Add($issue) }
            }
        }
        if ($isText) {
            foreach ($issue in @(Find-TextSanityIssue -Path $fullPath)) {
                if ($issue.Severity -eq 'Error') { $fatalIssues.Add($issue) } else { $warnIssues.Add($issue) }
            }
        }
    }

    # The project's own syntax checker runs too: it is written for the schema
    # a generic scanner does not know. `npm run workflow` in the Node repo
    # that lives next to this tool is exactly that checker.
    $runProjectGates = $true
    if ($contentGateCfg) { $runProjectGates = ($contentGateCfg.runProjectGates -ne $false) }
    if ($runProjectGates) {
        $gateNames = @('workflow')
        if ($contentGateCfg -and $contentGateCfg.PSObject.Properties.Name -contains 'projectGates') {
            $gateNames = @($contentGateCfg.projectGates)
        }
        $pkgPath = Join-Path $repoRootForGate 'package.json'
        if ((Test-Path -LiteralPath $pkgPath) -and (Get-Command npm -ErrorAction SilentlyContinue)) {
            $packageJson = Get-Content -LiteralPath $pkgPath -Raw | ConvertFrom-Json
            foreach ($gateName in $gateNames) {
                if (-not ($packageJson.scripts -and $packageJson.scripts.PSObject.Properties.Name -contains $gateName)) { continue }
                Write-Debug "gsync pre-push: project gate 'npm run $gateName'"
                Push-Location $repoRootForGate
                try {
                    $gateOutput = @(& npm run $gateName 2>&1)
                    if ($LASTEXITCODE -ne 0) {
                        $fatalIssues.Add([PSCustomObject]@{
                            File = 'package.json'; Severity = 'Error'; Line = 0
                            Code = 'project-gate-failed'
                            Message = "Project gate 'npm run $gateName' exited $LASTEXITCODE - it validates what this push ships."
                        })
                        Write-Host "  --- output of 'npm run $gateName' (last lines) ---" -ForegroundColor Yellow
                        $gateOutput | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" }
                    }
                } finally { Pop-Location }
            }
        }
    }

    if ($fatalIssues.Count -gt 0) {
        Write-Warning "gsync content gate: push BLOCKED - $($fatalIssues.Count) problem(s) would ship broken content:"
        foreach ($issue in $fatalIssues) {
            Write-Warning ("  {0}  [{1}]{2} {3}" -f ((Split-Path $issue.File -Leaf)), $issue.Code, ($(if ($issue.Line) { " line $($issue.Line):" } else { ':' })), $issue.Message)
        }
        Write-Warning "  (turn off with contentGate.enabled=false in gsync.config.json, or fix the files above)"
        if (Get-Command Send-WebhookNotification -ErrorAction SilentlyContinue) {
            Send-WebhookNotification -Config $Config -Status "blocked" -Message "Content gate blocked push"
        }
        return $false
    }
    $warnIssues | ForEach-Object {
        Write-Warning "gsync content gate (non-fatal): $((Split-Path $_.File -Leaf)) [$($_.Code)] $($_.Message)"
    }
}

Write-Debug (Get-LocaleMessage -Key 'gsync.msg.hook.prePushPassed')
return $true
