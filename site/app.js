import {
  LIMITS,
  domainFromOrganizationalUnit,
  machineNames,
  namingSchemeDigits,
  profileApplicationIds,
  resolveApplications,
  toCommands,
  toMcsPlanScript,
  toPackerVariables,
  validateConfiguration,
} from './lib/image-builder.js';

const MEMORY_GB = [4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128];
const DISK_GB = [64, 80, 96, 128, 160, 200, 256, 512];
const DEFAULT_MCS = {
  catalogName: 'Engineering Desktops',
  provisioningSchemeName: 'Engineering-W11',
  hostingUnitName: 'Primary',
  namingScheme: 'VDI-ENG-###',
  domain: 'corp.example.test',
  organizationalUnit: 'OU=Engineering,OU=VDI,DC=corp,DC=example,DC=test',
  machineCount: 25,
  allocationType: 'Random',
  machine: { cpus: 2, memoryMb: 8192 },
};

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

let reference;
let example;
let config;
let savedMcs = structuredClone(DEFAULT_MCS);
let activeTab = 'plan';

// ------------------------------------------------------------------ utilities

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function getPath(object, path) {
  return path.split('.').reduce((value, key) => (value == null ? undefined : value[key]), object);
}

function setPath(object, path, value) {
  const keys = path.split('.');
  let target = object;
  for (const key of keys.slice(0, -1)) {
    if (target[key] == null || typeof target[key] !== 'object') {
      target[key] = {};
    }
    target = target[key];
  }
  target[keys.at(-1)] = value;
}

function toast(message) {
  const element = $('#toast');
  element.textContent = message;
  element.classList.add('show');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => element.classList.remove('show'), 1800);
}

