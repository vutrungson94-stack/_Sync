BeforeAll {
    $global:ScriptRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $global:ScriptRoot "Modules\gsync-Hooks.ps1") -Force -Global -DisableNameChecking -ErrorAction Stop
    # Pester 5 keeps only BeforeAll-scoped values visible to the It bodies;
    # a Describe-scope or script-level value would be invisible at run time
    # under Invoke-Pester (-Path) as used by Run-Tests.ps1.
    $cfg = [PSCustomObject]@{
        contentGate = [PSCustomObject]@{ enabled = $true; runProjectGates = $false }
    }
    function New-TestRepo {
        $repo = Join-Path $TestDrive ("repo-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Push-Location $repo
        & git init -q 2>&1 | Out-Null
        & git config user.email 'test@example.invalid' 2>&1 | Out-Null
        & git config user.name 'Test' 2>&1 | Out-Null
        return $repo
    }
}

Describe "gsync content gate (pre-push)" {
    It "blocks a push whose staged text file carries a NUL byte" {
        New-TestRepo
        try {
            # WriteAllText with a U+0000 in the string is the bug's signature:
            # PowerShell >> / Out-File wrote UTF-16 behind an edit once and a
            # workflow shipped broken because of it.
            [System.IO.File]::WriteAllText(
                (Join-Path (Get-Location) 'note.txt'),
                "plain text with a relic char: $([char]0x00)"
            )
            & git add note.txt 2>&1 | Out-Null
            $verdict = Invoke-GSyncHook -HookType 'pre-push' -Config $cfg
            $verdict | Should -BeFalse -Because 'a NUL byte in a text file is corruption'
        } finally {
            Pop-Location
        }
    }

    It "blocks a push whose YAML workflow records the same key twice" {
        New-TestRepo
        try {
            $workflow = Join-Path (Get-Location) 'broken.yml'
            # Two identical keys at the same indent inside one mapping - the
            # two lines that closed a real workflow for every Node version.
            Set-Content -LiteralPath $workflow -Value "jobs:`n  build:`n    strategy:`n      fail-fast: false`n    name: build`n    name: build`n" -Encoding utf8
            & git add broken.yml 2>&1 | Out-Null
            $verdict = Invoke-GSyncHook -HookType 'pre-push' -Config $cfg
            $verdict | Should -BeFalse -Because 'GitHub refuses to start a workflow with duplicate keys'
        } finally {
            Pop-Location
        }
    }

    It "allows a clean push when no project gate is configured" {
        New-TestRepo
        try {
            Set-Content -LiteralPath (Join-Path (Get-Location) 'ok.yml') -Value "name: t`njobs:`n  one:`n    name: one`n" -Encoding utf8
            & git add ok.yml 2>&1 | Out-Null
            $verdict = Invoke-GSyncHook -HookType 'pre-push' -Config $cfg
            $verdict | Should -BeTrue -Because 'parseable files with no NUL bytes must pass'
        } finally {
            Pop-Location
        }
    }

    It "does not run project gates that do not exist" {
        New-TestRepo
        try {
            Set-Content -LiteralPath (Join-Path (Get-Location) 'ok.yml') -Value "name: t`n" -Encoding utf8
            & git add ok.yml 2>&1 | Out-Null
            $repoCfg = [PSCustomObject]@{
                contentGate = [PSCustomObject]@{ enabled = $true; runProjectGates = $true; projectGates = @('workflow') }
            }
            $verdict = Invoke-GSyncHook -HookType 'pre-push' -Config $repoCfg
            $verdict | Should -BeTrue -Because 'a repo without package.json has no npm gate to run'
        } finally {
            Pop-Location
        }
    }

    It "runs nothing when the gate is disabled in config" {
        New-TestRepo
        try {
            Set-Content -LiteralPath (Join-Path (Get-Location) 'broken.yml') -Value "a: 1`na: 2`n" -Encoding utf8
            & git add broken.yml 2>&1 | Out-Null
            $offCfg = [PSCustomObject]@{ contentGate = [PSCustomObject]@{ enabled = $false } }
            $verdict = Invoke-GSyncHook -HookType 'pre-push' -Config $offCfg
            $verdict | Should -BeTrue -Because 'contentGate.enabled=false must be an escape hatch, not a promise'
        } finally {
            Pop-Location
        }
    }
}
