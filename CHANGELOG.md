# Changelog

All notable changes to this project will be documented in this file. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/).

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
