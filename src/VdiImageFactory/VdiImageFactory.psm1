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

# ------------------------------------------------------------------------
# Build configuration: validation and generators.
# Every rule mirrors site/lib/image-builder.js; both implementations run the
# shared fixtures in tests/fixtures.

$script:BuildLimits = @{
    Cpus = @{ Min = 2; Max = 64; Step = 0 }
    MemoryMb = @{ Min = 4096; Max = 262144; Step = 1024 }
    DiskSizeMb = @{ Min = 65536; Max = 2097152; Step = 1024 }
    WindowsImageIndex = @{ Min = 1; Max = 32; Step = 0 }
    MachineCountMax = 1000
    ComputerNameLength = 15
}

$script:NamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{1,62}$'
$script:VersionPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'
$script:ChecksumPattern = '^sha256:[A-Fa-f0-9]{64}$'
$script:CitrixObjectNamePattern = '^[^\\/;:#.*?=<>|\[\]()"'']{1,64}$'
$script:NamingSchemePattern = '^[A-Za-z0-9#][A-Za-z0-9#-]*$'
$script:FqdnPattern = '^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
$script:OuPattern = '(?i)^OU=[^,=]+(?:,OU=[^,=]+)*(?:,DC=[^,=]+)+$'

function Test-BuildObject {
    param($Value)
    return ($null -ne $Value) -and ($Value -is [System.Management.Automation.PSCustomObject])
}

function Get-BuildProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $null }
    # The comma keeps arrays intact; PowerShell would otherwise unroll them.
    return , $property.Value
}

function Test-BuildProperty {
    param($Object, [string]$Name)
    return ($null -ne $Object) -and ($null -ne $Object.PSObject.Properties[$Name])
}

function Test-WholeNumber {
    param($Value)
    return ($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [int16]) -or ($Value -is [byte])
}

function Test-BuildMatch {
    param($Value, [string]$Pattern)
    return ($Value -is [string]) -and [regex]::IsMatch($Value, $Pattern)
}

function Test-BlankValue {
    param($Value)
    return -not ($Value -is [string]) -or [string]::IsNullOrWhiteSpace($Value)
}

function Add-RangeError {
    param(
        [System.Collections.Generic.List[object]]$Errors,
        [string]$Path,
        $Value,
        [long]$Min,
        [long]$Max,
        [long]$Step = 0
    )
    if (-not (Test-WholeNumber $Value) -or $Value -lt $Min -or $Value -gt $Max) {
        $Errors.Add([pscustomobject]@{ Path = $Path; Message = "Must be a whole number from $Min to $Max." })
        return
    }
    if ($Step -gt 0 -and ($Value % $Step) -ne 0) {
        $Errors.Add([pscustomobject]@{ Path = $Path; Message = "Must be a multiple of $Step." })
    }
}

function Get-VdiBuildReference {
    <#
    .SYNOPSIS
    Loads the catalog, locale, and time zone reference data used to validate a build.
    #>
    [CmdletBinding()]
    param(
        [string]$CatalogPath = (Join-Path $PSScriptRoot '..\..\config\application-catalog.json'),
        [string]$LocalePath = (Join-Path $PSScriptRoot '..\..\config\windows-locales.json'),
        [string]$TimeZonePath = (Join-Path $PSScriptRoot '..\..\config\windows-time-zones.json')
    )

    $catalog = Get-ApplicationCatalog -Path $CatalogPath
    [pscustomobject]@{
        CatalogPath = $CatalogPath
        Catalog = $catalog
        Locales = @((Get-Content -LiteralPath $LocalePath -Raw | ConvertFrom-Json).locales | ForEach-Object { [string]$_.id })
        TimeZones = @((Get-Content -LiteralPath $TimeZonePath -Raw | ConvertFrom-Json).timeZones | ForEach-Object { [string]$_.id })
    }
}

function Get-VdiNamingSchemeDigit {
    param([string]$NamingScheme)
    $match = [regex]::Match([string]$NamingScheme, '#+')
    if ($match.Success) { return $match.Length }
    return 0
}

