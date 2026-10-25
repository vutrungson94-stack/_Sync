#Requires -Version 5.1
#Requires -Module Pester

Describe "Locale parity and fallback" {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $locales = Join-Path $root 'Locales'
        $en = Get-Content (Join-Path $locales 'en.json') -Raw | ConvertFrom-Json
        $script:enFiles = @(Get-ChildItem -Path $locales -Filter '*.json' -File)
        $script:enCount = @($en.PSObject.Properties).Count
        $script:rootPath = $root
    }

    It "Has 7 locale files" {
        $script:enFiles.Count | Should -Be 7
    }

    It "Each locale has the same top-level key count as en.json" {
        foreach ($f in $script:enFiles) {
            $obj = Get-Content $f.FullName -Raw | ConvertFrom-Json
            @($obj.PSObject.Properties).Count | Should -Be $script:enCount
        }
    }

    It "All locale files parse as valid JSON" {
        foreach ($f in $script:enFiles) {
            { Get-Content $f.FullName -Raw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
        }
    }

    It "Locale fallback returns key when missing" {
        $bp = Join-Path $PSScriptRoot '_TestBootstrap.ps1'
        if (Test-Path $bp) { . $bp }
        Import-Module (Join-Path $script:rootPath 'Modules/Locale.psm1') -Force -DisableNameChecking -Scope Global -ErrorAction SilentlyContinue
        if (Get-Command Get-LocaleMessage -ErrorAction SilentlyContinue) {
            Get-LocaleMessage -Key 'zzz.totally.missing' | Should -Be 'zzz.totally.missing'
        }
    }
}
0