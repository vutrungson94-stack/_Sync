#Requires -Version 5.1
# Locale.psm1 - Runtime i18n resource loader for multi-language messages
# Uses resource files in Locales/*.json; graceful-degrade to English if locale missing.

$script:LocaleResources = @{}
$script:CurrentLocale  = 'en'

function Get-CurrentLocale {
    return $script:CurrentLocale
}

function Set-CurrentLocale {
    param([string]$Locale)

Set-StrictMode -Version 1.0
    $resFile = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Locales') "$Locale.json"
    if (-not (Test-Path $resFile)) {
        Write-Warning (Get-LocaleMessage -Key 'gsync.msg.locale.notFound' -MessageArgs @($Locale, $script:CurrentLocale))
        return
    }
    $script:CurrentLocale = $Locale
}

function Import-LocaleResource {
    param([string]$Locale = $script:CurrentLocale)
    $resFile = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Locales') "$Locale.json"
    if (Test-Path $resFile) {
        try {
            $json = Get-Content $resFile -Raw -Encoding UTF8
            try {
                $script:LocaleResources[$Locale] = ($json | ConvertFrom-Json -AsHashtable -Depth 5 -ErrorAction Stop)
            } catch {
                # PS 5.1 fallback: no -AsHashtable, convert PSCustomObject manually
                $obj = ($json | ConvertFrom-Json)
                $script:LocaleResources[$Locale] = ConvertTo-LocaleHashtable -InputObject $obj
            }
        } catch {
            $script:LocaleResources[$Locale] = @{}
        }
    } else {
        $script:LocaleResources[$Locale] = @{}
    }
}

function ConvertTo-LocaleHashtable {
    param($InputObject)
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject }
    $ht = @{}
    if ($InputObject -is [PSCustomObject]) {
        foreach ($p in $InputObject.PSObject.Properties) {
            $v = $p.Value
            if ($v -is [PSCustomObject]) { $v = ConvertTo-LocaleHashtable -InputObject $v }
            $ht[$p.Name] = $v
        }
    }
    return $ht
}

function Resolve-LocaleValue {
    <#
    .SYNOPSIS
        Looks a key up in a locale resource table.
    .DESCRIPTION
        The shipped Locales/*.json catalogs are FLAT: the key is the literal
        property name, e.g. "menu.help" -> "Help". A nested-path walk alone
        asked the table for "menu", found nothing, and every lookup degraded
        to returning the key name - the i18n system produced key names in
        every language. The flat key is therefore tried FIRST; the nested walk
        is kept as a fallback for catalogs authored in the nested form.
    #>
    [CmdletBinding()]
    param($Resources, [Parameter(Mandatory)][string]$Key)
    if ($null -eq $Resources) { return $null }

    if ($Resources -is [System.Collections.IDictionary]) {
        if ($Resources.Contains($Key)) {
            $flat = $Resources[$Key]
            if ($null -ne $flat) { return $flat }
        }
    } else {
        $flatProp = $Resources.PSObject.Properties[$Key]
        if ($flatProp -and $null -ne $flatProp.Value) { return $flatProp.Value }
    }

    $val = $Resources
    foreach ($k in $Key.Split('.')) {
        if ($val -and $val -is [System.Collections.IDictionary]) { $val = $val[$k] }
        else { $val = $null; break }
    }
    return $val
}

function Get-LocaleMessage {
    <#
    .SYNOPSIS
        Resolves a locale key to its text.
    .DESCRIPTION
        The parameter contract is IDENTICAL to _Build's Get-LocaleMessage,
        and that is deliberate. The two tools ship the same command name, so
        whichever module is imported last decides which one the session sees.
        They used to disagree: _Build took -MessageArgs and -Fallback, _Sync
        took -Args and had no -Fallback. A call site in one tool therefore
        threw a parameter-binding error as soon as the other tool's module
        had been imported - the same call worked in isolation and failed in
        the suite. Both sides now accept -MessageArgs (alias -Args),
        -Locale and -Fallback, in the same positional order.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Alias('Args')][object[]]$MessageArgs = @(),
        [string]$Locale = '',
        [string]$Fallback = ''
    )
    if (-not $Locale) { $Locale = Get-CurrentLocale }
    if (-not $script:LocaleResources.ContainsKey($Locale)) {
        Import-LocaleResource -Locale $Locale
    }
    # Ensure English fallback is loaded for missing-key fallback
    if ($Locale -ne 'en' -and -not $script:LocaleResources.ContainsKey('en')) {
        Import-LocaleResource -Locale 'en'
    }
    $val = Resolve-LocaleValue -Resources $script:LocaleResources[$Locale] -Key $Key
    if ($null -eq $val -and $Locale -ne 'en' -and $script:LocaleResources.ContainsKey('en')) {
        $fallbackText = Resolve-LocaleValue -Resources $script:LocaleResources['en'] -Key $Key
        if ($null -ne $fallbackText) { $val = $fallbackText }
    }
    $msg = if ($null -ne $val) { [string]$val } else { $null }
    if ($null -eq $msg) {
        # No catalog entry: the call-site fallback, formatted the same way.
        if (-not [string]::IsNullOrEmpty($Fallback)) {
            $msg = $Fallback
        } else {
            return $Key
        }
    }
    if ($MessageArgs -and $MessageArgs.Length -gt 0) {
        try { return [string]::Format($msg, [object[]]$MessageArgs) } catch { return $msg }
    }
    return $msg
}

function Get-MenuLabel {
    param([string]$Key, [string]$Locale = $script:CurrentLocale)
    return Get-LocaleMessage -Key $Key -Locale $Locale
}

# Pre-load default locale (English) so first call never hits missing-resource path
Import-LocaleResource -Locale 'en'

Export-ModuleMember -Function @('Get-CurrentLocale','Set-CurrentLocale','Import-LocaleResource','Get-LocaleMessage','Get-MenuLabel','Resolve-LocaleValue')
