# Bridge from the existing Clinical DSL

This adapter uses the **actual generated Langium parser, linker, and validators** from
[`bogdanparvu18/langium_dsl_lab/clinical-dsl-demo`](https://github.com/bogdanparvu18/langium_dsl_lab/tree/338e2e15dd446ac7ffb75f1aab0d09f2b3cc36c8/clinical-dsl-demo),
verified at commit `338e2e15dd446ac7ffb75f1aab0d09f2b3cc36c8`. It does not contain a
replacement parser and does not change that repository. There are no extra npm dependencies
in this bridge: it loads Langium from the existing project's installation.

The current path is `clinical-dsl-demo`, not `clinical-dsl`. The grammar declares
`Patient`, `Medication`, `Plan`, and `DisplayPlan` nodes. A `Plan` cross-references a
patient and a medication; `show DemoPlan` references the plan to export.

## Prepare the existing language

From the directory that will contain both repositories, using Node.js 22 or 24:

```bash
git clone --filter=blob:none --sparse https://github.com/bogdanparvu18/langium_dsl_lab.git
cd langium_dsl_lab
git sparse-checkout set clinical-dsl-demo
git checkout 338e2e15dd446ac7ffb75f1aab0d09f2b3cc36c8
cd clinical-dsl-demo
npm ci
npm run langium:generate
npm run build
cd ../../scala-testing-lab
```

If you already have this repository with local work, use a separate checkout or `git
worktree` instead of changing its branch. Pinning the source commit makes the lab
repeatable; a future update of that commit should rerun the bridge integration tests.

## Export

Replace the release string with the identifier used when building the local lexical
index from your downloaded RxNorm files. The exporter does not infer a release or
download terminology. It does not need a seed concept, an RxCUI, or an alias file.

```bash
node bridge/export-ast.mjs \
  --langium-root ../langium_dsl_lab/clinical-dsl-demo \
  --input examples/paracetamol.clinical \
  --release YOUR_RXNORM_RELEASE \
  --output data/ast/paracetamol.json
```

For **Windows PowerShell**, from the `scala-testing-lab` root, use the same command on
one line (Bash `\` continuation is not PowerShell syntax):

```powershell
node bridge/export-ast.mjs --langium-root ../langium_dsl_lab/clinical-dsl-demo --input examples/paracetamol.clinical --release 2026-10-05 --output data/ast/paracetamol.json
if ($LASTEXITCODE -ne 0) { throw 'Langium export failed; do not resolve a previous output file.' }
Get-Content data/ast/paracetamol.json -Raw
```

In a pipeline, run the Scala resolution command only after a successful export (`&&`).
Failure exits with status 1 and does not replace an existing output file; do not consume
an old file after a failed export. `--output` is optional; omitting it writes JSON to stdout.
Status and error messages go to stderr. Successful file output is replaced atomically.

The bridge validates the whole document and rejects syntax errors, unresolved references,
the existing demo validation errors, duplicate patient/medication/plan names, duplicate
`show` selections, and an empty selection. Only plans explicitly selected with `show`
are exported. Warnings do not prevent export.

## Contract

```text
schemaVersion: "1"
policyVersion: "exact-v1"
terminologyRelease: the release identifier of the local RxNorm lexical index
document: { uri, text }
mentions: [
  {
    id, originalText, role: "medication",
    source: {
      uri,
      start: { line, character, offset },
      end: { line, character, offset },
      text
    },
    dose: { amount, unit }, route, frequency, patientRef, orderId
  }
]
```

- `originalText` preserves the medication name (`paracetamol`) from the AST.
- The bridge exports no RxCUI or ingredient identity. Its input contains the name
  entered in the DSL; Scala searches that name in the local RxNorm index, using the
  selected release's imported terms. The bridge does not replace `paracetamol` with
  `acetaminophen` or inject an alias. An absent or ambiguous name remains a resolution
  result to handle explicitly.
- `source.text` is the complete medication declaration, including its exact whitespace.
- Lines and characters are zero-based. Offsets and characters use UTF-16 code units,
  matching LSP and JavaScript strings; the end position is exclusive.
- `document.text` preserves the original document for source auditing. Use fictional
  patients in this lab and keep real clinical data out of Git.
- `id` is `planName:medicationName`; one medication can appear in multiple selected plans.
- `dose.amount` is the **administered dose**, not the strength of a manufactured product.
  The existing grammar does not capture dosage form or product strength. No such fields
  are invented. A name can identify an RxNorm ingredient while product selection remains
  unresolved; the Scala service reports that distinction.

The existing demo accepts only numeric amounts `1`, `2.5`, and `10`. The example uses
`1 mg` only to pass that prototype rule. It is a fictional software test and is not a
paracetamol dosing recommendation. That list is not an RxNorm or clinical rule.
Terminology matching, role checks, candidate disambiguation, and release validation belong
in Scala; the bridge introduces no drug-specific clinical rules.

The VS Code `show` command currently projects a smaller plan JSON without this complete
source contract. Do not pass that JSON directly as schema version 1. For this lab, parse
the `.clinical` file through this bridge. A future extension command can reuse the same
projection after editor validation, rather than inventing missing source positions.

The request schema remains version `1` with policy `exact-v1`. The Scala result has its
own version (`ResolutionReport` schema `2`) and describes `terminologyScope`; it does
not use an ingredient seed as the search scope. Input and output schema versions serve
different contracts and do not need to be identical.

## Representative AST from several medication names

The existing grammar accepts a medication `name=ID`: letters/digits/underscores, with
the first character a letter or underscore. It does not accept multiword product names
in quotes. Keep that limitation explicit; do not silently interpret underscores as
spaces or add an `ingredient` property to the grammar for this resolver.

To inspect several independent lookups while retaining the actual grammar, save the
following fictional parser fixture as `data/input/representative.clinical`. The numeric
value `1` merely satisfies the existing demo validation list; this is not a medication
order to use in care.

```text
patient DemoPatient { age 30 condition DemoCondition }
medication acetaminophen { 1 mg route PO frequency PRN }
medication Tylenol { 1 mg route PO frequency PRN }
medication paracetamol { 1 mg route PO frequency PRN }
plan IngredientName { for DemoPatient prescribe acetaminophen }
plan BrandName { for DemoPatient prescribe Tylenol }
plan AlternativeName { for DemoPatient prescribe paracetamol }
show IngredientName
show BrandName
show AlternativeName
```

These plan names are labels for the fixture, not semantic declarations. All three
exported mentions have `role: "medication"`; the resolver discovers the type of any
matching concept. Whether a term resolves depends on the actual downloaded release and
the index's documented source filters. Export it in PowerShell with:

```powershell
node bridge/export-ast.mjs --langium-root ../langium_dsl_lab/clinical-dsl-demo --input data/input/representative.clinical --release 2026-10-05 --output data/ast/representative.json
if ($LASTEXITCODE -ne 0) { throw 'Langium export failed.' }
(Get-Content data/ast/representative.json -Raw | ConvertFrom-Json).mentions |
  Select-Object id, originalText, role, patientRef, orderId
```

Always regenerate the JSON after changing the DSL. Editing `originalText` alone in the
JSON would break the connection to `document.text` and the source range.

## Verify the real parser integration

```bash
LANGIUM_ROOT=../langium_dsl_lab/clinical-dsl-demo \
  node --test bridge/export-ast.test.mjs
```

In PowerShell:

```powershell
$env:LANGIUM_ROOT = '../langium_dsl_lab/clinical-dsl-demo'
node --test bridge/export-ast.test.mjs
if ($LASTEXITCODE -ne 0) { throw 'Bridge integration tests failed.' }
```

The six tests use the real generated parser and cover:

1. Linked AST projection, exact source text, and UTF-16 offsets with an emoji before
   the medication; no product strength/form is invented.
2. Exporting only plans selected with `show`.
3. Rejecting syntax errors and unresolved medication references.
4. Running the original demo amount validator.
5. Rejecting duplicate medication, patient, and plan declarations.
6. Rejecting duplicate `show` selections and a document without any `show` selection.
