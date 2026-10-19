# Colon syntax and contextual help

Rebuild the Langium workspace after pulling both repositories:

```sh
cd clinical-dsl-demo
npm ci
npm run langium:generate
npm run build
npm test
```

Launch the extension using F5 and open `examples/colon-help.clinical` in the Extension Development Host.

```text
Patient DemoPatient: age 30, condition DemoCondition
Medication aspirin: 15 mg, strength 325 mg, doseForm Oral Tablet, route PO, frequency PRN
Plan DemoPlan: for DemoPatient, prescribe aspirin
show DemoPlan
```

These values illustrate syntax only. Dose and product strength are different fields.

Press **? (Shift+/ on a US keyboard)** while editing a `.clinical` file. The extension consumes the key before text insertion and shows help for the cursor position. Dismiss the message to continue, or select **Show suggestions**. You can also use Ctrl+Space for ordinary completion. On another keyboard layout, bind **Clinical DSL: Context Help (?)** to the key that produces `?` in VS Code Keyboard Shortcuts; the command is also available from the Command Palette. A question mark pasted into a file is not valid DSL and is never silently stripped by the exporter.

The colon form uses commas and fixed field order. `strength` and `doseForm` are optional together; `route` and `frequency` remain required. Multiword forms such as `Oral Tablet` need no quotes. Medication identifiers still use letters, digits and underscores, starting with a letter or underscore. A declaration ends after its final required field; whitespace and line breaks are allowed between tokens. Legacy brace syntax remains supported.

Positive numeric doses are accepted; the old demo list is no longer a validation constraint. Existing completion examples remain a fictional demo catalog, not live RxNorm suggestions. Product resolution still runs on save or through the RxNorm command using the configured Scala/PostgreSQL installation. No database connection is needed for syntax help.

The exported JSON contract is unchanged. Rebuild Langium before running Scala bridge tests:

```sh
LANGIUM_ROOT=/absolute/path/to/langium_dsl_lab/clinical-dsl-demo node --test bridge/export-ast.test.mjs
```

Run that command from `scala-testing-lab`. Actual RxNorm resolution requires your local terminology snapshot and PostgreSQL settings.
