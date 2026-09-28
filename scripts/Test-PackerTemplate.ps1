<#
.SYNOPSIS
Initializes, format-checks, and validates the Packer template without real media.

.DESCRIPTION
The template requires an ISO location, checksum, and WinRM password, which a
fresh clone does not have. This script supplies obviously fake placeholders so
the template can be validated anywhere; it never starts a build. Pass
-VariableFile to validate a generated build.auto.pkrvars.hcl as well.

.EXAMPLE
./scripts/Test-PackerTemplate.ps1
./scripts/Test-PackerTemplate.ps1 -VariableFile ./build/build.auto.pkrvars.hcl
#>
[CmdletBinding()]
param(
    [string]$PackerPath = 'packer',
    [string]$VariableFile
)

$ErrorActionPreference = 'Stop'
$templateDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'packer'

function Invoke-Packer {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "packer $($Arguments[0]) failed with exit code $LASTEXITCODE."
    }
}

$placeholders = @(
    '-var', 'iso_url=https://example.test/windows.iso',
    '-var', 'iso_checksum=sha256:0000000000000000000000000000000000000000000000000000000000000000',
    '-var', 'winrm_password=Placeholder-Password123'
)

Invoke-Packer $PackerPath @('init', $templateDirectory)
Invoke-Packer $PackerPath @('fmt', '-check', '-recursive', $templateDirectory)

$validate = @('validate')
if ($VariableFile) {
    if (-not (Test-Path -LiteralPath $VariableFile -PathType Leaf)) {
        throw "Variable file was not found: $VariableFile"
    }
    $VariableFile = (Resolve-Path -LiteralPath $VariableFile).Path
    Invoke-Packer $PackerPath @('fmt', '-check', $VariableFile)
    $validate += @('-var-file', $VariableFile)
}
Invoke-Packer $PackerPath ($validate + $placeholders + @($templateDirectory))
