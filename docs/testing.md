# Testing Guide

Run the infrastructure-free suite with PowerShell 7 and, on Windows, Windows
PowerShell 5.1:

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester ./tests/VdiImageFactory.Tests.ps1 -CI -Output Detailed
./scripts/Invoke-VdiImagePipeline.ps1 -Simulation
./scripts/Invoke-VdiImagePipeline.ps1 -ApplicationProfile developer -Simulation
./scripts/Invoke-VdiImagePipeline.ps1 -ApplicationProfile application -IncludeApplication '*' -Simulation
```

The Image Builder page shares its rules with the module. Run its suite with
Node.js 20 or newer; it has no npm dependencies:

```powershell
node --test tests/web/*.test.mjs
```

Both suites read `tests/fixtures`: `build-configuration-cases.json` lists
configurations with the exact error paths expected, `catalog-resolution-cases.json`
lists profile selections with the expected packages or error, and the
`build.example.*` files are golden outputs that both implementations must
reproduce byte for byte. When a rule changes, update the fixtures, then both
implementations.

CI also runs PSScriptAnalyzer, `packer fmt -check`, `packer validate` (through
`scripts/Test-PackerTemplate.ps1`, including a generated variable file), Ansible
syntax checking, `ansible-lint`, and Mermaid source rendering. It never builds a
Windows VM or contacts a Citrix site. Pester covers default profiles, inheritance,
per-build overrides, select-all behavior, invalid references, and inheritance
cycles.

A real acceptance test requires licensed installation media, Hyper-V, approved
packages, and a non-production Citrix environment. Validate the VHDX, manifest,
canary registration, application launch, logon, profile behavior, and rollback.
