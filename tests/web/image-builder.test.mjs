// Runs the shared fixtures against the browser implementation.
// The PowerShell suite (tests/VdiImageFactory.Tests.ps1) runs the same files.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

import {
  machineNames,
  resolveApplications,
  toCommands,
  toMcsPlanScript,
  toPackerVariables,
  validateConfiguration,
} from '../../site/lib/image-builder.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const readJson = (relative) => JSON.parse(readFileSync(path.join(root, relative), 'utf8'));
const readText = (relative) => readFileSync(path.join(root, relative), 'utf8').replace(/\r\n/g, '\n');

const catalog = readJson('config/application-catalog.json');
const reference = {
  catalog,
  locales: readJson('config/windows-locales.json').locales,
  timeZones: readJson('config/windows-time-zones.json').timeZones,
};
const example = readJson('config/build.example.json');

function applyPatch(base, patch) {
  const config = structuredClone(base);
  for (const [dotted, value] of Object.entries(patch)) {
    const keys = dotted.split('.');
    let target = config;
    for (const key of keys.slice(0, -1)) {
      target = target[key];
    }
    target[keys.at(-1)] = value;
  }
  return config;
}

for (const testCase of readJson('tests/fixtures/build-configuration-cases.json').cases) {
  test(`validation: ${testCase.name}`, () => {
    const errors = validateConfiguration(applyPatch(example, testCase.patch), reference);
    assert.deepEqual(errors.map((error) => error.path), testCase.errors);
  });
}

for (const testCase of readJson('tests/fixtures/catalog-resolution-cases.json').cases) {
  test(`catalog: ${testCase.name}`, () => {
    const run = () => resolveApplications(catalog, testCase.profiles, testCase.include, testCase.exclude);
    if (testCase.error) {
      assert.throws(run, { message: testCase.error });
      return;
    }
    const ids = run().map((app) => app.id);
    if (testCase.ids) {
      assert.deepEqual(ids, testCase.ids);
    }
    if (testCase.count !== undefined) {
      assert.equal(ids.length, testCase.count);
    }
  });
}

test('packer variables match the golden file', () => {
  assert.equal(toPackerVariables(example), readText('tests/fixtures/build.example.pkrvars.hcl'));
});

test('MCS plan matches the golden file', () => {
  assert.equal(toMcsPlanScript(example), readText('tests/fixtures/build.example.mcs-catalog-plan.ps1'));
});

test('HCL strings are escaped', () => {
  const config = applyPatch(example, { 'image.hardware.switchName': 'Lab "A" \\ ${x}' });
  assert.match(toPackerVariables(config), /switch_name\s+= "Lab \\"A\\" \\\\ \$\$\{x\}"/);
});

test('PowerShell strings in the MCS plan are escaped', () => {
  const config = applyPatch(example, { 'mcs.hostingUnitName': "O'Brien" });
  assert.match(toMcsPlanScript(config), /-HostingUnitName 'O''Brien'/);
});

test('machine names follow the naming scheme', () => {
  assert.deepEqual(machineNames('VDI-ENG-###', 25), { first: 'VDI-ENG-001', last: 'VDI-ENG-025' });
});

test('commands ask for the ISO only when it is not in the file', () => {
  assert.match(toCommands(example), /iso_url=<path/);
  const withIso = applyPatch(example, {
    'image.isoUrl': 'file:///C:/ISO/Win11.iso',
    'image.isoChecksum': `sha256:${'a'.repeat(64)}`,
  });
  assert.doesNotMatch(toCommands(withIso), /iso_url=/);
});
