#Requires -Version 5.1
Set-StrictMode -Version 1.0
# Python language plugin (thin wrapper over LanguagePlugin.Base.ps1)

$script:PluginName = 'Python'
$script:SupportedLanguages = @('python', 'pyproject.toml', 'requirements.txt')
$script:PluginDescription = 'Python build/test/plugin scaffold for multi-language gsync support'
$script:ManifestFile = 'pyproject.toml'
$script:PreflightWarning = 'python plugin preflight: pytest/ruff required'
$script:BuildCommand = 'python -m build'
$script:TestCommand = 'pytest'
$script:LintCommand = 'ruff check .'

. (Join-Path $PSScriptRoot 'LanguagePlugin.Base.ps1')