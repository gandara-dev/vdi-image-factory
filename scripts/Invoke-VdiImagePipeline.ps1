[CmdletBinding()]
param(
    [Alias('ApplicationManifestPath')]
    [string]$ApplicationCatalogPath = (
        Join-Path $PSScriptRoot '..\config\application-catalog.json'
    ),
    [string[]]$ApplicationProfile = @('standard'),
    [string[]]$IncludeApplication = @(),
    [string[]]$ExcludeApplication = @(),
    [string]$OptimizerEnginePath = 'C:\CitrixOptimizer\CtxOptimizerEngine.ps1',
    [string]$OptimizerTemplate = 'AutoSelect',
    [ValidateSet('Analyze', 'Execute')][string]$OptimizerMode = 'Execute',
    [string]$ImageManifestPath = 'C:\ProgramData\VdiImageFactory\image-manifest.json',
    [string]$ImageVersion = 'dev',
    [string]$ProvisioningSchemeName = 'Windows 11 - Production',
    [string]$MasterImageVM = 'XDHyp:\HostingUnits\Primary\gold-image.snapshot',
    [string]$AdminAddress,
    [switch]$SkipOptimizer,
    [switch]$SkipPublish,
    [switch]$Simulation
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\src\VdiImageFactory\VdiImageFactory.psd1'
Import-Module $modulePath -Force

$parameters = @{
    ApplicationCatalogPath = $ApplicationCatalogPath
    ApplicationProfile = $ApplicationProfile
    IncludeApplication = $IncludeApplication
    ExcludeApplication = $ExcludeApplication
    OptimizerEnginePath = $OptimizerEnginePath
    OptimizerTemplate = $OptimizerTemplate
    OptimizerMode = $OptimizerMode
    ImageManifestPath = $ImageManifestPath
    ImageVersion = $ImageVersion
    ProvisioningSchemeName = $ProvisioningSchemeName
    MasterImageVM = $MasterImageVM
    AdminAddress = $AdminAddress
    SkipOptimizer = $SkipOptimizer
    SkipPublish = $SkipPublish
    Simulation = $Simulation
}

$result = Invoke-VdiImagePipeline @parameters
$result | ConvertTo-Json -Depth 10
