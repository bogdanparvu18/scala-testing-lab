#!/usr/bin/env node
// Project the real, validated Langium AST; never serialize AST cycles or re-parse the DSL here.
import { createRequire } from 'node:module';
import { readFile, writeFile, mkdir, rename, rm } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

const usage = `Usage: node bridge/export-ast.mjs \\
  --langium-root ../langium_dsl_lab/clinical-dsl-demo \\
  --input examples/paracetamol.clinical --release 2026-10-05 \\
  --output data/ast/paracetamol.json

Build the existing clinical-dsl-demo language first. --release must match the
locally imported RxNorm release. Without --output, JSON is written to stdout.
Only plans selected by a 'show PLAN' statement are exported. All examples are fictional.`;

function duplicates(nodes, kind, errors) {
  const seen = new Set();
  for (const node of nodes) {
    if (seen.has(node.name)) errors.push(`Duplicate ${kind} name: ${node.name}`);
    seen.add(node.name);
  }
}

async function langiumImportUrl(resolveFromLanguage, subpath) {
  // Langium 4 is ESM-only. require.resolve('langium') cannot select its `import`
  // export, so locate its package through Node's search paths, then use that export.
  for (const directory of resolveFromLanguage.resolve.paths('langium') ?? []) {
    const packageRoot = path.join(directory, 'langium');
    let metadata;
    try {
      metadata = JSON.parse(await readFile(path.join(packageRoot, 'package.json'), 'utf8'));
    } catch (error) {
      if (error.code === 'ENOENT') continue;
      throw error;
    }
    const target = metadata.exports?.[subpath]?.import;
    if (typeof target !== 'string') throw new Error(`Langium has no ESM export for ${subpath}.`);
    return pathToFileURL(path.resolve(packageRoot, target)).href;
  }
  throw new Error('Langium is not installed in the Clinical DSL workspace.');
}

export async function exportDocument({ langiumRoot, input, release }) {
  if (typeof release !== 'string' || !release.trim()) {
    throw new Error('A nonempty --release is required; it must match the imported terminology.');
  }
  const root = path.resolve(langiumRoot);
  const entry = path.join(root, 'packages/language/out/index.js');
  const resolveFromLanguage = createRequire(entry);
  let language, langium, nodeServices;
  try {
    const [coreUrl, nodeUrl] = await Promise.all([
      langiumImportUrl(resolveFromLanguage, '.'),
      langiumImportUrl(resolveFromLanguage, './node')
    ]);
    [language, langium, nodeServices] = await Promise.all([
      import(pathToFileURL(entry).href),
      import(coreUrl),
      import(nodeUrl)
    ]);
  } catch (error) {
    throw new Error(`Cannot load the built language at ${entry}. Run npm ci, npm run langium:generate, and npm run build in clinical-dsl-demo first. ${error.message}`);
  }
  const { shared, ClinicalDsl } = language.createClinicalDslServices({ ...nodeServices.NodeFileSystem });
  const inputPath = path.resolve(input);
  if (!ClinicalDsl.LanguageMetaData.fileExtensions.includes(path.extname(inputPath))) {
    throw new Error(`Expected a ${ClinicalDsl.LanguageMetaData.fileExtensions.join(' or ')} input file.`);
  }
  // Read once, so text and CST positions describe exactly the same source snapshot.
  const sourceText = await readFile(inputPath, 'utf8');
  const uri = langium.URI.file(inputPath);
  const document = shared.workspace.LangiumDocumentFactory.fromString(sourceText, uri);
  shared.workspace.LangiumDocuments.addDocument(document);
  await shared.workspace.DocumentBuilder.build([document], { validation: true });
  const errors = (document.diagnostics ?? [])
    .filter(d => d.severity === 1)
    .map(d => `${d.range.start.line + 1}:${d.range.start.character + 1}: ${d.message}`);
  if (document.parseResult.lexerErrors.length || document.parseResult.parserErrors.length) {
    errors.push('Lexing/parsing failed; no terminology request was produced.');
  }
  const model = document.parseResult.value;
  if (!language.isModel(model)) errors.push('The input did not produce a Clinical DSL Model.');
  if (errors.length) throw new Error(errors.join('\n'));

  // The original demo does not reject duplicate declarations. Reject these before
  // following .ref: otherwise the linker may choose one of two same-named nodes.
  duplicates(model.patient, 'patient', errors);
  duplicates(model.medication, 'medication', errors);
  duplicates(model.plan, 'plan', errors);
  const selected = new Set();
  for (const statement of model.display) {
    const name = statement.plan.$refText;
    if (selected.has(name)) errors.push(`Plan ${name} is selected more than once with show.`);
    selected.add(name);
  }
  if (!model.display.length) errors.push('No show statement: select at least one plan to export.');
  if (errors.length) throw new Error(errors.join('\n'));

  const mentions = model.display.map(statement => {
    const plan = statement.plan.ref;
    const patient = plan?.patient.ref;
    const medication = plan?.medication.ref;
    if (!plan || !patient || !medication) {
      throw new Error(`Plan ${statement.plan.$refText} has an unresolved reference.`);
    }
    const cst = medication.$cstNode;
    if (!cst) throw new Error(`Medication ${medication.name} has no source CST.`);
    const amount = Number(medication.amount);
    if (!Number.isFinite(amount)) throw new Error(`Medication ${medication.name} has a nonfinite amount.`);
    const position = value => ({
      line: value.line,
      character: value.character,
      offset: document.textDocument.offsetAt(value)
    });
    return {
      id: `${plan.name}:${medication.name}`,
      originalText: medication.name,
      role: 'medication',
      source: {
        uri: uri.toString(),
        start: position(cst.range.start),
        end: position(cst.range.end),
        text: document.textDocument.getText(cst.range)
      },
      // This is the administered dose from the existing grammar, not product strength.
      dose: { amount, unit: medication.unit },
      ...(medication.productStrength !== undefined ? { productStrength: medication.productStrength } : {}),
      ...(medication.doseForm !== undefined ? { doseForm: medication.doseForm } : {}),
      route: medication.route,
      frequency: medication.frequency,
      patientRef: patient.name,
      orderId: plan.name
    };
  });
  return {
    schemaVersion: '1',
    policyVersion: 'exact-v1',
    terminologyRelease: release.trim(),
    document: { uri: uri.toString(), text: sourceText },
    mentions
  };
}

async function main() {
  const { values } = parseArgs({ options: {
    'langium-root': { type: 'string' },
    input: { type: 'string' },
    release: { type: 'string' },
    output: { type: 'string' },
    help: { type: 'boolean', short: 'h' }
  } });
  if (values.help) { console.log(usage); return; }
  for (const name of ['langium-root', 'input', 'release']) {
    if (!values[name]) throw new Error(`Missing --${name}.\n${usage}`);
  }
  const request = await exportDocument({ langiumRoot: values['langium-root'], input: values.input, release: values.release });
  const json = `${JSON.stringify(request, null, 2)}\n`;
  if (!values.output) { process.stdout.write(json); return; }
  const output = path.resolve(values.output);
  if (output === path.resolve(values.input)) throw new Error('Output must not overwrite the input DSL.');
  await mkdir(path.dirname(output), { recursive: true });
  const temporary = `${output}.${process.pid}.tmp`;
  try {
    await writeFile(temporary, json, { flag: 'wx' });
    await rename(temporary, output);
  } finally {
    await rm(temporary, { force: true });
  }
  process.stderr.write(`Exported ${request.mentions.length} medication mention(s) to ${output}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