function Test-VdiBuildConfiguration {
    <#
    .SYNOPSIS
    Validates an Image Builder configuration and returns one object per problem.

    .DESCRIPTION
    Returns nothing when the configuration is valid. Each error has a Path that
    identifies the offending field and a human-readable Message.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Configuration,
        $Reference = (Get-VdiBuildReference)
    )

    $errors = [System.Collections.Generic.List[object]]::new()
    $add = { param($Path, $Message) $errors.Add([pscustomobject]@{ Path = $Path; Message = $Message }) }

    if (-not (Test-BuildObject $Configuration)) {
        & $add '' 'The configuration must be a JSON object.'
        return $errors.ToArray()
    }
    $schemaVersion = Get-BuildProperty $Configuration 'schemaVersion'
    if (-not (Test-WholeNumber $schemaVersion) -or $schemaVersion -ne 1) {
        & $add 'schemaVersion' 'Only schemaVersion 1 is supported.'
    }

    $image = Get-BuildProperty $Configuration 'image'
    if (-not (Test-BuildObject $image)) {
        & $add 'image' 'The image section is required.'
    }
    else {
        if (-not (Test-BuildMatch (Get-BuildProperty $image 'name') $script:NamePattern)) {
            & $add 'image.name' 'Use 2-63 letters, digits, dots, hyphens, or underscores, starting with a letter or digit.'
        }
        if (-not (Test-BuildMatch (Get-BuildProperty $image 'version') $script:VersionPattern)) {
            & $add 'image.version' 'Use 1-32 letters, digits, dots, hyphens, or underscores.'
        }
        $limit = $script:BuildLimits.WindowsImageIndex
        Add-RangeError $errors 'image.windowsImageIndex' (Get-BuildProperty $image 'windowsImageIndex') $limit.Min $limit.Max
        if ((Test-BuildProperty $image 'isoUrl') -and -not ((Get-BuildProperty $image 'isoUrl') -is [string])) {
            & $add 'image.isoUrl' 'Must be a string.'
        }
        $checksum = Get-BuildProperty $image 'isoChecksum'
        if ((Test-BuildProperty $image 'isoChecksum') -and -not ($checksum -is [string] -and $checksum -eq '') -and
            -not (Test-BuildMatch $checksum $script:ChecksumPattern)) {
            & $add 'image.isoChecksum' 'Use sha256: followed by 64 hexadecimal characters.'
        }

        $hardware = Get-BuildProperty $image 'hardware'
        if (-not (Test-BuildObject $hardware)) {
            & $add 'image.hardware' 'The hardware section is required.'
        }
        else {
            foreach ($item in @(
                    @('cpus', 'Cpus'),
                    @('memoryMb', 'MemoryMb'),
                    @('diskSizeMb', 'DiskSizeMb'))) {
                $limit = $script:BuildLimits[$item[1]]
                Add-RangeError $errors "image.hardware.$($item[0])" (Get-BuildProperty $hardware $item[0]) $limit.Min $limit.Max $limit.Step
            }
            $switchName = Get-BuildProperty $hardware 'switchName'
            if ((Test-BlankValue $switchName) -or $switchName.Length -gt 64) {
                & $add 'image.hardware.switchName' 'Enter the Hyper-V virtual switch name (up to 64 characters).'
            }
        }

        $regional = Get-BuildProperty $image 'regional'
        if (-not (Test-BuildObject $regional)) {
            & $add 'image.regional' 'The regional section is required.'
        }
        else {
            if (-not ($Reference.Locales -ccontains (Get-BuildProperty $regional 'uiLanguage'))) {
                & $add 'image.regional.uiLanguage' 'Choose a supported language.'
            }
            if (-not ($Reference.Locales -ccontains (Get-BuildProperty $regional 'locale'))) {
                & $add 'image.regional.locale' 'Choose a supported locale.'
            }
            if (-not ($Reference.TimeZones -ccontains (Get-BuildProperty $regional 'timeZone'))) {
                & $add 'image.regional.timeZone' 'Choose a Windows time zone ID.'
            }
        }

        $applications = Get-BuildProperty $image 'applications'
        if (-not (Test-BuildObject $applications)) {
            & $add 'image.applications' 'The applications section is required.'
        }
        else {
            $profileNames = @($Reference.Catalog.Profiles | ForEach-Object { $_.Name })
            $ids = @($Reference.Catalog.Applications | ForEach-Object { $_.Id })
            $profiles = Get-BuildProperty $applications 'profiles'
            if (-not ($profiles -is [array]) -or $profiles.Count -eq 0) {
                & $add 'image.applications.profiles' 'Select at least one profile.'
            }
            else {
                for ($index = 0; $index -lt $profiles.Count; $index++) {
                    $name = $profiles[$index]
                    if (-not ($name -is [string]) -or -not ($profileNames -contains $name)) {
                        & $add "image.applications.profiles[$index]" "Unknown profile: $name"
                    }
                }
            }
            foreach ($listName in @('include', 'exclude')) {
                $list = Get-BuildProperty $applications $listName
                if (-not ($list -is [array])) {
                    & $add "image.applications.$listName" 'Must be a list of catalog IDs.'
                    continue
                }
                for ($index = 0; $index -lt $list.Count; $index++) {
                    $id = $list[$index]
                    if ($id -ne '*' -and (-not ($id -is [string]) -or -not ($ids -contains $id))) {
                        & $add "image.applications.$listName[$index]" "Unknown application ID: $id"
                    }
                }
            }
        }

        $optimizer = Get-BuildProperty $image 'optimizer'
        if (-not (Test-BuildObject $optimizer)) {
            & $add 'image.optimizer' 'The optimizer section is required.'
        }
        else {
            if (-not ((Get-BuildProperty $optimizer 'enabled') -is [bool])) {
                & $add 'image.optimizer.enabled' 'Must be true or false.'
            }
            if (Test-BlankValue (Get-BuildProperty $optimizer 'template')) {
                & $add 'image.optimizer.template' 'Enter AutoSelect or a template path.'
            }
        }
    }

    $mcs = Get-BuildProperty $Configuration 'mcs'
    if ($null -ne $mcs) {
        if (-not (Test-BuildObject $mcs)) {
            & $add 'mcs' 'The mcs section must be an object or null.'
        }
        else {
            foreach ($field in @('catalogName', 'provisioningSchemeName')) {
                $value = Get-BuildProperty $mcs $field
                if (-not ($value -is [string]) -or $value.Trim() -cne $value -or
                    -not [regex]::IsMatch($value, $script:CitrixObjectNamePattern)) {
                    & $add "mcs.$field" 'Use 1-64 characters without \ / ; : # . * ? = < > | [ ] ( ) quotes or edge spaces.'
                }
            }
            $hostingUnit = Get-BuildProperty $mcs 'hostingUnitName'
            if ((Test-BlankValue $hostingUnit) -or $hostingUnit.Length -gt 64) {
                & $add 'mcs.hostingUnitName' 'Enter the hosting unit (resource) name.'
            }

            $scheme = Get-BuildProperty $mcs 'namingScheme'
            $digits = 0
            if (-not (Test-BuildMatch $scheme $script:NamingSchemePattern) -or
                [regex]::Matches($scheme, '#+').Count -ne 1 -or
                -not [regex]::IsMatch($scheme, '[A-Za-z]')) {
                & $add 'mcs.namingScheme' 'Use letters, digits, and hyphens with exactly one run of # (for example VDI-W11-###).'
            }
            elseif ($scheme.Length -gt $script:BuildLimits.ComputerNameLength) {
                & $add 'mcs.namingScheme' "Computer names cannot exceed $($script:BuildLimits.ComputerNameLength) characters."
            }
            else {
                $digits = Get-VdiNamingSchemeDigit $scheme
            }

            $domain = Get-BuildProperty $mcs 'domain'
            $domainValid = Test-BuildMatch $domain $script:FqdnPattern
            if (-not $domainValid) {
                & $add 'mcs.domain' 'Enter a fully qualified domain name, for example corp.example.test.'
            }
            $ou = Get-BuildProperty $mcs 'organizationalUnit'
            if (-not (Test-BuildMatch $ou $script:OuPattern)) {
                & $add 'mcs.organizationalUnit' 'Use a distinguished name such as OU=VDI,DC=corp,DC=example,DC=test.'
            }
            elseif ($domainValid) {
                $ouDomain = (@($ou -split ',' | ForEach-Object { $_.Trim() } |
                            Where-Object { $_ -match '^(?i)DC=' } |
                            ForEach-Object { $_.Substring(3) }) -join '.')
                if ($ouDomain.ToLowerInvariant() -ne $domain.ToLowerInvariant()) {
                    & $add 'mcs.organizationalUnit' 'The OU must be inside the selected domain.'
                }
            }

            $maxMachines = $script:BuildLimits.MachineCountMax
            if ($digits -gt 0) {
                $maxMachines = [Math]::Min($maxMachines, [long][Math]::Pow(10, $digits) - 1)
            }
            Add-RangeError $errors 'mcs.machineCount' (Get-BuildProperty $mcs 'machineCount') 1 $maxMachines

            if (@('Random', 'Static') -cnotcontains (Get-BuildProperty $mcs 'allocationType')) {
                & $add 'mcs.allocationType' 'Choose Random (pooled) or Static (assigned).'
            }

            $machine = Get-BuildProperty $mcs 'machine'
            if (-not (Test-BuildObject $machine)) {
                & $add 'mcs.machine' 'The machine size section is required.'
            }
            else {
                $limit = $script:BuildLimits.Cpus
                Add-RangeError $errors 'mcs.machine.cpus' (Get-BuildProperty $machine 'cpus') $limit.Min $limit.Max
                $limit = $script:BuildLimits.MemoryMb
                Add-RangeError $errors 'mcs.machine.memoryMb' (Get-BuildProperty $machine 'memoryMb') $limit.Min $limit.Max $limit.Step
            }
        }
    }

    return $errors.ToArray()
}

