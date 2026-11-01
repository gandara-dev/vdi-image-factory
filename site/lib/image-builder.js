// Shared build logic for the Image Builder page.
//
// Every rule in this module has a PowerShell counterpart in
// src/VdiImageFactory/VdiImageFactory.psm1. Both implementations run the same
// fixtures in tests/fixtures, so the browser and the CLI accept, reject, and
// generate exactly the same things.

export const LIMITS = Object.freeze({
  cpus: { min: 2, max: 64 },
  memoryMb: { min: 4096, max: 262144, step: 1024 },
  diskSizeMb: { min: 65536, max: 2097152, step: 1024 },
  windowsImageIndex: { min: 1, max: 32 },
  machineCount: { max: 1000 },
  adComputerNameLength: 15,
  citrixObjectNameLength: 64,
  vsphereEntityNameLength: 79,
});

const NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{1,78}$/;
const VERSION_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$/;
const CHECKSUM_PATTERN = /^sha256:[A-Fa-f0-9]{64}$/;
const CITRIX_OBJECT_NAME_PATTERN = /^[^\\/;:#.*?=<>|[\]()"']+$/;
const NAMING_SCHEME_PATTERN = /^[A-Za-z0-9#][A-Za-z0-9#-]*$/;
const FQDN_PATTERN =
  /^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$/;
const OU_PATTERN = /^OU=[^,=]+(?:,OU=[^,=]+)*(?:,DC=[^,=]+)+$/i;

// ---------------------------------------------------------------- catalog

export class CatalogError extends Error {}

function lower(value) {
  return String(value).toLowerCase();
}

export function resolveApplications(catalog, profiles, include = [], exclude = []) {
  if (!Array.isArray(profiles) || profiles.length === 0) {
    throw new CatalogError('At least one application profile is required.');
  }

  const profilesByName = new Map(catalog.profiles.map((item) => [lower(item.name), item]));
  const knownIds = new Map(catalog.applications.map((app) => [lower(app.id), app.id]));
  const selected = new Set();
  const resolved = new Set();
  const active = new Set();

  const addProfile = (name) => {
    const key = lower(name);
    if (!profilesByName.has(key)) {
      throw new CatalogError(`Application profile was not found: ${name}`);
    }
    if (resolved.has(key)) {
      return;
    }
    if (active.has(key)) {
      throw new CatalogError(`Application profile inheritance contains a cycle at: ${name}`);
    }
    active.add(key);
    const item = profilesByName.get(key);
    for (const parent of item.extends || []) {
      addProfile(parent);
    }
    for (const id of item.applications) {
      selected.add(lower(id));
    }
    active.delete(key);
    resolved.add(key);
  };

  for (const name of profiles) {
    if (typeof name !== 'string' || name.trim() === '') {
      throw new CatalogError('Application profile names cannot be empty.');
    }
    addProfile(name);
  }
  for (const id of include) {
    if (id === '*') {
      for (const app of catalog.applications) {
        selected.add(lower(app.id));
      }
    } else if (!knownIds.has(lower(id))) {
      throw new CatalogError(`Included application was not found in the catalog: ${id}`);
    } else {
      selected.add(lower(id));
    }
  }
  for (const id of exclude) {
    if (id === '*') {
      selected.clear();
    } else if (!knownIds.has(lower(id))) {
      throw new CatalogError(`Excluded application was not found in the catalog: ${id}`);
    } else {
      selected.delete(lower(id));
    }
  }

  return catalog.applications.filter((app) => selected.has(lower(app.id)));
}

export function profileApplicationIds(catalog, profiles) {
  if (!profiles.length) {
    return [];
  }
  return resolveApplications(catalog, profiles).map((app) => app.id);
}

// ------------------------------------------------------------- validation

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isInteger(value) {
  return typeof value === 'number' && Number.isInteger(value);
}

function isBlank(value) {
  return typeof value !== 'string' || value.trim() === '';
}

function checkRange(errors, path, value, limits) {
  if (!isInteger(value) || value < limits.min || value > limits.max) {
    errors.push({ path, message: `Must be a whole number from ${limits.min} to ${limits.max}.` });
    return;
  }
  if (limits.step && value % limits.step !== 0) {
    errors.push({ path, message: `Must be a multiple of ${limits.step}.` });
  }
}

export function namingSchemeDigits(scheme) {
  const match = /#+/.exec(scheme || '');
  return match ? match[0].length : 0;
}

export function domainFromOrganizationalUnit(ou) {
  return ou
    .split(',')
    .filter((part) => /^DC=/i.test(part.trim()))
    .map((part) => part.trim().slice(3))
    .join('.');
}

export function validateConfiguration(config, reference) {
  const errors = [];
  const add = (path, message) => errors.push({ path, message });

  if (!isObject(config)) {
    add('', 'The configuration must be a JSON object.');
    return errors;
  }
  if (config.schemaVersion !== 2) {
    add('schemaVersion', 'Only schemaVersion 2 is supported.');
  }

  const image = config.image;
  if (!isObject(image)) {
    add('image', 'The image section is required.');
  } else {
    validateImage(image, reference, add, errors);
  }

  if (config.mcs !== undefined && config.mcs !== null) {
    if (!isObject(config.mcs)) {
      add('mcs', 'The mcs section must be an object or null.');
    } else {
      validateMcs(config.mcs, add, errors);
    }
  }

  return errors;
}

function validateImage(image, reference, add, errors) {
  const imageNameValid = typeof image.name === 'string' && NAME_PATTERN.test(image.name);
  const imageVersionValid = typeof image.version === 'string' && VERSION_PATTERN.test(image.version);
  if (!imageNameValid) {
    add('image.name', 'Use 2-79 letters, digits, dots, hyphens, or underscores, starting with a letter or digit (the vCenter entity-name limit is 79).');
  }
  if (!imageVersionValid) {
    add('image.version', 'Use 1-32 letters, digits, dots, hyphens, or underscores.');
  }
  if (imageNameValid && imageVersionValid &&
      `${image.name}-${image.version}`.length > LIMITS.vsphereEntityNameLength) {
    add('image.name', `The derived snapshot name (${image.name}-${image.version}) exceeds vCenter's ${LIMITS.vsphereEntityNameLength}-character limit.`);
  }
  checkRange(errors, 'image.windowsImageIndex', image.windowsImageIndex, LIMITS.windowsImageIndex);
  if (image.isoUrl !== undefined && typeof image.isoUrl !== 'string') {
    add('image.isoUrl', 'Must be a string.');
  }
  if (image.isoChecksum !== undefined && image.isoChecksum !== '' &&
      (typeof image.isoChecksum !== 'string' || !CHECKSUM_PATTERN.test(image.isoChecksum))) {
    add('image.isoChecksum', 'Use sha256: followed by 64 hexadecimal characters.');
  }

  const vsphere = image.vsphere;
  if (!isObject(vsphere)) {
    add('image.vsphere', 'The vSphere placement section is required.');
  } else {
    if (typeof vsphere.vcenterServer !== 'string' ||
        (!FQDN_PATTERN.test(vsphere.vcenterServer) && !/^(?:\d{1,3}\.){3}\d{1,3}$/.test(vsphere.vcenterServer))) {
      add('image.vsphere.vcenterServer', 'Enter the vCenter FQDN or IP address.');
    }
    for (const field of ['datacenter', 'datastore', 'folder', 'network']) {
      const value = vsphere[field];
      if (isBlank(value) || value.length > LIMITS.vsphereEntityNameLength) {
        add(`image.vsphere.${field}`, `Enter a vCenter inventory name from 1 to ${LIMITS.vsphereEntityNameLength} characters.`);
      }
    }
    if (isBlank(vsphere.cluster) && isBlank(vsphere.host)) {
      add('image.vsphere.cluster', 'Enter a cluster, an ESXi host, or both when the cluster does not use DRS.');
    } else if (vsphere.cluster !== undefined && vsphere.cluster !== '' &&
               (isBlank(vsphere.cluster) || vsphere.cluster.trim() !== vsphere.cluster ||
                vsphere.cluster.length > LIMITS.vsphereEntityNameLength)) {
      add('image.vsphere.cluster', `The optional cluster name cannot exceed ${LIMITS.vsphereEntityNameLength} characters.`);
    }
    if (vsphere.host !== undefined && vsphere.host !== '' &&
        (isBlank(vsphere.host) || vsphere.host.trim() !== vsphere.host ||
         vsphere.host.length > LIMITS.vsphereEntityNameLength)) {
      add('image.vsphere.host', `The optional ESXi host name cannot exceed ${LIMITS.vsphereEntityNameLength} characters.`);
    }
    if (typeof vsphere.insecureConnection !== 'boolean') {
      add('image.vsphere.insecureConnection', 'Must be true or false. Keep false when vCenter has a trusted certificate.');
    }
  }

  const hardware = image.hardware;
  if (!isObject(hardware)) {
    add('image.hardware', 'The hardware section is required.');
  } else {
    checkRange(errors, 'image.hardware.cpus', hardware.cpus, LIMITS.cpus);
    checkRange(errors, 'image.hardware.memoryMb', hardware.memoryMb, LIMITS.memoryMb);
    checkRange(errors, 'image.hardware.diskSizeMb', hardware.diskSizeMb, LIMITS.diskSizeMb);
  }

  const regional = image.regional;
  if (!isObject(regional)) {
    add('image.regional', 'The regional section is required.');
  } else {
    const locales = new Set(reference.locales.map((item) => item.id));
    const zones = new Set(reference.timeZones.map((item) => item.id));
    if (!locales.has(regional.uiLanguage)) {
      add('image.regional.uiLanguage', 'Choose a supported language.');
    }
    if (!locales.has(regional.locale)) {
      add('image.regional.locale', 'Choose a supported locale.');
    }
    if (!zones.has(regional.timeZone)) {
      add('image.regional.timeZone', 'Choose a Windows time zone ID.');
    }
  }

  const applications = image.applications;
  if (!isObject(applications)) {
    add('image.applications', 'The applications section is required.');
  } else {
    validateApplications(applications, reference.catalog, add);
  }

  const optimizer = image.optimizer;
  if (!isObject(optimizer)) {
    add('image.optimizer', 'The optimizer section is required.');
  } else {
    if (typeof optimizer.enabled !== 'boolean') {
      add('image.optimizer.enabled', 'Must be true or false.');
    }
    if (isBlank(optimizer.template)) {
      add('image.optimizer.template', 'Enter AutoSelect or a template path.');
    }
  }
}

function validateApplications(applications, catalog, add) {
  const profileNames = new Set(catalog.profiles.map((item) => lower(item.name)));
  const ids = new Set(catalog.applications.map((app) => lower(app.id)));

  if (!Array.isArray(applications.profiles) || applications.profiles.length === 0) {
    add('image.applications.profiles', 'Select at least one profile.');
  } else {
    applications.profiles.forEach((name, index) => {
      if (typeof name !== 'string' || !profileNames.has(lower(name))) {
        add(`image.applications.profiles[${index}]`, `Unknown profile: ${name}`);
      }
    });
  }

  for (const listName of ['include', 'exclude']) {
    const list = applications[listName];
    if (!Array.isArray(list)) {
      add(`image.applications.${listName}`, 'Must be a list of catalog IDs.');
      continue;
    }
    list.forEach((id, index) => {
      if (id !== '*' && (typeof id !== 'string' || !ids.has(lower(id)))) {
        add(`image.applications.${listName}[${index}]`, `Unknown application ID: ${id}`);
      }
    });
  }
}

function validateMcs(mcs, add, errors) {
  for (const field of ['catalogName', 'provisioningSchemeName']) {
    const value = mcs[field];
    if (typeof value !== 'string' || value.trim() !== value ||
        value.length > LIMITS.citrixObjectNameLength || !CITRIX_OBJECT_NAME_PATTERN.test(value)) {
      add(`mcs.${field}`, `Use 1-${LIMITS.citrixObjectNameLength} characters without \\ / ; : # . * ? = < > | [ ] ( ) quotes or edge spaces.`);
    }
  }
  if (isBlank(mcs.hostingUnitName) || mcs.hostingUnitName.length > 64) {
    add('mcs.hostingUnitName', 'Enter the hosting unit (resource) name.');
  }

  const scheme = mcs.namingScheme;
  let digits = 0;
  if (typeof scheme !== 'string' || !NAMING_SCHEME_PATTERN.test(scheme) ||
      (scheme.match(/#+/g) || []).length !== 1 || !/[A-Za-z]/.test(scheme)) {
    add('mcs.namingScheme', 'Use letters, digits, and hyphens with exactly one run of # (for example VDI-W11-###).');
  } else if (scheme.length > LIMITS.adComputerNameLength) {
    add('mcs.namingScheme', `The complete machine name, including digits, cannot exceed the Active Directory limit of ${LIMITS.adComputerNameLength} characters (and therefore remains below vCenter's 79-character limit).`);
  } else {
    digits = namingSchemeDigits(scheme);
  }

  const domainValid = typeof mcs.domain === 'string' && FQDN_PATTERN.test(mcs.domain);
  if (!domainValid) {
    add('mcs.domain', 'Enter a fully qualified domain name, for example corp.example.test.');
  }
  if (typeof mcs.organizationalUnit !== 'string' || !OU_PATTERN.test(mcs.organizationalUnit)) {
    add('mcs.organizationalUnit', 'Use a distinguished name such as OU=VDI,DC=corp,DC=example,DC=test.');
  } else if (domainValid &&
             lower(domainFromOrganizationalUnit(mcs.organizationalUnit)) !== lower(mcs.domain)) {
    add('mcs.organizationalUnit', 'The OU must be inside the selected domain.');
  }

  const maxMachines = digits > 0
    ? Math.min(LIMITS.machineCount.max, 10 ** digits - 1)
    : LIMITS.machineCount.max;
  checkRange(errors, 'mcs.machineCount', mcs.machineCount, { min: 1, max: maxMachines });

  if (!['Random', 'Static'].includes(mcs.allocationType)) {
    add('mcs.allocationType', 'Choose Random (pooled) or Static (assigned).');
  }

  const machine = mcs.machine;
  if (!isObject(machine)) {
    add('mcs.machine', 'The machine size section is required.');
  } else {
    checkRange(errors, 'mcs.machine.cpus', machine.cpus, LIMITS.cpus);
    checkRange(errors, 'mcs.machine.memoryMb', machine.memoryMb, LIMITS.memoryMb);
  }
}

// ------------------------------------------------------------- generators

function hclString(value) {
  const escaped = String(value)
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\$\{/g, () => '$${')
    .replace(/%\{/g, () => '%%{');
  return `"${escaped}"`;
}

function hclList(values) {
  return `[${values.map(hclString).join(', ')}]`;
}

export function toPackerVariables(config) {
  const image = config.image;
  const entries = [];
  if (image.isoUrl) {
    entries.push(['iso_url', hclString(image.isoUrl)]);
  }
  if (image.isoChecksum) {
    entries.push(['iso_checksum', hclString(image.isoChecksum)]);
  }
  entries.push(
    ['image_name', hclString(image.name)],
    ['image_version', hclString(image.version)],
    ['vsphere_server', hclString(image.vsphere.vcenterServer)],
    ['vsphere_datacenter', hclString(image.vsphere.datacenter)],
    ...(image.vsphere.cluster ? [['vsphere_cluster', hclString(image.vsphere.cluster)]] : []),
    ...(image.vsphere.host ? [['vsphere_host', hclString(image.vsphere.host)]] : []),
    ['vsphere_datastore', hclString(image.vsphere.datastore)],
    ['vsphere_folder', hclString(image.vsphere.folder)],
    ['vsphere_network', hclString(image.vsphere.network)],
    ['vsphere_insecure_connection', image.vsphere.insecureConnection ? 'true' : 'false'],
    ['windows_image_index', String(image.windowsImageIndex)],
    ['cpus', String(image.hardware.cpus)],
    ['memory_mb', String(image.hardware.memoryMb)],
    ['disk_size_mb', String(image.hardware.diskSizeMb)],
    ['ui_language', hclString(image.regional.uiLanguage)],
    ['locale', hclString(image.regional.locale)],
    ['time_zone', hclString(image.regional.timeZone)],
    ['application_profiles', hclList(image.applications.profiles)],
    ['include_applications', hclList(image.applications.include)],
    ['exclude_applications', hclList(image.applications.exclude)],
    ['run_optimizer', image.optimizer.enabled ? 'true' : 'false'],
    ['optimizer_template', hclString(image.optimizer.template)],
  );

  const width = Math.max(...entries.map(([key]) => key.length));
  const lines = [
    '# Generated by the VDI Image Factory Image Builder. This file contains no secrets.',
    '# Supply vCenter credentials and the temporary WinRM password separately through',
    '# PKR_VAR_vsphere_username, PKR_VAR_vsphere_password, and PKR_VAR_winrm_password.',
  ];
  for (const [key, value] of entries) {
    lines.push(`${key.padEnd(width)} = ${value}`);
  }
  return `${lines.join('\n')}\n`;
}

function psString(value) {
  return `'${String(value).replace(/'/g, "''")}'`;
}

export function machineNames(scheme, count) {
  const digits = namingSchemeDigits(scheme);
  const format = (n) => scheme.replace(/#+/, String(n).padStart(digits, '0'));
  return { first: format(1), last: format(count) };
}

export function toMcsPlanScript(config) {
  const mcs = config.mcs;
  const image = config.image;
  const random = mcs.allocationType === 'Random';
  const masterImagePath =
    `XDHyp:\\HostingUnits\\${mcs.hostingUnitName}\\${image.name}.vm\\${image.name}-${image.version}.snapshot`;
  const names = machineNames(mcs.namingScheme, mcs.machineCount);
  const scheme = psString(mcs.provisioningSchemeName);

  const lines = [
    '#Requires -Version 5.1',
    '# MCS machine catalog plan generated by the VDI Image Factory Image Builder.',
    '# Nothing in this script has been executed. Review every value, load the',
    '# Citrix PowerShell SDK, and run it first against a non-production site.',
    `# Machines: ${names.first} to ${names.last} (${mcs.machineCount}) in ${mcs.organizationalUnit}`,
    "$ErrorActionPreference = 'Stop'",
    '',
    '# Snapshot of the imported master VM; adjust it to the snapshot you created.',
    `$masterImageVM = ${psString(masterImagePath)}`,
    '',
    'function Wait-ProvTask {',
    '    param([Parameter(Mandatory)][guid]$TaskId)',
    '    $task = Get-ProvTask -TaskId $TaskId',
    '    while ($task.Active) {',
    '        Start-Sleep -Seconds 30',
    '        $task = Get-ProvTask -TaskId $TaskId',
    '    }',
    "    if ($task.TaskState -ne 'Finished') {",
    '        throw "Provisioning task $TaskId ended in state $($task.TaskState)."',
    '    }',
    '}',
    '',
    '# 1. Identity pool: machine names, domain, and OU for the new computer accounts.',
    `New-AcctIdentityPool -IdentityPoolName ${psString(mcs.catalogName)} \``,
    `    -NamingScheme ${psString(mcs.namingScheme)} -NamingSchemeType Numeric \``,
    `    -Domain ${psString(mcs.domain)} -OU ${psString(mcs.organizationalUnit)} | Out-Null`,
    '',
    '# 2. Provisioning scheme based on the golden image snapshot.',
    `$schemeTask = New-ProvScheme -ProvisioningSchemeName ${scheme} \``,
    `    -HostingUnitName ${psString(mcs.hostingUnitName)} -IdentityPoolName ${psString(mcs.catalogName)} \``,
    `    -MasterImageVM $masterImageVM -VMCpuCount ${mcs.machine.cpus} -VMMemoryMB ${mcs.machine.memoryMb} \``,
    `    ${random ? '-CleanOnBoot ' : ''}-RunAsynchronously`,
    'Wait-ProvTask -TaskId $schemeTask',
    `$provScheme = Get-ProvScheme -ProvisioningSchemeName ${scheme}`,
    '',
    '# 3. Broker machine catalog.',
    `$catalog = New-BrokerCatalog -Name ${psString(mcs.catalogName)} \``,
    `    -AllocationType ${random ? 'Random' : 'Permanent'} -ProvisioningType MCS -SessionSupport SingleSession \``,
    `    -PersistUserChanges ${random ? 'Discard' : 'OnLocal'} -MachinesArePhysical $false \``,
    '    -ProvisioningSchemeId $provScheme.ProvisioningSchemeUid',
    '',
    '# 4. Computer accounts and virtual machines.',
    `$accounts = New-AcctADAccount -IdentityPoolName ${psString(mcs.catalogName)} -Count ${mcs.machineCount}`,
    `$vmTask = New-ProvVM -ProvisioningSchemeName ${scheme} \``,
    '    -ADAccountName @($accounts.SuccessfulAccounts.ADAccountName) -RunAsynchronously',
    'Wait-ProvTask -TaskId $vmTask',
    '',
    '# 5. Register the new machines with the catalog.',
    `$hostingUnit = Get-Item -LiteralPath ${psString(`XDHyp:\\HostingUnits\\${mcs.hostingUnitName}`)}`,
    '$connection = Get-BrokerHypervisorConnection `',
    '    -HypHypervisorConnectionUid $hostingUnit.HypervisorConnection.HypervisorConnectionUid',
    `foreach ($vm in Get-ProvVM -ProvisioningSchemeName ${scheme}) {`,
    `    Lock-ProvVM -ProvisioningSchemeName ${scheme} -Tag 'Brokered' -VMID @($vm.VMId)`,
    '    New-BrokerMachine -CatalogUid $catalog.Uid -MachineName $vm.ADAccountSid `',
    '        -HostedMachineId $vm.VMId -HypervisorConnectionUid $connection.Uid | Out-Null',
    '}',
  ];
  return `${lines.join('\n')}\n`;
}

export function toCommands(config) {
  const isoArguments = [];
  if (!config.image.isoUrl) {
    isoArguments.push("-var 'iso_url=<path or URL of a licensed Windows 11 ISO>'");
  }
  if (!config.image.isoChecksum) {
    isoArguments.push("-var 'iso_checksum=sha256:<ISO checksum>'");
  }
  const build = ['packer build -var-file ./build/build.auto.pkrvars.hcl', ...isoArguments, './packer'];
  const lines = [
    '# 1. Validate the configuration, simulate the pipeline, and write the build files.',
    './scripts/New-VdiBuild.ps1 -ConfigPath ./build.json -OutputDirectory ./build',
    '',
    '# 2. Build the golden image through vCenter on the target ESXi cluster (licensed ISO required).',
    "$env:PKR_VAR_vsphere_username = '<vCenter service account>'",
    "$env:PKR_VAR_vsphere_password = '<vCenter password>'",
    "$env:PKR_VAR_winrm_password = '<temporary password, 16+ characters>'",
    'packer init ./packer',
    build.join(' `\n    '),
  ];
  if (config.mcs) {
    lines.push('', '# 3. Review build/mcs-catalog-plan.ps1, then run it in a non-production Citrix site.');
  }
  return `${lines.join('\n')}\n`;
}
