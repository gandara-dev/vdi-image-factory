$ErrorActionPreference = 'Stop'

$modulePath = 'C:\Windows\Temp\VdiImageFactory\VdiImageFactory.psd1'
Import-Module $modulePath -Force

$profiles = @($env:VIF_APP_PROFILES -split ',' | Where-Object { $_ })
$includeApplications = @($env:VIF_APP_INCLUDE -split ',' | Where-Object { $_ })
$excludeApplications = @($env:VIF_APP_EXCLUDE -split ',' | Where-Object { $_ })

$applications = @(Install-VdiApplication `
        -CatalogPath $env:VIF_APP_CATALOG `
        -ApplicationProfile $profiles `
        -IncludeApplication $includeApplications `
        -ExcludeApplication $excludeApplications)

if ([bool]::Parse($env:VIF_RUN_OPTIMIZER)) {
    Invoke-CitrixOptimizer `
        -EnginePath $env:VIF_OPTIMIZER_ENGINE `
        -Template $env:VIF_OPTIMIZER_TEMPLATE `
        -Mode Execute
}

Complete-VdiImage `
    -ManifestPath 'C:\ProgramData\VdiImageFactory\image-manifest.json' `
    -ImageVersion $env:VIF_IMAGE_VERSION `
    -ApplicationProfile $profiles `
    -ApplicationId @($applications.Id)
