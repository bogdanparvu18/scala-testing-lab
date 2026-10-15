import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { exportDocument } from './export-ast.mjs';

const langiumRoot = process.env.LANGIUM_ROOT;
if (!langiumRoot) throw new Error('Set LANGIUM_ROOT to the built clinical-dsl-demo directory.');
const fixture = `// Supplementary character exercises UTF-16: 🧪
patient DemoPatient { age 30 condition DemoCondition }
medication paracetamol { 1 mg route PO frequency PRN }
plan DemoPlan { for DemoPatient prescribe paracetamol }
show DemoPlan
`;

async function project(text) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'clinical-bridge-'));
  const input = path.join(directory, 'fixture.clinical');
  try {
    await writeFile(input, text);
    return await exportDocument({ langiumRoot, input, release: 'test-release' });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

test('projects linked AST nodes with exact source text and UTF-16 positions', async () => {
  const request = await project(fixture);
  assert.equal(request.schemaVersion, '1');
  assert.equal(request.policyVersion, 'exact-v1');
  assert.equal(request.terminologyRelease, 'test-release');
  assert.equal(request.document.text, fixture);
  assert.equal(request.mentions.length, 1);
  const m = request.mentions[0];
  assert.equal(m.originalText, 'paracetamol');
  assert.equal(m.role, 'medication');
  assert.equal(m.patientRef, 'DemoPatient');
  assert.equal(m.orderId, 'DemoPlan');
  assert.deepEqual(m.dose, { amount: 1, unit: 'mg' });
  assert.equal(m.source.start.offset, fixture.indexOf('medication'));
  assert.deepEqual(m.source.start, { line: 2, character: 0, offset: fixture.indexOf('medication') });
  assert.equal(fixture.slice(m.source.start.offset, m.source.end.offset), m.source.text);
  assert.equal(m.source.text, 'medication paracetamol { 1 mg route PO frequency PRN }');
  assert.equal('productStrength' in m, false);
  assert.equal('doseForm' in m, false);
});

test('exports only plans selected with show', async () => {
  const request = await project(`${fixture}\nplan Unselected { for DemoPatient prescribe paracetamol }\n`);
  assert.deepEqual(request.mentions.map(m => m.orderId), ['DemoPlan']);
});

test('rejects syntax and unresolved references', async () => {
  await assert.rejects(project(fixture.replace('route PO', 'route INVALID')), /errors|Expecting|expected|Lexing/);
  await assert.rejects(project(fixture.replace('prescribe paracetamol', 'prescribe MissingDrug')), /reference|resolve/);
});

test('runs original Langium demo amount validator', async () => {
  await assert.rejects(project(fixture.replace('1 mg', '500 mg')), /Amount not in the prototype list/);
});

test('rejects duplicate declarations before dereferencing', async () => {
  await assert.rejects(project(`${fixture}\nmedication paracetamol { 2.5 mg route PO frequency PRN }`), /Duplicate medication/);
  await assert.rejects(project(`${fixture}\npatient DemoPatient { age 35 condition Other }`), /Duplicate patient/);
  await assert.rejects(project(`${fixture}\nplan DemoPlan { for DemoPatient prescribe paracetamol }`), /Duplicate plan/);
});

test('rejects repeated or absent show statements', async () => {
  await assert.rejects(project(`${fixture}\nshow DemoPlan`), /more than once/);
  await assert.rejects(project(fixture.replace('show DemoPlan', '')), /No show statement/);
});
