## Why

Aurora issue 48 needs a reproducible clinician-text-to-RxNorm workflow. This personal lab now uses PostgreSQL at the user's request: RxNorm RRF is tabular text, and a relational schema provides inspectable source rows, bulk loading and indexed local terminology lookup.

## Changes

- Keep Scala 3.5.1, sbt 1.10.2, ZIO/JVM and the real Langium AST bridge.
- Replace the Neo4j adapter with PostgreSQL/JDBC and an explicit SQL schema.
- Stream RXNCONSO and RXNREL into raw tables using COPY, then derive canonical active RXNORM concepts, associated active names across sources, and eligible relationships with provenance.
- Import each release in one transaction; rollback on failure, retry from the beginning. Verify source hashes and counts; reject changed input under an existing release identity.
- Resolve names against a local lexical index and fetch only relevant candidate composition. No external terminology API call per lookup, manual alias or hardcoded seed.
- Retain lookup/resolve CLI commands, semantic ambiguity handling and output schema 2 with terminologyScope.
- Supply Windows native PostgreSQL setup and safe Full ZIP extraction/import helpers. Docker PostgreSQL 17 is optional.

## Architecture decision

The issue proposes DuckDB/Parquet. This revision evaluates PostgreSQL under the personal account without assuming it is already Aurora's backend standard. RRF is pipe-delimited UTF-8 text, not a PostgreSQL native format; Scala handles validation, the trailing delimiter and COPY escaping. JDBC remains on the JVM. No extra Scala HTTP server is introduced.

Existing Neo4j installations are not migrated or deleted. Users create the separate PostgreSQL database and import the original RRF again.

## Paracetamol

Previously inspected CPC data did not contain the name paracetamol. The implementation relies on source atoms in the locally imported Full release and reports their SAB/RxAUI evidence. It does not hardcode a paracetamol target. Missing names remain unresolved; ambiguous candidates require clarification.

## Validation and scope

See docs/VALIDATION.md for tests actually performed. A licensed Full archive was unavailable in the preparation environment, so full-release import, resource sizing and the real paracetamol result require acceptance on the user's VM. Windows helper execution also requires Windows validation.

No RxNorm data, credentials, local database or patient records are included. Structured product filtering, clinician confirmation UI, fuzzy matching, Parquet output and Aurora HTTP integration remain outside this milestone. Administered dose is never treated as product strength.

This draft PR targets only bogdanparvu18/scala-testing-lab. It does not modify or deploy Aurora.

Related: https://github.com/Aurora-Constellations/auroraSjsExt/issues/48