function ConvertTo-HclString {
    param([string]$Value)
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace('${', '$${').Replace('%{', '%%{')
    return '"' + $escaped + '"'
}

function ConvertTo-HclList {
    param([object[]]$Values)
    return '[' + (@($Values | ForEach-Object { ConvertTo-HclString ([string]$_) }) -join ', ') + ']'
}

function ConvertTo-PowerShellLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-VdiPackerVariable {
    <#
    .SYNOPSIS
    Renders a validated build configuration as a Packer variable file without secrets.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Configuration)

    $image = $Configuration.image
    $entries = [System.Collections.Generic.List[object]]::new()
    if (-not [string]::IsNullOrEmpty((Get-BuildProperty $image 'isoUrl'))) {
        $entries.Add(@('iso_url', (ConvertTo-HclString $image.isoUrl)))
    }
    if (-not [string]::IsNullOrEmpty((Get-BuildProperty $image 'isoChecksum'))) {
        $entries.Add(@('iso_checksum', (ConvertTo-HclString $image.isoChecksum)))
    }
    $entries.Add(@('image_name', (ConvertTo-HclString $image.name)))
    $entries.Add(@('image_version', (ConvertTo-HclString $image.version)))
    $entries.Add(@('windows_image_index', [string]$image.windowsImageIndex))
    $entries.Add(@('cpus', [string]$image.hardware.cpus))
    $entries.Add(@('memory_mb', [string]$image.hardware.memoryMb))
    $entries.Add(@('disk_size_mb', [string]$image.hardware.diskSizeMb))
    $entries.Add(@('switch_name', (ConvertTo-HclString $image.hardware.switchName)))
    $entries.Add(@('ui_language', (ConvertTo-HclString $image.regional.uiLanguage)))
    $entries.Add(@('locale', (ConvertTo-HclString $image.regional.locale)))
    $entries.Add(@('time_zone', (ConvertTo-HclString $image.regional.timeZone)))
    $entries.Add(@('application_profiles', (ConvertTo-HclList $image.applications.profiles)))
    $entries.Add(@('include_applications', (ConvertTo-HclList $image.applications.include)))
    $entries.Add(@('exclude_applications', (ConvertTo-HclList $image.applications.exclude)))
    $runOptimizer = 'false'
    if ($image.optimizer.enabled) { $runOptimizer = 'true' }
    $entries.Add(@('run_optimizer', $runOptimizer))
    $entries.Add(@('optimizer_template', (ConvertTo-HclString $image.optimizer.template)))

    $width = ($entries | ForEach-Object { $_[0].Length } | Measure-Object -Maximum).Maximum
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Generated by the VDI Image Factory Image Builder. This file contains no secrets.')
    $lines.Add('# Supply the temporary WinRM password separately, for example through')
    $lines.Add('# the PKR_VAR_winrm_password environment variable.')
    foreach ($entry in $entries) {
        $lines.Add($entry[0].PadRight($width) + ' = ' + $entry[1])
    }
    return ($lines -join "`n") + "`n"
}

