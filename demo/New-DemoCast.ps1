[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'demo.cast')
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$pipelineScript = Join-Path $repositoryRoot 'scripts/Invoke-VdiImagePipeline.ps1'
$result = (& $pipelineScript -ApplicationProfile developer -Simulation | Out-String) |
    ConvertFrom-Json -Depth 10

$esc = [char]27
$green = "$esc[32m"
$yellow = "$esc[33m"
$cyan = "$esc[36m"
$dim = "$esc[2m"
$reset = "$esc[0m"
$events = [System.Collections.Generic.List[string]]::new()
$time = 0.0

function Add-DemoFrame {
    param([double]$Delay, [string]$Text)

    $script:time += $Delay
    $events.Add((@($script:time, 'o', $Text) | ConvertTo-Json -Compress))
}

$header = [ordered]@{
    version = 2
    width = 112
    height = 27
    timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    env = [ordered]@{ SHELL = 'pwsh'; TERM = 'xterm-256color' }
    title = 'VDI Image Factory demo'
} | ConvertTo-Json -Compress

Add-DemoFrame 0.0 "${cyan}VDI IMAGE FACTORY${reset}  ${dim}Golden image as reviewed code${reset}`r`n`r`n"
Add-DemoFrame 0.6 "${yellow}PS>${reset} ./scripts/Invoke-VdiImagePipeline.ps1 -ApplicationProfile developer -Simulation`r`n`r`n"

foreach ($application in $result.Applications) {
    Add-DemoFrame 0.35 "${green}[planned]${reset} app       $($application.Name)  ${dim}$($application.Id)${reset}`r`n"
}

Add-DemoFrame 0.4 "${green}[planned]${reset} optimizer Citrix Optimizer / $($result.Optimizer.Mode)`r`n"
Add-DemoFrame 0.4 "${green}[planned]${reset} seal      image $($result.Seal.ImageVersion), no pending reboot`r`n"
Add-DemoFrame 0.4 "${green}[planned]${reset} publish   $($result.Publication.ProvisioningSchemeName)`r`n"
Add-DemoFrame 0.3 "             ${dim}$($result.Publication.MasterImageVM)${reset}`r`n`r`n"
Add-DemoFrame 0.6 "${cyan}Pipeline status:${reset} ${green}$($result.Status)${reset}`r`n"
Add-DemoFrame 0.5 "${dim}Simulation contacted no Hyper-V host or Citrix site.${reset}`r`n"
Add-DemoFrame 1.8 "${dim}Review -> build -> canary -> publish -> monitor${reset}`r`n"

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
@($header) + $events | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Output "Created asciinema recording: $OutputPath"
