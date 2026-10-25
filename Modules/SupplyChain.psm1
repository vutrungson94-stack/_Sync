#Requires -Version 5.1
# SupplyChain.psm1

# Declare the sibling modules this one calls into.
. (Join-Path $PSScriptRoot 'ModuleBootstrap.ps1') -Dependencies @('Config', 'Security')
# SBOM generation, provenance and policy gate for _Sync.
# Convention: no external runtime deps, PS 5.1 safe.
#
# The SBOM is emitted in CycloneDX 1.5 JSON. It is built from the dependency
# inventory that Security.psm1 already produces, so the SBOM and the security
# gate always describe the same dependency set - two separate inventories would
# drift and the SBOM would become a document nobody trusts.

$script:SyncSbomSchema = 'http://cyclonedx.org/schema/bom-1.5.schema.json'

function Get-SyncSupplyChainConfig {
    <#
    .SYNOPSIS
        Reads the supplyChain section of the gsync config.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([PSCustomObject]$State = $null)

Set-StrictMode -Version 1.0
    $cfg = @{
        enabled    = $true
        format     = 'cyclonedx'
        outputDir  = 'build-reports'
        sbomName   = 'gsync-sbom.json'
        policy     = @{ enabled = $true; allowList = @(); denyList = @(); enforcement = 'block' }
        provenance = @{ enabled = $true }
    }
    $sc = $null
    if (Get-Command Get-ConfigValue -ErrorAction SilentlyContinue) {
        try { $sc = Get-ConfigValue -Path 'supplyChain' -State $State -Default $null } catch { }
    }
    if ($null -ne $sc) {
        if ($null -ne $sc.enabled) { $cfg.enabled = [bool]$sc.enabled }
        if ($sc.format) { $cfg.format = [string]$sc.format }
        if ($sc.outputDir) { $cfg.outputDir = [string]$sc.outputDir }
        if ($sc.sbomName) { $cfg.sbomName = [string]$sc.sbomName }
        if ($sc.policy) {
            if ($null -ne $sc.policy.enabled) { $cfg.policy.enabled = [bool]$sc.policy.enabled }
            if ($null -ne $sc.policy.allowList) { $cfg.policy.allowList = @($sc.policy.allowList) }
            if ($null -ne $sc.policy.denyList) { $cfg.policy.denyList = @($sc.policy.denyList) }
            if ($sc.policy.enforcement) { $cfg.policy.enforcement = [string]$sc.policy.enforcement }
        }
        if ($sc.provenance -and $null -ne $sc.provenance.enabled) { $cfg.provenance.enabled = [bool]$sc.provenance.enabled }
    }
    return $cfg
}

function Get-SyncSupplyChainReportDir {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Root = '', [PSCustomObject]$State = $null)
    if (-not $Root) { $Root = (Get-Location).Path }
    $cfg = Get-SyncSupplyChainConfig -State $State
    return (Join-Path $Root $cfg.outputDir)
}

function Get-SyncSbomDependencyInventory {
    <#
    .SYNOPSIS
        Dependency inventory for the SBOM.
    .DESCRIPTION
        Delegates to the inventory owner in Security.psm1 so the SBOM and the
        security gate share one dependency set. The call is module-qualified
        on purpose: a plain call would resolve to THIS function again and
        recurse until the call depth overflowed.
    #>
    [CmdletBinding()]
    param([string]$Root = '')
    $secModule = Get-Module -Name 'Security' -ErrorAction SilentlyContinue
    if ($secModule) {
        return @(& $secModule { param($r) Get-SyncDependencyInventory -Root $r } $Root)
    }
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

function ConvertTo-SyncSbomComponent {
    param([PSCustomObject]$Dependency)
    $purl = switch ($Dependency.Ecosystem) {
        'npm'   { "pkg:npm/$($Dependency.Name)@$($Dependency.Version)" }
        'pypi'  { "pkg:pypi/$($Dependency.Name)@$($Dependency.Version)" }
        'go'    { "pkg:golang/$($Dependency.Name)@$($Dependency.Version)" }
        'cargo' { "pkg:cargo/$($Dependency.Name)@$($Dependency.Version)" }
        'nuget' { "pkg:nuget/$($Dependency.Name)@$($Dependency.Version)" }
        default { '' }
    }
    return @{
        type    = 'library'
        name    = $Dependency.Name
        version = $Dependency.Version
        purl    = $purl
        scope   = $Dependency.Scope
    }
}

function New-SyncSbom {
    <#
    .SYNOPSIS
        Builds a CycloneDX 1.5 SBOM document for the tool root.
    .OUTPUTS
        A hashtable that serializes to CycloneDX 1.5 JSON.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Root = '',
        [string]$ToolName = 'gsync',
        [string]$ToolVersion = '',
        [PSCustomObject]$State = $null
    )
    if (-not $Root) { $Root = (Get-Location).Path }
    $deps = @(Get-SyncSbomDependencyInventory -Root $Root)
    $components = @()
    foreach ($d in ($deps | Sort-Object Ecosystem, Name -Unique)) {
        $components += ConvertTo-SyncSbomComponent -Dependency $d
    }
    $rootComponent = @{
        type    = 'application'
        name    = $ToolName
        version = if ($ToolVersion) { $ToolVersion } else { '0.0.0' }
    }
    if ($components.Count -gt 0) {
        $rootComponent.dependencies = @(@{ ref = $rootComponent.name; dependsOn = @($components | ForEach-Object { $_.name }) })
    }
    return @{
        bomFormat   = 'CycloneDX'
        specVersion = '1.5'
        serialNumber = "urn:uuid:$([guid]::NewGuid().ToString())"
        version     = 1
        metadata    = @{
            timestamp = (Get-Date).ToString('o')
            tools     = @(@{ vendor = 'gsync'; name = 'gsync-sbom'; version = $rootComponent.version })
            component = $rootComponent
        }
        components = @($components)
    }
}

