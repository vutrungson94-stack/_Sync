# PathNormalization.Tests.ps1 - Integration tests for cross-platform path handling
#Requires -Version 5.1

# Load module globally so Pester 5.x It blocks can see it
Import-Module (Join-Path $PSScriptRoot '../Modules/PathNormalization.psm1') -Force -DisableNameChecking -Scope Global

Describe "PathNormalization Module" {
    Context "ConvertTo-RepoPath" {
        It "Should convert backslashes to forward slashes on Windows" {
            $result = ConvertTo-RepoPath -Path "folder\subfolder\file.txt"
            $result | Should -Be "folder/subfolder/file.txt"
        }

        It "Should keep forward slashes as-is" {
            $result = ConvertTo-RepoPath -Path "folder/subfolder/file.txt"
            $result | Should -Be "folder/subfolder/file.txt"
        }

        It "Should handle empty path" {
            $result = ConvertTo-RepoPath -Path ""
            $result | Should -Be ""
        }
    }

    Context "Get-RelativePath" {
        It "Should compute relative path from repo root" {
            $result = Get-RelativePath -Path "C:\projects\repo\src\file.cs" -RepoRoot "C:\projects\repo"
            $result | Should -Be "src/file.cs"
        }

        It "Should return normalized path when path not under root" {
            $result = Get-RelativePath -Path "D:\other\file.txt" -RepoRoot "C:\projects\repo"
            $result | Should -Be "D:/other/file.txt"
        }
    }

    Context "Join-RepoPath" {
        It "Should join path segments" {
            $result = Join-RepoPath -Paths @("src", "app", "core", "file.cs")
            $result | Should -Be "src/app/core/file.cs"
        }

        It "Should handle single path segment" {
            $result = Join-RepoPath -Paths @("file.txt")
            $result | Should -Be "file.txt"
        }
    }

    Context "Test-PathExcluded" {
        It "Should detect excluded directory" {
            $result = Test-PathExcluded -Path "node_modules/package/index.js" -Patterns @("node_modules/", "bin/")
            $result | Should -Be $true
        }

        It "Should not exclude non-matching path" {
            $result = Test-PathExcluded -Path "src/app/file.js" -Patterns @("node_modules/", "bin/")
            $result | Should -Be $false
        }

        It "Should handle Windows-style backslash paths" {
            $result = Test-PathExcluded -Path "bin\release\app.exe" -Patterns @("node_modules/", "bin/")
            $result | Should -Be $true
        }
    }
}
