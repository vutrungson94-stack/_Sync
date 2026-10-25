#Requires -Version 5.1
Set-StrictMode -Version 1.0
# Node language plugin (thin wrapper over LanguagePlugin.Base.ps1)

$script:PluginName = 'Node'
$script:SupportedLanguages = @('node', 'javascript', 'typescript', 'json')
$script:PluginDescription = 'Node.js build/test/plugin scaffold for multi-language gsync support'
$script:ManifestFile = 'package.json'
$script:PreflightWarning = 'node plugin preflight: npm required'
$script:BuildCommand = 'npm run build'
$script:TestCommand = 'npm test'
$script:LintCommand = 'npm run lint'

. (Join-Path $PSScriptRoot 'LanguagePlugin.Base.ps1')