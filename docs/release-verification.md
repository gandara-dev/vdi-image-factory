# Release Verification

## Public release gate

Every change must pass:

- Pester on PowerShell 7 for Windows and Linux;
- the same Pester suite on Windows PowerShell 5.1;
- the Node suite for the Image Builder page, which runs the same validation,
  catalog, and golden-output fixtures as Pester;
- `New-VdiBuild.ps1` against `config/build.example.json`, and `packer validate`
  of the generated variable file;
- simulation of the complete application, Optimizer, seal, and MCS pipeline;
- catalog tests for profiles, inheritance, overrides, select-all, missing IDs,
  invalid scopes, duplicate definitions, and inheritance cycles;
- PSScriptAnalyzer and actionlint;
- `packer init`, formatting, and validation with Packer 1.16.1 and Hyper-V
  plugin 1.1.5;
- Ansible syntax checking and `ansible-lint` with the pinned collection;
- Mermaid rendering and JSON catalog parsing;
- exact WinGet lookup with machine scope for every public catalog ID.

Run the infrastructure-free acceptance path:

```powershell
Invoke-Pester ./tests/VdiImageFactory.Tests.ps1 -CI -Output Detailed
./scripts/Invoke-VdiImagePipeline.ps1 `
  -ApplicationProfile developer `
  -SkipPublish `
  -Simulation
node --test tests/web/*.test.mjs
./scripts/New-VdiBuild.ps1 `
  -ConfigPath ./config/build.example.json `
  -OutputDirectory ./build `
  -Simulation
./scripts/Test-PackerTemplate.ps1 -VariableFile ./build/build.auto.pkrvars.hcl
```

`Test-PackerTemplate.ps1` runs `packer init`, `packer fmt -check`, and
`packer validate` with placeholder ISO and password values, so it works on a
fresh clone without licensed media.

## Environment acceptance gate

A complete golden-image build necessarily uses licensed and
environment-specific components that public CI cannot redistribute. Before
promotion, the operator must:

1. Use an approved Windows ISO and verify its SHA-256 checksum.
2. Confirm the image index and Windows licensing channel.
3. Validate Hyper-V capacity, virtual switch access, Secure Boot, and WinRM.
4. Confirm WinGet availability inside the fresh guest before package install.
5. Review package versions, licenses, silent-install behavior, and machine scope.
6. Build the VHDX and boot it in an isolated network.
7. Validate every selected application, Windows Update state, VDA installation,
   Optimizer output, reboot state, profile behavior, and shutdown.
8. Snapshot and publish only to a non-production MCS catalog first.
9. Test registration, launch, logon, application behavior, monitoring, canary
   rollback, and the previous master-image recovery path.

The public release validates orchestration, manifests, Packer and Ansible
configuration, and package discoverability. It does not claim that a Windows
image, Citrix VDA, licensed Office activation, or a real MCS publication was
executed without the operator-supplied infrastructure.