function Get-VdiMachineName {
    <#
    .SYNOPSIS
    Returns the first and last computer names produced by an MCS naming scheme.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$NamingScheme, [Parameter(Mandatory)][int]$Count)

    $digits = Get-VdiNamingSchemeDigit $NamingScheme
    $pattern = [regex]'#+'
    [pscustomobject]@{
        First = $pattern.Replace($NamingScheme, '1'.PadLeft($digits, '0'), 1)
        Last = $pattern.Replace($NamingScheme, ([string]$Count).PadLeft($digits, '0'), 1)
    }
}

function ConvertTo-VdiMcsPlanScript {
    <#
    .SYNOPSIS
    Renders the reviewed Citrix SDK commands that create the MCS machine catalog.

    .DESCRIPTION
    The script is a plan for human review. This project never executes it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Configuration)

    $mcs = $Configuration.mcs
    $image = $Configuration.image
    $random = $mcs.allocationType -ceq 'Random'
    $masterImagePath = "XDHyp:\HostingUnits\$($mcs.hostingUnitName)\$($image.name).vm\$($image.name)-$($image.version).snapshot"
    $names = Get-VdiMachineName -NamingScheme $mcs.namingScheme -Count $mcs.machineCount
    $scheme = ConvertTo-PowerShellLiteral $mcs.provisioningSchemeName
    $catalogName = ConvertTo-PowerShellLiteral $mcs.catalogName
    $bt = '`'
    $cleanOnBoot = ''
    $allocation = 'Permanent'
    $persistence = 'OnLocal'
    if ($random) {
        $cleanOnBoot = '-CleanOnBoot '
        $allocation = 'Random'
        $persistence = 'Discard'
    }

    $lines = @(
        '#Requires -Version 5.1'
        '# MCS machine catalog plan generated by the VDI Image Factory Image Builder.'
        '# Nothing in this script has been executed. Review every value, load the'
        '# Citrix PowerShell SDK, and run it first against a non-production site.'
        "# Machines: $($names.First) to $($names.Last) ($($mcs.machineCount)) in $($mcs.organizationalUnit)"
        '$ErrorActionPreference = ''Stop'''
        ''
        '# Snapshot of the imported master VM; adjust it to the snapshot you created.'
        ('$masterImageVM = ' + (ConvertTo-PowerShellLiteral $masterImagePath))
        ''
        'function Wait-ProvTask {'
        '    param([Parameter(Mandatory)][guid]$TaskId)'
        '    $task = Get-ProvTask -TaskId $TaskId'
        '    while ($task.Active) {'
        '        Start-Sleep -Seconds 30'
        '        $task = Get-ProvTask -TaskId $TaskId'
        '    }'
        '    if ($task.TaskState -ne ''Finished'') {'
        '        throw "Provisioning task $TaskId ended in state $($task.TaskState)."'
        '    }'
        '}'
        ''
        '# 1. Identity pool: machine names, domain, and OU for the new computer accounts.'
        "New-AcctIdentityPool -IdentityPoolName $catalogName $bt"
        "    -NamingScheme $(ConvertTo-PowerShellLiteral $mcs.namingScheme) -NamingSchemeType Numeric $bt"
        "    -Domain $(ConvertTo-PowerShellLiteral $mcs.domain) -OU $(ConvertTo-PowerShellLiteral $mcs.organizationalUnit) | Out-Null"
        ''
        '# 2. Provisioning scheme based on the golden image snapshot.'
        "`$schemeTask = New-ProvScheme -ProvisioningSchemeName $scheme $bt"
        "    -HostingUnitName $(ConvertTo-PowerShellLiteral $mcs.hostingUnitName) -IdentityPoolName $catalogName $bt"
        "    -MasterImageVM `$masterImageVM -VMCpuCount $($mcs.machine.cpus) -VMMemoryMB $($mcs.machine.memoryMb) $bt"
        "    $($cleanOnBoot)-RunAsynchronously"
        'Wait-ProvTask -TaskId $schemeTask'
        "`$provScheme = Get-ProvScheme -ProvisioningSchemeName $scheme"
        ''
        '# 3. Broker machine catalog.'
        "`$catalog = New-BrokerCatalog -Name $catalogName $bt"
        "    -AllocationType $allocation -ProvisioningType MCS -SessionSupport SingleSession $bt"
        "    -PersistUserChanges $persistence -MachinesArePhysical `$false $bt"
        '    -ProvisioningSchemeId $provScheme.ProvisioningSchemeUid'
        ''
        '# 4. Computer accounts and virtual machines.'
        "`$accounts = New-AcctADAccount -IdentityPoolName $catalogName -Count $($mcs.machineCount)"
        "`$vmTask = New-ProvVM -ProvisioningSchemeName $scheme $bt"
        '    -ADAccountName @($accounts.SuccessfulAccounts.ADAccountName) -RunAsynchronously'
        'Wait-ProvTask -TaskId $vmTask'
        ''
        '# 5. Register the new machines with the catalog.'
        "`$hostingUnit = Get-Item -LiteralPath $(ConvertTo-PowerShellLiteral ('XDHyp:\HostingUnits\' + $mcs.hostingUnitName))"
        "`$connection = Get-BrokerHypervisorConnection $bt"
        '    -HypHypervisorConnectionUid $hostingUnit.HypervisorConnection.HypervisorConnectionUid'
        "foreach (`$vm in Get-ProvVM -ProvisioningSchemeName $scheme) {"
        "    Lock-ProvVM -ProvisioningSchemeName $scheme -Tag 'Brokered' -VMID @(`$vm.VMId)"
        "    New-BrokerMachine -CatalogUid `$catalog.Uid -MachineName `$vm.ADAccountSid $bt"
        '        -HostedMachineId $vm.VMId -HypervisorConnectionUid $connection.Uid | Out-Null'
        '}'
    )
    return ($lines -join "`n") + "`n"
}

Export-ModuleMember -Function @(
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
