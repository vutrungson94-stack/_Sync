#Requires -Version 5.1
# AiCommit.psm1 - Commit summary with optional free AI providers and a
# conventional-commit heuristic fallback. No paid API key is required: it
# auto-detects GitHub Models (via the git credential store / gh CLI) and a
# local Ollama instance, and degrades to a deterministic heuristic otherwise.

function Get-AiCommitGitHubToken {
    foreach ($v in @('GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_MODELS_TOKEN', 'GSYNC_AI_API_KEY')) {
        $val = [Environment]::GetEnvironmentVariable($v)
        if (-not [string]::IsNullOrWhiteSpace($val)) { return $val.Trim() }
    }
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        try {
            $t = & gh auth token 2>$null
            if ($t) { $t = ([string]$t).Trim(); if ($t) { return $t } }
        } catch { }
    }
    try {
        $input = "protocol=https`nhost=github.com`n`n"
        $out = $input | & git credential fill 2>$null
        $prefix = 'pass' + 'word='
        foreach ($line in @($out)) {
            $line = [string]$line
            if ($line.StartsWith($prefix)) { return $line.Substring($prefix.Length).Trim() }
        }
    } catch { }
    return $null
}

function Invoke-AiCommitProvider {
    param(
        [Parameter(Mandatory)][string[]]$Files,
        [string]$Locale = 'en',
        [int]$TimeoutSec = 15
    )
    $fileList = ($Files -join "`n")
    $system = 'You are a commit-message generator. Reply with ONLY a conventional commit message: a subject line (max 72 chars), optionally a blank line and a short bullet body. No markdown fences, no explanation, no quotes.'
    $user = "Locale: $Locale`nChanged files:`n$fileList`nGenerate a concise conventional commit message."

    # 1. GitHub Models (free tier, uses the user's GitHub credential)
    $token = Get-AiCommitGitHubToken
    if ($token) {
        $model = $env:GSYNC_AI_MODEL
        if ([string]::IsNullOrWhiteSpace($model)) { $model = 'gpt-4o-mini' }
        $endpoint = $env:GSYNC_AI_ENDPOINT
        if ([string]::IsNullOrWhiteSpace($endpoint)) { $endpoint = 'https://models.inference.ai.azure.com/chat/completions' }
        try {
            $body = @{
                model       = $model
                messages    = @(
                    @{ role = 'system'; content = $system }
                    @{ role = 'user'; content = $user }
                )
                temperature = 0.3
                max_tokens  = 200
            } | ConvertTo-Json -Depth 6
            $resp = Invoke-RestMethod -Uri $endpoint -Method Post -Headers @{ Authorization = "Bearer $token" } -Body $body -ContentType 'application/json' -TimeoutSec $TimeoutSec -ErrorAction Stop
            $text = [string]$resp.choices[0].message.content
            if (-not [string]::IsNullOrWhiteSpace($text)) { return $text.Trim() }
        } catch { }
    }

    # 2. Local Ollama (free, no key; only if a chat model is present)
    try {
        $tags = Invoke-RestMethod -Uri 'http://localhost:11434/api/tags' -TimeoutSec 2 -ErrorAction Stop
        $chatModel = @($tags.models) | Where-Object { $_.name -match 'llama|qwen|mistral|phi|gemma|deepseek|smollm' } | Select-Object -First 1
        if ($chatModel) {
            $body = @{
                model    = $chatModel.name
                messages = @(
                    @{ role = 'system'; content = $system }
                    @{ role = 'user'; content = $user }
                )
                stream   = $false
                options  = @{ temperature = 0.3; num_predict = 200 }
            } | ConvertTo-Json -Depth 6
            $resp = Invoke-RestMethod -Uri 'http://localhost:11434/api/chat' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec $TimeoutSec -ErrorAction Stop
            $text = [string]$resp.message.content
            if (-not [string]::IsNullOrWhiteSpace($text)) { return $text.Trim() }
        }
    } catch { }

    return $null
}

