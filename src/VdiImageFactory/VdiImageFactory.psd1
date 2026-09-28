@{
    RootModule = 'VdiImageFactory.psm1'
    ModuleVersion = '0.4.0'
    GUID = 'dd923999-330c-43ee-8f3f-7e79ddc90c8a'
    Author = 'Mateus Gandara'
    CompanyName = 'Community'
    Copyright = '(c) 2026 Mateus Gandara. All rights reserved.'
    Description = 'Build and publish repeatable Citrix VDI golden images.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Complete-VdiImage'
        'ConvertTo-VdiMcsPlanScript'
        'ConvertTo-VdiPackerVariable'
        'Get-VdiBuildReference'
        'Get-VdiMachineName'
        'Install-VdiApplication'
        'Invoke-CitrixOptimizer'
        'Invoke-VdiImagePipeline'
        'Publish-McsImage'
        'Resolve-VdiApplicationCatalog'
        'Test-VdiBuildConfiguration'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Citrix', 'VDI', 'Packer', 'MCS', 'GoldenImage')
            LicenseUri = 'https://opensource.org/license/mit'
            ProjectUri = 'https://github.com/gandara-dev/vdi-image-factory'
        }
    }
}
