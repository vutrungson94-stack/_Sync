@{
    RootModule        = 'gsync.module.psm1'
    ModuleVersion     = '6.0.0'
    GUID              = '7c9e4a1f-3b2d-4e5f-8a6b-1c2d3e4f5a6b'
    Author            = 'GBuild Team'
    CompanyName       = 'MultiAiAgent'
    Copyright         = '(c) 2026. All rights reserved.'
    Description       = 'Sync Platform - self-contained git sync engine with rollback recovery and plugin execution'

    RequiredModules   = @()
    # The manifest must declare exactly what the root module exports. It
    # listed 30 functions, of which the module exported one - the rest came
    # from Core/ and Providers/ modules that the live path never reached.
    FunctionsToExport = @(
        'Start-GSync',
        'Invoke-GSyncFailureRecovery',
        'Invoke-EnabledSyncPlugins'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('sync', 'git', 'devops', 'platform', 'enterprise')
            ProjectUri = 'https://github.com/example/gsync'
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
