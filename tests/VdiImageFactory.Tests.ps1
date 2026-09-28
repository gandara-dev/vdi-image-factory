BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ModulePath = Join-Path $RepositoryRoot 'src/VdiImageFactory/VdiImageFactory.psd1'
    $script:CatalogPath = Join-Path $RepositoryRoot 'config/application-catalog.json'
    Import-Module $ModulePath -Force
}

Describe 'Module contract' {
    It 'publishes the documented module version' {
        (Test-ModuleManifest $ModulePath).Version | Should -Be '0.4.0'
    }
}

Describe 'Install-VdiApplication' {
    It 'plans the standard profile by default' {
        $results = @(Install-VdiApplication -CatalogPath $CatalogPath -Simulation)

        $results.Count | Should -Be 5
        $results.Status | Should -Not -Contain 'Installed'
        $results.Id | Should -Contain '7zip.7zip'
        $results.Id | Should -Contain 'Google.Chrome'
        $results.Id | Should -Contain 'Mozilla.Firefox'
        $results.Id | Should -Contain 'Microsoft.Office'
        $results.Id | Should -Not -Contain 'Microsoft.VisualStudioCode'
        $results.Scope | Should -Not -Contain 'user'
    }

    It 'inherits standard applications into the developer profile' {
        $results = @(Install-VdiApplication `
                -CatalogPath $CatalogPath `
                -Profile developer `
                -Simulation)

        $results.Count | Should -Be 21
        $results.Id | Should -Contain 'Microsoft.Office'
        $results.Id | Should -Contain 'Microsoft.VisualStudioCode'
        $results.Id | Should -Contain 'Python.Python.3.13'
        $results.Id | Should -Not -Contain 'Docker.DockerDesktop'
    }

    It 'builds an application-specific selection with include and exclude overrides' {
        $results = @(Install-VdiApplication `
                -CatalogPath $CatalogPath `
                -Profile application `
                -IncludeApplication 'Google.Chrome', 'Postman.Postman', 'Notepad++.Notepad++' `
                -ExcludeApplication 'Google.Chrome' `
                -Simulation)

        $results.Id | Should -Be @('Postman.Postman', 'Notepad++.Notepad++')
    }

    It 'can select every catalog application explicitly' {
        $results = @(Resolve-VdiApplicationCatalog `
                -CatalogPath $CatalogPath `
                -Profile application `
                -IncludeApplication '*')

        $results.Count | Should -Be 23
        $results.Id | Should -Contain 'Docker.DockerDesktop'
    }

    It 'rejects duplicate application IDs' {
        $manifestPath = Join-Path $TestDrive 'duplicate.json'
        @{
            applications = @(
                @{ name = 'First'; id = 'Vendor.App' }
                @{ name = 'Second'; id = 'vendor.app' }
            )
            profiles = @(@{ name = 'standard'; applications = @('Vendor.App') })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath

        { Install-VdiApplication -CatalogPath $manifestPath -Simulation } |
            Should -Throw '*unique*'
    }

    It 'rejects malformed JSON' {
        $manifestPath = Join-Path $TestDrive 'invalid.json'
        Set-Content -LiteralPath $manifestPath -Value '{'

        { Install-VdiApplication -CatalogPath $manifestPath -Simulation } |
            Should -Throw '*valid JSON*'
    }

    It 'defaults optional version and scope values safely' {
        $manifestPath = Join-Path $TestDrive 'minimal.json'
        @{
            applications = @(@{ name = 'Minimal'; id = 'Vendor.Minimal' })
            profiles = @(@{ name = 'standard'; applications = @('Vendor.Minimal') })
        } |
            ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $manifestPath

        $result = Install-VdiApplication -CatalogPath $manifestPath -Simulation

        $result.Status | Should -Be 'Planned'
        $result.Version | Should -Be ''
        $result.Scope | Should -Be 'machine'
    }

    It 'rejects an unsupported installation scope' {
        $manifestPath = Join-Path $TestDrive 'invalid-scope.json'
        @{
            applications = @(@{ name = 'Invalid'; id = 'Vendor.Invalid'; scope = 'session' })
            profiles = @(@{ name = 'standard'; applications = @('Vendor.Invalid') })
        } |
            ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath $manifestPath

        { Install-VdiApplication -CatalogPath $manifestPath -Simulation } |
            Should -Throw "Application 'scope' must be 'machine' or 'user': Vendor.Invalid"
    }

    It 'rejects unknown profiles and application IDs' {
        { Resolve-VdiApplicationCatalog -CatalogPath $CatalogPath -Profile missing } |
            Should -Throw '*profile was not found*'
        { Resolve-VdiApplicationCatalog `
                -CatalogPath $CatalogPath `
                -Profile application `
                -IncludeApplication 'Vendor.Missing' } |
            Should -Throw '*not found in the catalog*'
    }

    It 'rejects cyclic profile inheritance' {
        $catalogPath = Join-Path $TestDrive 'cycle.json'
        @{
            applications = @(@{ name = 'App'; id = 'Vendor.App' })
            profiles = @(
                @{ name = 'one'; extends = @('two'); applications = @() }
                @{ name = 'two'; extends = @('one'); applications = @('Vendor.App') }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $catalogPath

        { Resolve-VdiApplicationCatalog -CatalogPath $catalogPath -Profile one } |
            Should -Throw '*cycle*'
    }
}

Describe 'Invoke-CitrixOptimizer' {
    It 'does not require the engine in simulation mode' {
        $result = Invoke-CitrixOptimizer `
            -EnginePath 'C:\missing\CtxOptimizerEngine.ps1' `
            -Template 'AutoSelect' `
            -Mode Analyze `
            -Simulation

        $result.Status | Should -Be 'Planned'
        $result.Mode | Should -Be 'Analyze'
    }

    It 'requires the engine for a live run' {
        { Invoke-CitrixOptimizer -EnginePath (Join-Path $TestDrive 'missing.ps1') } |
            Should -Throw '*was not found*'
    }
}

Describe 'Complete-VdiImage' {
    It 'returns deterministic safety properties in simulation mode' {
        $result = Complete-VdiImage `
            -ManifestPath 'C:\ProgramData\VdiImageFactory\image-manifest.json' `
            -ImageVersion '2026.09.27.1' `
            -Shutdown `
            -Simulation

        $result.Status | Should -Be 'Planned'
        $result.PendingReboot | Should -BeFalse
        $result.ShutdownRequested | Should -BeTrue
        $result.Metadata.computerName | Should -Be 'SIMULATED-VDI'
    }

    It 'writes a machine-readable manifest in a live filesystem run' {
        Mock Test-PendingReboot -ModuleName VdiImageFactory { $false }
        $manifestPath = Join-Path $TestDrive 'image-manifest.json'
        $result = Complete-VdiImage `
            -ManifestPath $manifestPath `
            -ImageVersion '2026.09.27.2' `
            -ApplicationProfile developer `
            -ApplicationId 'Git.Git', 'Python.Python.3.13' `
            -AllowPendingReboot

        $result.Status | Should -Be 'Completed'
        $metadata = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $metadata.schemaVersion | Should -Be 2
        $metadata.imageVersion | Should -Be '2026.09.27.2'
        $metadata.applicationProfiles | Should -Be @('developer')
        $metadata.applications | Should -Be @('Git.Git', 'Python.Python.3.13')
    }
}

Describe 'Publish-McsImage' {
    It 'plans an asynchronous publication without the Citrix SDK' {
        $result = Publish-McsImage `
            -ProvisioningSchemeName 'Windows 11 - Production' `
            -MasterImageVM 'XDHyp:\HostingUnits\Primary\gold.snapshot' `
            -Simulation

        $result.Status | Should -Be 'Planned'
        $result.TaskId | Should -Be '00000000-0000-0000-0000-000000000000'
    }
}

Describe 'Invoke-VdiImagePipeline' {
    It 'runs the complete workflow in simulation mode' {
        $result = Invoke-VdiImagePipeline `
            -ApplicationCatalogPath $CatalogPath `
            -ApplicationProfile developer `
            -ExcludeApplication 'Microsoft.Office' `
            -ProvisioningSchemeName 'Windows 11 - Production' `
            -MasterImageVM 'XDHyp:\HostingUnits\Primary\gold.snapshot' `
            -ImageVersion '2026.09.27.1' `
            -Simulation

        $result.Mode | Should -Be 'Simulation'
        $result.ApplicationProfiles | Should -Be @('developer')
        $result.Applications.Count | Should -Be 20
        $result.Applications.Id | Should -Not -Contain 'Microsoft.Office'
        $result.Seal.Metadata.applications.Count | Should -Be 20
        $result.Optimizer.Status | Should -Be 'Planned'
        $result.Seal.Status | Should -Be 'Planned'
        $result.Publication.Status | Should -Be 'Planned'
        $result.Status | Should -Be 'Completed'
    }

    It 'requires MCS inputs when publication is enabled' {
        {
            Invoke-VdiImagePipeline `
                -ApplicationCatalogPath $CatalogPath `
                -Simulation
        } | Should -Throw '*required unless -SkipPublish*'
    }

    It 'can stop after guest customization' {
        $result = Invoke-VdiImagePipeline `
            -ApplicationCatalogPath $CatalogPath `
            -SkipOptimizer `
            -SkipPublish `
            -Simulation

        $result.Optimizer | Should -BeNullOrEmpty
        $result.Publication | Should -BeNullOrEmpty
    }
}

BeforeDiscovery {
    $fixtureRoot = Join-Path (Split-Path -Parent $PSCommandPath) 'fixtures'
    $script:ValidationCases = @(
        (Get-Content -LiteralPath (Join-Path $fixtureRoot 'build-configuration-cases.json') -Raw |
            ConvertFrom-Json).cases | ForEach-Object {
            @{ Name = $_.name; Patch = $_.patch; ExpectedErrors = @($_.errors) }
        }
    )
    $script:ResolutionCases = @(
        (Get-Content -LiteralPath (Join-Path $fixtureRoot 'catalog-resolution-cases.json') -Raw |
            ConvertFrom-Json).cases | ForEach-Object {
            @{ Name = $_.name; Case = $_ }
        }
    )
}

Describe 'Build configuration (shared fixtures with the Image Builder page)' {
    BeforeAll {
        $script:FixtureRoot = Join-Path $PSScriptRoot 'fixtures'
        $script:ExamplePath = Join-Path $RepositoryRoot 'config/build.example.json'
        $script:Reference = Get-VdiBuildReference

        function Get-PatchedConfiguration {
            param($Patch)
            $config = Get-Content -LiteralPath $ExamplePath -Raw | ConvertFrom-Json
            foreach ($property in $Patch.PSObject.Properties) {
                $keys = $property.Name -split '\.'
                $target = $config
                for ($i = 0; $i -lt $keys.Count - 1; $i++) {
                    $target = $target.($keys[$i])
                }
                $target.($keys[-1]) = $property.Value
            }
            return $config
        }

        function Get-FixtureText {
            param([string]$Name)
            return (Get-Content -LiteralPath (Join-Path $FixtureRoot $Name) -Raw) -replace "`r`n", "`n"
        }
    }

    It 'validation: <Name>' -ForEach $ValidationCases {
        $configuration = Get-PatchedConfiguration $Patch
        $paths = @(Test-VdiBuildConfiguration -Configuration $configuration -Reference $Reference |
                ForEach-Object { $_.Path })
        $paths | Should -Be $ExpectedErrors
    }

    It 'catalog: <Name>' -ForEach $ResolutionCases {
        $run = {
            Resolve-VdiApplicationCatalog -CatalogPath $CatalogPath `
                -ApplicationProfile @($Case.profiles) `
                -IncludeApplication @($Case.include) `
                -ExcludeApplication @($Case.exclude)
        }
        if ($Case.PSObject.Properties['error']) {
            $run | Should -Throw -ExpectedMessage $Case.error
            return
        }
        $ids = @(& $run | ForEach-Object { $_.Id })
        if ($Case.PSObject.Properties['ids']) {
            $ids | Should -Be @($Case.ids)
        }
        if ($Case.PSObject.Properties['count']) {
            $ids.Count | Should -Be $Case.count
        }
    }

    It 'renders the same Packer variables as the page' {
        $configuration = Get-Content -LiteralPath $ExamplePath -Raw | ConvertFrom-Json
        ConvertTo-VdiPackerVariable -Configuration $configuration |
            Should -BeExactly (Get-FixtureText 'build.example.pkrvars.hcl')
    }

    It 'renders the same MCS plan as the page' {
        $configuration = Get-Content -LiteralPath $ExamplePath -Raw | ConvertFrom-Json
        ConvertTo-VdiMcsPlanScript -Configuration $configuration |
            Should -BeExactly (Get-FixtureText 'build.example.mcs-catalog-plan.ps1')
    }

    It 'produces an MCS plan that PowerShell can parse' {
        $configuration = Get-Content -LiteralPath $ExamplePath -Raw | ConvertFrom-Json
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput(
            (ConvertTo-VdiMcsPlanScript -Configuration $configuration), [ref]$null, [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0
    }

    It 'escapes HCL template sequences and quotes' {
        $configuration = Get-PatchedConfiguration ([pscustomobject]@{ 'image.hardware.switchName' = 'Lab "A" \ ${x}' })
        ConvertTo-VdiPackerVariable -Configuration $configuration |
            Should -Match 'switch_name\s+= "Lab \\"A\\" \\\\ \$\$\{x\}"'
    }

    It 'names the first and last machines from the naming scheme' {
        $names = Get-VdiMachineName -NamingScheme 'VDI-ENG-###' -Count 25
        $names.First | Should -Be 'VDI-ENG-001'
        $names.Last | Should -Be 'VDI-ENG-025'
    }
}
