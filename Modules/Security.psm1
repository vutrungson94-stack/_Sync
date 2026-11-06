#Requires -Version 5.1
# Security.psm1 - secret scanning, sensitive-file gate, dependency and license
# audit for _Sync Platform.
# Convention: no external runtime deps, PS 5.1 safe.
#
# Native to _Sync. The public surface consumed by the rest of the platform:
#   Get-SyncSecretPatternCatalog, Test-SyncSecretContent, Invoke-SyncSecretScan,
#   Get-SecretPatterns, Get-SensitivePatterns, Test-SecretScan,
#   Test-SensitiveFiles, Update-Gitignore, Protect-GSyncString,
#   Unprotect-GSyncString, Get-GSyncAesKeyBytes.
# The security gate itself lives in Invoke-SyncSecurityScan / Test-SyncSecurityGate.

# Make the logger available when this module is imported on its own.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('Config')

$script:SyncSecretPatterns = @(
    '(?i)(sk-or-v1-[a-z0-9]{32,})',
    '(?i)(ghp_[a-z0-9]{36})',
    '(?i)(gho_[a-z0-9]{36})',
    '(?i)(ghu_[a-z0-9]{36})',
    '(?i)(ghs_[a-z0-9]{36})',
    '(?i)(ghr_[a-z0-9]{36})',
    '(?i)(npm_[a-z0-9]{36})',
    '(?i)(token\s*[=:]\s*[a-zA-Z0-9]{20,})',
    '(?i)(password\s*[=:]\s*\S+)',
    '(?i)(AKIA[0-9A-Z]{16})',
    '(?i)(-----BEGIN.*PRIVATE KEY-----)'
)

$script:SyncGitHubSecretPatterns = @(
    '(?i)(sk-or-v1-[a-z0-9]{20,})',
    '(?i)(ghp_[a-z0-9]{36})',
    '(?i)(gho_[a-z0-9]{36})',
    '(?i)(ghu_[a-z0-9]{36})',
    '(?i)(ghs_[a-z0-9]{36})',
    '(?i)(ghr_[a-z0-9]{36})',
    '(?i)(npm_[a-z0-9]{36})',
    '(?i)(token\s*=\s*[a-zA-Z0-9]{20,})',
    '(?i)(AKIA[0-9A-Z]{16})',
    '(?i)(-----BEGIN.*PRIVATE KEY-----)'
)

$script:SyncSensitivePatterns = @(
    '(?i)\.pem$', '(?i)\.key$', '(?i)\.p12$', '(?i)\.pfx$',
    '(?i)\.keystore$', '(?i)\.jks$', '(?i)id_rsa$', '(?i)id_ed25519$',
    '(?i)\.env$', '(?i)\.env\.(local|prod|production)$',
    '(?i)credentials$', '(?i)secrets?\.(json|ya?ml)$',
    '(?i)\.npmrc$', '(?i)\.pypirc$', '(?i)\.netrc$'
)

$script:SyncSensitiveExactNames = @(
    'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519',
    'credentials.json', 'service-account.json'
)

$script:SyncExcludeDirs = @(
    '.git', 'node_modules', 'bin', 'obj', 'dist', 'build', 'out',
    'vendor', '.venv', 'venv', 'coverage', '.sync_snapshots', 'TestResults',
    'logs', '.github', 'publish-output'
)

$script:SyncBinaryExtensions = @(
    '.exe', '.dll', '.so', '.dylib', '.a', '.lib', '.obj', '.o', '.pdb',
    '.zip', '.7z', '.gz', '.tar', '.bz2', '.xz', '.rar',
    '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.svg', '.webp',
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
    '.mp3', '.mp4', '.avi', '.mov', '.mkv', '.wav',
    '.ttf', '.otf', '.woff', '.woff2', '.eot',
    '.db', '.sqlite', '.mdf', '.ldf', '.bin', '.dat', '.class', '.jar', '.war'
)

$script:AuditLogPath = $null

