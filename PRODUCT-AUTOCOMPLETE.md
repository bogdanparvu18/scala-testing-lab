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

Choosing a product writes these fields into the Medication colon declaration:

```text
rxcui "900001" rxnormRelease "2026-10-05"
```

`900001` is a synthetic fixture identifier in this documentation. Actual IDs must come from the imported product suggestions. A complete declaration also needs its administered dose, route, and frequency. These are never inferred from the product ID.

The bridge exports the pair as:

```json
"productBinding": {
  "rxcui": "900001",
  "release": "2026-10-05"
}
```

| Request | Schema | Policy |
| --- | --- | --- |
| No mention has a binding | `1` | `exact-v1` |
| At least one mention has a binding | `2` | `explicit-product-v1` |

Mixed requests retain normal name resolution for their unbound mentions. The resolution report remains schema `2` and echoes the original binding. The source declaration and UTF-16 locations are preserved.

For a bound mention, `originalText` is a **local DSL alias**. Resolution fetches the selected RxCUI directly, checks its release and SCD/SBD type, and derives ingredients through the existing permitted relationship paths. Renaming the alias cannot change the selected terminology concept.

| Conflict | Behavior |
| --- | --- |
| Bound release differs from configured/requested release | The bridge rejects export; a direct resolver request returns a release-clarification result. |
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