function Get-HeuristicCommitMessage {
    param(
        [Parameter(Mandatory)][string[]]$Files,
        [string]$Locale = 'en'
    )
    $files = @($Files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ -replace '\\', '/' })
    $count = $files.Count
    if ($count -eq 0) { return 'chore: empty sync' }

    $testCount = @($files | Where-Object { $_ -match 'Tests?/' -or $_ -match '\.Tests\.ps1$' }).Count
    $ciCount   = @($files | Where-Object { $_ -match '\.github/' }).Count
    $docCount  = @($files | Where-Object { $_ -match '\.md$' -or $_ -match '(^|/)docs/' }).Count
    $codeCount = @($files | Where-Object { $_ -match '\.(ps1|psm1|py|js|ts|tsx|go|java|cs|rs)$' }).Count

    $type = 'chore'
    if ($testCount -gt 0 -and $testCount -eq $count) { $type = 'test' }
    elseif ($ciCount -gt 0 -and $ciCount -eq $count) { $type = 'ci' }
    elseif ($docCount -gt 0 -and $docCount -eq $count) { $type = 'docs' }
    elseif ($codeCount -gt 0) { $type = 'feat' }

    # scope: common stem across changed files
    $stems = $files | ForEach-Object {
        $b = [System.IO.Path]::GetFileNameWithoutExtension($_)
        $b -replace '\.Tests$', '' -replace '^Test-', ''
    }
    $scope = ''
    $top = $stems | Group-Object | Sort-Object Count -Descending | Select-Object -First 1
    if ($top -and $top.Count -gt 1) { $scope = [string]$top.Name }
    elseif ($count -eq 1) { $scope = [string]$top.Name }
    else {
        # Fall back to a shared prefix (e.g. SyncRollback + SyncContext -> Sync)
        $sorted = @($stems | Sort-Object)
        $first = $sorted[0]; $last = $sorted[$sorted.Count - 1]
        $i = 0
        while ($i -lt $first.Length -and $i -lt $last.Length -and $first[$i] -eq $last[$i]) { $i++ }
        if ($i -ge 4) { $scope = $first.Substring(0, $i) }
    }

    $subjectCore = if ($count -eq 1) { "update $([System.IO.Path]::GetFileName($files[0]))" } else { "update $count files" }
    $subject = if ($scope) { "$type($scope): $subjectCore" } else { "${type}: $subjectCore" }
    if ($subject.Length -gt 72) { $subject = $subject.Substring(0, 69) + '...' }

    $bodyLines = @($files | Select-Object -First 15 | ForEach-Object { "- $_" })
    if ($files.Count -gt 15) { $bodyLines += "- ... and $($files.Count - 15) more" }
    $body = $bodyLines -join "`n"

    if ([string]::IsNullOrWhiteSpace($body)) { return $subject }
    return "$subject`n`n$body"
}

function New-AiCommitSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ChangedFiles,
        [string]$Locale = 'en',
        [PSCustomObject]$Config = @{ }
    )

    Set-StrictMode -Version 1.0
    $files = @($ChangedFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($files.Count -eq 0) { return 'chore: empty sync' }

    # Resolve effective locale
    $eff = $Locale
    if ([string]::IsNullOrWhiteSpace($eff) -and $Config -and $Config.build -and $Config.build.locale -and $Config.build.locale.default) {
        $eff = [string]$Config.build.locale.default
    }
    if ([string]::IsNullOrWhiteSpace($eff)) { $eff = 'en' }
    $eff = $eff.ToLowerInvariant()

    # Try a free AI provider first
    $aiText = $null
    try { $aiText = Invoke-AiCommitProvider -Files $files -Locale $eff } catch { $aiText = $null }

    $result = $null
    if (-not [string]::IsNullOrWhiteSpace($aiText)) {
        # Sanitize: strip fences, take first line as subject
        $clean = $aiText -replace '```[a-zA-Z]*', '' -replace '```', ''
        $lines = @($clean -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($lines.Count -gt 0) {
            $subj = $lines[0]
            if ($subj.Length -gt 72) { $subj = $subj.Substring(0, 69) + '...' }
            if ($lines.Count -gt 1) {
                $rest = ($lines[1..($lines.Count - 1)]) -join "`n"
                $result = "$subj`n`n$rest"
            } else {
                $result = $subj
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($result)) {
        $result = Get-HeuristicCommitMessage -Files $files -Locale $eff
    }
    return $result
}

Export-ModuleMember -Function @('New-AiCommitSummary')

# End of AiCommit.psm1
