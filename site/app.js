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

const STEPS = [
  { id: 'image', title: 'Image' },
  { id: 'vm', title: 'Build VM' },
  { id: 'region', title: 'Language and region' },
  { id: 'apps', title: 'Applications' },
  { id: 'optimizer', title: 'Citrix Optimizer' },
  { id: 'catalog', title: 'Machine catalog' },
  { id: 'summary', title: 'Summary' },
];

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

let reference;
let example;
let config;
let savedMcs = structuredClone(DEFAULT_MCS);
let current = 0;
const visited = new Set(['image']);
const checked = new Set();

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
  return `${Math.round((mb || 0) / 1024)} GB`;
}

function plural(count, word) {
  return `${count} ${word}${count === 1 ? '' : 's'}`;
}

// ---------------------------------------------------------------- validation

function stepOf(path) {
  if (path.startsWith('mcs')) return 'catalog';
  if (path.startsWith('image.hardware')) return 'vm';
  if (path.startsWith('image.regional')) return 'region';
  if (path.startsWith('image.applications')) return 'apps';
  if (path.startsWith('image.optimizer')) return 'optimizer';
  return 'image';
}

function allErrors() {
  return validateConfiguration(config, reference);
}

function errorsFor(stepId, errors = allErrors()) {
  return errors.filter((error) => stepOf(error.path) === stepId);
}

// ---------------------------------------------------------------- form setup

function fillSelect(select, options, value) {
  const values = options.map((option) => String(option.value));
  const all = [...options];
  if (value != null && !values.includes(String(value))) {
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
  const locales = reference.locales.map((item) => ({ value: item.id, label: `${item.name} (${item.id})` }));
  const zones = reference.timeZones.map((item) => ({ value: item.id, label: `(UTC${item.utcOffset}) ${item.id}` }));
  const image = config.image;
  const mcs = config.mcs || savedMcs;
  fillSelect($('#f-memory'), sizeOptions(MEMORY_GB), getPath(image, 'hardware.memoryMb'));
  fillSelect($('#f-disk'), sizeOptions(DISK_GB), getPath(image, 'hardware.diskSizeMb'));
  fillSelect($('#f-ui'), locales, getPath(image, 'regional.uiLanguage'));
  fillSelect($('#f-locale'), locales, getPath(image, 'regional.locale'));
  fillSelect($('#f-tz'), zones, getPath(image, 'regional.timeZone'));
  fillSelect($('#m-memory'), sizeOptions(MEMORY_GB), getPath(mcs, 'machine.memoryMb'));

  for (const input of $$('[data-path]')) {
    const path = input.dataset.path;
    const source = path.startsWith('mcs.') && !config.mcs ? { mcs: savedMcs } : config;
    const value = getPath(source, path);
    if (input.type === 'radio') {
      input.checked = input.value === value;
    } else if (input.tagName !== 'SELECT') {
      input.value = value ?? '';
    }
  }
  $('#opt-yes').checked = Boolean(image.optimizer.enabled);
  $('#opt-no').checked = !image.optimizer.enabled;
  $('#mcs-yes').checked = Boolean(config.mcs);
  $('#mcs-no').checked = !config.mcs;
  renderProfiles();
  renderApplications();
}

function readInput(input) {
  if (input.dataset.type === 'int') {
    if (input.value.trim() === '') {
      return null;
    }
    const number = Number(input.value);
    return Number.isFinite(number) ? number : input.value;
  }
  return input.value;
}

function bindForm() {
  const form = $('#builder');
  form.addEventListener('input', (event) => {
    const input = event.target;
    if (!input.dataset.path || (input.type === 'radio' && !input.checked)) {
      return;
    }
    const path = input.dataset.path;
    if (path.startsWith('mcs.') && !config.mcs) {
      return;
    }
    setPath(config, path, readInput(input));
    refresh();
  });
  form.addEventListener('change', (event) => {
    if (event.target.tagName === 'SELECT' || event.target.type === 'radio') {
      event.target.dispatchEvent(new Event('input', { bubbles: true }));
    }
  });
  form.addEventListener('submit', (event) => event.preventDefault());
  form.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && event.target.tagName === 'INPUT' && event.target.type !== 'checkbox') {
      event.preventDefault();
      next();
    }
  });

  for (const radio of $$('input[name="optimizer"]')) {
    radio.addEventListener('change', () => {
      config.image.optimizer.enabled = $('#opt-yes').checked;
      refresh();
    });
  }
  for (const radio of $$('input[name="mcs-enabled"]')) {
    radio.addEventListener('change', () => {
      if ($('#mcs-yes').checked && !config.mcs) {
        config.mcs = structuredClone(savedMcs);
      } else if ($('#mcs-no').checked && config.mcs) {
        savedMcs = structuredClone(config.mcs);
        config.mcs = null;
      }
      populateForm();
      refresh();
    });
  }

  $('#ou-from-domain').addEventListener('click', () => {
    const parts = (config.mcs?.domain || '').split('.').filter(Boolean).map((part) => `DC=${part}`);
    if (!parts.length) {
      toast('Enter the domain first');
      return;
    }
    config.mcs.organizationalUnit = ['OU=VDI', ...parts].join(',');
    $('#m-ou').value = config.mcs.organizationalUnit;
    refresh();
  });

  $('#app-search').addEventListener('input', renderApplications);
  $('#apps-reset').addEventListener('click', () => {
    config.image.applications.include = [];
    config.image.applications.exclude = [];
    renderApplications();
    refresh();
  });

  $('#back').addEventListener('click', () => go(current - 1));
  $('#next').addEventListener('click', next);

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
      STEPS.forEach((step) => { visited.add(step.id); checked.add(step.id); });
      go(STEPS.length - 1);
      toast(`${file.name} opened`);
    } catch (error) {
      toast(`Could not open the file: ${error.message}`);
    }
  });
  $('#share').addEventListener('click', () => {
    const url = `${location.origin}${location.pathname}#config=${encodeConfig(config)}`;
    history.replaceState(null, '', url);
    copy(url, 'Link');
  });
}

