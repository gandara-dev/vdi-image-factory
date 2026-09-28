# Operations Guide

## Configuration layers

Keep environment-specific values outside source control. The factory has three
configuration layers:

| Layer | File or parameters | Purpose |
|---|---|---|
| Image composition | `config/application-catalog.json` plus `ApplicationProfile`, `IncludeApplication`, and `ExcludeApplication` | Select software for the target persona |
| Hyper-V build | private copy of `packer/variables.pkrvars.example.hcl` | ISO, checksum, image index, VM sizing, virtual switch, temporary WinRM password, and profile overrides |
| Citrix publication | `Publish-McsImage.ps1` parameters | Provisioning scheme, snapshot path, and optional Delivery Controller |

The private Packer file must end in `.auto.pkrvars.hcl` to be loaded
automatically and is ignored by Git. Do not place Citrix credentials in that
file: MCS publication intentionally runs later from an authenticated management
host.

## Before a build

- Use a licensed Windows ISO and verify its SHA-256 checksum.
- Confirm the image index with DISM.
- Review the selected profiles and every package ID and version in
  `config/application-catalog.json`.
- Confirm every package supports machine-wide installation and the target OS.
- Define Microsoft 365 licensing, activation, update channel, and shared-computer
  activation through an approved Office Deployment Tool configuration.
- Store ISO paths, WinRM passwords, inventories, and Citrix credentials outside
  the repository.
- Validate available Hyper-V memory and disk capacity.

Copy the example variables to an ignored private file, run `packer init`, then
run `packer validate` before starting a build.

```powershell
Copy-Item packer/variables.pkrvars.example.hcl packer/private.auto.pkrvars.hcl
packer init ./packer
packer fmt -check -recursive ./packer
packer validate ./packer
```

If validation reports a missing variable, confirm that the private filename
ends exactly in `.auto.pkrvars.hcl`. If package installation reports that
WinGet is unavailable, verify App Installer registration inside the fresh guest;
installing WinGet only on the Hyper-V host does not satisfy the guest workflow.

## Build and validation

Run the pipeline first with `-Simulation`. For a real build, preserve Packer
logs in an access-controlled location and treat the resulting VHDX and image
manifest as release artifacts. Boot the image in an isolated network and test
applications, policy, VDA registration, logon, profile behavior, and shutdown.

Citrix Optimizer should begin in `Analyze` mode. Any optimization template is a
versioned build input and requires regression testing against the OS, VDA, and
application set.

The public CI validates the template but cannot redistribute a licensed Windows
ISO or build a production VHDX. Follow the environment acceptance checklist in
[Release verification](release-verification.md) before promotion.

Start from `standard`, `developer`, or the empty `application` profile. Use
per-build include/exclude overrides for experiments and update the catalog for
an approved permanent composition. Preserve the resolved profile names and
application IDs from the sealed image manifest with the build artifacts.

Keep Docker Desktop outside default profiles unless the target supports nested
virtualization and the organization has approved its licensing and resource use.

## MCS publication

Publication runs from a trusted management host, not from the golden image.
Always use `-WhatIf` first, verify the provisioning scheme and snapshot path,
then remove it only during an approved change. The SDK call is asynchronous;
success means a task was started, not that rollout completed.

Use canary machines before broad rollout. Record the previous master image so
the existing MCS rollback process can restore it if validation fails.

## Upgrade and recovery

Pin and review Packer, its Hyper-V plugin, Ansible collections, package versions,
and Optimizer inputs. Reproduce the build from a repository tag. On failure,
discard the incomplete artifact; do not attempt to promote a partially sealed
image.