# ── Logging helpers ──────────────────────────────────────────────────────────
function Write-SyncAuditLog {
    [CmdletBinding()]
    param([string]$Message, [string]$Level = 'Info', [string]$Action = '', [string]$Outcome = '', [PSCustomObject]$State = $null, [string]$Detail = '')

Set-StrictMode -Version 1.0
    $line = "[{0}] [{1}] {2}" -f (Get-Date).ToString('o'), $Level, $Message
    try {
        $dir = if ($script:AuditLogPath) { Split-Path -Parent $script:AuditLogPath } else { $null }
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ($script:AuditLogPath) {
            Add-Content -LiteralPath $script:AuditLogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    } catch { }
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        try { Write-Log $Message -Level $Level } catch { }
    }
}

function Reset-SyncAuditLogPath {
    param([string]$Path = '')
    $script:AuditLogPath = $Path
}

# ── Config access ────────────────────────────────────────────────────────────
function Get-SecurityConfigValue {
    [CmdletBinding()]
    param([PSCustomObject]$State, [string]$Path, $Default = $null)
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
        try { return Get-ConfigValue -Path $Path -State $State -Default $Default } catch { }
    }
    return $Default
}

# ── Pattern catalog ──────────────────────────────────────────────────────────
function Get-SyncSecretPatternCatalog {
    <#
    .SYNOPSIS
        Returns the canonical secret-detection regex catalog.
    .PARAMETER GitHubOnly
        Restrict the catalog to the GitHub/npm token families.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([switch]$GitHubOnly)
    if ($GitHubOnly) { return @($script:SyncGitHubSecretPatterns) }
    return @($script:SyncSecretPatterns)
}

function Get-SecretPatterns {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([PSCustomObject]$State = $null)
    $cfg = Get-SecurityConfigValue -State $State -Path 'security.secretPatterns' -Default $null
    if ($cfg -and @($cfg).Count -gt 0) { return @($cfg) }
    return @(Get-SyncSecretPatternCatalog)
}

function Get-SensitivePatterns {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([PSCustomObject]$State = $null)
    $cfg = Get-SecurityConfigValue -State $State -Path 'security.sensitivePatterns' -Default $null
    if ($cfg -and @($cfg).Count -gt 0) { return @($cfg) }
    return @($script:SyncSensitivePatterns)
}

# ── Content scanning ─────────────────────────────────────────────────────────
function Test-SyncSecretContent {
    <#
    .SYNOPSIS
        Returns $true when the given text matches any secret pattern.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Content,
        [string[]]$Patterns = @()
    )
    if ([string]::IsNullOrEmpty($Content)) { return $false }
    if (-not $Patterns -or $Patterns.Count -eq 0) { $Patterns = @(Get-SyncSecretPatternCatalog) }
    foreach ($p in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        try {
            if ($Content -match $p) { return $true }
        } catch { }
    }
    return $false
}

