@{
    RootModule = 'CitrixCatalogBaseline.psm1'
    ModuleVersion = '0.1.0'
    GUID = '8b720de2-ea8a-43f5-8cb7-03395d84d9cb'
    Author = 'Mateus Gandara'
    Description = 'Inventory and access review for Citrix Virtual Apps and Desktops machine catalogs: machines, software, and who can reach each catalog, with deterministic recommendations.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-CcbRecommendation',
        'Get-CcbSiteSnapshot',
        'New-CcbReport',
        'New-CcbSyntheticSnapshot',
        'Protect-CcbSnapshot',
        'Resolve-CcbAccess',
        'Test-CcbSnapshot'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            LicenseUri = 'https://github.com/gandara-dev/citrix-catalog-baseline/blob/main/LICENSE'
            ProjectUri = 'https://github.com/gandara-dev/citrix-catalog-baseline'
        }
    }
}
