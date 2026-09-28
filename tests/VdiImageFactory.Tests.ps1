BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ModulePath = Join-Path $RepositoryRoot 'src/VdiImageFactory/VdiImageFactory.psd1'
    $script:AppsPath = Join-Path $RepositoryRoot 'config/apps.json'
    Import-Module $ModulePath -Force
}

Describe 'Install-VdiApplication' {
    It 'plans only enabled applications in simulation mode' {
        $results = @(Install-VdiApplication -ManifestPath $AppsPath -Simulation)

        $results.Count | Should -Be 20
        $results.Status | Should -Not -Contain 'Installed'
        $results.Id | Should -Contain '7zip.7zip'
        $results.Id | Should -Contain 'Google.Chrome'
        $results.Id | Should -Contain 'Microsoft.VisualStudioCode'
        $results.Id | Should -Contain 'Python.Python.3.13'
        $results.Id | Should -Contain 'Microsoft.Office'
        $results.Id | Should -Not -Contain 'Notepad++.Notepad++'
        $results.Id | Should -Not -Contain 'Docker.DockerDesktop'
        $results.Scope | Should -Not -Contain 'user'
    }

    It 'rejects duplicate application IDs' {
        $manifestPath = Join-Path $TestDrive 'duplicate.json'
        @{
            applications = @(
                @{ name = 'First'; id = 'Vendor.App'; enabled = $true }
                @{ name = 'Second'; id = 'vendor.app'; enabled = $true }
            )
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath

        { Install-VdiApplication -ManifestPath $manifestPath -Simulation } |
            Should -Throw '*unique*'
    }

    It 'rejects malformed JSON' {
        $manifestPath = Join-Path $TestDrive 'invalid.json'
        Set-Content -LiteralPath $manifestPath -Value '{'

        { Install-VdiApplication -ManifestPath $manifestPath -Simulation } |
            Should -Throw '*valid JSON*'
    }

    It 'defaults optional version and enabled values safely' {
        $manifestPath = Join-Path $TestDrive 'minimal.json'
        @{ applications = @(@{ name = 'Minimal'; id = 'Vendor.Minimal' }) } |
            ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $manifestPath

        $result = Install-VdiApplication -ManifestPath $manifestPath -Simulation

        $result.Status | Should -Be 'Planned'
        $result.Version | Should -Be ''
        $result.Scope | Should -Be 'machine'
    }

    It 'rejects an unsupported installation scope' {
        $manifestPath = Join-Path $TestDrive 'invalid-scope.json'
        @{ applications = @(@{ name = 'Invalid'; id = 'Vendor.Invalid'; scope = 'session' }) } |
            ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath $manifestPath

        { Install-VdiApplication -ManifestPath $manifestPath -Simulation } |
            Should -Throw "Application 'scope' must be 'machine' or 'user': Vendor.Invalid"
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
            -AllowPendingReboot

        $result.Status | Should -Be 'Completed'
        $metadata = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $metadata.schemaVersion | Should -Be 1
        $metadata.imageVersion | Should -Be '2026.09.27.2'
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
            -ApplicationManifestPath $AppsPath `
            -ProvisioningSchemeName 'Windows 11 - Production' `
            -MasterImageVM 'XDHyp:\HostingUnits\Primary\gold.snapshot' `
            -ImageVersion '2026.09.27.1' `
            -Simulation

        $result.Mode | Should -Be 'Simulation'
        $result.Applications.Count | Should -Be 20
        $result.Optimizer.Status | Should -Be 'Planned'
        $result.Seal.Status | Should -Be 'Planned'
        $result.Publication.Status | Should -Be 'Planned'
        $result.Status | Should -Be 'Completed'
    }

    It 'requires MCS inputs when publication is enabled' {
        {
            Invoke-VdiImagePipeline `
                -ApplicationManifestPath $AppsPath `
                -Simulation
        } | Should -Throw '*required unless -SkipPublish*'
    }

    It 'can stop after guest customization' {
        $result = Invoke-VdiImagePipeline `
            -ApplicationManifestPath $AppsPath `
            -SkipOptimizer `
            -SkipPublish `
            -Simulation

        $result.Optimizer | Should -BeNullOrEmpty
        $result.Publication | Should -BeNullOrEmpty
    }
}
