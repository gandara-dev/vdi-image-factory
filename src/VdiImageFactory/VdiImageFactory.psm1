Set-StrictMode -Version Latest

function Get-ApplicationCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Application catalog was not found: $Path"
    }

    try {
        $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Application catalog is not valid JSON: $($_.Exception.Message)"
    }

    if ($null -eq $manifest.applications) {
        throw "Application catalog must contain an 'applications' array."
    }

    $ids = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $normalizedApplications = [System.Collections.Generic.List[object]]::new()

    foreach ($application in @($manifest.applications)) {
        if ([string]::IsNullOrWhiteSpace([string]$application.name) -or
            [string]::IsNullOrWhiteSpace([string]$application.id)) {
            throw "Every application requires non-empty 'name' and 'id' values."
        }

        if (-not $ids.Add([string]$application.id)) {
            throw "Application IDs must be unique: $($application.id)"
        }

        $hasVersion = $application.PSObject.Properties.Name -contains 'version'
        $hasScope = $application.PSObject.Properties.Name -contains 'scope'
        if ($hasScope -and $application.scope -notin @('machine', 'user')) {
            throw "Application 'scope' must be 'machine' or 'user': $($application.id)"
        }

        $normalizedApplications.Add([pscustomobject]@{
                Name = [string]$application.name
                Id = [string]$application.id
                Version = if ($hasVersion) { [string]$application.version } else { '' }
                Scope = if ($hasScope) { [string]$application.scope } else { 'machine' }
            })
    }

    $normalizedProfiles = [System.Collections.Generic.List[object]]::new()
    $profileNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    if ($null -eq $manifest.profiles) {
        throw "Application catalog must contain a 'profiles' array."
    }

    foreach ($profileDefinition in @($manifest.profiles)) {
        if ([string]::IsNullOrWhiteSpace([string]$profileDefinition.name)) {
            throw "Every profile requires a non-empty 'name' value."
        }
        if (-not $profileNames.Add([string]$profileDefinition.name)) {
            throw "Profile names must be unique: $($profileDefinition.name)"
        }
        if ($null -eq $profileDefinition.applications) {
            throw "Profile must contain an 'applications' array: $($profileDefinition.name)"
        }

        $extends = if ($profileDefinition.PSObject.Properties.Name -contains 'extends') {
            @($profileDefinition.extends | ForEach-Object { [string]$_ })
        }
        else {
            @()
        }
        $profileApplications = @($profileDefinition.applications | ForEach-Object { [string]$_ })
        $normalizedProfiles.Add([pscustomobject]@{
                Name = [string]$profileDefinition.name
                Description = if ($profileDefinition.PSObject.Properties.Name -contains 'description') {
                    [string]$profileDefinition.description
                }
                else { '' }
                Extends = $extends
                Applications = $profileApplications
            })
    }

    $knownIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($application in $normalizedApplications) {
        [void]$knownIds.Add($application.Id)
    }
    foreach ($profileDefinition in $normalizedProfiles) {
        foreach ($id in $profileDefinition.Applications) {
            if (-not $knownIds.Contains($id)) {
                throw "Profile '$($profileDefinition.Name)' references an unknown application: $id"
            }
        }
        foreach ($parent in $profileDefinition.Extends) {
            if (-not $profileNames.Contains($parent)) {
                throw "Profile '$($profileDefinition.Name)' extends an unknown profile: $parent"
            }
        }
    }

    return [pscustomobject]@{
        Applications = @($normalizedApplications)
        Profiles = @($normalizedProfiles)
    }
}