// ---------------------------------------------------------------- navigation

function go(index) {
  if (index < 0 || index >= STEPS.length) {
    return;
  }
  current = index;
  visited.add(STEPS[index].id);
  for (const section of $$('.step')) {
    section.hidden = section.dataset.step !== STEPS[index].id;
  }
  $('#step-error').textContent = '';
  refresh();
  const heading = $(`.step[data-step="${STEPS[index].id}"] h1`);
  heading.setAttribute('tabindex', '-1');
  heading.focus({ preventScroll: true });
  window.scrollTo({ top: 0 });
}

function next() {
  const step = STEPS[current];
  if (step.id === 'summary') {
    $('#files').scrollIntoView({ behavior: 'smooth' });
    return;
  }
  checked.add(step.id);
  const errors = errorsFor(step.id);
  if (errors.length) {
    refresh();
    $('#step-error').textContent = `Fix ${plural(errors.length, 'problem')} on this page to continue.`;
    const field = $(`.step[data-step="${step.id}"] .invalid input, .step[data-step="${step.id}"] .invalid select`);
    field?.focus();
    return;
  }
  go(current + 1);
}

function renderSteps(errors) {
  $('#step-list').innerHTML = STEPS.map((step, index) => {
    const bad = step.id !== 'summary' && checked.has(step.id) && errorsFor(step.id, errors).length > 0;
    const done = !bad && index < current && !errorsFor(step.id, errors).length;
    const mark = bad ? '!' : done ? '✓' : String(index + 1);
    const state = bad ? 'invalid' : done ? 'done' : '';
    return `<li><button type="button" class="${state}" data-go="${index}"${index === current ? ' aria-current="step"' : ''}>
      <span class="mark" aria-hidden="true">${mark}</span><span>${escapeHtml(step.title)}</span></button></li>`;
  }).join('');
  for (const button of $$('[data-go]')) {
    button.addEventListener('click', () => go(Number(button.dataset.go)));
  }
  $('#progress').textContent = `Step ${current + 1} of ${STEPS.length} · ${STEPS[current].title}`;
  $('#back').disabled = current === 0;
  $('#next').textContent = STEPS[current].id === 'summary' ? 'Get the files' : STEPS[current + 1].id === 'summary' ? 'Review' : 'Next';
}

// ------------------------------------------------------------- applications