function Write-SyncSbom {
    <#
    .SYNOPSIS
        Writes the SBOM document to the supply-chain report directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Root = '',
        [string]$OutputPath = '',
        [string]$ToolName = 'gsync',
        [string]$ToolVersion = '',
        [PSCustomObject]$State = $null
    )
    if (-not $Root) { $Root = (Get-Location).Path }
    $sbom = New-SyncSbom -Root $Root -ToolName $ToolName -ToolVersion $ToolVersion -State $State
    $cfg = Get-SyncSupplyChainConfig -State $State
    if (-not $OutputPath) {
        $dir = Get-SyncSupplyChainReportDir -Root $Root -State $State
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $OutputPath = Join-Path $dir $cfg.sbomName
    } else {
        $parent = Split-Path -Parent $OutputPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    }
    $json = $sbom | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
    return $OutputPath
}

function New-SyncProvenance {
    <#
    .SYNOPSIS
        Builds a provenance record describing where the artifact came from.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Root = '',
        [string]$ToolName = 'gsync',
        [string]$ToolVersion = '',
        [PSCustomObject]$State = $null
    )
    if (-not $Root) { $Root = (Get-Location).Path }
    $commit = $null; $branch = $null; $dirty = $null
    try {
        $commit = (& git -C $Root rev-parse HEAD 2>$null | Out-String).Trim()
        $branch = (& git -C $Root rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
        $dirty = [bool](& git -C $Root status --porcelain 2>$null)
    } catch { }
    return @{
        subject        = @(@{ name = $ToolName; version = $ToolVersion; digest = @{ algorithm = 'sha256'; value = (Get-SyncTreeDigest -Root $Root) } })
        predicateType  = 'https://slsa.dev/provenance/v1'
        buildDefinition = @{
            buildType = 'https://github.com/vutrungson/gsync/actions/runs'
            externalParameters = @{ source = @{ uri = "file://$Root" } }
            internalParameters = @{ branch = $branch; commit = $commit; dirty = $dirty }
        }
        runDetails = @{
            builder = @{ id = "gsync/$ToolName" }
            metadata = @{ invocationId = [guid]::NewGuid().ToString(); startedOn = (Get-Date).ToString('o') }
        }
    }
}