function Test-SyncPatternDefinitionLine {
    <#
    .SYNOPSIS
        Returns $true when the line is a pattern/replacement DEFINITION.
    .DESCRIPTION
        A secret scanner that cannot tell a definition from a value reports
        its own catalog as a leak: the config carries the pattern list, the
        plugin mirrors it and the module defines it. Two shapes are treated
        as definitions and never as findings:
          - a quoted inline-flag regex literal  '(?i)(ghp_[a-z0-9]{36})'
          - a config field that carries a pattern or its replacement
            "pattern": "password\\s*[=:]\\s*\\S+"
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Line)
    if ([string]::IsNullOrEmpty($Line)) { return $false }
    if ($Line -match "['`"]\(\?") { return $true }
    if ($Line -match "['`"](pattern|replacement|secretPatterns|redactPatterns)['`"]\s*:") { return $true }
    return $false
}

function Invoke-SyncSecretScan {
    <#
    .SYNOPSIS
        Scans files (or a whole tool root) for secret patterns.
    .DESCRIPTION
        Two call shapes are supported because the platform needs both:
          - Files: the staged-file list produced by git (used by the pre-commit
            hook and by AutoCommit).
          - ToolRoot: a whole-tree scan used by the security gate.
        Findings are {File, Pattern, Line} objects.

        A line that IS a pattern definition (a quoted regex literal such as
        '(?i)(ghp_[a-z0-9]{36})') is not a finding. Without that exemption the
        scanner matches its own catalog, the plugin mirror and the config that
        carries the pattern list, and the gate reports three phantom secrets on
        a clean tree.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [string[]]$Files = @(),
        [string[]]$Patterns = @(),
        [string]$ToolRoot = '',
        [switch]$NonInteractive,
        [int]$MaxFiles = 5000
    )
    if (-not $Patterns -or $Patterns.Count -eq 0) { $Patterns = @(Get-SyncSecretPatternCatalog) }

    $targets = @()
    if ($ToolRoot) {
        $root = (Resolve-Path -LiteralPath $ToolRoot -ErrorAction SilentlyContinue)
        if (-not $root) { return @() }
        $scanned = 0
        foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            if ($scanned -ge $MaxFiles) { break }
            $skip = $false
            foreach ($seg in ($f.FullName -split '[\\/]')) {
                if ($script:SyncExcludeDirs -contains $seg) { $skip = $true; break }
            }
            if ($skip) { continue }
            if ($script:SyncBinaryExtensions -contains $f.Extension.ToLowerInvariant()) { continue }
            $targets += $f.FullName
            $scanned++
        }
    } else {
        foreach ($f in $Files) {
            if ($f -and (Test-Path -LiteralPath $f -PathType Leaf)) { $targets += $f }
        }
    }

    $findings = @()
    foreach ($file in $targets) {
        $content = $null
        try { $content = Get-Content -LiteralPath $file -Raw -ErrorAction Stop } catch { continue }
        if ($null -eq $content) { continue }
        $lines = $content -split "`r?`n"
        foreach ($p in $Patterns) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $hit = $false
            $lineNo = 0
            try {
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -notmatch $p) { continue }
                    # A quoted regex literal or a pattern/replacement field is a
                    # pattern DEFINITION, not a secret.
                    if (Test-SyncPatternDefinitionLine -Line $lines[$i]) { continue }
                    $hit = $true; $lineNo = $i + 1; break
                }
            } catch { continue }
            if ($hit) {
                $findings += [PSCustomObject]@{
                    File    = $file
                    Pattern = $p
                    Line    = $lineNo
                }
            }
        }
    }
    return @($findings)
}

function Test-SecretScan {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string[]]$Files = @(),
        [string[]]$Patterns = @(),
        [string]$ToolRoot = ''
    )
    $findings = Invoke-SyncSecretScan -Files $Files -Patterns $Patterns -ToolRoot $ToolRoot
    return (@($findings).Count -gt 0)
}

function Find-SecretsInFile {
    [CmdletBinding()]
    param([Alias('FilePath')][string]$Path, [string[]]$Patterns = @(), [int]$ContextLines = -1, [PSCustomObject]$State = $null)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @(Invoke-SyncSecretScan -Files @($Path) -Patterns $Patterns)
}

# ── Sensitive files ──────────────────────────────────────────────────────────
function Test-SensitiveFiles {
    <#
    .SYNOPSIS
        Returns the sensitive files present in a git status listing.
    .PARAMETER Status
        Raw `git status --porcelain` text (or an array of paths).
    .PARAMETER Config
        The loaded gsync config; security.sensitivePatterns may override the
        built-in catalog.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$Status = '',
        [string[]]$StatusPaths = @(),
        [PSCustomObject]$Config = $null
    )
    $patterns = @()
    if ($Config) {
        $cfg = Get-SecurityConfigValue -State $Config -Path 'security.sensitivePatterns' -Default $null
        if ($cfg -and @($cfg).Count -gt 0) { $patterns = @($cfg) }
    }
    if ($patterns.Count -eq 0) { $patterns = @($script:SyncSensitivePatterns) }

    $paths = @()
    if ($StatusPaths -and $StatusPaths.Count -gt 0) {
        $paths = @($StatusPaths)
    } elseif ($Status) {
        foreach ($line in ($Status -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $p = $line.Trim()
            if ($p.Length -gt 3) { $p = $p.Substring(3).Trim() }
            if ($p -match '"(.+)"') { $p = $Matches[1] }
            if ($p) { $paths += $p }
        }
    }

    $blocked = @()
    foreach ($p in $paths) {
        $leaf = Split-Path -Leaf $p
        $hit = $false
        if ($script:SyncSensitiveExactNames -contains $leaf) { $hit = $true }
        if (-not $hit) {
            foreach ($pat in $patterns) {
                if ([string]::IsNullOrWhiteSpace($pat)) { continue }
                try { if ($leaf -match $pat -or $p -match $pat) { $hit = $true; break } } catch { }
            }
        }
        if ($hit) { $blocked += $p }
    }
    return @($blocked)
}

