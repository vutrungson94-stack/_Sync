#Requires -Version 5.1
# Event dependency: canonical Send-GSyncEventSafe lives in EventBus.psm1 (same dir).
if (-not (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'EventBus.psm1') -Force -DisableNameChecking -Scope Global -ErrorAction SilentlyContinue
}

# SmartGitignore.psm1 - Per-project smart .gitignore management (Enterprise)
# Detects project type from file signatures and applies appropriate rules.
# Requires -Version 5.1


# Make the logger available when this module is imported on its own.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('EventBus', 'Security')

# Per-project templates (signature -> rules)
$script:GitignoreTemplates = @{
    'dotnet' = @(
        'bin/','obj/','*.user','*.suo','*.cache','*.pdb','*.dll','*.exe',
        'appsettings.Development.json','appsettings.*.json','*.pubxml',
        '.vs/','*.nupkg','*.snk'
    )
    'node' = @(
        'node_modules/','dist/','build/','.env.local','.env.development.local',
        '.env.test.local','.env.production.local','npm-debug.log*','yarn-debug.log*',
        'yarn-error.log*','package-lock.json','.pnp.*'
    )
    'python' = @(
        '__pycache__/','*.pyc','*.pyo','*.pyd','.venv/','venv/','env/','.env/',
        '*.egg-info/','.pytest_cache/','*.egg','*.manifest','*.spec'
    )
    'java' = @(
        'target/','build/','.gradle/','.mvn/','out/','*.class','*.jar','*.war',
        '*.ear','*.log','*.ctxt','.factorypath'
    )
    'general' = @(
        '.DS_Store','Thumbs.db','*.tmp','*.log','*.swp','*~','.vscode/','.idea/',
        '*.orig','*.rej','.cache/'
    )
}

# Signature files mapped to template key
$script:ProjectSignatures = @{
    '\.csproj$' = 'dotnet'
    '\.sln$' = 'dotnet'
    'package\.json$' = 'node'
    'yarn\.lock$' = 'node'
    'pnpm-lock\.yaml$' = 'node'
    'requirements\.txt$' = 'python'
    'pyproject\.toml$' = 'python'
    'setup\.py$' = 'python'
    'Pipfile$' = 'python'
    'pom\.xml$' = 'java'
    'build\.gradle$' = 'java'
    'settings\.gradle$' = 'java'
    'gradle\.properties$' = 'java'
}

function Get-DetectedProjectType {
    [CmdletBinding()]
    param([string]$Root = (Get-Location), [int]$MaxDepth = 3)

Set-StrictMode -Version 1.0

    if (-not (Test-Path $Root)) { return @('general') }

    $found = @{}
    $dirs = @($Root)
    for ($depth = 0; $depth -lt $MaxDepth; $depth++) {
        $next = @()
        foreach ($d in $dirs) {
            $files = Get-ChildItem -Path $d -File -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
            foreach ($sig in $script:ProjectSignatures.Keys) {
                foreach ($f in $files) {
                    if ($f -match $sig) { $found[$script:ProjectSignatures[$sig]] = $true }
                }
            }
            $next += Get-ChildItem -Path $d -Directory -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        }
        $dirs = $next
        if (-not $dirs) { break }
    }

    if ($found.Count -eq 0) { return @('general') }
    return @($found.Keys)
}

function Get-SmartGitignoreRules {
    [CmdletBinding()]
    param(
        [string[]]$ProjectTypes,
        [string[]]$ExtraRules = @()
    )

    if (-not $ProjectTypes -or $ProjectTypes.Count -eq 0) { $ProjectTypes = @(Get-DetectedProjectType) }

    # Start with security rules (env/secrets)
    $securityRules = @('.env','*.pfx','ssh_id','*.p12','*.key')

    # Add general safety rules
    $rules = @($securityRules)

    # Add project-specific templates (merge all detected types)
    foreach ($pt in $ProjectTypes) {
        if ($script:GitignoreTemplates.ContainsKey($pt)) {
            $rules += $script:GitignoreTemplates[$pt]
        }
    }

    # Always include general rules
    $rules += $script:GitignoreTemplates['general']

    # Add extra rules from config
    if ($ExtraRules -and $ExtraRules.Count -gt 0) { $rules += $ExtraRules }

    # Deduplicate and clean
    $clean = @()
    $seen = @{}
    foreach ($r in $rules) {
        $r = [string]$r
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        $n = $r.Trim()
        if (-not $seen.ContainsKey($n)) {
            $clean += $n
            $seen[$n] = $true
        }
    }
    return $clean
}

function Update-SmartGitignore {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [string]$WorkingDir = (Get-Location)
    )

    if (-not $Config.gitignore.enabled) {
        Write-Log (Get-LocaleMessage -Key 'gsync.msg.gitignore.disabled') -Level Info
        return
    }

    # Merge static + smart rules
    $staticRules = @($Config.gitignore.rulesToAdd)
    $projectTypes = @(Get-DetectedProjectType -Root $WorkingDir)
    $smartRules = Get-SmartGitignoreRules -ProjectTypes $projectTypes -ExtraRules $staticRules

    # Add security patterns from config if any
    if ($Config.security.secretPatterns -and $Config.security.secretPatterns.Count -gt 0) {
        $securityAdditions = @('.env','*.env','secrets.*','*.secret','*.pem','*.p12','*.pfx','ssh_id')
        foreach ($add in $securityAdditions) {
            if ($smartRules -notcontains $add) { $smartRules += $add }
        }
    }

    # Auto-include gsync specific patterns
    $gsyncRules = @('.gsync.state','sync-outputs/')
    foreach ($r in $gsyncRules) {
        if ($smartRules -notcontains $r) { $smartRules += $r }
    }

    # Emit EventBus event if available
    try {
        if (Get-Command Send-BuildEvent -ErrorAction SilentlyContinue) {
            Send-BuildEvent -Name 'gsync.gitignore.smart_applied' -Data @{
                projectType = ($projectTypes -join ',')
                rulesCount = $smartRules.Count
                timestamp = (Get-Date).ToString('o')
            } | Out-Null
        }
    } catch { }

    # Emit event then write to .gitignore
    Update-Gitignore -Rules $smartRules -WorkingDir $WorkingDir
    Send-GSyncEventSafe -Name "gsync.gitignore.applied" -Data @{ projectType = ($projectTypes -join ','); rulesCount = $smartRules.Count } | Out-Null
}

Export-ModuleMember -Function @('Get-DetectedProjectType','Get-SmartGitignoreRules','Update-SmartGitignore')