function download(name, content, type = 'text/plain') {
  const url = URL.createObjectURL(new Blob([content], { type }));
  const link = Object.assign(document.createElement('a'), { href: url, download: name });
  document.body.append(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

async function copy(text, label) {
  try {
    await navigator.clipboard.writeText(text);
    toast(`${label} copied`);
  } catch {
    toast('Copy is not available in this browser');
  }
}

function encodeConfig(value) {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  let binary = '';
  bytes.forEach((byte) => { binary += String.fromCharCode(byte); });
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function decodeConfig(text) {
  const binary = atob(text.replace(/-/g, '+').replace(/_/g, '/'));
  const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
  return JSON.parse(new TextDecoder().decode(bytes));
}

function gb(mb) {
  return `${Math.round(mb / 1024)} GB`;
}

// --------------------------------------------------------------- form setup

function fillSelect(select, options, value) {
  const values = options.map((option) => option.value);
  const all = [...options];
  if (value != null && !values.includes(value)) {
    all.push({ value, label: `${value} (custom)` });
  }
  select.innerHTML = all
    .map((option) => `<option value="${escapeHtml(option.value)}">${escapeHtml(option.label)}</option>`)
    .join('');
  if (value != null) {
    select.value = String(value);
  }
}

function sizeOptions(values) {
  return values.map((size) => ({ value: size * 1024, label: `${size} GB` }));
}

function populateForm() {
  const locales = reference.locales.map((item) => ({ value: item.id, label: `${item.name} — ${item.id}` }));
  const zones = reference.timeZones.map((item) => ({ value: item.id, label: `(UTC${item.utcOffset}) ${item.id}` }));
  const image = config.image || {};
  fillSelect($('#f-memory'), sizeOptions(MEMORY_GB), getPath(image, 'hardware.memoryMb'));
  fillSelect($('#f-disk'), sizeOptions(DISK_GB), getPath(image, 'hardware.diskSizeMb'));
  fillSelect($('#f-ui'), locales, getPath(image, 'regional.uiLanguage'));
  fillSelect($('#f-locale'), locales, getPath(image, 'regional.locale'));
  fillSelect($('#f-tz'), zones, getPath(image, 'regional.timeZone'));
  const mcs = config.mcs || savedMcs;
  fillSelect($('#m-memory'), sizeOptions(MEMORY_GB), getPath(mcs, 'machine.memoryMb'));

  for (const input of $$('[data-path]')) {
    const path = input.dataset.path;
    const source = path.startsWith('mcs.') && !config.mcs ? { mcs: savedMcs } : config;
    const value = getPath(source, path);
    if (input.type === 'checkbox') {
      input.checked = Boolean(value);
    } else if (input.type === 'radio') {
      input.checked = input.value === value;
    } else if (input.tagName !== 'SELECT') {
      input.value = value ?? '';
    }
  }
  $('#mcs-enabled').checked = Boolean(config.mcs);
  syncSliders();
  renderProfiles();
  renderApplications();
}

function syncSliders() {
  for (const slider of $$('input[type="range"][data-mirror]')) {
    const target = document.getElementById(slider.dataset.mirror);
    slider.value = target.value;
  }
}

function readInput(input) {
  const type = input.dataset.type;
  if (type === 'bool') {
    return input.checked;
  }
  if (type === 'int') {
    if (input.value.trim() === '') {
      return null;
    }
    const number = Number(input.value);
    return Number.isFinite(number) ? number : input.value;
  }
  return input.value;
}

function bindForm() {
  $('#builder').addEventListener('input', (event) => {
    const input = event.target;
    if (input.matches('input[type="range"][data-mirror]')) {
      const target = document.getElementById(input.dataset.mirror);
      target.value = input.value;
      target.dispatchEvent(new Event('input', { bubbles: true }));
      return;
    }
    if (!input.dataset.path) {
      return;
    }
    if (input.type === 'radio' && !input.checked) {
      return;
    }
    const path = input.dataset.path;
    if (path.startsWith('mcs.') && !config.mcs) {
      return;
    }
    setPath(config, path, readInput(input));
    syncSliders();
    refresh();
  });
  $('#builder').addEventListener('change', (event) => {
    if (event.target.tagName === 'SELECT' || event.target.type === 'radio' || event.target.type === 'checkbox') {
      event.target.dispatchEvent(new Event('input', { bubbles: true }));
    }
  });
  $('#builder').addEventListener('submit', (event) => event.preventDefault());

  $('#mcs-enabled').addEventListener('change', (event) => {
    if (event.target.checked) {
      config.mcs = structuredClone(savedMcs);
    } else {
      savedMcs = structuredClone(config.mcs);
      config.mcs = null;
    }
    populateForm();
    refresh();
  });

  $('#ou-from-domain').addEventListener('click', () => {
    const domain = config.mcs?.domain || '';
    const parts = domain.split('.').filter(Boolean).map((part) => `DC=${part}`);
    if (!parts.length) {
      toast('Enter the domain first');
      return;
    }
    config.mcs.organizationalUnit = ['OU=VDI', ...parts].join(',');
    $('#m-ou').value = config.mcs.organizationalUnit;
    refresh();
  });

  $('#app-search').addEventListener('input', renderApplications);
  $('#apps-all').addEventListener('click', () => {
    const base = new Set(baseIds().map((id) => id.toLowerCase()));
    config.image.applications.include = reference.catalog.applications
      .map((app) => app.id)
      .filter((id) => !base.has(id.toLowerCase()));
    config.image.applications.exclude = [];
    renderApplications();
    refresh();
  });
  $('#apps-reset').addEventListener('click', () => {
    config.image.applications.include = [];
    config.image.applications.exclude = [];
    renderApplications();
    refresh();
  });

  $('#load-example').addEventListener('click', () => {
    loadConfig(structuredClone(example));
    toast('Example loaded');
  });
  $('#import-file').addEventListener('change', async (event) => {
    const [file] = event.target.files;
    event.target.value = '';
    if (!file) {
      return;
    }
    try {
      loadConfig(JSON.parse(await file.text()));
      toast(`${file.name} imported`);
    } catch (error) {
      toast(`Could not import: ${error.message}`);
    }
  });
  $('#share').addEventListener('click', () => {
    const url = `${location.origin}${location.pathname}#config=${encodeConfig(config)}`;
    history.replaceState(null, '', url);
    copy(url, 'Share link');
  });

  for (const tab of $$('.tabs [data-tab]')) {
    tab.addEventListener('click', () => {
      activeTab = tab.dataset.tab;
      $$('.tabs [data-tab]').forEach((item) => item.setAttribute('aria-selected', String(item === tab)));
      renderPanel(validateConfiguration(config, reference));
    });
  }
}

// ------------------------------------------------------------- applications

function baseIds() {
  const profiles = (config.image?.applications?.profiles || []).filter((name) =>
    reference.catalog.profiles.some((item) => item.name.toLowerCase() === String(name).toLowerCase()));
  try {
    return profileApplicationIds(reference.catalog, profiles);
  } catch {
    return [];
  }
}

function selectedIds() {
  const apps = config.image.applications;
  try {
    return resolveApplications(reference.catalog, apps.profiles, apps.include, apps.exclude).map((app) => app.id);
  } catch {
    return [];
  }
}

function renderProfiles() {
  const selected = new Set((config.image?.applications?.profiles || []).map((name) => String(name).toLowerCase()));
  $('#profiles').innerHTML = reference.catalog.profiles.map((item) => {
    const on = selected.has(item.name.toLowerCase());
    const parent = item.extends?.length ? ` Includes ${item.extends.join(', ')}.` : '';
    return `<label class="chip${on ? ' selected' : ''}">
      <input type="checkbox" data-profile="${escapeHtml(item.name)}"${on ? ' checked' : ''}>
      <div><strong>${escapeHtml(item.name)}</strong><span>${escapeHtml(item.description || '')}${escapeHtml(parent)}</span></div>
    </label>`;
  }).join('');

  for (const input of $$('[data-profile]')) {
    input.addEventListener('change', () => {
      const apps = config.image.applications;
      const name = input.dataset.profile;
      apps.profiles = input.checked
        ? [...apps.profiles, name]
        : apps.profiles.filter((item) => String(item).toLowerCase() !== name.toLowerCase());
      const base = new Set(baseIds().map((id) => id.toLowerCase()));
      apps.include = apps.include.filter((id) => id === '*' || !base.has(id.toLowerCase()));
      apps.exclude = apps.exclude.filter((id) => id === '*' || base.has(id.toLowerCase()));
      renderProfiles();
      renderApplications();
      refresh();
    });
  }
}

function renderApplications() {
  const base = new Set(baseIds().map((id) => id.toLowerCase()));
  const selected = new Set(selectedIds().map((id) => id.toLowerCase()));
  const query = $('#app-search').value.trim().toLowerCase();
  const apps = reference.catalog.applications.filter((app) =>
    !query || app.name.toLowerCase().includes(query) || app.id.toLowerCase().includes(query));

  $('#app-list').innerHTML = apps.map((app) => {
    const key = app.id.toLowerCase();
    const on = selected.has(key);
    let tag = '';
    if (base.has(key) && on) tag = '<span class="tag profile">profile</span>';
    else if (base.has(key)) tag = '<span class="tag removed">removed</span>';
    else if (on) tag = '<span class="tag added">added</span>';
    return `<label class="app">
      <input type="checkbox" data-app="${escapeHtml(app.id)}"${on ? ' checked' : ''}>
      <div class="meta"><div class="name">${escapeHtml(app.name)}</div><div class="id">${escapeHtml(app.id)}</div></div>
      ${tag}
    </label>`;
  }).join('') || '<p class="hint">No application matches the search.</p>';

  for (const input of $$('[data-app]')) {
    input.addEventListener('change', () => toggleApplication(input.dataset.app, input.checked));
  }
  $('#apps-count').textContent = `${selected.size} of ${reference.catalog.applications.length} selected`;
}

function toggleApplication(id, checked) {
  const apps = config.image.applications;
  const key = id.toLowerCase();
  const inBase = baseIds().some((item) => item.toLowerCase() === key);
  apps.include = apps.include.filter((item) => item.toLowerCase() !== key);
  apps.exclude = apps.exclude.filter((item) => item.toLowerCase() !== key);
  if (inBase && !checked) apps.exclude.push(id);
  if (!inBase && checked) apps.include.push(id);
  renderApplications();
  refresh();
}

// -------------------------------------------------------------------- output

function planSteps() {
  const image = config.image;
  const apps = selectedIds();
  const names = Object.fromEntries(reference.catalog.applications.map((app) => [app.id.toLowerCase(), app.name]));
  const zone = reference.timeZones.find((item) => item.id === image.regional.timeZone);
  const steps = [
    {
      where: 'Hyper-V host',
      title: `Create build VM ${image.name}`,
      detail: `Generation 2, Secure Boot, ${image.hardware.cpus} vCPU, ${gb(image.hardware.memoryMb)} RAM, ${gb(image.hardware.diskSizeMb)} disk on “${image.hardware.switchName}”.`,
    },
    {
      where: 'Guest',
      title: 'Unattended Windows 11 setup',
      detail: `Edition index ${image.windowsImageIndex}; ${image.regional.uiLanguage} display language, ${image.regional.locale} locale; ${zone ? `(UTC${zone.utcOffset}) ` : ''}${image.regional.timeZone}.`,
    },
    {
      where: 'Guest',
      title: `Install ${apps.length} application${apps.length === 1 ? '' : 's'} with WinGet`,
      detail: apps.length ? apps.map((id) => names[id.toLowerCase()] || id).join(', ') : 'No applications selected.',
    },
    {
      where: 'Guest',
      title: 'Citrix Optimizer',
      detail: image.optimizer.enabled ? `Execute with template ${image.optimizer.template}.` : 'Skipped for this build.',
      skipped: !image.optimizer.enabled,
    },
    {
      where: 'Guest',
      title: 'Seal and record the manifest',
      detail: `Refuse to seal with a pending reboot; write version ${image.version} and the application list to C:\\ProgramData\\VdiImageFactory\\image-manifest.json; export the VHDX.`,
    },
  ];
  if (config.mcs) {
    const mcs = config.mcs;
    const range = machineNames(mcs.namingScheme, mcs.machineCount);
    steps.push({
      where: 'Citrix site (review first)',
      title: `Create catalog “${mcs.catalogName}”`,
      detail: `Identity pool ${range.first} … ${range.last} (${mcs.machineCount}) in ${mcs.organizationalUnit}; ${mcs.allocationType === 'Random' ? 'pooled, changes discarded' : 'assigned, changes kept'}; ${mcs.machine.cpus} vCPU and ${gb(mcs.machine.memoryMb)} per machine.`,
    });
  }
  return steps;
}

function outputs() {
  return {
    json: `${JSON.stringify(config, null, 2)}\n`,
    hcl: toPackerVariables(config),
    mcs: config.mcs ? toMcsPlanScript(config) : '',
    commands: toCommands(config),
  };
}

const FILES = {
  json: ['build.json', 'application/json'],
  hcl: ['build.auto.pkrvars.hcl', 'text/plain'],
  mcs: ['mcs-catalog-plan.ps1', 'text/plain'],
  commands: ['commands.ps1', 'text/plain'],
};

function renderPanel(errors) {
  const panel = $('#panel');
  if (activeTab === 'plan') {
    if (errors.length) {
      panel.innerHTML = '<p class="hint">Fix the highlighted fields to see the build plan.</p>';
      return;
    }
    panel.innerHTML = `<ol class="plan">${planSteps().map((step, index) => `
      <li data-step="${index + 1}" class="${step.skipped ? 'skipped' : ''}">
        <span class="where">${escapeHtml(step.where)}</span>
        <strong>${escapeHtml(step.title)}</strong>
        <div class="detail">${escapeHtml(step.detail)}</div>
      </li>`).join('')}</ol>`;
    return;
  }
  if (errors.length && activeTab !== 'json') {
    panel.innerHTML = '<p class="hint">Files are generated once the configuration is valid.</p>';
    return;
  }
  if (activeTab === 'mcs' && !config.mcs) {
    panel.innerHTML = '<p class="hint">Enable “Plan a machine catalog” in section 6 to generate the Citrix SDK plan.</p>';
    return;
  }
  const content = outputs()[activeTab];
  const [name, type] = FILES[activeTab];
  panel.innerHTML = `<div class="panel-actions">
      <button type="button" id="copy-out">Copy</button>
      <button type="button" class="primary" id="download-out">Download ${escapeHtml(name)}</button>
    </div>
    <pre class="code" tabindex="0">${escapeHtml(content)}</pre>`;
  $('#copy-out').addEventListener('click', () => copy(content, name));
  $('#download-out').addEventListener('click', () => download(name, content, type));
}

function renderErrors(errors) {
  const byPath = new Map();
  for (const error of errors) {
    const path = error.path.replace(/\[\d+\]$/, '');
    if (!byPath.has(path)) byPath.set(path, error.message);
  }
  for (const element of $$('[data-error-for]')) {
    const message = byPath.get(element.dataset.errorFor);
    element.textContent = message || '';
    element.closest('.field')?.classList.toggle('invalid', Boolean(message));
    if (!element.closest('.field')) element.style.display = message ? 'block' : 'none';
  }

  const status = $('#status');
  status.className = `status ${errors.length ? 'bad' : 'ok'}`;
  status.textContent = errors.length
    ? `${errors.length} problem${errors.length === 1 ? '' : 's'} to fix before generating files`
    : 'Configuration is valid';

  $('#problems').innerHTML = errors.map((error) =>
    `<li><button type="button" data-goto="${escapeHtml(error.path.replace(/\[\d+\]$/, ''))}">${escapeHtml(error.path)}: ${escapeHtml(error.message)}</button></li>`).join('');
  for (const button of $$('[data-goto]')) {
    button.addEventListener('click', () => {
      const target = $(`[data-path="${button.dataset.goto}"]`) || $(`[data-error-for="${button.dataset.goto}"]`);
      target?.scrollIntoView({ behavior: 'smooth', block: 'center' });
      target?.focus?.({ preventScroll: true });
    });
  }
}

function renderSummary() {
  const image = config.image;
  const items = [
    ['Image', `${image.name} ${image.version}`],
    ['Build VM', `${image.hardware.cpus} vCPU · ${gb(image.hardware.memoryMb || 0)} · ${gb(image.hardware.diskSizeMb || 0)}`],
    ['Applications', `${selectedIds().length}`],
    ['Machines', config.mcs ? `${config.mcs.machineCount} × ${config.mcs.machine.cpus} vCPU / ${gb(config.mcs.machine.memoryMb || 0)}` : 'No catalog planned'],
  ];
  $('#summary').innerHTML = items.map(([label, value]) =>
    `<div><dt>${escapeHtml(label)}</dt><dd>${escapeHtml(value)}</dd></div>`).join('');
}

function renderMcsHelpers() {
  $('#mcs-fields').style.opacity = config.mcs ? '1' : '0.5';
  for (const input of $$('#mcs-fields input, #mcs-fields select, #mcs-fields button')) {
    input.disabled = !config.mcs;
  }
  const mcs = config.mcs || savedMcs;
  const digits = namingSchemeDigits(mcs.namingScheme);
  const max = digits > 0 ? Math.min(LIMITS.machineCount.max, 10 ** digits - 1) : LIMITS.machineCount.max;
  $('#m-count').max = String(max);
  $('input[data-mirror="m-count"]').max = String(Math.min(max, 200));
  if (digits > 0 && Number.isInteger(mcs.machineCount) && mcs.machineCount > 0) {
    const range = machineNames(mcs.namingScheme, Math.min(mcs.machineCount, max));
    $('#names-preview').textContent = `${range.first} … ${range.last} (up to ${max} machines)`;
  } else {
    $('#names-preview').textContent = 'Use # for the machine number, for example VDI-W11-###.';
  }
  const domainPart = mcs.organizationalUnit ? domainFromOrganizationalUnit(mcs.organizationalUnit) : '';
  $('#ou-from-domain').title = domainPart ? `Current OU is in ${domainPart}` : '';
  for (const card of $$('.radio-card')) {
    card.classList.toggle('selected', card.querySelector('input').checked);
  }
}

function refresh() {
  const errors = validateConfiguration(config, reference);
  renderErrors(errors);
  renderSummary();
  renderMcsHelpers();
  renderPanel(errors);
  if (location.hash.startsWith('#config=')) {
    history.replaceState(null, '', `${location.pathname}#config=${encodeConfig(config)}`);
  }
}

function normalize(value) {
  const next = structuredClone(value);
  next.image ??= structuredClone(example.image);
  next.image.applications ??= { profiles: ['standard'], include: [], exclude: [] };
  next.image.applications.include ??= [];
  next.image.applications.exclude ??= [];
  next.image.hardware ??= structuredClone(example.image.hardware);
  next.image.regional ??= structuredClone(example.image.regional);
  next.image.optimizer ??= structuredClone(example.image.optimizer);
  if (next.mcs === undefined) next.mcs = null;
  return next;
}

function loadConfig(value) {
  config = normalize(value);
  if (config.mcs) savedMcs = structuredClone(config.mcs);
  populateForm();
  refresh();
}

async function start() {
  const load = (name) => fetch(`./config/${name}`).then((response) => {
    if (!response.ok) throw new Error(`${name}: HTTP ${response.status}`);
    return response.json();
  });
  const [catalog, locales, zones, sample] = await Promise.all([
    load('application-catalog.json'),
    load('windows-locales.json'),
    load('windows-time-zones.json'),
    load('build.example.json'),
  ]);
  reference = { catalog, locales: locales.locales, timeZones: zones.timeZones };
  example = sample;
  bindForm();

  let initial = structuredClone(example);
  if (location.hash.startsWith('#config=')) {
    try {
      initial = decodeConfig(location.hash.slice('#config='.length));
    } catch {
      toast('The share link could not be read; the example was loaded instead');
    }
  }
  loadConfig(initial);
}

start().catch((error) => {
  $('#status').className = 'status bad';
  $('#status').textContent = `Could not load the catalog: ${error.message}`;
});