function Resolve-VdiApplicationCatalog {
    <#
    .SYNOPSIS
    Resolves one or more image profiles into an ordered application plan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Alias('ManifestPath')][string]$CatalogPath,
        [Alias('Profile')][string[]]$ApplicationProfile = @('standard'),
        [string[]]$IncludeApplication = @(),
        [string[]]$ExcludeApplication = @()
    )

    $catalog = Get-ApplicationCatalog -Path $CatalogPath
    if ($ApplicationProfile.Count -eq 0) {
        throw 'At least one application profile is required.'
    }

    $profilesByName = @{}
    foreach ($item in $catalog.Profiles) {
        $profilesByName[$item.Name.ToLowerInvariant()] = $item
    }
    $selectedIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $resolvedProfiles = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $activeProfiles = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    function Add-ProfileApplication {
        param([Parameter(Mandatory)][string]$Name)

        $key = $Name.ToLowerInvariant()
        if (-not $profilesByName.ContainsKey($key)) {
            throw "Application profile was not found: $Name"
        }
        if ($resolvedProfiles.Contains($key)) {
            return
        }
        if (-not $activeProfiles.Add($key)) {
            throw "Application profile inheritance contains a cycle at: $Name"
        }

        $item = $profilesByName[$key]
        foreach ($parent in $item.Extends) {
            Add-ProfileApplication -Name $parent
        }
        foreach ($id in $item.Applications) {
            [void]$selectedIds.Add($id)
        }

        [void]$activeProfiles.Remove($key)
        [void]$resolvedProfiles.Add($key)
    }

    foreach ($profileName in $ApplicationProfile) {
        if ([string]::IsNullOrWhiteSpace($profileName)) {
            throw 'Application profile names cannot be empty.'
        }
        Add-ProfileApplication -Name $profileName
    }

    $knownIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($application in $catalog.Applications) {
        [void]$knownIds.Add($application.Id)
    }
    foreach ($id in $IncludeApplication) {
        if ($id -eq '*') {
            foreach ($application in $catalog.Applications) {
                [void]$selectedIds.Add($application.Id)
            }
        }
        elseif (-not $knownIds.Contains($id)) {
            throw "Included application was not found in the catalog: $id"
        }
        else {
            [void]$selectedIds.Add($id)
        }
    }
    foreach ($id in $ExcludeApplication) {
        if ($id -eq '*') {
            $selectedIds.Clear()
        }
        elseif (-not $knownIds.Contains($id)) {
            throw "Excluded application was not found in the catalog: $id"
        }
        else {
            [void]$selectedIds.Remove($id)
        }
    }

    return @($catalog.Applications | Where-Object { $selectedIds.Contains($_.Id) })
}

function Invoke-WingetCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & winget @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed with exit code $LASTEXITCODE`: $($output -join [Environment]::NewLine)"
    }

    return $output
}

function Install-VdiApplication {
    <#
    .SYNOPSIS
    Resolves application profiles and installs the selected packages with WinGet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Alias('ManifestPath')][string]$CatalogPath,
        [Alias('Profile')][string[]]$ApplicationProfile = @('standard'),
        [string[]]$IncludeApplication = @(),
        [string[]]$ExcludeApplication = @(),
        [switch]$Simulation
    )

    $applications = @(Resolve-VdiApplicationCatalog `
            -CatalogPath $CatalogPath `
            -ApplicationProfile $ApplicationProfile `
            -IncludeApplication $IncludeApplication `
            -ExcludeApplication $ExcludeApplication)

    if (-not $Simulation -and -not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'WinGet is required to install applications.'
    }

    foreach ($application in $applications) {
        $result = [ordered]@{
            Stage = 'Applications'
            Name = $application.Name
            Id = $application.Id
            Version = $application.Version
            Scope = $application.Scope
            Status = 'Planned'
        }

        if (-not $Simulation) {
            $arguments = @(
                'install', '--id', $application.Id, '--exact', '--silent',
                '--accept-package-agreements', '--accept-source-agreements',
                '--disable-interactivity', '--scope', $application.Scope
            )
            if (-not [string]::IsNullOrWhiteSpace($application.Version)) {
                $arguments += @('--version', $application.Version)
            }

            Invoke-WingetCommand -Arguments $arguments | Out-Null
            $result.Status = 'Installed'
        }

        [pscustomobject]$result
    }
}

function Invoke-CitrixOptimizer {
    <#
    .SYNOPSIS
    Invokes the official Citrix Optimizer engine in Analyze or Execute mode.
    #>
    [CmdletBinding()]
    param(
        [string]$EnginePath = 'C:\CitrixOptimizer\CtxOptimizerEngine.ps1',
        [string]$Template = 'AutoSelect',
        [ValidateSet('Analyze', 'Execute')][string]$Mode = 'Execute',
        [switch]$Simulation
    )

    $result = [ordered]@{
        Stage = 'Optimizer'
        EnginePath = $EnginePath
        Template = $Template
        Mode = $Mode
        Status = 'Planned'
    }

    if ($Simulation) {
        return [pscustomobject]$result
    }

    if (-not (Test-Path -LiteralPath $EnginePath -PathType Leaf)) {
        throw "Citrix Optimizer engine was not found: $EnginePath"
    }
    if ($Template -ne 'AutoSelect' -and -not (Test-Path -LiteralPath $Template -PathType Leaf)) {
        throw "Citrix Optimizer template was not found: $Template"
    }

    & $EnginePath -Source $Template -Mode $Mode
    if (-not $?) {
        throw 'Citrix Optimizer reported a failure.'
    }
    $result.Status = 'Completed'
    return [pscustomobject]$result
}

function Test-PendingReboot {
    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSEdition -ne 'Desktop' -and -not $IsWindows) {
        return $false
    }

    $rebootPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    if ($rebootPaths | Where-Object { Test-Path -LiteralPath $_ }) {
        return $true
    }

    $sessionManager = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $pendingRename = Get-ItemPropertyValue -LiteralPath $sessionManager `
        -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    return $null -ne $pendingRename
}

