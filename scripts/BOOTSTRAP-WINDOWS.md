# Windows bootstrap: update, rebuild, verify

Run from a directory OUTSIDE either checkout, or pass the same explicit installation root each time:

```powershell
.\bootstrap-windows.ps1 -Root 'C:\Aurora Lab'
```

`Root` contains the sibling `scala-testing-lab`, `langium_dsl_lab` and `medication-lab-setup` directories. Keep the original Root, port, container and volume names when reusing an installation. Run one bootstrap at a time. Install Git, Java 21 (`JAVA_HOME`), Node >=22.12, npm >=10.2.3, Docker Desktop (Linux containers), and VS Code beforehand. `-NoEditor` deliberately skips VS Code, not the runtime checks.

## Every successful run

1. Execute Java/Node/npm checks. Start Docker Desktop from its standard installation path when its engine is unavailable; wait up to `StartupTimeoutSeconds` (default 180). Never silently switch Docker contexts or container engines.
2. Fetch both repositories and fast-forward to the current `origin/main`. No repository commit SHA is pinned. Verify local HEAD equals the remote commit fetched during this run. An offline/failing fetch is a failure, not permission to report success with stale code.
3. Migrate clean detached checkouts made by the old bootstrap back to `main`. If the bootstrap itself changed, restart using the fetched script in this same invocation (bounded to avoid an update loop).
4. Run `npm ci --include=dev`, `npm run clean`, `npm run langium:generate`, and `npm run build`, unconditionally. Check that the language, extension, server and grammar artifacts exist.
5. Create/start the matching PostgreSQL container, retain its existing volume, and set `unless-stopped` restart policy. Require container-running state, `pg_isready`, and an authenticated `SELECT 1`.
6. Run sbt `clean` and `compile`, every time. Verify the imported RxNorm release and product index, import the original checked archive when necessary, and verify the readiness query again after importing. Run sbt `test`.
7. Generate fresh valid/invalid `.clinical` fixtures in a unique protected state directory. Export each through the newly built Langium services and resolve each through Scala/JDBC/PostgreSQL. Require a resolved product with evidence for `aspirin / 325 mg / Oral Tablet`; require `productNotFound` and `PRODUCT_NOT_FOUND` for `32500 mg`. Inspect the JSON contents, not just process exit codes. These fictional fixtures are software checks, not prescribing advice.
8. Start the actual bundled Node language server with `--stdio`. Require LSP initialization, error-free diagnostics for the valid `.clinical` document, and a clean protocol shutdown. The probe has a timeout and reaps its child on failure.
9. Recheck PostgreSQL, configure the editor, optionally request a VS Code window, and only then write `state/health.json` with `status: ready` and print `READY`.

A failed check throws and does not print `READY`. Once the state directory is initialized, the health report is marked `running`, then `ready` or `failed`. Reports retain timestamps, checked commit SHAs, and the smoke-results directory. A SHA in a report is an audit record, **not** a pinned input.

## Services versus build commands

PostgreSQL remains running. sbt and npm are synchronous build commands, not application daemons. Node is a runtime: the standalone language-server probe is stopped after verification; VS Code owns its own language server. This Scala application is a CLI, not an HTTP server.

A successful `code.cmd` invocation is reported as an **editor launch request**, not proof that the extension activated inside the graphical editor. Full VS Code activation/GUI testing is separate from the headless smoke checks. Close an older lab editor window and rerun if it locks build files. Do not claim a headless run left an editor or language server running when `-NoEditor` was used.

## Protecting local work

The bootstrap does **not** use `reset --hard`, force checkout, merge conflict resolution, or source-code auto-stashing. Source edits, untracked non-build files, another development branch, and unpublished/divergent commits stop the update with an actionable message. Resolve those locally and rerun; changes are not silently discarded.

Legacy versions of `scala-testing-lab` track generated `target` and `.metals` files. Changes confined to the explicitly allowlisted build-output paths are saved in a named `bootstrap-generated-*` Git stash before updating. The stash hash is printed, the stash is retained, and obsolete compiled files are not reapplied over the new build. A failure while saving that backup also stops setup. This lets a second run update cleanly without deleting previous build outputs without a backup.

Existing PostgreSQL volumes, `secrets.json`, and the editable `aspirin-demo.clinical` are preserved. Import/build failure is not rolled back across the two repositories or database; inspect the error and rerun after fixing it. RxNorm remains the validated **2026-10-05** dataset; updating source code does not silently change the terminology release or the verified sbt launcher artifact.

## Testing this PR before merge

`main` is the default for both repositories. Optional `-ScalaBranch` / `-LangiumBranch` select moving branches, not commit pins; they are useful for reviewing a PR in a **separate** Root:

```powershell
.\bootstrap-windows.ps1 -Root 'C:\Aurora PR Test' `
  -ScalaBranch 'codex/windows-bootstrap-update-and-health' `
  -Port 55434 -ContainerName aurora-pr-test-pg -VolumeName aurora-pr-test-pgdata -NoEditor
```

After merge, omit the branch overrides and keep using the normal command. An already-downloaded copy of the **old pinned script** cannot discover this feature by itself: replace it once with the revised script.

### Small regression tests (no dataset or Docker)

```powershell
# Real local temporary Git repositories; no Pester dependency. Run in 5.1 and 7.
.\scripts\tests\bootstrap-git-sync.ps1
# Dependency-free protocol probe tests with a fake server process.
node --test scripts/tests/bootstrap-lsp-smoke.test.mjs
```

### Required Windows acceptance checks

- Fresh install with a Root containing spaces, then unchanged rerun: both builds and runtime probes must run both times; existing data remains usable.
- Push a new commit upstream and rerun: HEAD reaches the newly fetched branch tip, and the refreshed bootstrap is used when it changed.
- Old detached checkout, modified tracked build outputs, and stopped PostgreSQL: migration/backup/restart succeed without losing database contents.
- Dirty/staged/untracked source, unpublished/divergent commits, another branch, incorrect origin, or failed fetch: stop without a misleading success or destructive reset.
- Failed npm generation/build, failed sbt compilation/test, wrong database configuration, or incorrect clinical result: no `READY`; inspect `health.json` and the unique smoke directory.
- Docker Desktop initially stopped, unavailable Linux engine, `-NoEditor`, and the normal editor-launch path: report the actual outcome without claiming GUI activation was tested.

The protocol tests do not establish that a real Windows/Docker/RxNorm installation succeeds. Run the full acceptance checks before treating the change as release-validated.
