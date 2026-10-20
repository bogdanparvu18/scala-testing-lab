# scala-testing-lab

An offline Scala/ZIO laboratory for resolving medication names and pharmaceutical products from a Langium medical DSL against RxNorm data stored in local PostgreSQL.

The project connects a human-readable clinical language to explicit terminology concepts. A medication written as `paracetamol` can be resolved to RxCUI `161`, canonical name `acetaminophen`, type `IN`, using names supplied by the imported terminology. When product strength and dose form are explicit, the resolver can also identify a supported pharmaceutical product and retain the evidence for that selection.

This is a personal integration laboratory for work that can later be adapted to Aurora's Scala/ZIO ecosystem. It keeps language tooling, terminology data access, and resolution policy separate.


## Contents

1. [Purpose and architecture](#1-purpose-and-architecture)
2. [Libraries and tools](#2-libraries-and-tools)
3. [Scala execution flow: JSON to terminology report](#3-scala-execution-flow-json-to-terminology-report)
4. [RxNorm and the PostgreSQL data model](#4-rxnorm-and-the-postgresql-data-model)
5. [Windows installation and project setup](#5-windows-installation-and-project-setup)
6. [Configure local PostgreSQL](#6-configure-local-postgresql)
7. [Download and import RxNorm](#7-download-and-import-rxnorm)
8. [Complete example: paracetamol](#8-complete-example-paracetamol)
9. [Product strength and dose form](#9-product-strength-and-dose-form)
10. [VS Code extension workflow](#10-vs-code-extension-workflow)
11. [Functions and design decisions](#11-functions-and-design-decisions)
12. [Testing](#12-testing)
13. [Limitations and troubleshooting](#13-limitations-and-troubleshooting)
14. [References](#14-references)

## 1. Purpose and architecture

The laboratory provides:

- A local import of original RxNorm rows and derived lookup tables.
- Exact normalized name lookup across eligible imported terminology names.
- A JSON contract between the Langium AST and the Scala application.
- Semantic role validation for medication, active ingredient, and pharmaceutical product.
- Ingredient derivation through explicitly permitted RxNorm relationships.
- Conservative product selection using ingredient, explicit strength, and dose form.
- Source names, attributes, relationship paths, release identifiers, and hashes supporting the result.
- A VS Code integration that presents the Scala result in Problems, Output, and Preview JSON.

~~~mermaid
flowchart TD
    L["Langium: parsing, linking and validation"] -->|"AST projection: JSON request"| S["Scala/ZIO: resolution policy"]
    F["RxNorm RRF files"] --> I["Scala import"]
    I --> P["Local PostgreSQL: raw rows and indexes"]
    P -->|"Release-specific snapshot"| S
    S --> R["JSON report: concepts, products and evidence"]
    R --> V["VS Code: Problems, Output and Preview JSON"]
~~~

There are two related workflows:

1. **Import time:** download an RxNorm release, inspect its files, and import them into PostgreSQL.
2. **Resolution time:** export a validated DSL document, query the local index, apply the Scala policy, and display or save the result.

RxNorm is downloaded once per imported release. A normal lookup or resolution does not make an RxNorm API call. Building the project for the first time still requires internet access to obtain dependencies.

The Scala application is a CLI. It does not start an HTTP server. The VS Code extension launches the exporter and Scala CLI as local child processes.

### Repository responsibilities

| Repository | Responsibility |
| --- | --- |
| [scala-testing-lab](https://github.com/bogdanparvu18/scala-testing-lab) | Scala/ZIO CLI, PostgreSQL schema and import, terminology policy, AST export bridge, and Scala/bridge tests. |
| [langium_dsl_lab/clinical-dsl-demo](https://github.com/bogdanparvu18/langium_dsl_lab/tree/main/clinical-dsl-demo) | Grammar, AST services, language validators, language server, editor extension, and JSON preview. |

The bridge is stored here but loads the compiled language services from the Langium project. Both repositories are needed for the complete DSL-to-editor workflow.

## 2. Libraries and tools

### Scala/JVM dependencies

The versions are declared in [build.sbt](build.sbt) and [project/build.properties](project/build.properties).

| Dependency | Version | How it is used |
| --- | --- | --- |
| Scala | 3.5.1 | Case classes, pattern matching, immutable collections, BigDecimal, and the implementation language. |
| sbt | 1.10.2 | Downloads the compiler/dependencies, compiles the application, runs commands, and executes tests. |
| `dev.zio::zio` | 2.1.9 | Effectful application entry point, resource scopes, blocking I/O, sequencing, and error propagation. |
| `dev.zio::zio-json` | 0.7.3 | Derives JSON codecs for case classes and decodes/encodes requests, reports, and manifests. |
| `org.postgresql:postgresql` | 42.7.14 | PostgreSQL JDBC connections, prepared statements, SQL arrays, transactions, and the native COPY API. |
| `dev.zio::zio-test` | 2.1.9 | Effect-aware test suites and assertions over synthetic fixtures. |
| `dev.zio::zio-test-sbt` | 2.1.9 | Connects ZIO Test to sbt's test runner. |

The project uses PostgreSQL JDBC directly. It does not require an ORM, a graph database driver, or an HTTP client for RxNorm resolution.

### JVM and Scala standard libraries

| API | Purpose |
| --- | --- |
| `java.nio.file.Files` / `Path` / `Paths` | Read RRF and JSON files, create directories, and write result files. |
| `StandardCopyOption.ATOMIC_MOVE` | Attempt atomic replacement of the completed JSON result. |
| `MessageDigest` | Calculate SHA-256 for release files and deterministic identifiers. |
| `java.text.Normalizer` / `Locale.ROOT` | Stable Unicode NFKC normalization and locale-independent lowercase matching. |
| `java.time.LocalDate` | Validate release dates. |
| `java.sql` / `DriverManager` / `PreparedStatement` | Execute parameterized SQL and control connection transactions. |
| `java.util.Properties` | Supply JDBC credentials and connection options separately from SQL. |
| `scala.util.Using` | Close file streams, statements, and result sets reliably. |
| `BigDecimal` | Compare mass and concentration without binary floating-point approximation. |

### Langium, TypeScript, and editor dependencies

| Library/tool | Purpose |
| --- | --- |
| Langium / langium-cli, `~4.4.0` | Generate the language implementation from the grammar; parse documents, link references, build the AST, and run validators. |
| TypeScript, `~5.9.3` | Type-check the language services, protocol objects, and extension implementation. |
| `vscode-languageclient` / `vscode-languageserver`, `~10.1.0` | Connect the editor extension and language server through the Language Server Protocol. |
| VS Code extension API | Register commands, diagnostics, hover/CodeLens providers, events, output channels, progress, configuration, and SecretStorage. |
| Node.js | Execute the AST bridge and extension-side process orchestration. The Windows setup below uses Node 22.x, at least 22.12.0. |
| esbuild | Bundle the extension and language server for execution. |
| shx | Provide portable build operations such as creating/copying build directories. |
| concurrently | Run TypeScript and bundler watch tasks together during development. |
| Vitest | Language-workspace test tooling. |
| Node `node:test` and `node:assert/strict` | Run bridge and extension integration tests. |

Node's built-in modules also do significant work:

- `node:fs/promises` reads source files, layout configuration, and temporary JSON files.
- `node:path` handles paths; `node:os` locates the user's home directory.
- `node:module.createRequire` helps locate dependencies belonging to the language workspace.
- `node:url.pathToFileURL` makes filesystem paths safe for ESM imports.
- `node:util.parseArgs` parses the bridge CLI arguments.
- `node:child_process.spawn` starts Node and Java without a command shell.
- `JSON.parse` / `JSON.stringify` handle plain JSON at the TypeScript/JavaScript boundary.

## 3. Scala execution flow: JSON to terminology report

The `resolve <ast.json> <result.json>` command receives a **JSON file path**. It decodes structured fields, reads a release-specific PostgreSQL snapshot, applies pure Scala terminology rules, and writes a report. ZIO sequences these operations and manages failures/resources; it does not decide which medication matches.

### Execution and failure boundaries

~~~mermaid
flowchart TD
    A["Main.run: resolve input output"] --> B["readInput: Files.readString and fromJson AstRequest"]
    B --> C["InputValidation.validate: contract and source integrity"]
    C --> D["PostgresStore.open: configuration and ensureSchema"]
    D --> E["snapshotForResolution: names, forms and product-data flag"]
    E --> F["readSnapshot: scoped JDBC connection and REPEATABLE READ"]
    F --> G["Ready release, exact name queries, bounded relationships and attributes"]
    G --> H["RxSnapshot in memory; JDBC connection closed"]
    H --> I["Resolver.resolve: revalidate input, release and scope"]
    I --> J["Resolve each mention: name, role, product and ingredients"]
    J --> K["ResolutionReport: findings, evidence and hashes"]
    K --> L["Main.run: calculate deterministic runId"]
    L --> M["saveBinding: commit request and report in PostgreSQL"]
    M --> N["writeJson: temporary file then replace output"]
    N --> O["Console summary and successful completion"]
    B -.-> X["Decode, validation or I/O failure: stop dependent steps"]
    C -.-> X
    D -.-> X
    F -.-> X
    G -.-> X
    I -.-> X
    M -.-> X
    N -.-> X
    X --> Y["ZIO failure; CLI fails without a structured error-report JSON"]
~~~

A terminology finding such as `unresolved` is a normal report result. A malformed request or database failure aborts the command. There is **no automatic retry** and no HTTP response in this CLI.

### 1. Decode fields and verify their integrity

Sources: [Main.scala](src/main/scala/lab/Main.scala), [Domain.scala](src/main/scala/lab/Domain.scala).

| Function / field | Implemented decision |
| --- | --- |
| `readInput → raw.fromJson[AstRequest]` | zio-json decodes the file into case classes. Required fields/types must decode; `@jsonNoExtraFields` rejects unknown input keys. Decode errors become `IllegalArgumentException`. |
| `AstRequest.mentions` | Each `Mention` already contains `originalText` (medication name), `productStrength`, `doseForm`, `dose.amount/unit`, `route`, `frequency`, role, IDs and source location. Scala reads these fields; it does not extract strength from the medication name or reparse the DSL. |
| `InputValidation.validate` | Requires input schema `1`, policy `exact-v1`, a valid release label, nonempty mentions, unique mention/order IDs and nonempty patient/order references. |
| Dose and role checks | Positive `BigDecimal` dose; allowed unit, route and frequency; role must be `medication`, `activeIngredient` or `medicationProduct`. These are representation checks, not prescribing-safety checks. |
| Qualifier checks | A supplied strength must pass `ProductStrength.parse`; a supplied form must be nonblank and at most 200 characters. The requirement to supply both qualifiers is handled later by `ProductSelector.select`. |
| Source checks | URI must match the document; line/character/offset values must agree with its UTF-16 text; range must be ordered; extracted substring must equal `source.text`, which must contain `originalText`. |
| Integrity boundary | These checks verify internal consistency. Scala does not independently prove that every dose/qualifier field was faithfully extracted from the DSL, or that a patient reference names a real patient. |

### 2. Normalize lookup keys, not the whole JSON

[`TextKey.normalize`](src/main/scala/lab/Domain.scala) applies **Unicode NFKC → trim → collapse whitespace → lowercase with Locale.ROOT**. `Rrf.normalize` implements the same steps for database lookup keys. The original mention and source text remain available in the report.

| Input / operation | Behaviour |
| --- | --- |
| `Aspirin`, `ASPIRIN`, ` aspirin ` | Same lookup key: `aspirin`. A match still requires that name in the imported release. |
| `Oral   Tablet` | Lookup key becomes `oral tablet`; dose-form matching uses the same normalization. |
| `asprin` | No spelling correction. If absent from the eligible imported names, the result is `unresolved`. |
| Punctuation or alternative name | Punctuation is retained. A synonym matches only if imported terminology supplies it; no invented alias or fuzzy match. |
| Strength such as `0.325 g` | Separately parsed by `ProductStrength.parse` into mass in mg and optional volume in ml; `equivalent` compares decimal masses or cross-multiplies concentrations. Administered dose is never substituted for product strength. |
| Units, route and frequency | Input validation uses explicit case-sensitive sets; medication-name normalization does not silently repair these fields. |

### 3. Connect through JDBC and load evidence

Source: [PostgresStore.scala](src/main/scala/lab/PostgresStore.scala).

| Function | Access / checks |
| --- | --- |
| `PGConfig.fromEnvironment → PostgresStore.open` | Reads PostgreSQL environment variables; requires a password, loopback host, valid port, simple database identifier and nonempty credentials. `ensureSchema` initializes the schema under an advisory transaction lock. |
| `connect` | Calls `DriverManager.getConnection(jdbc:postgresql://..., properties)`; credentials are properties. Sets `connectTimeout=10` seconds and `sslmode=disable` for this loopback-only lab. This is not a query or whole-command timeout. |
| `use` | `ZIO.acquireRelease` acquires/closes each operation's connection; `attemptBlocking` runs JDBC work on the blocking executor. No connection pool is implemented. |
| `snapshotForResolution` | Reads names from `mentions.originalText` and optional `doseForm`; either product qualifier requests product-index data. |
| `readSnapshot` | Requires a ready base release and matching scope. Product requests also require a ready product index with the supported policy. Reads names, concepts, relationships and attributes in one read-only `REPEATABLE READ` transaction. |
| `query / strings / array` | Uses prepared statements and bound values/arrays. Name lookup compares both `md5(normalized)` and full normalized equality; the hash alone is not accepted as a match. Statements/results are closed and SQL arrays freed. |
| Bounds and completeness | Requires 1–100 distinct terms; at most 5,000 product candidates; relationship closure bounded to 24 passes, 25,000 concepts and 100,000 edges. Exceeding a limit fails instead of returning a partial snapshot. |
| `transaction` | Commits on success; catches `NonFatal`, attempts rollback and rethrows the original error. A rollback failure is attached as a suppressed exception. Connection-close failure becomes a ZIO defect through `orDie`. |

### 4. Resolve each medication and validate its semantic role

Sources: [Resolver.scala](src/main/scala/lab/Resolver.scala), [ProductSelector.scala](src/main/scala/lab/ProductSelector.scala), [ProductStrength.scala](src/main/scala/lab/ProductStrength.scala).

~~~mermaid
flowchart TD
    A["Mention.originalText"] --> B["Resolver.candidates: exact normalized names grouped by RxCUI"]
    B --> C{"Any candidates?"}
    C -->|"No"| U["unresolved: UNRESOLVED_IN_DATASET"]
    C -->|"Yes"| D["Filter canonical concept types by mention.role"]
    D --> E{"Allowed candidates"}
    E -->|"Zero"| V["invalidRole: SEMANTIC_TYPE_MISMATCH"]
    E -->|"Several"| W["needsClarification: AMBIGUOUS_EXACT_MATCH"]
    E -->|"One"| F{"Either product qualifier supplied?"}
    F -->|"No"| G["Keep matched concept; select product only if SCD or SBD"]
    F -->|"Yes"| H["ProductSelector.select: require strength and form"]
    H --> I["Resolve exact DF; inspect ingredient or brand product paths"]
    I --> J["Check one component, direct IN, form and imported RXN_STRENGTH"]
    J --> K{"Complete evidence and number of matches"}
    K -->|"Incomplete or several"| Q["needsClarification; retain diagnostics and candidates"]
    K -->|"Complete, zero"| R["productNotFound"]
    K -->|"Complete, one"| S["resolved; selectedProduct and productEvidence"]
    G --> T["derive: permitted typed edges, cycle guard and evidence paths"]
    S --> T
    T --> Z["Resolution; then sharedIngredients across resolved orders"]
~~~

| Decision | Rule / result |
| --- | --- |
| Semantic role | `medication`: IN/PIN/MIN/BN/SCD/SBD; `activeIngredient`: IN/PIN; `medicationProduct`: SCD/SBD. A matching spelling alone does not establish the required type. |
| Product prerequisites | Missing qualifier: `PRODUCT_FIELDS_REQUIRED`; ingredient-only role requesting a product: `PRODUCT_ROLE_MISMATCH`; unsupported initial concept: `PRODUCT_MATCH_SCOPE_UNSUPPORTED`. |
| Dose-form resolution | Only exact candidates of type DF qualify. None: `DOSE_FORM_UNKNOWN` / `productNotFound`; several: `DOSE_FORM_AMBIGUOUS` / `needsClarification`. |
| Product evidence | Follows permitted ingredient/brand/product links and `has_dose_form`. Requires a supported single component with a direct IN ingredient and consistent, parseable imported `RXN_STRENGTH` evidence. A single strength must not silently select a combination product. |
| Product outcome | Zero verified matches: `PRODUCT_NOT_FOUND`; multiple: `PRODUCT_AMBIGUOUS`; missing/conflicting evidence in a potential product: `PRODUCT_EVIDENCE_INCOMPLETE`. Incomplete evidence takes priority over selecting another apparent match. |
| Ingredients | Local `derive / visit / allowedStep` traverse allowed typed edges, track visited concepts, deduplicate ingredients and retain a deterministic supporting path. A brand alone does not establish a product's ingredients. |
| Name-only success | May be `resolved` with `PRODUCT_NOT_SELECTED`; this is a concept match, not necessarily a selected product. A directly matched product without ingredient evidence receives `INGREDIENT_EVIDENCE_MISSING`. |

### 5. Build, persist and return the JSON

| Function / stage | Output and software decision |
| --- | --- |
| `Resolver.resolve → ResolutionReport` | Output schema `2`; policy/release/scope, snapshot fingerprint, input hash, per-mention status, original mention, matched concept, selected product, candidates, ingredient paths, diagnostics and product evidence. `clinicianConfirmed` remains `false`. |
| `sharedIngredients` | Groups resolved ingredients by patient and distinct order IDs. Reports shared ingredients without claiming dose safety or drug interactions. |
| `Hashing.sha256 / fingerprint` | `inputSha256` hashes the decoded request re-encoded with `a.toJson`, not the raw input-file bytes. Snapshot fingerprint hashes release, scope and sorted source-file hashes. |
| `Main.run → runId` | Hashes input hash, snapshot fingerprint, policy and report hash. Same request/report evidence gives the same binding ID. |
| `saveBinding` | Stores request/report in one transaction; on run-ID conflict, reads the stored values and requires exact equality. Conflicting evidence fails with `Binding runId already has different evidence`. |
| `writeJson(report.toJsonPretty)` | Writes a temporary file in the destination directory, attempts atomic replacement, falls back to ordinary replacement if unsupported, and cleans up the temporary file. Console output then lists mention statuses and the binding ID. |
| Output assurance | Typed report construction and derived codecs produce JSON. Scala does not re-decode the written report or run a separate output-schema validator. Source/hash/evidence fields support downstream verification. |

### Failure handling and retry limits

| Failure class | What the current implementation does |
| --- | --- |
| Invalid JSON or request | Fails before database lookup; examples: `Unsupported schemaVersion`, `Duplicate mention IDs`, `Source text mismatch`, `Unsupported product strength: use mass or mass/ml`. |
| Missing release/product import | Fails snapshot loading with `No ready local release ...` or `Product index unavailable ...`. This occurs before per-medication matching in the normal CLI path. |
| JDBC authentication, connection or SQL error | Propagates the exception through ZIO; dependent steps stop; active transactions attempt rollback and scoped connections close. No retry/backoff or custom SQL-error-to-JSON mapping. |
| Terminology unknown, ambiguous or mismatched | Returns a normal `Resolution` status and diagnostic; other mentions are still processed. No guessed correction or automatic candidate selection. |
| Persistence or output-file failure | Fails the command. Database commit precedes file writing: the binding can exist even if output writing fails. Rerunning the same request can reuse the identical binding. |
| Existing result file | Early failure does not remove a previous output file. A caller must check process success rather than treating an old file as this run's result. |

**ZIO's boundary:** `ZIOAppDefault` supplies the runtime; the `for` comprehension sequences dependent steps; `attempt / attemptBlocking` capture exceptions; `scoped / acquireRelease` manage resource lifetime. Database rollback is implemented explicitly in `transaction`. Idempotent persistence permits safe repetition with identical evidence, but is not an automatic retry mechanism.

## 4. RxNorm and the PostgreSQL data model

RxNorm supplies terminology facts. PostgreSQL stores a local copy and makes those facts queryable. Scala interprets the retrieved facts according to the resolution policy.

### Important terminology identifiers

| Term | Meaning |
| --- | --- |
| RxCUI | Identifier of a terminology concept. |
| RXAUI | Identifier of an atom: a particular source representation/name associated with a concept. |
| SAB | Abbreviation of the source vocabulary. |
| TTY | Term type, such as ingredient or clinical drug. |
| RUI | Relationship identifier retained as evidence. |
| ATUI | Attribute identifier retained as evidence. |
| `IN` | Ingredient. |
| `PIN` | Precise ingredient. |
| `BN` | Brand name. |
| `SCD` | Semantic Clinical Drug: a generic clinical drug concept. |
| `SBD` | Semantic Branded Drug: a branded clinical drug concept. |
| `SCDC` | Semantic Clinical Drug Component, used in the ingredient/strength path. |
| `DF` | Dose form. |

The source type of a synonym is not the same as the canonical type of its associated concept. A name atom can come from another vocabulary while the resolved concept is an RxNorm `IN`.

### RRF is a text format

RRF files are UTF-8, pipe-delimited tables. They are not native PostgreSQL SQL files.

| File | Original columns | Use |
| --- | --- | --- |
| `RXNCONSO.RRF` | 18 | Names, atoms, sources, and concept term types. |
| `RXNREL.RRF` | 16 | Relationships between atoms/concepts. |
| `RXNSAT.RRF` | 13 | Attributes; product verification uses `RXN_STRENGTH` on eligible SCDC atoms. |

The final pipe is a delimiter, not an extra data column.

The importer first understands RRF fields, then encodes them separately for PostgreSQL COPY text transport. Quotes and backslashes are not interpreted as CSV syntax.

### Tables

The schema is defined in [src/main/resources/db/schema.sql](src/main/resources/db/schema.sql).

| Table in `rxnorm_lab` | Purpose |
| --- | --- |
| `release` | Base release manifest, scope, SHA-256 hashes, state, and counts. |
| `rxnconso` / `rxnrel` | All original rows from the two imported files, with a release column. |
| `rx_concept` | Eligible active English canonical RxNorm concepts. |
| `lexical_name` | Eligible active names, their normalized lookup keys, and original source evidence. |
| `product_release` | Product-attribute manifest linked to the exact base import. |
| `rxnsat` | All original SAT rows, with a release column. |
| `product_attribute` | Eligible active atom-linked SCDC strength attributes. |
| `binding` | Input request, output report, release, and deterministic run identifier. |

The base scope is `all-active-rxnorm-pg-v4`. Eligibility is defined in `Rrf.canonicalTypes` and the source/language/suppression filters. Source-only concepts without an eligible active canonical RxNorm form remain in raw storage but do not become lookup candidates.

### Why PostgreSQL

- The source data is tabular and can be preserved in ordinary relational tables.
- Prepared statements and indexes support exact local lookup.
- SQL joins connect names, canonical concepts, atoms, attributes, and relationships.
- Transactions keep incomplete imports from being activated.
- Multiple releases can coexist without silently mixing their evidence.
- JDBC exposes PostgreSQL COPY for efficient bulk loading.

A graph database is not required to follow terminology relationships. This implementation queries the relational relationship table and constructs a bounded in-memory snapshot for the pure resolver.

**Docker is optional and is not required for this Windows workflow.** PostgreSQL can run as a normal Windows service. The application accepts only a loopback database host such as `127.0.0.1`, `localhost`, or `::1`.

## 5. Windows installation and project setup

Use PowerShell in VS Code's integrated terminal. The same commands can run in a normal PowerShell window.

### Prerequisites

Install these tools, or keep the installations already working on the VM:

- [Git for Windows](https://git-scm.com/downloads/win).
- JDK 21, for example [Azul Zulu](https://www.azul.com/downloads/?package=jdk#zulu).
- [Node.js 22.x](https://nodejs.org/en/download), at least 22.12.0, including npm.
- [PostgreSQL 18.x for Windows](https://www.postgresql.org/download/windows/), including command-line tools.
- [Visual Studio Code](https://code.visualstudio.com/).

Scala does not need a separate global installation. sbt downloads the compiler version declared in this project.

Verify the tools:

~~~powershell
git --version
java -version
node.exe --version
npm.cmd --version

Get-Service -Name '*postgres*'
Test-NetConnection 127.0.0.1 -Port 5432

$psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
& $psql --version
~~~

Adjust `$psql` if PostgreSQL is installed elsewhere. The service running and the port responding do not yet prove that application credentials work; the next section checks authentication.

### Clone both repositories

For a fresh machine:

~~~powershell
New-Item -ItemType Directory -Path 'C:\AuroraLab\repos' -Force | Out-Null

git clone https://github.com/bogdanparvu18/scala-testing-lab.git C:\AuroraLab\repos\scala-testing-lab
git clone https://github.com/bogdanparvu18/langium_dsl_lab.git C:\AuroraLab\repos\langium_dsl_lab

$scalaRoot = 'C:\AuroraLab\repos\scala-testing-lab'
$langiumRoot = 'C:\AuroraLab\repos\langium_dsl_lab\clinical-dsl-demo'
~~~

If the repositories already exist, skip cloning and define the variables using their actual paths.

`$langiumRoot` must contain `package.json` and `packages`. For the existing nested VM layout, use:

~~~powershell
$langiumRoot = 'C:\AuroraLab\repos\langium_dsl_lab\clinical-dsl-demo\clinical-dsl-demo'
~~~

Do not create another clone inside that project directory.

### Prepare Java and the sbt launcher

The build files belong at:

| File | Location and role |
| --- | --- |
| `build.sbt` | Repository root; Scala version, dependencies, main class, and tests. |
| `project/build.properties` | sbt version. |
| `src/main/scala/lab` | Application source. |
| `src/main/resources/db/schema.sql` | Schema packaged as an application resource. |
| `src/test/scala/lab` | Tests and the optional database integration check. |
| `bridge` | Langium AST exporter and its tests. |
| `examples` | Fictional DSL input examples. |

The following setup uses Java directly and downloads the pinned sbt launcher if needed:

~~~powershell
$javaExecutable = (Get-Command java.exe -ErrorAction Stop).Source
$toolsRoot = Join-Path $env:USERPROFILE 'AuroraLab\tools'
$sbtHome = Join-Path $toolsRoot 'sbt-1.10.2'
$sbtBin = Join-Path $sbtHome 'bin'

New-Item -ItemType Directory -Path $sbtBin -Force | Out-Null
$sbtLauncher = Join-Path $sbtBin 'sbt-launch.jar'

if (-not (Test-Path -LiteralPath $sbtLauncher)) {
    Invoke-WebRequest -UseBasicParsing `
        -Uri 'https://repo.maven.apache.org/maven2/org/scala-sbt/sbt-launch/1.10.2/sbt-launch-1.10.2.jar' `
        -OutFile $sbtLauncher
}

$sbtArgs = @(
    '-Xmx2G',
    '-Dsbt.supershell=false',
    '-Dsbt.log.noformat=true',
    '-jar',
    $sbtLauncher
)

Set-Location $scalaRoot
& $javaExecutable @sbtArgs 'show scalaVersion'
& $javaExecutable @sbtArgs test
~~~

The Scala version should be `3.5.1`. The first build downloads sbt, the compiler, and dependencies.

If the VM already has a working `layout.json` from the earlier tools setup, the following is an alternative to selecting the paths above:

~~~powershell
$layoutFile = Join-Path $env:USERPROFILE 'AuroraLab\tools\layout.json'
$layout = Get-Content -LiteralPath $layoutFile -Raw -Encoding UTF8 | ConvertFrom-Json

$toolsRoot = Split-Path -Parent $layoutFile
$javaExecutable = Join-Path $layout.javaHome 'bin\java.exe'
$sbtHome = $layout.sbtHome
$sbtLauncher = Join-Path $sbtHome 'bin\sbt-launch.jar'
$sbtArgs = @('-Xmx2G', '-Dsbt.supershell=false', '-Dsbt.log.noformat=true', '-jar', $sbtLauncher)
~~~

Use one set of tool paths consistently within a session.

The operator `&` invokes the Java executable correctly even when its path contains spaces. `-Xmx2G` is a JVM argument before `-jar`. This avoids relying on a wrapper to interpret `-J-Xmx2G`.

Recreate these variables when starting a new PowerShell session.

## 6. Configure local PostgreSQL

### Create the role and database once

Open an administrator database session:

~~~powershell
& $psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -W
~~~

At the `psql` prompt:

~~~sql
CREATE ROLE scala_lab LOGIN;
~~~

Set the application password interactively:

~~~text
\password scala_lab
~~~

Then:

~~~sql
CREATE DATABASE scala_testing_lab OWNER scala_lab;
~~~

~~~text
\q
~~~

Skip creation if the role/database already exist. To change an existing role's password, use `\password scala_lab` in the administrator session.

Check the application login:

~~~powershell
& $psql -h 127.0.0.1 -p 5432 -U scala_lab -d scala_testing_lab -W `
    -c 'SELECT current_user, current_database(), version();'
~~~

The application creates `rxnorm_lab` and its tables automatically. The role must be able to create the schema in its database.

### Configure the Scala process

~~~powershell
$env:PGHOST = '127.0.0.1'
$env:PGPORT = '5432'
$env:PGDATABASE = 'scala_testing_lab'
$env:PGUSER = 'scala_lab'

$securePassword = Read-Host 'PostgreSQL password for scala_lab' -AsSecureString
$env:PGPASSWORD = [System.Net.NetworkCredential]::new('', $securePassword).Password
Remove-Variable securePassword
~~~

The application has no default password. These variables apply to the current PowerShell session and its child processes.

The CLI cannot automatically read a password saved in VS Code SecretStorage. Terminal credentials and extension credentials are configured separately.

## 7. Download and import RxNorm

### Download the Full release

Use the [official NLM RxNorm Files page](https://www.nlm.nih.gov/research/umls/rxnorm/docs/rxnormfiles.html) and your UMLS account to download **RxNorm Full Monthly Release**.

The examples below use:

- Archive: `RxNorm_full_10052026.zip`.
- Terminology release: `2026-10-05`.
- Extracted files: `C:\AuroraLab\data\rxnorm-manual\2026-10-05\rrf`.

For another release, change both the date and paths consistently. The release date is the terminology release date, not the day the import is executed.

Use CONSO, REL, and SAT from the **same Full archive**. The archive itself is not included in this repository.

### Extract the three files

~~~powershell
$rxArchive = 'C:\Users\bogdan\Downloads\RxNorm_full_10052026.zip'
$rxRelease = '2026-10-05'
$rrfRoot = "C:\AuroraLab\data\rxnorm-manual\$rxRelease\rrf"

New-Item -ItemType Directory -Path $rrfRoot -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem

$zip = [System.IO.Compression.ZipFile]::OpenRead($rxArchive)
try {
    foreach ($fileName in @('RXNCONSO.RRF', 'RXNREL.RRF', 'RXNSAT.RRF')) {
        $expectedPath = "rrf/$fileName"
        $entries = @(
            $zip.Entries | Where-Object {
                $_.FullName.Replace('\', '/') -eq $expectedPath
            }
        )

        if ($entries.Count -ne 1) {
            throw "Expected exactly one entry at $expectedPath."
        }

        $destination = Join-Path $rrfRoot $fileName
        if (-not (Test-Path -LiteralPath $destination)) {
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile(
                $entries[0], $destination, $false
            )
        }

        Get-Item -LiteralPath $destination | Select-Object Name, Length
    }
} finally {
    $zip.Dispose()
}
~~~

The selection uses the full ZIP path, such as `rrf/RXNSAT.RRF`. Matching only the filename can also find a copy belonging to the prescribable-content subset.

Existing files are not overwritten. Keep releases in separate directories.

### Inspect before importing

~~~powershell
Set-Location $scalaRoot
$rrfForSbt = $rrfRoot.Replace('\', '/')

& $javaExecutable @sbtArgs "run inspect-rxnorm $rrfForSbt $rxRelease"
if ($LASTEXITCODE -ne 0) { throw 'RRF inspection failed.' }
~~~

This validates CONSO/REL, computes hashes, and counts eligible concepts, names, and relationships. It does not need PostgreSQL and does not inspect SAT.

Counts depend on the imported release. The reported scope is `all-active-rxnorm-pg-v4`.

### Import the base index

~~~powershell
& $javaExecutable @sbtArgs "run import-rxnorm $rrfForSbt $rxRelease"
if ($LASTEXITCODE -ne 0) { throw 'Base RxNorm import failed.' }
~~~

This loads raw CONSO/REL and the canonical/lexical projections. Wait for `Index ready`.

### Import product attributes

~~~powershell
& $javaExecutable @sbtArgs "run import-product-attributes $rrfForSbt $rxRelease"
if ($LASTEXITCODE -ne 0) { throw 'Product attribute import failed.' }
~~~

This imports SAT and derives eligible `RXN_STRENGTH` attributes. Wait for `Product index ready`, or `Product index verified` for an identical existing import.

The SAT import is additive. It requires the base release and matching CONSO/REL hashes; the lexical index does not need to be rebuilt.

### Inspect database state

~~~powershell
& $psql -h 127.0.0.1 -p 5432 -U scala_lab -d scala_testing_lab `
    -c 'SELECT release, scope, state, concept_count, description_count, relation_count FROM rxnorm_lab.release;'

& $psql -h 127.0.0.1 -p 5432 -U scala_lab -d scala_testing_lab `
    -c 'SELECT release, policy, state, raw_count, attribute_count FROM rxnorm_lab.product_release;'
~~~

### Import guarantees

- Each import activates its raw rows, projections, counts, and manifest transactionally.
- Identical files for the same release can be verified by reimport.
- Different hashes for an existing release are rejected.
- File hashes are checked again before activation.
- Advisory locks prevent competing imports of the same release.
- The product manifest includes SAT and its link to the base import.

The date label alone does not authenticate a downloaded release. Obtain the archive from NLM; the hashes identify and pin the actual files used by this application.

## 8. Complete example: paracetamol

### Step 1: query the local terminology

~~~powershell
Set-Location $scalaRoot

& $javaExecutable @sbtArgs "run lookup $rxRelease paracetamol"
& $javaExecutable @sbtArgs "run lookup $rxRelease acetaminophen"
~~~

In the release used for the VM demonstration, both names identify:

~~~json
{
  "system": "http://www.nlm.nih.gov/research/umls/rxnorm",
  "rxcui": "161",
  "release": "2026-10-05",
  "display": "acetaminophen",
  "tty": "IN"
}
~~~

The number `161` is retrieved from the terminology. It is not placed in the grammar, AST input, or a hand-written paracetamol mapping.

The lookup's `names` array shows the RXAUI, original name, source TTY, and SAB supporting the result. Synonyms work because the imported source atoms associate those names with the same concept.

### Step 2: build the Langium project

~~~powershell
Set-Location $langiumRoot

npm.cmd ci
if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }

npm.cmd run langium:generate
if ($LASTEXITCODE -ne 0) { throw 'Langium generation failed.' }

npm.cmd run build
if ($LASTEXITCODE -ne 0) { throw 'Langium build failed.' }
~~~

`langium:generate` turns the grammar into parser metadata, generated AST types, and language support. `build` compiles the TypeScript services and bundles the extension. Generated sources should be regenerated after a grammar change.

### Step 3: understand the input document

[examples/paracetamol.clinical](examples/paracetamol.clinical) contains a fictional patient, medication, plan, and a `show` statement:

~~~text
patient DemoPatient {
  age 30
  condition DemoCondition
}

medication paracetamol {
  1 mg
  route PO
  frequency PRN
}

plan DemoPlan {
  for DemoPatient
  prescribe paracetamol
}

show DemoPlan
~~~

The current Langium validator accepts positive finite administered amounts, including decimals. `[1, 2.5, 10]` are completion suggestions, not an enforced list. The example's `1 mg` is a parser fixture, not a dosing recommendation or product strength.

Langium links `DemoPlan` to `DemoPatient` and `paracetamol`. The exporter follows these linked objects rather than extracting names from source text with regular expressions.

### Step 4: export the real validated AST

~~~powershell
Set-Location $scalaRoot

node.exe bridge/export-ast.mjs `
    --langium-root $langiumRoot `
    --input examples/paracetamol.clinical `
    --release $rxRelease `
    --output data/ast/paracetamol.json

if ($LASTEXITCODE -ne 0) { throw 'AST export failed.' }

Get-Content -LiteralPath data/ast/paracetamol.json -Raw -Encoding UTF8
~~~

The exporter:

1. Loads the compiled `createClinicalDslServices` implementation.
2. Creates a Langium document from one snapshot of the input file.
3. Builds it with validation enabled.
4. Rejects lexer/parser errors, unresolved references, duplicate declarations, and duplicate/absent `show` selections.
5. Follows each selected plan's patient and medication references.
6. Produces a plain JSON request.

The contract includes:

| Field | Purpose |
| --- | --- |
| `schemaVersion: "1"` | Input contract version. |
| `policyVersion: "exact-v1"` | Resolution policy version. |
| `terminologyRelease` | Exact local release to use. |
| `document.uri` / `document.text` | Original document identity and text. |
| `mentions[].originalText` | Medication name from the AST. |
| `mentions[].role` | Semantic role; the current DSL bridge exports `medication`. |
| `mentions[].source` | Original medication declaration and UTF-16 source positions. |
| `dose` / `route` / `frequency` | Administration information already represented by the grammar. |
| `patientRef` / `orderId` | Patient and plan context. |
| `productStrength` / `doseForm` | Optional explicit product qualifiers. |

The JSON is an AST projection. It does not serialize all Langium internals and their object references/cycles.

### Step 5: resolve in Scala

~~~powershell
& $javaExecutable @sbtArgs 'run resolve data/ast/paracetamol.json out/paracetamol-resolved.json'
if ($LASTEXITCODE -ne 0) { throw 'Scala resolution failed.' }

$report = Get-Content -LiteralPath out/paracetamol-resolved.json -Raw -Encoding UTF8 |
    ConvertFrom-Json

$report.resolutions | ForEach-Object {
    [pscustomobject]@{
        Text   = $_.mention.originalText
        Role   = $_.mention.role
        Status = $_.status
        RxCUI  = $_.initialConcept.rxcui
        Name   = $_.initialConcept.display
        Type   = $_.initialConcept.tty
    }
} | Format-Table -AutoSize
~~~

Expected demonstration result:

| Text | Role | Status | RxCUI | Name | Type |
| --- | --- | --- | --- | --- | --- |
| paracetamol | medication | resolved | 161 | acetaminophen | IN |

Scala validates the input, obtains the release-specific database snapshot, applies the pure resolver, saves the binding, and writes the report.

The output contract has `schemaVersion: "2"`. `initialConcept` is the name-resolved concept. `selectedProduct` is absent in this example because an ingredient and an administered dose do not identify a product.

The informational diagnostic `PRODUCT_NOT_SELECTED: administered dose is not product strength` explains this distinction; it does not invalidate the ingredient match.

Regenerate the AST after editing or moving a DSL example. The included JSON files represent previous example runs; they are not a replacement for exporting the current source with its current URI and positions.

## 9. Product strength and dose form

Use a complete fictional example such as:

~~~text
patient ProductPatient {
  age 30
  condition DemoCondition
}

medication aspirin {
  1 mg
  strength "325 mg"
  doseForm "Oral Tablet"
  route PO
  frequency PRN
}

plan ProductPlan {
  for ProductPatient
  prescribe aspirin
}

show ProductPlan
~~~

Save it as `examples/aspirin-product.clinical`.

~~~powershell
Set-Location $scalaRoot

node.exe bridge/export-ast.mjs `
    --langium-root $langiumRoot `
    --input examples/aspirin-product.clinical `
    --release $rxRelease `
    --output data/ast/aspirin-product.json

if ($LASTEXITCODE -ne 0) { throw 'Product AST export failed.' }

& $javaExecutable @sbtArgs 'run resolve data/ast/aspirin-product.json out/aspirin-product-resolved.json'
if ($LASTEXITCODE -ne 0) { throw 'Product resolution failed.' }
~~~

### Dose, strength, and dosage

| Term | Meaning |
| --- | --- |
| Administered `dose` | Amount given at an administration event; `1 mg` is the existing demo fixture. |
| Product `strength` | Ingredient amount in the pharmaceutical product, such as `325 mg` per tablet. |
| Concentration | A strength expressed per volume, such as `160 mg/5 ml`. |
| `doseForm` | Pharmaceutical form, resolved to a terminology `DF` concept. |
| Dosage | Administration instructions/regimen; this is not the name chosen for the product-strength field. |

The grammar maps the `strength` keyword to `productStrength`: legacy brace syntax uses `productStrength=STRING`, while colon syntax uses `productStrength=UnquotedStrength`. The user writes `strength` in the DSL; AST/JSON/Scala retain `productStrength`. The custom Langium value converter preserves spaces in unquoted strength and multiword dose-form values.

The administered dose remains separate. The strength pair is optional for ingredient resolution, but `productStrength` and `doseForm` must be supplied together when requesting product verification.

### The product policy

The policy identifier is `single-component-mass-v1`.

1. Resolve the medication name and semantic role first.
2. Resolve the dose-form text to one exact eligible `DF` concept.
3. Find generic `SCD` candidates for an `IN` seed, or branded `SBD` candidates for a `BN` seed. A directly identified SCD/SBD can also be checked.
4. Verify `has_dose_form`.
5. Follow the generic component path to one `SCDC` with one direct `IN` ingredient.
6. Read the imported atom-linked `RXN_STRENGTH`.
7. Compare it with the explicit requested strength.
8. Select only one verified product when the required evidence is complete.

For branded products, the evidence also preserves `SBD → tradename_of → SCD`.

`BigDecimal` comparisons allow `0.325 g` to match `325 mg`. Concentrations are compared by cross multiplication, so `160 mg/5 ml` matches `32 mg/ml` without rounding a ratio. A simple mass is not equated with mass per volume.

### Inspect the evidence

A product resolution separates:

- `initialConcept`: the ingredient, brand, or product found by name.
- `selectedProduct`: the selected clinical/branded product.
- `ingredients`: derived ingredient concepts and their relationship paths.
- `productEvidence`: policy, product, dose form, component, strength attribute, RXAUI/ATUI, and supporting relations.

The product RxCUI is read from the imported release. It is not hard-coded in the example.

### Statuses and negative tests

| `resolve` status | Meaning |
| --- | --- |
| `resolved` | Name/role resolved; if product verification was requested, a product passed that policy. |
| `unresolved` | No exact eligible imported name. |
| `invalidRole` | The concept exists but cannot fill the requested semantic role. |
| `productNotFound` | No supported product/form match for the requested qualifiers. |
| `needsClarification` | Ambiguity, missing fields/evidence, or a request outside the implemented policy. |

The simpler `lookup` command uses `matched`, `unresolved`, and `ambiguous`.

Try a fictional name absent from the dataset to test `unresolved`. Change only the strength to `100000 mg` to test a product mismatch. That requests 100 g per unit; there is no medical maximum-strength threshold in this code. A known aspirin ingredient can remain `IN 1191` even when no product with the requested attributes is found.

Missing or conflicting strength evidence produces `PRODUCT_EVIDENCE_INCOMPLETE` and requires clarification. Multiple supported matches produce `PRODUCT_AMBIGUOUS`. A database failure is an unavailable check, not an unknown medication.

## 10. VS Code extension workflow

### Colon syntax and contextual help

Use `:` after the declaration name and commas between fields. Names remain identifiers; product strength and multiword dose forms do not need quotes in colon syntax.

```text
Patient DemoPatient: age 30, condition DemoCondition
Medication aspirin: 15 mg, strength 325 mg, doseForm Oral Tablet, route PO, frequency PRN
Plan DemoPlan: for DemoPatient, prescribe aspirin
show DemoPlan
```

This is a syntax example, not a treatment recommendation. `15 mg` is the administered amount; `325 mg` is the product strength. `route` and `frequency` are required. Supply both `strength` and `doseForm`, or omit both.

In a writable `.clinical` editor:

1. Press **Ctrl+Space** for completion suggestions.
2. Press **?** for help based on the text before the cursor: declaration name, amount, strength, dose form, route, frequency, patient, plan, or `show`.
3. Choose **Show suggestions** in the help message to open completion at that position.

The command is **Clinical DSL: Context Help (?)** in the Command Palette. Its default keybinding is **Shift+/**; on other keyboard layouts, rebind that command in Keyboard Shortcuts. The shortcut consumes the key without inserting `?`: it is editor help, not part of the grammar, saved document, or JSON sent to Scala. A question mark pasted into the source is not automatically removed and can cause a syntax error.

Lowercase `patient`, `medication`, and `plan` remain accepted, as do legacy brace declarations. `show` stays lowercase. Completion provides local language suggestions; it does not query RxNorm on every keystroke.

The AST/JSON contract is unchanged. The bridge still exports the plans selected by `show`, preserving source positions. No PostgreSQL reimport is needed for the syntax/help update.

The grammar and editor command live in the companion Langium repository; Scala continues to consume the same exported JSON. For legacy brace syntax, product qualifiers remain quoted. See the [Langium grammar guide](https://github.com/bogdanparvu18/langium_dsl_lab/blob/main/clinical-dsl-demo/README.md) and this repository's [colon example](examples/colon-help.clinical).

After updating the Langium checkout, rebuild it and reload Extension Development Host:

~~~powershell
Set-Location $langiumRoot
npm ci
npm run langium:generate
npm run build
npm test
~~~

Open the workspace folder containing `package.json` and `.vscode`, launch **Run Extension** with F5, and open an example from that same checkout. The syntax/help update itself requires no Scala schema migration or new RxNorm import.


### Tool layout

The extension reads `layout.json` from `clinicalDsl.rxnorm.toolsRoot`. The default directory is `USERPROFILE\AuroraLab\tools`. Its fields identify the real JDK directory, Node executable directory, and sbt home containing `bin\sbt-launch.jar`.

If a working layout already exists, keep it. For a fresh setup using the launcher prepared above, create it as follows:

~~~powershell
$layoutFile = Join-Path $toolsRoot 'layout.json'

if (-not (Test-Path -LiteralPath $layoutFile)) {
    $javaSettings = & $javaExecutable '-XshowSettings:properties' '-version' 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect Java.' }

    $javaHomeLine = $javaSettings |
        ForEach-Object { $_.ToString() } |
        Where-Object { $_ -match '^\s*java\.home\s*=' } |
        Select-Object -First 1

    if (-not $javaHomeLine) { throw 'java.home was not found.' }
    $jdkHome = ($javaHomeLine -split '=', 2)[1].Trim()

    if (-not (Test-Path -LiteralPath (Join-Path $jdkHome 'bin\javac.exe'))) {
        throw 'The selected Java installation is not a full JDK.'
    }

    $nodeHome = Split-Path -Parent (Get-Command node.exe -ErrorAction Stop).Source

    [ordered]@{
        javaHome = $jdkHome
        nodeHome = $nodeHome
        sbtHome = $sbtHome
    } | ConvertTo-Json | Set-Content -LiteralPath $layoutFile -Encoding UTF8
}
~~~

### Extension settings and password

Build the Langium project, open `$langiumRoot` in VS Code, select **Run Extension**, and press F5.

In the Extension Development Host, configure the following in **User Settings (JSON)**. This PowerShell block prints a JSON object containing the actual paths from the setup; merge its keys into the existing user settings:

~~~powershell
[ordered]@{
    'clinicalDsl.rxnorm.scalaRoot' = $scalaRoot
    'clinicalDsl.rxnorm.toolsRoot' = $toolsRoot
    'clinicalDsl.rxnorm.release' = $rxRelease
    'clinicalDsl.rxnorm.onSave' = $true
    'clinicalDsl.rxnorm.pgHost' = '127.0.0.1'
    'clinicalDsl.rxnorm.pgPort' = 5432
    'clinicalDsl.rxnorm.pgDatabase' = 'scala_testing_lab'
    'clinicalDsl.rxnorm.pgUser' = 'scala_lab'
    'clinicalDsl.rxnorm.timeoutSeconds' = 300
} | ConvertTo-Json
~~~

Run these commands through the VS Code Command Palette:

1. **Clinical DSL: Set RxNorm PostgreSQL Password**
2. **Clinical DSL: Resolve Medications with RxNorm**

The password command uses VS Code SecretStorage. It is not a password field in project settings. The database configuration is part of the secret's key, so changing the database/user may require setting its password again.

### What happens on save

With `onSave` enabled:

1. The extension records the document version and invalidates the previous result.
2. It invokes the Node exporter against the saved `.clinical` file.
3. It verifies that the exported text/URI still represent the requested document.
4. It starts Java/sbt with `run resolve`.
5. Scala consults local PostgreSQL and writes the report.
6. The extension validates report identity and publishes diagnostics/preview data.
7. Temporary files are cleaned up.

Only one queued sbt resolution runs at a time. Superseded saves are skipped. An edit, close, or configuration change invalidates the cached result.

### Where results appear

- **Output → Clinical DSL RxNorm:** process logs, release/snapshot metadata, and the result table.
- **Problems:** information for resolved concepts, errors for unknown names/products, and warnings for clarification.
- **Preview JSON** at a `show` statement: the projected plan enriched with `medication.rxnorm`.

| Preview state | Interpretation |
| --- | --- |
| `notChecked` | No current verified result. |
| `checking` | Resolution is running. |
| `unavailable` | Export/process/database verification failed. |
| `unresolved` with `MEDICATION_UNKNOWN` | Scala found no eligible exact imported medication name. |
| `productNotFound` with `PRODUCT_NOT_FOUND` | Ingredient/name may be known, but the requested product was not selected. |
| `resolved` | Current terminology result, including selected product/evidence when available. |

Backend `UNRESOLVED_IN_DATASET` is presented as `MEDICATION_UNKNOWN` by the UI. The extension does not perform a second terminology-matching algorithm.

## 11. Functions and design decisions

### A. Input contract and source validation — [Domain.scala](src/main/scala/lab/Domain.scala)

| Function/type | Responsibility | Design reason |
| --- | --- | --- |
| `AstRequest` / `Mention` | Represent document, policy/release, role, administration context, and optional product qualifiers. | An explicit contract prevents the resolver from depending on Langium's internal object representation. |
| `SourceLocation` / `Position` | Preserve URI, text, line, character, and offset. | The result can be attached to the original declaration in the editor. |
| `InputValidation.validate` | Check contract versions, IDs, role, dose representation, qualifier format, URI, and source ranges. | Reject inconsistent inputs before applying terminology rules. |
| `TextKey.normalize` | NFKC normalization, trim, whitespace compaction, and lowercase with `Locale.ROOT`. | Normalize formatting without creating semantic equivalence. |
| `Hashing.sha256` | Hash text/content identifiers. | Support reproducibility and stable binding IDs. |
| `Hashing.fingerprint` | Hash release, scope, and sorted source-file hashes. | Identify the terminology snapshot behind a report. |
| `Candidate` / evidence types | Preserve supporting names, relations, attributes, and identifiers. | Make a result explainable and auditable. |
| `ResolutionReport` | Carry results, shared ingredients, input hash, policy, and snapshot metadata. | Separate terminology findings from the input DSL. |

`@jsonNoExtraFields` is used on input case classes. Unknown input keys are rejected instead of silently discarding a qualifier. `derives JsonCodec` generates the codecs; `fromJson` decodes input and `toJson`/`toJsonPretty` encode stored/human-readable output.

Source validation checks UTF-16 positions against the original text. This matches the coordinate system used by Langium/LSP and JVM strings.

### B. Preparing and reading terminology — [Rrf.scala](src/main/scala/lab/Rrf.scala)

| Function | Responsibility |
| --- | --- |
| `Rrf.prepare` | Validate the release label and required files, calculate hashes, and prepare canonical concept summaries. |
| `Rrf.rows` | Read UTF-8 lines and require the correct field count plus a final pipe. |
| `Rrf.hash` | Hash a file incrementally through a buffered input stream. |
| `foreachConsoRow` | Emit original CONSO fields without filtering the raw data. |
| `foreachRelRow` | Emit original REL fields in official order. |
| `foreachDescription` | Emit eligible active English names associated with imported canonical concepts; retain source evidence and reject duplicate retained RXAUIs. |
| `foreachRelation` | Emit eligible active RXNORM CUI-to-CUI edges, orient them correctly, and reject incomplete required composition paths. |
| `verifyUnchanged` | Compare current file hashes with the preparation manifest. |

The import plan keeps canonical concept summaries in memory. Name processing also tracks numeric atom identifiers for duplicate detection. The large row payloads are read incrementally rather than retaining the entire release as a large collection.

Canonical selection requires eligible active English RXNORM atoms. The name index can additionally retain names from other imported sources attached to those concepts. A source synonym is not relabeled as an RXNORM synonym.

RRF relation direction is important: the relationship describes what the second endpoint has to the first. The application represents an edge as `source = RXCUI2` and `target = RXCUI1`.

### C. PostgreSQL connection and transaction helpers — [PostgresStore.scala](src/main/scala/lab/PostgresStore.scala)

| Function | Responsibility |
| --- | --- |
| `PGConfig.fromEnvironment` | Read PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD and reject a missing password. |
| `PostgresStore.open` | Restrict the connection to loopback, validate configuration, and initialize the schema. |
| `connect` | Open a JDBC connection with credentials supplied as properties. |
| `use` | Acquire/close a connection within a ZIO scope and run blocking work appropriately. |
| `transaction` | Select isolation, disable auto-commit, commit on success, and roll back on failure. |
| `query` / `update` | Execute prepared SQL and close statements/result sets. |
| `strings` | Bind string parameters through `setString`. |
| `array` | Bind PostgreSQL arrays and free the JDBC array afterward. |
| `ensureSchema` | Load the packaged SQL resource and initialize tables/indexes under an advisory transaction lock. |

Parameters are bound through prepared statements rather than interpolating medication text into SQL. Table/relation fragments in the implementation are defined by code.

The store materializes the requested snapshot before closing the JDBC connection. The resolver therefore receives normal Scala values and does not depend on a live ResultSet.

### D. COPY and import functions

| Function | Responsibility |
| --- | --- |
| `CopyText.encodeRow` | Encode fields for COPY text: preserve empty strings and quotes; escape backslash, tab, newline, and carriage return; reject null/NUL fields. |
| `copy` | Send bounded buffers to PostgreSQL's `CopyManager` and check the returned row count. |
| `importIndex` | Import CONSO/REL, canonical concepts, and lexical names; verify counts and hashes before activation. |
| `counts` | Compare actual persisted counts with the recorded import manifest. |
| `ProductAttributes.prepare` | Prepare the SAT extension and hash CONSO, REL, and SAT. |
| `PreparedProductAttributes.foreachRow` | Stream all 13 original SAT fields. |
| `importProductAttributes` | Require the matching ready base release, import raw SAT, derive product attributes, and activate atomically. |
| `materializeProductAttributes` | Join SAT to its exact CONSO atom and canonical SCDC; keep eligible RXNORM `RXN_STRENGTH` attributes. |

The copy transport has a small buffer, approximately 64 KiB plus the current row. The raw RRF fields are preserved even though the transport encoding is different.

The product attribute join checks the atom identity, vocabulary, language, suppression status, attribute name, and SCDC type. An attribute belonging to another atom/source does not automatically become product-strength evidence.

Release imports are immutable by identity. Re-running the same import verifies it; a different file manifest for the same release is not silently substituted.

### E. Snapshot queries and local indexing

| Function | Responsibility |
| --- | --- |
| `snapshot` | Load names and the relevant concept/ingredient relationships for ordinary lookup. |
| `snapshotForResolution` | Include medication names and dose forms; determine whether product data is required. |
| `readSnapshot` | Read a ready release and its bounded concept/relation/attribute closure in one consistent read transaction. |
| `saveBinding` | Store the request/report under a deterministic run ID and verify an existing identical binding. |

Read transactions use **REPEATABLE READ**, so one snapshot query sequence observes a consistent database state.

The lexical index uses `md5(normalized)` to keep index keys fixed-size, then checks **full normalized string equality** as well. The digest is an indexing aid; it is not a replacement for comparing the name. File provenance uses SHA-256.

The code enforces bounds including:

- 1–100 distinct lookup terms.
- At most 5,000 product candidates.
- Bounded relationship traversal depth, concept count, and edge count.

If a bound is exceeded, the operation fails rather than presenting a truncated result as complete.

### F. Pure semantic resolution — [Resolver.scala](src/main/scala/lab/Resolver.scala)

`Resolver.candidates` groups exact normalized names by concept and returns all candidate concepts with their source name evidence.

`Resolver.resolve`:

1. Validates the request and release/scope compatibility.
2. Obtains exact lexical candidates.
3. Applies the semantic role filter.
4. Retains ambiguity when multiple allowed concepts remain.
5. Runs product selection when qualifiers are present.
6. Derives ingredients through supported typed paths.
7. Builds diagnostics, shared-ingredient findings, and report metadata.

| Role | Accepted canonical types |
| --- | --- |
| `medication` | IN, PIN, MIN, BN, SCD, SBD |
| `activeIngredient` | IN, PIN |
| `medicationProduct` | SCD, SBD |

The DSL bridge currently exports `medication`. The other roles are supported by the Scala contract/policy; they are not inferred solely from the spelling of the medication.

The internal `derive` function traverses only permitted typed relationships, such as clinical drug → component → ingredient, branded → generic drug, or precise ingredient → ingredient. It tracks visited concepts to prevent cycles, deduplicates resulting ingredients, and keeps a deterministic supporting path.

A brand name by itself is not treated as a selected product with a complete ingredient set.

The `sharedIngredients` calculation groups resolved ingredients by patient and distinct order IDs. It can identify a common ingredient across orders in the current request. It does not calculate dose totals or drug interactions.

The resolver is pure: identical request, snapshot, and policy produce the same report. Filesystem access, JDBC operations, and UI presentation remain outside it.

### G. Product matching

[ProductStrength.scala](src/main/scala/lab/ProductStrength.scala):

- `parse` recognizes positive g/mg/mcg values, optionally per ml.
- It converts mass to mg and retains an optional volume denominator.
- `equivalent` compares simple masses directly or uses cross multiplication for concentrations.
- Binary floating-point arithmetic is not used for these comparisons.

[ProductAttributes.scala](src/main/scala/lab/ProductAttributes.scala):

- Defines `single-component-mass-v1`.
- Prepares the additional source manifest.
- Streams raw attributes and checks that source files remain unchanged.

[ProductSelector.scala](src/main/scala/lab/ProductSelector.scala):

- `select` requires both product qualifiers.
- It resolves the form, finds supported product paths, checks the component and direct IN ingredient, and verifies the imported strength.
- Missing/conflicting evidence is kept distinct from a verified mismatch.
- Several verified matches remain ambiguous.
- A single requested strength cannot silently select a combination product.

### H. CLI entry point — [Main.scala](src/main/scala/lab/Main.scala)

`Main` extends `ZIOAppDefault`. Its argument pattern matching dispatches the commands below.

| Command passed to sbt | PostgreSQL required | Result |
| --- | --- | --- |
| `run inspect-rxnorm <rrf-dir> <release>` | No | Source validation, hashes, and counts. |
| `run import-rxnorm <rrf-dir> <release>` | Yes | Ready base index. |
| `run import-product-attributes <rrf-dir> <release>` | Yes | Ready product-attribute extension. |
| `run lookup <release> <name>` | Yes | Lookup JSON report. |
| `run resolve <ast.json> <result.json>` | Yes | Saved binding and JSON resolution report. |

`readInput` reads the request, decodes it with zio-json, and calls input validation.

`writeJson` writes to a temporary file, attempts an atomic move to the destination, and falls back to replacement when atomic move is unavailable.

The run ID combines input/report/policy/snapshot information. Repeating an identical resolution does not create another distinct binding.

The sbt command is passed as one argument after `@sbtArgs`. The example sbt paths use directories without spaces.

### I. Langium AST export — [bridge/export-ast.mjs](bridge/export-ast.mjs)

| Function/API | Responsibility |
| --- | --- |
| `langiumImportUrl` | Locate the language workspace's Langium package and its ESM import export. |
| `createRequire` / dynamic `import` | Resolve dependencies from the correct workspace and load the compiled ESM services. |
| `exportDocument` | Build and validate a real Langium document and project selected plans into the request contract. |
| `LangiumDocumentFactory.fromString` | Create a document from the exact source snapshot. |
| `DocumentBuilder.build(..., { validation: true })` | Parse, link, and execute language validators. |
| `duplicates` | Reject duplicate declarations before following linked references. |
| `$cstNode` / `textDocument.offsetAt` | Obtain source ranges and UTF-16 offsets for editor diagnostics. |
| `parseArgs` | Validate CLI options. |
| Exporter `main` | Read options and write JSON through a temporary file. |

The bridge does not resolve RxNorm itself. It passes user input and context to Scala.

### J. Langium validation and editor presentation

In the companion repository:

- `registerValidationChecks` registers validators for AST node types.
- `checkMedicationAmount` validates positive finite amounts; completion suggestions do not restrict the accepted amounts.
- `ClinicalDslValueConverter` preserves whitespace in unquoted strength and dose-form values.
- `registerContextHelp` provides contextual editor help without inserting `?` into the document.
- `checkProductQualifiers` checks the explicit strength/form pair and supported positive strength syntax.
- `projectPlan` projects linked plan objects for Preview JSON.
- `activate` starts the LanguageClient and registers editor functionality.
- `registerRxNorm` connects commands and editor events to the local workflow.
- `runProcess` uses `spawn` with `shell: false`, streams logs, and enforces a timeout.
- `schedule` queues work and binds it to document version/generation.
- `invalidate` removes stale cached results and diagnostics.
- `checkReport` rejects reports inconsistent with the requested source, release, mention IDs, or qualifiers.
- `getPreview` exposes only a result valid for the current document and selected plan.
- `withRxNormPreview` adds Scala's result to the plan JSON.
- `rxnormPreviewTitle` labels checking, unavailable, unknown, and product-not-found previews.

These functions divide responsibilities deliberately: Langium owns language structure, Scala owns terminology resolution, and the extension owns presentation and process orchestration.

## 12. Testing

### Scala tests: no PostgreSQL required

~~~powershell
Set-Location $scalaRoot
& $javaExecutable @sbtArgs test
~~~

The current suite has **51 tests** using synthetic fixtures:

| Test file | Coverage |
| --- | --- |
| [RrfSpec.scala](src/test/scala/lab/RrfSpec.scala) | RRF layout, scope, synonyms, source identity, relation direction, and incomplete composition. |
| [CopyTextSpec.scala](src/test/scala/lab/CopyTextSpec.scala) | COPY escaping and faithful field transport. |
| [ResolverSpec.scala](src/test/scala/lab/ResolverSpec.scala) | Roles, ambiguity, source validation, deterministic results, and shared ingredients. |
| [ProductSpec.scala](src/test/scala/lab/ProductSpec.scala) | Exact units/ratios, product selection, mismatches, ambiguity, brand paths, and missing evidence. |
| [ProductAttributesSpec.scala](src/test/scala/lab/ProductAttributesSpec.scala) | SAT columns and immutable source hashes. |

The tests do not require the licensed Full release.

### Optional PostgreSQL integration check

With the database environment configured:

~~~powershell
& $javaExecutable @sbtArgs 'Test/runMain lab.ProductIntegrationCheck'
~~~

This uses synthetic reserved releases `2099-02-01` and `2099-02-02` in the configured database. It exercises native COPY, atom-linked attribute filtering, generic/branded products, mismatched strength, immutable imports, idempotency, and rollback.

The optional `--read-only-fixture` mode is for a SQL harness without native COPY support. It skips native importer/idempotency/rollback checks and does not replace the normal PostgreSQL integration check.

### AST bridge tests

After building Langium:

~~~powershell
Set-Location $scalaRoot
$env:LANGIUM_ROOT = $langiumRoot
node.exe --test bridge/export-ast.test.mjs
~~~

There are **10 tests**, including real parser/linker/validator execution, source positions, selected plans, product qualifiers, and colon syntax with unquoted values.

### Extension tests

~~~powershell
Set-Location $langiumRoot
node.exe --test packages/extension/test/context-help.test.mjs packages/extension/test/rxnorm.test.mjs
~~~

The two suites contain **25 tests**: 3 contextual-help tests and 22 RxNorm tests covering process orchestration, unknown medications, product feedback, preview state, and invalidation of obsolete results.

Simulated-process UI tests are separate from a complete import of a real NLM release and a visual check on Windows. Run the database check and the saved-document editor examples on the target VM.

## 13. Limitations and troubleshooting

### Scope

- Name matching is exact after formatting normalization. There is no fuzzy spelling correction.
- Only eligible active English names associated with supported canonical concepts participate in resolution.
- Product selection currently supports one component with a direct IN ingredient and mass or mass/ml strength.
- Combination products, salt/BoSS equivalence, percentages, international units, and mg/hour require additional policies.
- Strength/form can still leave multiple products; the application requires clarification.
- `clinicianConfirmed` remains `false`. Terminology resolution does not record clinician confirmation.
- Shared-ingredient findings are structural findings for the supplied orders, not clinical dose-safety or interaction conclusions.
- Each editor resolution starts sbt; startup latency is acceptable for this laboratory but can motivate a persistent service during future Aurora integration.

### Common issues

| Symptom | Action |
| --- | --- |
| PowerShell says the expression after `&` is invalid | Recreate `$javaExecutable` and `$sbtArgs` in the current terminal; verify the executable path. |
| `psql` is not recognized | Use the absolute `$psql` path or add PostgreSQL's bin directory to the session PATH. |
| `-J-Xmx2G` is treated as an sbt command | Use the direct Java invocation documented above, with `-Xmx2G` before `-jar`. |
| PostgreSQL authentication fails | Verify PGUSER/database, then reset with administrator `\password scala_lab` if needed. |
| `No ready local release` | Finish `import-rxnorm` for the exact requested date. |
| `Product index unavailable` | Run `import-product-attributes` using SAT from the matching Full archive. |
| More than one RXNSAT filename in ZIP | Select `rrf/RXNSAT.RRF` by full archive path. |
| `strength` is rejected by the parser | Confirm the product-aware grammar, regenerate Langium, rebuild, and restart Extension Development Host. |
| Nothing appears in Output | Save a `.clinical` file with a valid `show` statement, check configuration, or invoke the resolve command manually; select `Clinical DSL RxNorm` in Output. |
| Preview shows an older result | Save and rerun after editing; the current integration invalidates prior results on changes. |
| `PRODUCT_NOT_SELECTED` after an IN match | Supply explicit strength/form if a product is required; an ingredient match alone is valid. |
| `medication unknown` | No exact eligible imported name was found. Inspect `lookup` and its source evidence; do not insert a guessed RxCUI. |

Remove the password from the terminal environment when finished:

~~~powershell
Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
~~~

Keep terminology archives and real clinical documents outside published source code. The Windows examples place RxNorm under `C:\AuroraLab\data`.

## 14. References

- [Companion medical DSL](https://github.com/bogdanparvu18/langium_dsl_lab/tree/main/clinical-dsl-demo)
- [Aurora medication concept mapping: issue 48](https://github.com/Aurora-Constellations/auroraSjsExt/issues/48)
- [ZIO effect type](https://zio.dev/reference/core/zio/)
- [ZIO resource management](https://zio.dev/reference/resource/)
- [zio-json](https://zio.dev/zio-json/)
- [PostgreSQL JDBC documentation](https://jdbc.postgresql.org/documentation/)
- [PostgreSQL COPY](https://www.postgresql.org/docs/18/sql-copy.html)
- [PostgreSQL transaction isolation](https://www.postgresql.org/docs/18/transaction-iso.html)
- [Langium workflow](https://langium.org/docs/learn/workflow/)
- [RxNorm downloads](https://www.nlm.nih.gov/research/umls/rxnorm/docs/rxnormfiles.html)
- [RxNorm technical documentation](https://www.nlm.nih.gov/research/umls/rxnorm/docs/techdoc.html)
- [RxNorm relationships](https://www.nlm.nih.gov/research/umls/rxnorm/docs/appendix1.html)
- [RxNorm attributes](https://www.nlm.nih.gov/research/umls/rxnorm/docs/appendix4.html)
- [RxNorm term types](https://www.nlm.nih.gov/research/umls/rxnorm/docs/appendix5.html)
- [HL7 FHIR Medication](https://hl7.org/fhir/R5/medication.html) and [Dosage](https://hl7.org/fhir/R5/dosage.html)
- [Installing sbt on Windows](https://www.scala-sbt.org/1.x/docs/Installing-sbt-on-Windows.html)