function Get-SyncTreeDigest {
    <#
    .SYNOPSIS
        Computes a stable sha256 digest over the tracked source tree.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Root = '')
    if (-not $Root) { $Root = (Get-Location).Path }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $sb = [System.Text.StringBuilder]::new()
        foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|bin|obj|logs|TestResults|build-reports)[\\/]' } |
                Sort-Object FullName)) {
            [void]$sb.Append($f.FullName.Substring($Root.Length).Replace('\', '/'))
            [void]$sb.Append("`n")
            try { [void]$sb.Append((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash) } catch { }
            [void]$sb.Append("`n")
        }
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sb.ToString()))
        return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Invoke-SyncSbomPolicyGate {
    <#
    .SYNOPSIS
        Applies the SBOM policy (allow-list / deny-list) to an SBOM document.
    .DESCRIPTION
        The policy lists components as ecosystem:name:version. A component on the
        deny-list is a violation; a component explicitly allowed is never a
        violation. With enforcement=block the gate fails the build, with
        enforcement=warn it only reports.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [object]$Sbom = $null,
        [string]$SbomPath = '',
        [string]$Root = '',
        [string[]]$AllowList = @(),
        [string[]]$DenyList = @(),
        [string]$Enforcement = 'block',
        [PSCustomObject]$State = $null
    )
    if (-not $Sbom -and $SbomPath) {
        if (-not (Test-Path -LiteralPath $SbomPath -PathType Leaf)) { throw (Get-LocaleMessage -Key 'gsync.msg.sbom.notFound' -MessageArgs @($SbomPath)) }
        # ConvertFrom-Json yields PSCustomObject, not a hashtable; the parameter
        # is typed [object] so a file-loaded document is accepted too.
        $Sbom = Get-Content -LiteralPath $SbomPath -Raw | ConvertFrom-Json
    }
    if (-not $Sbom) { $Sbom = New-SyncSbom -Root $Root -State $State }
    $cfg = Get-SyncSupplyChainConfig -State $State
    if (-not $AllowList -or $AllowList.Count -eq 0) { $AllowList = @($cfg.policy.allowList) }
    if (-not $DenyList -or $DenyList.Count -eq 0) { $DenyList = @($cfg.policy.denyList) }
    if (-not $Enforcement) { $Enforcement = $cfg.policy.enforcement }

    $violations = @()
    foreach ($c in @($Sbom.components)) {
        $purl = [string]$c.purl
        $eco = ''
        if ($purl -match '^pkg:([a-z]+)/') { $eco = $Matches[1] }
        if (-not $eco) { $eco = [string]$c.type }
        $key = "{0}:{1}:{2}" -f $eco, $c.name, $c.version
        $key2 = "{0}:{1}" -f $eco, $c.name
        if ($AllowList -contains $key -or $AllowList -contains $key2) { continue }
        foreach ($deny in $DenyList) {
            if (-not $deny) { continue }
            if ($deny -eq $key -or $deny -eq $key2) {
                $violations += [PSCustomObject]@{ Component = $c.name; Version = $c.version; Rule = $deny }
                break
            }
        }
    }
    $blocking = ($Enforcement -eq 'block' -and $violations.Count -gt 0)
    return [PSCustomObject]@{
        Passed      = (-not $blocking)
        Violations  = @($violations)
        Enforcement = $Enforcement
        Components  = @($Sbom.components).Count
    }
}

function Invoke-SyncSupplyChainChecks {
    <#
    .SYNOPSIS
        Runs the whole supply-chain stage: SBOM + provenance + policy gate.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$Root = '',
        [string]$ToolName = 'gsync',
        [string]$ToolVersion = '',
        [PSCustomObject]$State = $null
    )
    if (-not $Root) { $Root = (Get-Location).Path }
    $cfg = Get-SyncSupplyChainConfig -State $State
    $sbomPath = ''
    $provenancePath = ''
    if ($cfg.enabled) {
        $sbomPath = Write-SyncSbom -Root $Root -ToolName $ToolName -ToolVersion $ToolVersion -State $State
    }
    if ($cfg.provenance.enabled) {
        $prov = New-SyncProvenance -Root $Root -ToolName $ToolName -ToolVersion $ToolVersion -State $State
        $dir = Get-SyncSupplyChainReportDir -Root $Root -State $State
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $provenancePath = Join-Path $dir 'provenance.json'
        [System.IO.File]::WriteAllText($provenancePath, ($prov | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
    }
    $gate = $null
    if ($cfg.policy.enabled) {
        $gate = Invoke-SyncSbomPolicyGate -SbomPath $sbomPath -Root $Root -State $State
    }
    return [PSCustomObject]@{
        Passed         = $true
        SbomPath       = $sbomPath
        ProvenancePath = $provenancePath
        Policy         = $gate
    }
}

Export-ModuleMember -Function @(
    'Get-SyncSupplyChainConfig', 'Get-SyncSupplyChainReportDir', 'Get-SyncSbomDependencyInventory',
    'New-SyncSbom', 'Write-SyncSbom', 'New-SyncProvenance', 'Get-SyncTreeDigest',
    'Invoke-SyncSbomPolicyGate', 'Invoke-SyncSupplyChainChecks'
)