function Complete-VdiImage {
    <#
    .SYNOPSIS
    Validates reboot state, records build metadata, and optionally shuts down the image.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ManifestPath = 'C:\ProgramData\VdiImageFactory\image-manifest.json',
        [string]$ImageVersion = 'dev',
        [string[]]$ApplicationProfile = @(),
        [string[]]$ApplicationId = @(),
        [switch]$AllowPendingReboot,
        [switch]$Shutdown,
        [switch]$Simulation
    )

    $pendingReboot = if ($Simulation) { $false } else { Test-PendingReboot }
    if ($pendingReboot -and -not $AllowPendingReboot) {
        throw 'The image has a pending reboot. Restart it before sealing, or use -AllowPendingReboot.'
    }

    $metadata = [ordered]@{
        schemaVersion = 2
        imageVersion = $ImageVersion
        builtAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        computerName = if ($Simulation) { 'SIMULATED-VDI' } else { $env:COMPUTERNAME }
        pendingReboot = $pendingReboot
        applicationProfiles = @($ApplicationProfile)
        applications = @($ApplicationId)
    }

    if (-not $Simulation -and $PSCmdlet.ShouldProcess($ManifestPath, 'Write image manifest')) {
        $parent = Split-Path -Parent $ManifestPath
        if ($parent) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $json = $metadata | ConvertTo-Json
        [System.IO.File]::WriteAllText(
            $ManifestPath,
            $json,
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    if (-not $Simulation -and $Shutdown -and
        $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Shut down image')) {
        Stop-Computer -Force
    }

    [pscustomobject]@{
        Stage = 'Seal'
        ManifestPath = $ManifestPath
        ImageVersion = $ImageVersion
        PendingReboot = $pendingReboot
        ShutdownRequested = [bool]$Shutdown
        Status = if ($Simulation) { 'Planned' } else { 'Completed' }
        Metadata = [pscustomobject]$metadata
    }
}

function Publish-McsImage {
    <#
    .SYNOPSIS
    Starts an asynchronous MCS master-image publication task.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ProvisioningSchemeName,
        [Parameter(Mandatory)][string]$MasterImageVM,
        [string]$AdminAddress,
        [switch]$Simulation
    )

    if ($Simulation) {
        return [pscustomobject]@{
            Stage = 'MCS publish'
            ProvisioningSchemeName = $ProvisioningSchemeName
            MasterImageVM = $MasterImageVM
            AdminAddress = $AdminAddress
            TaskId = '00000000-0000-0000-0000-000000000000'
            Status = 'Planned'
        }
    }

    if (-not (Get-Command Publish-ProvMasterVMImage -ErrorAction SilentlyContinue)) {
        throw 'Publish-ProvMasterVMImage is unavailable. Install the Citrix Machine Creation SDK.'
    }

    if (-not $PSCmdlet.ShouldProcess(
            $ProvisioningSchemeName,
            "Publish master image '$MasterImageVM'"
        )) {
        return
    }

    $parameters = @{
        ProvisioningSchemeName = $ProvisioningSchemeName
        MasterImageVM = $MasterImageVM
        RunAsynchronously = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($AdminAddress)) {
        $parameters.AdminAddress = $AdminAddress
    }

    $task = Publish-ProvMasterVMImage @parameters
    [pscustomobject]@{
        Stage = 'MCS publish'
        ProvisioningSchemeName = $ProvisioningSchemeName
        MasterImageVM = $MasterImageVM
        AdminAddress = $AdminAddress
        TaskId = [string]$task.TaskId
        Status = 'Started'
    }
}