# ── .gitignore maintenance ───────────────────────────────────────────────────
function Update-Gitignore {
    <#
    .SYNOPSIS
        Ensures the given rules exist in the working directory's .gitignore.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Rules = @(),
        [string]$WorkingDir = ''
    )
    if (-not $Rules -or $Rules.Count -eq 0) { return $false }
    $dir = if ($WorkingDir) { $WorkingDir } else { (Get-Location).Path }
    # Anti-leak guard: never write a .gitignore into a workspace root that merely
    # holds the platform tool folders. Such a folder is not a project and writing
    # there is exactly how a stray .gitignore escapes the _Sync system.
    $toolFolderNames = @('_Build', '_Sync', '_Tests')
    $holdsPlatformFolders = @($toolFolderNames | Where-Object { Test-Path -LiteralPath (Join-Path $dir $_) -PathType Container }).Count -gt 0
    $isPlatformFolder = @((($dir -replace '\\', '/') -split '/') | Where-Object { $_ -in $toolFolderNames }).Count -gt 0
    if ($holdsPlatformFolders -and -not $isPlatformFolder) { return $false }
    $gitignore = Join-Path $dir '.gitignore'
    $existing = @()
    if (Test-Path -LiteralPath $gitignore) {
        $existing = @(Get-Content -LiteralPath $gitignore -ErrorAction SilentlyContinue)
    }
    $normalized = @($existing | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $added = @()
    foreach ($rule in $Rules) {
        if ([string]::IsNullOrWhiteSpace($rule)) { continue }
        $r = $rule.Trim()
        if ($normalized -notcontains $r) { $added += $r }
    }
    if ($added.Count -eq 0) { return $false }
    try {
        $lines = @()
        if ($existing.Count -gt 0) { $lines = @($existing) }
        $lines += ''
        $lines += '# --- added by gsync security gate ---'
        $lines += $added
        Set-Content -LiteralPath $gitignore -Value $lines -Encoding UTF8 -ErrorAction Stop
        return $true
    } catch {
        Write-SyncAuditLog "Failed to update .gitignore: $($_.Exception.Message)" 'Warn'
        return $false
    }
}

# ── Encrypted state ──────────────────────────────────────────────────────────
function Get-GSyncAesKeyBytes {
    [CmdletBinding()]
    param([string]$Key = '')
    if (-not $Key) { $Key = [Environment]::GetEnvironmentVariable('GSYNC_STATE_KEY') }
    if (-not $Key) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Key))
        return $bytes
    } finally { $sha.Dispose() }
}

function Protect-GSyncString {
    <#
    .SYNOPSIS
        Encrypts a string with AES-256 (key from GSYNC_STATE_KEY).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Value, [string]$Key = '')
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    $keyBytes = Get-GSyncAesKeyBytes -Key $Key
    if (-not $keyBytes) { throw (Get-LocaleMessage -Key 'gsync.msg.security.noStateKey') }
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $keyBytes
        $aes.GenerateIV()
        $enc = $aes.CreateEncryptor()
        $cipher = $enc.TransformFinalBlock([System.Text.Encoding]::UTF8.GetBytes($Value), 0, ([System.Text.Encoding]::UTF8.GetByteCount($Value)))
        return ([Convert]::ToBase64String($aes.IV) + ':' + [Convert]::ToBase64String($cipher))
    } finally { $aes.Dispose() }
}

