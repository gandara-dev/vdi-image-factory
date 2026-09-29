# VDI Image Factory in Codespaces

This codespace has PowerShell 7, Packer 1.16.1, and the project. The Image
Builder page runs on port 8765 and opens by itself (see the **Ports** tab).
Nothing here builds a real image: that needs a Hyper-V host and licensed
Windows media. Everything below runs for real on the synthetic inputs.

Open a terminal and run PowerShell with `pwsh`.

## Simulate the image pipeline with a profile

```powershell
./scripts/Invoke-VdiImagePipeline.ps1 -ApplicationProfile developer -SkipPublish -Simulation
```

## Turn build.json into Packer variables and an MCS plan

```powershell
./scripts/New-VdiBuild.ps1 -ConfigPath ./config/build.example.json -OutputDirectory ./build
Get-ChildItem ./build
```

`build.auto.pkrvars.hcl` has no secrets; `mcs-catalog-plan.ps1` is a plan to
review, never run by the project. You can also go through the Image Builder
wizard, download its `build.json` from the Summary step, and use it here.

## Validate the Packer template

```powershell
./scripts/Test-PackerTemplate.ps1
./scripts/Test-PackerTemplate.ps1 -VariableFile ./build/build.auto.pkrvars.hcl
```

## Tests

```powershell
Invoke-Pester ./tests
```

Stop the codespace when you are done so it does not use your Codespaces quota.
