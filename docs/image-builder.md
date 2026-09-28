# Image Builder

The Image Builder is a static page that designs a golden image and, optionally,
the MCS machine catalog that will use it. It is published at
<https://gandara-dev.github.io/vdi-image-factory/> and can run from a clone:

```powershell
./scripts/Start-ImageBuilder.ps1 -Open
```

`Start-ImageBuilder.ps1` serves `site/` and the reference files in `config/` on
`localhost` only. It has no dependencies and runs on Windows PowerShell 5.1 and
PowerShell 7.

The page works entirely in the browser. It reads the public catalog and
reference files, validates what you enter, and generates files for download. It
does not build images, contact Hyper-V or Citrix, or send data anywhere. Every
default value is synthetic.

## What you can configure

| Section | Settings | Where it is applied |
|---|---|---|
| Image | Name, version, Windows edition index, optional ISO location and SHA-256 checksum | Packer variables |
| Build VM | vCPUs, memory, system disk, Hyper-V switch | Packer (generation 2, Secure Boot) |
| Regional | Display language, locale and keyboard, Windows time zone | Unattended answer file |
| Applications | One or more profiles plus per-package additions and removals | `Install-VdiApplication` in the guest |
| Citrix Optimizer | Enabled or skipped, template | Guest customization |
| MCS catalog | Catalog and provisioning scheme names, hosting unit, naming scheme, machine count, domain, OU, pooled or assigned, per-machine vCPUs and memory | Reviewed Citrix SDK plan |

### Why the domain is not part of the image

With Machine Creation Services, computer names, the domain, and the OU belong
to the catalog's identity pool. MCS creates one AD computer account per machine
and gives each machine its identity when it is provisioned, so the same golden
image serves every machine in the catalog. The Image Builder therefore keeps
the image settings and the MCS catalog in separate sections, and only the
catalog plan uses the naming scheme, domain, and OU.

## Generated files

| File | Contents |
|---|---|
| `build.json` | The complete configuration. Import it back into the page, or pass it to `New-VdiBuild.ps1`. |
| `build.auto.pkrvars.hcl` | Packer variables for the image. It never contains the WinRM password. |
| `mcs-catalog-plan.ps1` | Citrix SDK commands that create the identity pool, provisioning scheme, broker catalog, AD accounts, and VMs, then register the machines. |
| `commands.ps1` | The commands to validate, simulate, and build from the downloaded files. |

The MCS plan is a script for human review. Nothing in this project executes it.
Run it only after reviewing every value, with the Citrix PowerShell SDK loaded,
against a non-production site first. CI checks that the generated script parses;
it cannot prove the commands against a real site. The snapshot path in the plan
follows the image name and version, and must be adjusted to the snapshot you
actually take of the imported master VM.

## From the page to a build

```powershell
./scripts/New-VdiBuild.ps1 -ConfigPath ./build.json -OutputDirectory ./build -Simulation
./scripts/Test-PackerTemplate.ps1 -VariableFile ./build/build.auto.pkrvars.hcl
$env:PKR_VAR_winrm_password = '<temporary password, 16+ characters>'
packer build -var-file ./build/build.auto.pkrvars.hcl `
    -var 'iso_url=file:///C:/ISO/Windows11.iso' `
    -var 'iso_checksum=sha256:<ISO checksum>' `
    ./packer
```

`New-VdiBuild.ps1` rejects an invalid configuration with the same messages the
page shows, simulates the guest pipeline with the selected applications, and
writes the Packer variables and, when present, the MCS plan.

## Validation rules

The same rules are implemented in `site/lib/image-builder.js` and in
`Test-VdiBuildConfiguration`.

| Field | Rule |
|---|---|
| Image name | 2-63 letters, digits, dots, hyphens, or underscores, starting with a letter or digit |
| Version | 1-32 letters, digits, dots, hyphens, or underscores |
| Edition index | Whole number from 1 to 32 |
| ISO checksum | Empty, or `sha256:` followed by 64 hexadecimal characters |
| vCPUs | 2 to 64 |
| Memory | 4096 to 262144 MB, in 1024 MB steps (Windows 11 needs at least 4 GB) |
| System disk | 65536 to 2097152 MB, in 1024 MB steps (Windows 11 needs at least 64 GB) |
| Language, locale | One of the entries in `config/windows-locales.json` |
| Time zone | One of the Windows IDs in `config/windows-time-zones.json` |
| Profiles | At least one, each defined in the catalog (case-insensitive) |
| Included and excluded IDs | Catalog IDs or `*` |
| Catalog and scheme names | 1-64 characters, no `\ / ; : # . * ? = < > \| [ ] ( )` or quotes, no edge spaces |
| Naming scheme | Letters, digits, and hyphens with exactly one run of `#`, at least one letter, not starting with a hyphen, and at most 15 characters |
| Machines | 1 to 1000, and no more than the `#` run can number (99 for `##`) |
| Domain | Fully qualified domain name |
| OU | Distinguished name made of `OU=` and `DC=` parts whose `DC=` parts match the domain |
| Assignment | `Random` (pooled, changes discarded) or `Static` (assigned, changes kept) |

## Keeping the page and the module in sync

`tests/fixtures` holds the contract both implementations must satisfy:

- `build-configuration-cases.json`: configurations with the exact error paths
  expected;
- `catalog-resolution-cases.json`: profile selections with the expected
  packages or error message;
- `build.example.pkrvars.hcl` and `build.example.mcs-catalog-plan.ps1`:
  golden output for `config/build.example.json`.

Pester runs them against the module, and `node --test tests/web/*.test.mjs`
runs them against the page. A change to a rule must update the fixtures and
both implementations in the same pull request.

## Limits

A valid configuration is not a tested image. A real build still needs licensed
installation media that includes the chosen display language, a Hyper-V host
with enough resources, approved package sources, and the operator checks in
[Release verification](release-verification.md).