function Unprotect-GSyncString {
    <#
    .SYNOPSIS
        Decrypts a value produced by Protect-GSyncString.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Value, [string]$Key = '')
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    $keyBytes = Get-GSyncAesKeyBytes -Key $Key
    if (-not $keyBytes) { throw (Get-LocaleMessage -Key 'gsync.msg.security.noStateKeyUnprotect') }
    $parts = $Value -split ':'
    if ($parts.Count -ne 2) { throw (Get-LocaleMessage -Key 'gsync.msg.security.malformed') }
    $iv = [Convert]::FromBase64String($parts[0])
    $cipher = [Convert]::FromBase64String($parts[1])
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $keyBytes
        $aes.IV = $iv
        $dec = $aes.CreateDecryptor()
        $plain = $dec.TransformFinalBlock($cipher, 0, $cipher.Length)
        return [System.Text.Encoding]::UTF8.GetString($plain)
    } finally { $aes.Dispose() }
}

function Get-SyncDependencyInventoryFallback {
    <#
    .SYNOPSIS
        Minimal dependency inventory used when Security.psm1 is unavailable.
    #>
    [CmdletBinding()]
    param([string]$Root = '')
    $items = @()
    if (-not $Root) { $Root = (Get-Location).Path }
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @('package.json', 'requirements.txt', 'go.mod', 'Cargo.toml') -or $_.Extension -eq '.csproj' })) {
        try {
            if ($f.Name -eq 'package.json') {
                $json = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
                foreach ($p in $json.dependencies.PSObject.Properties) {
                    $items += [PSCustomObject]@{ Ecosystem = 'npm'; Name = $p.Name; Version = [string]$p.Value; Manifest = $f.FullName; Scope = 'runtime' }
                }
            }
        } catch { }
    }
    return @($items)
}

# ── Dependency audit ─────────────────────────────────────────────────────────
function Get-SyncDependencyInventory {
    <#
    .SYNOPSIS
        Reads the declared dependencies of the tool root.
    .DESCRIPTION
        _Sync is a PowerShell tool with no package manifest of its own, so the
        inventory is derived from the manifests that do exist in the tree
        (package.json, requirements.txt, *.csproj, go.mod, Cargo.toml).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param([string]$Root = '')
    if (-not $Root) { $Root = (Get-Location).Path }
    $items = @()
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @('package.json', 'requirements.txt', 'go.mod', 'Cargo.toml') -or $_.Extension -eq '.csproj' })) {
        $dir = $f.DirectoryName
        switch ($f.Name) {
            'package.json' {
                try {
                    $json = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
                    foreach ($p in $json.dependencies.PSObject.Properties) {
                        $items += [PSCustomObject]@{ Ecosystem = 'npm'; Name = $p.Name; Version = [string]$p.Value; Manifest = $f.FullName; Scope = 'runtime' }
                    }
                    foreach ($p in $json.devDependencies.PSObject.Properties) {
                        $items += [PSCustomObject]@{ Ecosystem = 'npm'; Name = $p.Name; Version = [string]$p.Value; Manifest = $f.FullName; Scope = 'dev' }
                    }
                } catch { }
            }
            'requirements.txt' {
                $n = 0
                foreach ($line in (Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)) {
                    $n++
                    $t = $line.Trim()
                    if (-not $t -or $t.StartsWith('#')) { continue }
                    if ($t -match '^([A-Za-z0-9_.-]+)\s*==\s*([^\s;#]+)') {
                        $items += [PSCustomObject]@{ Ecosystem = 'pypi'; Name = $Matches[1]; Version = $Matches[2]; Manifest = $f.FullName; Scope = 'runtime' }
                    } elseif ($t -match '^([A-Za-z0-9_.-]+)') {
                        $items += [PSCustomObject]@{ Ecosystem = 'pypi'; Name = $Matches[1]; Version = ''; Manifest = $f.FullName; Scope = 'runtime' }
                    }
                }
            }
            'go.mod' {
                foreach ($line in (Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)) {
                    if ($line -match '^\s*([a-z0-9./-]+)\s+(v[^\s]+)') {
                        $items += [PSCustomObject]@{ Ecosystem = 'go'; Name = $Matches[1]; Version = $Matches[2]; Manifest = $f.FullName; Scope = 'runtime' }
                    }
                }
            }
            'Cargo.toml' {
                $inDeps = $false
                foreach ($line in (Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)) {
                    if ($line -match '^\[(.+)\]') { $inDeps = ($Matches[1] -match 'dependencies'); continue }
                    if ($inDeps -and $line -match '^([A-Za-z0-9_-]+)\s*=\s*"?([^"]+)"?') {
                        $items += [PSCustomObject]@{ Ecosystem = 'cargo'; Name = $Matches[1]; Version = $Matches[2]; Manifest = $f.FullName; Scope = 'runtime' }
                    }
                }
            }
            default {
                if ($f.Extension -eq '.csproj') {
                    try {
                        [xml]$x = Get-Content -LiteralPath $f.FullName -Raw
                        foreach ($node in $x.Project.ItemGroup.PackageReference) {
                            if ($null -ne $node) {
                                $items += [PSCustomObject]@{ Ecosystem = 'nuget'; Name = [string]$node.Include; Version = [string]$node.Version; Manifest = $f.FullName; Scope = 'runtime' }
                            }
                        }
                    } catch { }
                }
            }
        }
    }
    return @($items | Sort-Object Ecosystem, Name -Unique)
}

