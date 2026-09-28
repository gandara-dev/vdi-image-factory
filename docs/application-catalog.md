# Application Catalog

`config/application-catalog.json` is the source of truth for software available
to an image build. It has two independent parts:

- `applications` defines installable packages and their WinGet metadata;
- `profiles` composes those package IDs into reusable image personas.

## Built-in profiles

`standard` is the general-purpose office image. `developer` inherits `standard`
and adds the engineering toolchain. `application` intentionally starts empty so
an operator can select only the packages required by a published application.

Resolve a profile without installing anything:

```powershell
Import-Module ./src/VdiImageFactory/VdiImageFactory.psd1 -Force
Resolve-VdiApplicationCatalog `
  -CatalogPath ./config/application-catalog.json `
  -ApplicationProfile developer
```

## Per-build overrides

`IncludeApplication` adds an exact catalog ID after profiles are combined.
`ExcludeApplication` removes an exact ID last, so exclusion always wins. An
asterisk in `IncludeApplication` selects the entire library; an asterisk in
`ExcludeApplication` produces an empty plan.

```powershell
./scripts/Invoke-VdiImagePipeline.ps1 `
  -ApplicationProfile application `
  -IncludeApplication 'Microsoft.Office','Vendor.LineOfBusinessApp' `
  -SkipPublish `
  -Simulation
```

The example ID must exist in your private catalog before use. Unknown IDs fail
validation instead of being silently ignored.

## Permanent customization

Add an application once at the top level:

```json
{
  "name": "Contoso Client",
  "id": "Contoso.Client",
  "version": "",
  "scope": "machine"
}
```

Then add `Contoso.Client` to any profile's `applications` array. A profile may
inherit one or more parents through `extends`:

```json
{
  "name": "data-engineering",
  "description": "Developer tools plus the approved data client.",
  "extends": ["developer"],
  "applications": ["Contoso.Client"]
}
```

Application order follows the top-level library, independent of inheritance
order. Package IDs and profile names are case-insensitively unique. The factory
rejects missing references, missing parent profiles, invalid install scopes,
duplicate definitions, and inheritance cycles.

## Packer and Ansible

Set these values in a private Packer variables file:

```hcl
application_profiles = ["developer"]
include_applications  = ["Notepad++.Notepad++"]
exclude_applications  = ["Microsoft.OpenJDK.21"]
```

The Ansible playbook accepts equivalent variables:

```yaml
vdi_application_profiles:
  - application
vdi_include_applications:
  - Google.Chrome
  - Postman.Postman
vdi_exclude_applications: []
```

Keep internal package IDs and repository configuration in an approved private
overlay when they disclose organization-specific software. Review licensing,
silent-install behavior, machine scope, update channels, and VDI compatibility
for every catalog addition.
