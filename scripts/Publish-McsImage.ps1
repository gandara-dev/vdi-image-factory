[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ProvisioningSchemeName,
    [Parameter(Mandatory)][string]$MasterImageVM,
    [string]$AdminAddress,
    [switch]$Simulation
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\src\VdiImageFactory\VdiImageFactory.psd1'
Import-Module $modulePath -Force

$parameters = @{
    ProvisioningSchemeName = $ProvisioningSchemeName
    MasterImageVM = $MasterImageVM
    AdminAddress = $AdminAddress
    Simulation = $Simulation
}
Publish-McsImage @parameters | Format-List
