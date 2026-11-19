# Product search and explicit RxCUI bindings

## Start a service for the editor session

From this repository, with the same `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, and `PGPASSWORD` used for resolution:

```sh
sbt "run serve-products 8765"
```

On the Windows lab, after setting up the variables from the README, the equivalent launcher command is:

```powershell
& $javaExecutable @sbtArgs 'run serve-products 8765'
```

Keep the terminal open while editing. Stop the service with Ctrl+C. It binds to `127.0.0.1`, reuses the running JVM, and performs read-only searches over the ready imported release. Startup ensures the database schema and prefix index exist; first-time index creation can take longer. Original RRF data does not need reimporting.

Configure the companion VS Code extension:

```json
{
  "clinicalDsl.rxnorm.searchEnabled": true,
  "clinicalDsl.rxnorm.searchUrl": "http://127.0.0.1:8765",
  "clinicalDsl.rxnorm.release": "2026-10-05"
}
```

The service's PostgreSQL credentials come from its environment, not from the extension's SecretStorage. Both processes must point to the same database/release. Search can work without RXNSAT; validating manually supplied strength/form qualifiers still requires the matching product-attribute import.

## Search contract

```http
GET /products?release=2026-10-05&q=aspi&limit=20
```

The service returns `schemaVersion`, `release`, normalized `query`, `items`, and `hasMore`. Each item has string fields `rxcui`, `display`, `tty`, and `release`. Only **SCD/SBD** concepts are returned, including products matched through imported synonyms. RxCUIs remain strings.

Queries use NFKC/whitespace/case normalization and literal prefix matching. `%`, `_`, and backslash in user input are escaped rather than interpreted as SQL wildcards. Prefixes contain 2–100 normalized characters; result limits are 1–20. The database query uses a bounded-prefix index, prepared parameters, and a query timeout. Results are deduplicated by product and sorted deterministically by display and ID. `hasMore` tells the editor that the result set was truncated.

The endpoint accepts no document or patient payload, performs no binding writes, and is separate from final resolution. Missing/unready releases, malformed requests, and unavailable database searches return non-200 JSON errors. Browser origins and nonlocal Host headers are rejected; no CORS permission is provided.

## Persisted selection

On a new declaration line, type a product prefix such as `aspi` and press **Tab** on a suggestion to create a Medication. To keep an existing alias used by a Plan, type the prefix directly after the colon:

```text
Medication MorningMedication: aspi
```

For the synthetic product below, accepting the suggestion produces this line:

```text
Medication MorningMedication: product "aspirin synthetic product" rxcui "900001"
```

`Medication aspi` and the previously supported `rxcui "aspi"` search also offer products from the same catalog. In each case Tab writes the selected display name and numeric RxCUI. A bare search prefix on its own is temporary editor input. The bridge exports the completed declaration after the product is chosen and the required fields are filled in.

`900001` is a synthetic fixture identifier in this documentation. Actual IDs must come from the imported product suggestions. A complete declaration also needs its administered dose, route, and frequency. These are never inferred from the product ID.

The bridge includes the full display name and the configured release in each bound mention. For this example the exported binding is

```json
"productBinding": {
  "rxcui": "900001",
  "display": "aspirin synthetic product",
  "release": "2026-10-05"
}
```

| Request | Schema | Policy |
| --- | --- | --- |
| No mention has a binding | `1` | `exact-v1` |
| At least one mention has a binding | `2` | `explicit-product-v1` |

Mixed requests retain normal name resolution for their unbound mentions. The resolution report remains schema `2` and echoes the original binding. The source declaration and UTF-16 locations are preserved.

For a bound mention, `originalText` is a **local DSL alias**. Resolution fetches the selected RxCUI directly, checks its release, SCD/SBD type, and exact canonical display name when supplied, and derives ingredients through the existing permitted relationship paths. Renaming the alias cannot change the selected terminology concept.

| Conflict | Behavior |
| --- | --- |
| An older declaration explicitly pins a different release | The bridge rejects export; a direct resolver request returns a release-clarification result. |
| Saved product name differs from the canonical name for the selected RxCUI | Resolution asks for clarification. Select the product again to accept the current label. |
| Selected ID is absent | `productNotFound`, with no lexical fallback. |
| Selected ID is not an SCD/SBD or is used in an ingredient-only role | `invalidRole`. |
| Explicit strength/form conflict | Existing product validation checks only the selected ID and returns its failure/clarification result. |
| No manual strength/form | The exact product is retained, including a combination product, and ingredient evidence is derived when available. |

The existing strength/form policy remains limited to supported single-component products. An explicit binding does not bypass validation of manually supplied qualifiers and does not set `clinicianConfirmed` to true. Terminology identity is not a clinical suitability or dose-safety assessment.

## Implementation map

| File | Responsibility |
| --- | --- |
| `ProductSearch.scala` | Request/response types, bounds, HTTP handling and service lifecycle. |
| `PostgresStore.scala` | Indexed prefix search and explicit-ID snapshot loading. |
| `db/schema.sql` | Bounded lexical-prefix index over the imported release. |
| `Domain.scala` | ProductBinding type and versioned input validation. |
| `Resolver.scala` | Authoritative bound-product resolution without fallback. |
| `bridge/export-ast.mjs` | Validated Langium export and persisted selection contract. |

Run the usual Scala suite with `sbt test`, and the bridge tests with `LANGIUM_ROOT=/path/to/clinical-dsl-demo node --test bridge/export-ast.test.mjs` after building the companion language package. HTTP tests use synthetic fixtures; database integration requires a separate fixture database. No public terminology API or real patient data is needed for these tests.

## Canadian product selection and monographs

With the local service running and the companion extension installed, type `tyl` and accept the 500 mg Tylenol oral tablet suggestion. The editor asks which Canadian presentation you want. Confirm **TYLENOL EXTRA STRENGTH**, DIN `00559407`, to use the tablet presentation. The editor offers the cached English PDF and opens the professional dosage section when it can locate the heading. In the July 3, 2024 Tylenol document this is page 14. The backend compares the confirmed Canadian presentation with explicit dosage instructions in the English PDF. For this DIN it returns a draft dose of 500 mg and an interval of four to six hours as needed. The source includes an age group, a dose range, and per-dose and daily limits. The companion editor writes `dose 500 mg frequency 4-6H PRN` automatically in the selected declaration, where the clinician can edit either value before final validation. [Canadian prescribing information](https://pdf.hres.ca/dpd_pm/00076531.PDF#page=14).

| Action | Lookup |
| --- | --- |
| Type a prefix | The existing local `/products` endpoint searches RxNorm. |
| Accept a suggestion | `GET /canadian-products?release=…&rxcui=…` checks the selected RxNorm product and returns compatible marketed Canadian presentations from PostgreSQL. |
| Confirm a DIN | `POST /monograph?release=…&rxcui=…&din=…`, with `X-Aurora-Client: vscode`, validates the selection. On first access it looks up the DPD page by drug code, checks the DIN and follows the official document link. |
| View the PDF | The editor opens the returned signed `/monograph.pdf` URL, which identifies the confirmed DIN, RxNorm release, product and PDF checksum. This also supports VS Code port forwarding. The cached bytes remain available while Health Canada is unreachable. |

The candidate lookup compares all supported active ingredients and strengths, route and dosage form using the ready RxNorm release and DPD snapshot. Branded products also require brand-name evidence. Supported presentations include oral tablets and capsules, selected delayed-release, chewable, disintegrating and effervescent forms, and oral solutions and suspensions. Complex forms, unsupported release durations and unverified salt conversions can yield no candidates. The editor distinguishes this outcome from a Canadian product with no published electronic monograph. Reopen a document with **Open Health Canada Product Monograph** from the command palette while the cursor is in the bound Medication declaration.

### Dose and frequency in the monograph response

An available monograph includes `regimenSuggestions`. Each item has `dose`, `frequency`, the one-based physical PDF `page`, the applicable `context` and the source `evidence`. The response also includes the source URL, PDF checksum, revision when known, and a signed local preview link. The fields come from the dosage passage of that PDF. The catalog strength helps identify the passage. The extractor keeps as-needed qualifiers and interval ranges. Where the source gives a supported dose range for a matching whole tablet, the lower written dose is the editable starting value.

This version recognizes English dosage sections with an explicit immediate-release heading, a general adult age group, and a strength-labelled row for a single-ingredient oral tablet or capsule. The row must give an amount and an hourly or once-daily schedule. Tables, weight-based dosing, modified-release products, unrecognized layouts and conflicting instructions produce an empty suggestions list. The cached PDF remains available for the clinician to consult. Product resolution verifies the terminology binding. It does not assess the clinical suitability of an edited schedule.

### Keeping documents on a tester’s computer

The shared list in `src/main/resources/monographs.tsv` records the DPD drug code, DIN, verified English PDF URL, revision date, SHA-256 and product name. Add a verified entry to distribute a presentation to other installations on their next bootstrap. If the product page is temporarily unreachable on first use during setup, the installer can retrieve the previously verified document from its official PDF URL and requires an exact checksum match. It reports when it uses this fallback. An explicit withdrawal on the DPD page takes precedence. Each tester keeps their additional selections locally. The service and bootstrap use the same Scala checkout as their working directory. Inside the managed Docker runtime the cache is `/workspace/repos/scala-testing-lab/data/monographs/`.

The `documents/` directory contains one PDF per SHA-256 checksum. The `products/` directory records the DIN-to-document association, including source URL and revision when available. Bootstrap checks the shared list and this machine’s previous selections for updated DPD links. A change creates a new active association and keeps earlier PDFs on disk. A network failure with a previously verified local PDF emits a warning and retains that copy. A failed first download reports the DIN and a retry command. If Health Canada explicitly lists no electronic monograph, the product is marked accordingly. Git tracks the shared index and ignores the machine’s downloaded files.
