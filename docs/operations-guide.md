# Operations Guide

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

## Build and validation

Run the pipeline first with `-Simulation`. For a real build, preserve Packer
logs in an access-controlled location and treat the resulting VHDX and image
manifest as release artifacts. Boot the image in an isolated network and test
applications, policy, VDA registration, logon, profile behavior, and shutdown.

Citrix Optimizer should begin in `Analyze` mode. Any optimization template is a
versioned build input and requires regression testing against the OS, VDA, and
application set.

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
