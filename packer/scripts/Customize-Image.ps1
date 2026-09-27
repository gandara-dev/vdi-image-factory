$ErrorActionPreference = 'Stop'

$modulePath = 'C:\Windows\Temp\VdiImageFactory\VdiImageFactory.psd1'
Import-Module $modulePath -Force

Install-VdiApplication -ManifestPath $env:VIF_APP_MANIFEST

if ([bool]::Parse($env:VIF_RUN_OPTIMIZER)) {
    Invoke-CitrixOptimizer `
        -EnginePath $env:VIF_OPTIMIZER_ENGINE `
        -Template $env:VIF_OPTIMIZER_TEMPLATE `
        -Mode Execute
}

Complete-VdiImage `
    -ManifestPath 'C:\ProgramData\VdiImageFactory\image-manifest.json' `
    -ImageVersion $env:VIF_IMAGE_VERSION