function Invoke-VdiImagePipeline {
    <#
    .SYNOPSIS
    Runs guest customization and optionally plans or starts MCS publication.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Alias('ApplicationManifestPath')][string]$ApplicationCatalogPath,
        [string[]]$ApplicationProfile = @('standard'),
        [string[]]$IncludeApplication = @(),
        [string[]]$ExcludeApplication = @(),
        [string]$OptimizerEnginePath = 'C:\CitrixOptimizer\CtxOptimizerEngine.ps1',
        [string]$OptimizerTemplate = 'AutoSelect',
        [ValidateSet('Analyze', 'Execute')][string]$OptimizerMode = 'Execute',
        [string]$ImageManifestPath = 'C:\ProgramData\VdiImageFactory\image-manifest.json',
        [string]$ImageVersion = 'dev',
        [string]$ProvisioningSchemeName,
        [string]$MasterImageVM,
        [string]$AdminAddress,
        [switch]$SkipOptimizer,
        [switch]$SkipPublish,
        [switch]$Simulation
    )

    if (-not $SkipPublish -and
        ([string]::IsNullOrWhiteSpace($ProvisioningSchemeName) -or
         [string]::IsNullOrWhiteSpace($MasterImageVM))) {
        throw 'ProvisioningSchemeName and MasterImageVM are required unless -SkipPublish is used.'
    }

    $applications = @(Install-VdiApplication `
        -CatalogPath $ApplicationCatalogPath `
        -ApplicationProfile $ApplicationProfile `
        -IncludeApplication $IncludeApplication `
        -ExcludeApplication $ExcludeApplication `
        -Simulation:$Simulation)

    $optimizer = if ($SkipOptimizer) {
        $null
    }
    else {
        Invoke-CitrixOptimizer `
            -EnginePath $OptimizerEnginePath `
            -Template $OptimizerTemplate `
            -Mode $OptimizerMode `
            -Simulation:$Simulation
    }

    $seal = Complete-VdiImage `
        -ManifestPath $ImageManifestPath `
        -ImageVersion $ImageVersion `
        -ApplicationProfile $ApplicationProfile `
        -ApplicationId @($applications.Id) `
        -Simulation:$Simulation

    $publication = if ($SkipPublish) {
        $null
    }
    else {
        Publish-McsImage `
            -ProvisioningSchemeName $ProvisioningSchemeName `
            -MasterImageVM $MasterImageVM `
            -AdminAddress $AdminAddress `
            -Simulation:$Simulation
    }

    [pscustomobject]@{
        Mode = if ($Simulation) { 'Simulation' } else { 'Live' }
        ApplicationProfiles = @($ApplicationProfile)
        Applications = $applications
        Optimizer = $optimizer
        Seal = $seal
        Publication = $publication
        Status = 'Completed'
    }
}

Export-ModuleMember -Function @(
    'Complete-VdiImage'
    'Install-VdiApplication'
    'Invoke-CitrixOptimizer'
    'Invoke-VdiImagePipeline'
    'Publish-McsImage'
    'Resolve-VdiApplicationCatalog'
)