function baseIds() {
  const profiles = (config.image.applications.profiles || []).filter((name) =>
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
  const selected = new Set((config.image.applications.profiles || []).map((name) => String(name).toLowerCase()));
  $('#profiles').innerHTML = reference.catalog.profiles.map((item) => {
    const on = selected.has(item.name.toLowerCase());
    const parent = item.extends?.length ? ` Includes ${item.extends.join(', ')}.` : '';
    let count = 0;
    try { count = profileApplicationIds(reference.catalog, [item.name]).length; } catch { /* unknown profile */ }
    return `<label class="choice${on ? ' selected' : ''}">
      <input type="checkbox" data-profile="${escapeHtml(item.name)}"${on ? ' checked' : ''}>
      <span><strong>${escapeHtml(item.name[0].toUpperCase() + item.name.slice(1))}</strong>
      <small>${escapeHtml(item.description || '')}${escapeHtml(parent)} ${plural(count, 'application')}.</small></span>
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
    let change = '';
    if (base.has(key) && !on) change = 'removed';
    else if (!base.has(key) && on) change = 'added';
    return `<label class="app" title="${escapeHtml(app.id)}">
      <input type="checkbox" data-app="${escapeHtml(app.id)}"${on ? ' checked' : ''}>
      <span class="name">${escapeHtml(app.name)}</span>
      ${change ? `<span class="changed">${change}</span>` : ''}
    </label>`;
  }).join('') || '<p class="empty">No application matches the filter.</p>';

  for (const input of $$('[data-app]')) {
    input.addEventListener('change', () => toggleApplication(input.dataset.app, input.checked));
  }
  $('#apps-count').textContent = `${selected.size} of ${reference.catalog.applications.length} selected`;
}

function toggleApplication(id, on) {
  const apps = config.image.applications;
  const key = id.toLowerCase();
  const inBase = baseIds().some((item) => item.toLowerCase() === key);
  apps.include = apps.include.filter((item) => item.toLowerCase() !== key);
  apps.exclude = apps.exclude.filter((item) => item.toLowerCase() !== key);
  if (inBase && !on) apps.exclude.push(id);
  if (!inBase && on) apps.include.push(id);
  renderApplications();
  refresh();
}

// ------------------------------------------------------------------ summary

function planSteps() {
  const image = config.image;
  const apps = selectedIds();
  const names = Object.fromEntries(reference.catalog.applications.map((app) => [app.id.toLowerCase(), app.name]));
  const steps = [
    ['Hyper-V host', `Create the build VM ${image.name}: generation 2, Secure Boot, ${image.hardware.cpus} vCPU, ${gb(image.hardware.memoryMb)} memory, ${gb(image.hardware.diskSizeMb)} disk.`],
    ['Build VM', `Install Windows 11 unattended from edition index ${image.windowsImageIndex}, in ${image.regional.uiLanguage} with the ${image.regional.timeZone} time zone.`],
    ['Build VM', apps.length
      ? `Install ${plural(apps.length, 'application')} with WinGet: ${apps.map((id) => names[id.toLowerCase()] || id).join(', ')}.`
      : 'No applications to install.'],
    ['Build VM', image.optimizer.enabled ? `Run Citrix Optimizer with the ${image.optimizer.template} template.` : 'Citrix Optimizer is skipped.', !image.optimizer.enabled],
    ['Build VM', `Stop if a reboot is pending, write the manifest for version ${image.version}, seal, and export the VHDX.`],
  ];
  if (config.mcs) {
    const mcs = config.mcs;
    const range = machineNames(mcs.namingScheme, mcs.machineCount);
    steps.push(['Citrix site, after your review', `Create the catalog ${mcs.catalogName} with ${plural(mcs.machineCount, 'machine')}, ${range.first} to ${range.last}, in ${mcs.organizationalUnit}.`]);
  }
  return steps;
}

function summaryRows() {
  const image = config.image;
  const apps = selectedIds();
  const zone = reference.timeZones.find((item) => item.id === image.regional.timeZone);
  const locale = (id) => reference.locales.find((item) => item.id === id)?.name || id;
  const rows = [
    ['Image'],
    ['Name', image.name],
    ['Version', image.version],
    ['Windows edition index', image.windowsImageIndex],
    ['Installation media', image.isoUrl || 'Given to Packer at build time'],
    ['Build VM'],
    ['Size', `${image.hardware.cpus} vCPU, ${gb(image.hardware.memoryMb)} memory, ${gb(image.hardware.diskSizeMb)} disk`],
    ['Virtual switch', image.hardware.switchName],
    ['Language and region'],
    ['Display language', locale(image.regional.uiLanguage)],
    ['Formats and keyboard', locale(image.regional.locale)],
    ['Time zone', zone ? `(UTC${zone.utcOffset}) ${zone.id}` : image.regional.timeZone],
    ['Software'],
    ['Profiles', (image.applications.profiles || []).join(', ') || 'None'],
    ['Applications', plural(apps.length, 'application')],
    ['Citrix Optimizer', image.optimizer.enabled ? `Yes, ${image.optimizer.template}` : 'No'],
    ['Machine catalog'],
  ];
  if (config.mcs) {
    const mcs = config.mcs;
    let names = mcs.namingScheme;
    try {
      const range = machineNames(mcs.namingScheme, mcs.machineCount);
      names = `${range.first} to ${range.last}`;
    } catch { /* shown as the scheme */ }
    rows.push(
      ['Catalog', mcs.catalogName],
      ['Desktops', mcs.allocationType === 'Random' ? 'Random, pooled' : 'Static, assigned'],
      ['Machines', `${mcs.machineCount} × ${mcs.machine.cpus} vCPU, ${gb(mcs.machine.memoryMb)}`],
      ['Computer accounts', names],
      ['Domain and OU', `${mcs.domain}, ${mcs.organizationalUnit}`],
      ['Hosting unit', mcs.hostingUnitName],
    );
  } else {
    rows.push(['Catalog', 'Not planned. Create or update it in Studio.']);
  }
  return rows;
}

function fileList() {
  const files = [
    ['build.json', 'application/json', 'This configuration. Open it here again or pass it to New-VdiBuild.ps1.', `${JSON.stringify(config, null, 2)}\n`],
    ['build.auto.pkrvars.hcl', 'text/plain', 'Packer variables for the Hyper-V build. No secrets.', toPackerVariables(config)],
  ];
  if (config.mcs) {
    files.push(['mcs-catalog-plan.ps1', 'text/plain', 'Citrix PowerShell SDK plan for the catalog. Review it, then run it yourself.', toMcsPlanScript(config)]);
  }
  files.push(['commands.ps1', 'text/plain', 'The commands to run on the Hyper-V host, in order.', toCommands(config)]);
  return files;
}

function renderSummary(errors) {
  const status = $('#status');
  if (errors.length) {
    status.className = 'status bad';
    status.innerHTML = `${plural(errors.length, 'problem')} to fix before the files can be made
      <ul>${errors.map((error) => {
        const index = STEPS.findIndex((step) => step.id === stepOf(error.path));
        return `<li><button type="button" class="link" data-go-fix="${index}">${escapeHtml(STEPS[index].title)}</button>: ${escapeHtml(error.message)}</li>`;
      }).join('')}</ul>`;
    for (const button of $$('[data-go-fix]')) {
      button.addEventListener('click', () => go(Number(button.dataset.goFix)));
    }
    $('#summary').innerHTML = '';
    $('#plan').innerHTML = '';
    $('#files').innerHTML = '<p class="note" style="padding:10px 12px;margin:0">The files are made once every step is valid.</p>';
    return;
  }
  status.className = 'status ok';
  status.textContent = 'Ready. The configuration passed validation.';

  $('#summary').innerHTML = '<colgroup><col class="key"><col></colgroup>' + summaryRows().map(([label, value]) => (value === undefined
    ? `<tr class="group"><th colspan="2">${escapeHtml(label)}</th></tr>`
    : `<tr><th scope="row">${escapeHtml(label)}</th><td>${escapeHtml(value)}</td></tr>`)).join('');

  $('#plan').innerHTML = planSteps().map(([where, text, skipped]) =>
    `<li class="${skipped ? 'skipped' : ''}"><span class="where">${escapeHtml(where)}</span><br>${escapeHtml(text)}</li>`).join('');

  const files = fileList();
  $('#files').innerHTML = files.map(([name, , description], index) => `
    <div class="file">
      <div class="file-head">
        <div class="what"><strong>${escapeHtml(name)}</strong><small>${escapeHtml(description)}</small></div>
        <button type="button" data-view="${index}" aria-expanded="false">View</button>
        <button type="button" data-copy="${index}">Copy</button>
        <button type="button" class="primary" data-download="${index}">Download</button>
      </div>
      <pre hidden tabindex="0" id="file-${index}"></pre>
    </div>`).join('');
  for (const button of $$('[data-view]')) {
    button.addEventListener('click', () => {
      const [, , , content] = files[button.dataset.view];
      const pre = $(`#file-${button.dataset.view}`);
      pre.textContent = content;
      pre.hidden = !pre.hidden;
      button.textContent = pre.hidden ? 'View' : 'Hide';
      button.setAttribute('aria-expanded', String(!pre.hidden));
    });
  }
  for (const button of $$('[data-copy]')) {
    const [name, , , content] = files[button.dataset.copy];
    button.addEventListener('click', () => copy(content, name));
  }
  for (const button of $$('[data-download]')) {
    const [name, type, , content] = files[button.dataset.download];
    button.addEventListener('click', () => download(name, content, type));
  }
}

