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

test('accepts positive doses and rejects zero', async () => {
  assert.equal((await project(fixture.replace('1 mg', '15 mg'))).mentions[0].dose.amount, 15);
  await assert.rejects(project(fixture.replace('1 mg', '0 mg')), /greater than zero/);
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

test('exports explicit product strength and dose form separately from the administered dose', async () => {
  const text = fixture.replace('1 mg route', '1 mg strength "500 mg" doseForm "Oral Tablet" route');
  const request = await project(text);
  assert.deepEqual(request.mentions[0].dose, { amount: 1, unit: 'mg' });
  assert.equal(request.mentions[0].productStrength, '500 mg');
  assert.equal(request.mentions[0].doseForm, 'Oral Tablet');
  assert.equal(text.slice(request.mentions[0].source.start.offset, request.mentions[0].source.end.offset), request.mentions[0].source.text);
});

test('accepts concentration and unit variations without applying demo dose options to strength', async () => {
  for (const strength of ['325 mg', '0.5 g', '160 mg/5 ml']) {
    const request = await project(fixture.replace('1 mg route', `1 mg strength "${strength}" doseForm "Oral Tablet" route`));
    assert.equal(request.mentions[0].productStrength, strength);
  }
});

test('validates the pair of product qualifiers and positive supported strength representation', async () => {
  await assert.rejects(project(fixture.replace('1 mg route', '1 mg strength "325 mg" route')), /together/);
  await assert.rejects(project(fixture.replace('1 mg route', '1 mg doseForm "Oral Tablet" route')), /together/);
  for (const strength of ['0 mg', '12 mg/0 ml', '500 percent', '-1 mg']) {
    await assert.rejects(project(fixture.replace('1 mg route', `1 mg strength "${strength}" doseForm "Oral Tablet" route`)), /strength|positive/);
  }
});

const colonFixture = `// UTF-16 🧪
Patient DemoPatient: age 30, condition DemoCondition
Medication paracetamol: 15 mg, strength 160 mg/5 ml, doseForm Oral Solution, route PO, frequency PRN
Plan DemoPlan: for DemoPatient, prescribe paracetamol
show DemoPlan
`;
test('colon syntax exports the same contract and exact source positions', async () => {
  const request = await project(colonFixture);
  const m = request.mentions[0];
  assert.deepEqual(m.dose, { amount: 15, unit: 'mg' });
  assert.equal(m.productStrength, '160 mg/5 ml');
  assert.equal(m.doseForm, 'Oral Solution');
  assert.equal(m.originalText, 'paracetamol');
  assert.equal(m.patientRef, 'DemoPatient');
  assert.equal(colonFixture.slice(m.source.start.offset, m.source.end.offset), m.source.text);
  assert.equal(m.source.text, colonFixture.split('\n')[2]);
  assert.equal(request.schemaVersion, '1');
});
