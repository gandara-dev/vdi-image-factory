# Changelog

All notable changes to this project will be documented in this file. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/).

## [0.4.2] - 2026-09-29

### Changed

- Image Builder redesigned as a step-by-step wizard in the style of the
  Citrix Studio catalog wizard: Image, Build VM, Language and region,
  Applications, Citrix Optimizer, Machine catalog, and Summary. Next checks
  each step before moving on, and the Summary lists every setting and offers
  the generated files to view, copy, or download. Validation and generated
  output are unchanged.

## [0.4.1] - 2026-09-29

### Changed

- Image Builder redesigned as a build sheet: numbered sections of ruled
  fields, profiles and applications as checkable rows, and the generated
  files in a tabbed output panel. Validation and generated output are
  unchanged.
- License changed from MIT to PolyForm Shield 1.0.0. Releases up to v0.4.0
  remain available under the MIT license.

## [0.4.0] - 2026-09-28

### Added

- Image Builder page (`site/`) to design a golden image and an optional MCS
  machine catalog in the browser, published with GitHub Pages and runnable
  locally with `scripts/Start-ImageBuilder.ps1`.
- `New-VdiBuild.ps1`, which validates a `build.json`, simulates the guest
  pipeline, and writes Packer variables and a reviewed MCS catalog plan.
- `Test-VdiBuildConfiguration`, `ConvertTo-VdiPackerVariable`,
  `ConvertTo-VdiMcsPlanScript`, `Get-VdiBuildReference`, and
  `Get-VdiMachineName`.
- `ui_language`, `locale`, and `time_zone` Packer variables applied by the
  unattended answer file, with Windows locale and time zone reference files.
- Shared fixtures that run against both the PowerShell module and the page, plus
  a Node test suite.

### Fixed

- The documented `packer validate` step failed on a fresh clone because the ISO
  and password variables had no values. `scripts/Test-PackerTemplate.ps1` now
  validates the template with explicit placeholders.

## [0.3.1] - 2026-09-28

### Added

- Release-verification guide with the exact public acceptance gate and the
  operator-owned Windows, VDA, application, and MCS promotion checklist.

## [0.3.0] - 2026-09-28

### Added

- Composable `standard`, `developer`, and `application` image profiles backed by
  a single application catalog.
- Profile inheritance, multi-profile selection, per-build package inclusion and
  exclusion, and explicit select-all support.
- Catalog validation for missing references, duplicate definitions, unsupported
  scopes, unknown profiles, and inheritance cycles.
- Resolved profiles and package IDs in the sealed image manifest.
- Profile controls for the PowerShell entry point, Packer, and Ansible.

### Changed

- Replaced the enabled/disabled package manifest with a reusable catalog and
  profile model.
- Made the smaller `standard` office image the default build composition.

## [0.2.0] - 2026-09-27

### Added

- Machine-wide developer workstation manifest with Chrome, Visual Studio Code,
  Git, GitHub CLI, Python, Node.js, PowerShell, .NET, Go, Java, Rust, Azure CLI,
  Azure Storage Explorer, Terraform, kubectl, Windows Terminal, Postman, and
  Microsoft 365 Apps for enterprise.
- Optional disabled entries for Docker Desktop and Notepad++.
- Per-application WinGet scope validation with `machine` as the safe default.

## [0.1.0] - 2026-09-27

### Added

- Hyper-V golden-image template for Packer.
- PowerShell workflow for application installation, Citrix Optimizer, image
  sealing, and MCS publication.
- Ansible playbook for invoking the guest customization workflow.
- Infrastructure-free simulation mode, Pester tests, and CI validation.
- Static architecture diagram and architecture, operations, testing, security,
  and contribution documentation.
