BeforeAll { $script:HygToolRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
# Hygiene.Tests.ps1 for _Sync
$script:HygToolRoot = Split-Path -Parent $PSScriptRoot
Describe 'Hygiene: locale key sets identical' {
    It 'keeps key sets identical across all locales' {
        $locales = @('en','vi','zh','ja','fr','es','de')
        $ref = $null
        foreach ($l in $locales) {
            $p = Join-Path $script:HygToolRoot "Locales/$l.json"
            Test-Path -LiteralPath $p | Should -BeTrue -Because "$l.json must ship"
            $keys = @((Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties.Name) | Sort-Object
            if ($null -eq $ref) { $ref = $keys }
            (Compare-Object $ref $keys) | Should -BeNullOrEmpty -Because "$l.json key set drifted"
        }
    }
}
Describe 'Hygiene: no locale key ships untranslated' {
    It 'translates every English string' {
        $en = Get-Content -LiteralPath (Join-Path $script:HygToolRoot 'Locales/en.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $others = @('vi','zh','ja','fr','es','de')
        $locs = @{}
        foreach ($l in $others) { $locs[$l] = Get-Content -LiteralPath (Join-Path $script:HygToolRoot "Locales/$l.json") -Raw -Encoding UTF8 | ConvertFrom-Json }
        $exempt = @('menu.azurePipelines','menu.deployAws','menu.deployAwsLambda','menu.deployAzure','menu.deployGcp','menu.deployK8s','menu.deployVercel','menu.dockerCi','menu.githubCloudBuild','gsync.msg.git.conflictContinue','gsync.msg.cleanup.largeFile','gsync.msg.progress.bar','gsync.msg.ui.header','gsync.msg.ui.label','gsync.msg.hook.postCommitRef')
        $offenders = @()
        foreach ($prop in $en.PSObject.Properties) {
            if ($exempt -contains $prop.Name) { continue }
            $value = [string]$prop.Value
            $words = @($value -split '\s+' | Where-Object { $_ -match '[A-Za-z]{2,}' })
            if ($words.Count -lt 2) { continue }
            foreach ($l in $others) {
                $other = [string]$locs[$l].PSObject.Properties[$prop.Name].Value
                if ($other -ceq $value) { $offenders += "$($prop.Name) is still English in $l" }
            }
        }
        $offenders | Should -BeNullOrEmpty
    }
}
Describe 'Hygiene: the global import surface stays bounded' {
    It 'imports only THIS tool''s own modules into the global scope' {
        # The live path imports its modules with -Scope Global because on
        # PowerShell 5.1 a module imported into another module's scope
        # exports into that scope only, and the sibling modules call each
        # other. That is a deliberate, documented decision - but it means a
        # stray `Import-Module <something else> -Global` would pollute the
        # operator's session with a foreign module. Every globally imported
        # module must live inside this tool.
        $toolRoot = $script:HygToolRoot
        $sources = @()
        foreach ($f in @('gsync.module.psm1', 'gsync.ps1')) {
            $p = Join-Path $toolRoot $f
            if (Test-Path -LiteralPath $p) { $sources += $p }
        }
        $modulesDir = Join-Path $toolRoot 'Modules'
        $coreDir = Join-Path $toolRoot 'Core'
        $sources += (Get-ChildItem $modulesDir -Filter *.psm1 -File -ErrorAction SilentlyContinue).FullName
        $sources += (Get-ChildItem $coreDir -Filter *.psm1 -File -ErrorAction SilentlyContinue).FullName

        $foreign = @()
        foreach ($p in ($sources | Where-Object { $_ })) {
            $text = [System.IO.File]::ReadAllText($p)
            foreach ($m in [regex]::Matches($text, "Import-Module\s+(?<path>[^;\r\n]+?)\s+-(?<flags>[^\r\n;]*Global[^\r\n;]*)")) {
                $target = $m.Groups['path'].Value.Trim()
                if ($target -match '^\$') { continue }   # a variable path: resolved at runtime, checked by the owner
                # Strip any argument part that follows the path.
                $path = $target
                if ($path -match '^(?<p>''[^'']+''|"[^"]+")') { $path = $Matches['p'] }
                $path = $path.Trim("'", '"')
                if ($path -match '^[A-Za-z]:\\' -or $path -match '^/') { $foreign += "$([System.IO.Path]::GetFileName($p)): $path"; continue }
                # A relative path is fine as long as it resolves inside the tool.
                $resolved = $null
                try { $resolved = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $p) $path)) } catch { }
                if ($resolved -and -not $resolved.StartsWith($toolRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $foreign += "$([System.IO.Path]::GetFileName($p)): $path"
                }
            }
        }
        $foreign | Should -BeNullOrEmpty -Because "the global scope must only ever carry this tool's own modules: $($foreign -join ', ')"
    }

    It 'never force-reimports an already loaded module' {
        # A nested `Import-Module <mod> -Force` on PowerShell 5.1 orphans the
        # already loaded instance: the global copy loses its exported
        # commands and every module that resolved them from it suddenly gets
        # CommandNotFoundException. -Force is only safe on a FIRST import.
        $offenders = @()
        foreach ($p in @((Get-ChildItem (Join-Path $script:HygToolRoot 'Modules') -Filter *.psm1 -File).FullName)) {
            $text = [System.IO.File]::ReadAllText($p)
            foreach ($m in [regex]::Matches($text, "(?m)Import-Module\s+[^;\r\n]*-Force[^\r\n;]*-Global")) {
                $line = $m.Value
                # An import guarded by a "not already loaded" check is safe.
                $idx = $text.IndexOf($line)
                $before = if ($idx -gt 400) { $text.Substring([Math]::Max(0, $idx - 400), [Math]::Min(400, $idx)) } else { $text.Substring(0, [Math]::Max(0, $idx)) }
                if ($before -match 'Get-Module\s+-Name') { continue }
                $offenders += "$([System.IO.Path]::GetFileName($p)): $($line.Trim())"
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "a -Force -Global re-import orphans the loaded instance on PS 5.1: $($offenders -join ' | ')"
    }
}