// ------------------------------------------------------------------ refresh

function renderErrors(errors) {
  const byPath = new Map();
  for (const error of errors) {
    const path = error.path.replace(/\[\d+\]$/, '');
    if (!byPath.has(path)) byPath.set(path, error.message);
  }
  for (const element of $$('[data-error-for]')) {
    const path = element.dataset.errorFor;
    const message = checked.has(stepOf(path)) || edited.has(path) ? byPath.get(path) : undefined;
    element.textContent = message || '';
    element.closest('.field')?.classList.toggle('invalid', Boolean(message));
  }
  if (!errorsFor(STEPS[current].id, errors).length) {
    $('#step-error').textContent = '';
  }
}

function renderHelpers() {
  $('#mcs-fields').hidden = !config.mcs;
  $('#template-field').hidden = !config.image.optimizer.enabled;
  for (const choice of $$('.choice')) {
    choice.classList.toggle('selected', choice.querySelector('input').checked);
  }
  const mcs = config.mcs || savedMcs;
  const digits = namingSchemeDigits(mcs.namingScheme);
  const max = digits > 0 ? Math.min(LIMITS.machineCount.max, 10 ** digits - 1) : LIMITS.machineCount.max;
  $('#m-count').max = String(max);
  if (digits > 0 && Number.isInteger(mcs.machineCount) && mcs.machineCount > 0) {
    const range = machineNames(mcs.namingScheme, Math.min(mcs.machineCount, max));
    $('#names-preview').textContent = `Creates ${range.first} to ${range.last}. This scheme allows up to ${max} machines.`;
  } else {
    $('#names-preview').textContent = 'Use # for the machine number, for example VDI-FIN-###.';
  }
  const domainPart = mcs.organizationalUnit ? domainFromOrganizationalUnit(mcs.organizationalUnit) : '';
  $('#ou-from-domain').title = domainPart ? `The current OU is in ${domainPart}` : '';
}

const edited = new Set();

function refresh() {
  const errors = allErrors();
  renderErrors(errors);
  renderSteps(errors);
  renderHelpers();
  if (STEPS[current].id === 'summary') {
    renderSummary(errors);
  }
  if (location.hash.startsWith('#config=')) {
    history.replaceState(null, '', `${location.pathname}#config=${encodeConfig(config)}`);
  }
}

function normalize(value) {
  const next = structuredClone(value);
  next.image ??= structuredClone(example.image);
  next.image.applications ??= { profiles: ['standard'], include: [], exclude: [] };
  next.image.applications.profiles ??= [];
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
  $('#builder').addEventListener('input', (event) => {
    if (event.target.dataset.path) edited.add(event.target.dataset.path);
  }, true);

  let initial = structuredClone(example);
  if (location.hash.startsWith('#config=')) {
    try {
      initial = decodeConfig(location.hash.slice('#config='.length));
    } catch {
      toast('The link could not be read; the example was loaded instead');
    }
  }
  loadConfig(initial);
  go(0);
}

start().catch((error) => {
  $('#step-error').textContent = `Could not load the application catalog: ${error.message}`;
});
