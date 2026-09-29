#!/usr/bin/env bash
# Installs Packer (checksum verified) and Pester at the versions CI uses.
set -euo pipefail

PACKER_VERSION=1.16.1
work="$(mktemp -d)"
base="https://releases.hashicorp.com/packer/${PACKER_VERSION}"
curl -fsSLo "${work}/packer.zip" "${base}/packer_${PACKER_VERSION}_linux_amd64.zip"
curl -fsSLo "${work}/SHA256SUMS" "${base}/packer_${PACKER_VERSION}_SHA256SUMS"
(cd "${work}" && grep "packer_${PACKER_VERSION}_linux_amd64.zip" SHA256SUMS | sed "s/packer_${PACKER_VERSION}_linux_amd64.zip/packer.zip/" | sha256sum --check -)
command -v unzip >/dev/null || (sudo apt-get update -qq && sudo apt-get install -y -qq unzip)
sudo unzip -o -q "${work}/packer.zip" -d /usr/local/bin
rm -rf "${work}"
packer version

pwsh -NoProfile -Command '
  Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
  Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck'
