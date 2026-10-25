#Requires -Version 5.1
# PathNormalization.psm1 - Cross-platform path handling for _Sync
# Requires -Version 5.1


# Normalize path to forward slashes (cross-platform)
function ConvertTo-RepoPath {
    param([string]$Path)

Set-StrictMode -Version 1.0
    if (-not $Path) { return "" }
    return $Path.Replace('\', '/')
}

# Get relative path from repo root
function Get-RelativePath {
    param([string]$Path, [string]$RepoRoot = (Get-Location))
    $normalized = ConvertTo-RepoPath -Path $Path
    $normalizedRoot = ConvertTo-RepoPath -Path $RepoRoot
    if ($normalized.StartsWith($normalizedRoot)) {
        return $normalized.Substring($normalizedRoot.Length).TrimStart('/')
    }
    return $normalized
}

# Join path segments (PS 5.1 compatible - max 2 args)
function Join-RepoPath {
    param([string[]]$Paths)
    $result = $Paths[0]
    for ($i = 1; $i -lt $Paths.Length; $i++) {
        $result = Join-Path $result $Paths[$i]
    }
    return ConvertTo-RepoPath -Path $result
}

# Check if path is excluded
function Test-PathExcluded {
    param([string]$Path, [string[]]$Patterns)
    $normalized = ConvertTo-RepoPath -Path $Path
    foreach ($p in $Patterns) {
        $dirName = $p.TrimEnd('/').TrimEnd('\')
        if ($normalized.StartsWith("$dirName/")) {
            return $true
        }
    }
    return $false
}

Export-ModuleMember -Function @(
    'ConvertTo-RepoPath', 'Get-RelativePath', 'Join-RepoPath', 'Test-PathExcluded'
)
