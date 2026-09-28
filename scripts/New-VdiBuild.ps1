<#
.SYNOPSIS
Validates an Image Builder configuration and writes the files for a build.

.DESCRIPTION
Reads a build.json produced by the Image Builder page (or written by hand),
applies the same validation as the page, and writes:

- build.auto.pkrvars.hcl: Packer variables for the golden image, without secrets;
- mcs-catalog-plan.ps1: the reviewed Citrix SDK commands for the machine
  catalog, when the configuration has an mcs section. It is never executed.

With -Simulation, it also runs the guest pipeline in simulation mode with the
selected applications, so the plan can be reviewed without Hyper-V or Citrix.

.EXAMPLE
./scripts/New-VdiBuild.ps1 -ConfigPath ./config/build.example.json -OutputDirectory ./build -Simulation
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\build'),
    [switch]$Simulation
)

$ErrorActionPreference = 'Stop'
# .NET file APIs resolve relative paths against the process directory, not the
# PowerShell location, so resolve the output directory explicitly.
$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$modulePath = Join-Path $PSScriptRoot '..\src\VdiImageFactory\VdiImageFactory.psd1'
Import-Module $modulePath -Force

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Build configuration was not found: $ConfigPath"
}
try {
    $configuration = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
}
catch {
    throw "Build configuration is not valid JSON: $($_.Exception.Message)"
}

$reference = Get-VdiBuildReference
$problems = @(Test-VdiBuildConfiguration -Configuration $configuration -Reference $reference)
if ($problems.Count -gt 0) {
    $details = ($problems | ForEach-Object { "  $($_.Path): $($_.Message)" }) -join [Environment]::NewLine
    throw "The build configuration has $($problems.Count) problem(s):$([Environment]::NewLine)$details"
}

$image = $configuration.image
$applications = @(Resolve-VdiApplicationCatalog `
        -CatalogPath $reference.CatalogPath `
        -ApplicationProfile @($image.applications.profiles) `
        -IncludeApplication @($image.applications.include) `
        -ExcludeApplication @($image.applications.exclude))

$utf8 = [System.Text.UTF8Encoding]::new($false)
$written = [System.Collections.Generic.List[string]]::new()
if ($PSCmdlet.ShouldProcess($OutputDirectory, 'Write build files')) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $variablePath = Join-Path $OutputDirectory 'build.auto.pkrvars.hcl'
    [System.IO.File]::WriteAllText($variablePath, (ConvertTo-VdiPackerVariable -Configuration $configuration), $utf8)
    $written.Add($variablePath)

    if ($null -ne $configuration.mcs) {
        $planPath = Join-Path $OutputDirectory 'mcs-catalog-plan.ps1'
        [System.IO.File]::WriteAllText($planPath, (ConvertTo-VdiMcsPlanScript -Configuration $configuration), $utf8)
        $written.Add($planPath)
    }
}

$pipeline = $null
if ($Simulation) {
    $pipeline = Invoke-VdiImagePipeline `
        -ApplicationCatalogPath $reference.CatalogPath `
        -ApplicationProfile @($image.applications.profiles) `
        -IncludeApplication @($image.applications.include) `
        -ExcludeApplication @($image.applications.exclude) `
        -OptimizerTemplate $image.optimizer.template `
        -ImageVersion $image.version `
        -SkipOptimizer:(-not $image.optimizer.enabled) `
        -SkipPublish `
        -Simulation
}

$machines = $null
if ($null -ne $configuration.mcs) {
    $names = Get-VdiMachineName -NamingScheme $configuration.mcs.namingScheme -Count $configuration.mcs.machineCount
    $machines = [pscustomobject]@{
        Catalog = $configuration.mcs.catalogName
        Count = $configuration.mcs.machineCount
        Names = "$($names.First) .. $($names.Last)"
        Domain = $configuration.mcs.domain
        OrganizationalUnit = $configuration.mcs.organizationalUnit
    }
}

[pscustomobject]@{
    Image = "$($image.name) $($image.version)"
    Hardware = "$($image.hardware.cpus) vCPU, $($image.hardware.memoryMb) MB RAM, $($image.hardware.diskSizeMb) MB disk"
    Regional = "$($image.regional.uiLanguage) UI, $($image.regional.locale) locale, $($image.regional.timeZone)"
    Applications = @($applications | ForEach-Object { $_.Name })
    Optimizer = [bool]$image.optimizer.enabled
    MachineCatalog = $machines
    FilesWritten = $written.ToArray()
    Simulation = $pipeline
}
