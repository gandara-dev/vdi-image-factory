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

CI also runs PSScriptAnalyzer, `packer fmt -check`, `packer validate`, Ansible
syntax checking, `ansible-lint`, and Mermaid source rendering. It never builds a
Windows VM or contacts a Citrix site. Pester covers default profiles, inheritance,
per-build overrides, select-all behavior, invalid references, and inheritance
cycles.

A real acceptance test requires licensed installation media, Hyper-V, approved
packages, and a non-production Citrix environment. Validate the VHDX, manifest,
canary registration, application launch, logon, profile behavior, and rollback.