function Test-SyncVulnerablePackages {
    <#
    .SYNOPSIS
        Matches the dependency inventory against a deny-list.
    .DESCRIPTION
        A deny-list of ecosystem/name/version triples. The audit is offline and
        deterministic: it does not shell out to a network vulnerability feed, so
        it can run in CI without credentials.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [string]$Root = '',
        [string[]]$DenyList = @(),
        [string[]]$AllowList = @()
    )
    $inventory = @(Get-SyncDependencyInventory -Root $Root)
    $findings = @()
    foreach ($dep in $inventory) {
        foreach ($deny in $DenyList) {
            if (-not $deny) { continue }
            $parts = $deny -split ':'
            if ($parts.Count -lt 2) { continue }
            $eco = $parts[0]; $name = $parts[1]
            $ver = if ($parts.Count -ge 3) { $parts[2] } else { '' }
            if ($dep.Ecosystem -ne $eco) { continue }
            if ($dep.Name -ne $name) { continue }
            if ($ver -and $dep.Version -and $dep.Version -ne $ver) { continue }
            if ($AllowList -contains $deny) { continue }
            $findings += [PSCustomObject]@{ Ecosystem = $dep.Ecosystem; Name = $dep.Name; Version = $dep.Version; Rule = $deny }
            break
        }
    }
    return @($findings)
}

function Test-SyncLicenseCompliance {
    <#
    .SYNOPSIS
        Checks declared dependency licenses against an allow-list.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [string]$Root = '',
        [string[]]$AllowedLicenses = @('MIT', 'Apache-2.0', 'BSD-2-Clause', 'BSD-3-Clause', 'ISC', 'MIT-0', 'Unlicense', '0BSD', 'MPL-2.0', 'Python-2.0', 'Zlib')
    )
    $findings = @()
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'package.json' -Force -ErrorAction SilentlyContinue)) {
        try {
            $json = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            foreach ($p in $json.dependencies.PSObject.Properties) {
                $lic = $null
                if ($json.licenses -and $json.licenses.PSObject.Properties.Name -contains $p.Name) {
                    $lic = [string]$json.licenses.($p.Name)
                }
                if (-not $lic) { continue }
                $norm = $lic -replace '\s*\(.*\)$', ''
                if ($AllowedLicenses -notcontains $norm) {
                    $findings += [PSCustomObject]@{ Ecosystem = 'npm'; Name = $p.Name; License = $norm; Manifest = $f.FullName }
                }
            }
        } catch { }
    }
    return @($findings)
}

