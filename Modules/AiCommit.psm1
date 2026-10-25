#Requires -Version 5.1
# AiCommit.psm1 - AI-powered commit summary with graceful multi-language fallback

function New-AiCommitSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ChangedFiles,
        [string]$Locale = 'en',
        [PSCustomObject]$Config = @{}
    )

Set-StrictMode -Version 1.0
    $count = $ChangedFiles.Count
    $names = if ($count -gt 0) { ($ChangedFiles | ForEach-Object { [System.IO.Path]::GetFileName($_) }) -join ', ' } else { 'none' }
    $names = if ($names.Length -gt 80) { $names.Substring(0, 80) + '...' } else { $names }

    # Resolve effective locale: explicit param first, then config, then 'en'
    $eff = $Locale
    if ([string]::IsNullOrWhiteSpace($eff) -and $Config.build -and $Config.build.locale -and $Config.build.locale.default) {
        $eff = [string]$Config.build.locale.default
    }
    if ([string]::IsNullOrWhiteSpace($eff)) { $eff = 'en' }
    $eff = $eff.ToLowerInvariant()

    $templates = @{
        'vi' = @{ Short = 'Thay đổi {0} file: {1}' }
        'en' = @{ Short = 'Modified {0} file(s): {1}' }
        'de' = @{ Short = '{0} Datei(en) geändert: {1}' }
        'es' = @{ Short = '{0} archivo(s) modificado(s): {1}' }
        'fr' = @{ Short = '{0} fichier(s) modifié(s): {1}' }
        'ja' = @{ Short = '{0} ファイル変更: {1}' }
        'zh' = @{ Short = '修改 {0} 个文件: {1}' }
    }
    $t = if ($templates.ContainsKey($eff)) { $templates[$eff] } else { $templates['en'] }
    $msg = if ($count -gt 1) { $t.Short -f $count, $names } elseif ($count -eq 1) { $t.Short -f 1, $names } else { $t.Short -f 0, $names }
    return $msg
}

Export-ModuleMember -Function @('New-AiCommitSummary')