# ── Security gate ────────────────────────────────────────────────────────────
function Invoke-SyncSecurityScan {
    <#
    .SYNOPSIS
        Runs the full _Sync security gate.
    .DESCRIPTION
        Three checks, in order of severity:
          1. secret scan over the tool root
          2. sensitive files that would be committed
          3. vulnerable / non-compliant dependencies
        The result object is the gate contract: Passed, Findings, Checks.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$Root = '',
        [PSCustomObject]$Config = $null,
        [string[]]$DenyList = @(),
        [string[]]$AllowList = @(),
        [switch]$SkipDependencies
    )
    if (-not $Root) { $Root = (Get-Location).Path }
    $findings = @()
    $checks = @()

    $secretFindings = @(Invoke-SyncSecretScan -ToolRoot $Root)
    $checks += [PSCustomObject]@{ Check = 'secretScan'; Passed = ($secretFindings.Count -eq 0); Count = $secretFindings.Count }
    foreach ($f in $secretFindings) {
        $findings += [PSCustomObject]@{ Check = 'secretScan'; Severity = 'error'; File = $f.File; Line = $f.Line; Detail = $f.Pattern }
    }

    $status = ''
    try { $status = (& git -C $Root status --porcelain 2>$null | Out-String) } catch { }
    $sensitive = @(Test-SensitiveFiles -Status $status -Config $Config)
    $checks += [PSCustomObject]@{ Check = 'sensitiveFiles'; Passed = ($sensitive.Count -eq 0); Count = $sensitive.Count }
    foreach ($s in $sensitive) {
        $findings += [PSCustomObject]@{ Check = 'sensitiveFiles'; Severity = 'error'; File = $s; Line = 0; Detail = 'sensitive file' }
    }

    if (-not $SkipDependencies) {
        $vuln = @(Test-SyncVulnerablePackages -Root $Root -DenyList $DenyList -AllowList $AllowList)
        $checks += [PSCustomObject]@{ Check = 'vulnerablePackages'; Passed = ($vuln.Count -eq 0); Count = $vuln.Count }
        foreach ($v in $vuln) {
            $findings += [PSCustomObject]@{ Check = 'vulnerablePackages'; Severity = 'error'; File = $v.Name; Line = 0; Detail = "$($v.Ecosystem):$($v.Version) denied by $($v.Rule)" }
        }
    }

    $errors = @($findings | Where-Object { $_.Severity -eq 'error' })
    return [PSCustomObject]@{
        Passed   = ($errors.Count -eq 0)
        Findings = @($findings)
        Errors   = @($errors)
        Checks   = @($checks)
        Root     = $Root
    }
}

function Test-SyncSecurityGate {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Root = '', [PSCustomObject]$Config = $null, [string[]]$DenyList = @(), [switch]$SkipDependencies)
    $result = Invoke-SyncSecurityScan -Root $Root -Config $Config -DenyList $DenyList -SkipDependencies:$SkipDependencies
    return [bool]$result.Passed
}

Export-ModuleMember -Function @(
    'Get-SyncSecretPatternCatalog', 'Test-SyncSecretContent', 'Invoke-SyncSecretScan',
    'Get-SecretPatterns', 'Get-SensitivePatterns', 'Test-SecretScan', 'Find-SecretsInFile',
    'Test-SensitiveFiles', 'Update-Gitignore', 'Protect-GSyncString', 'Unprotect-GSyncString',
    'Get-GSyncAesKeyBytes', 'Write-SyncAuditLog', 'Reset-SyncAuditLogPath',
    'Get-SecurityConfigValue', 'Get-SyncDependencyInventory', 'Get-SyncDependencyInventoryFallback',
    'Test-SyncVulnerablePackages', 'Test-SyncLicenseCompliance',
    'Invoke-SyncSecurityScan', 'Test-SyncSecurityGate', 'Test-SyncPatternDefinitionLine'
)
