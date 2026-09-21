---
title: WAL state.db without a -shm sidecar cannot be read READONLY; the fix is a query_only fallback
type: note
permalink: scarf/architecture/wal-state-db-without-a-shm-sidecar-cannot-be-read-readonly
tags: [sqlite, state-db, wal, hermes, charter-c3, dashboard]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/Backends/LocalSQLiteBackend.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/Backends/RemoteSQLiteBackend.swift]
source_paths_inferred: false
source_sha: 41e58d74562498d9f61a89e0a8ed08575ae13b5c
created: 2026-09-08
updated: 2026-09-08
reviewed: 2026-09-10
reviewed_by: claude-opus-5
---

Fix for t-281048bc, found by the UI-gate Smoke sweep against the seeded fixture (2026-09-08). Cover: `LocalSQLiteBackendWALOpenTests` (5 tests — WAL-without-sidecars opens and creates -shm, the fallback handle refuses writes, DELETE-mode dbs take the plain READONLY path, a missing file still reports not-found, and the kept-open fallback handle picks up a second connection's WAL writes).

## Observations
- [gotcha] Hermes 0.21 keeps state.db in WAL mode; with no -shm/-wal sidecars (CLI-only users, gateway stopped, fresh home) a SQLITE_OPEN_READONLY connection CANNOT read it — SQLite must create the shared-memory sidecar first, so every statement fails SQLITE_CANTOPEN(14). Alan's own home worked only because a running gateway kept state.db-shm alive. #sqlite
- [gotcha] sqlite3_open_v2 is LAZY: it returns SQLITE_OK without touching the file, so the CANTOPEN surfaces on the FIRST STATEMENT, not at open. LocalSQLiteBackend.open() now probes with `SELECT count(*) FROM sqlite_master` so open() reports the truth its callers assume. #sqlite
- [decision] Guarded fallback in LocalSQLiteBackend.open(): on SQLITE_CANTOPEN, reopen SQLITE_OPEN_READWRITE|NOMUTEX (NEVER CREATE), immediately `PRAGMA query_only=1`, then re-probe; any failure closes the handle and reports the ORIGINAL error. Logged once at .info, exposed as `isQueryOnlyFallback`. #decision
- [constraint] Charter C3 reading (Alan): creating a WAL sidecar is not a state mutation; `PRAGMA query_only=1` is what makes the connection incapable of writing a row. Proven by test: an INSERT through the fallback handle throws BackendError.sqlite(exitCode: SQLITE_READONLY). #charter
- [decision] RemoteSQLiteBackend got the same fix (t-fb136a08, commit 4b42c0ca): all 3 call sites (preflight, query, queryBatch) route through `runSQLite`, which retries once with `-readonly` dropped and `PRAGMA query_only=1;` prefixed, then LATCHES `isQueryOnlyFallback` so a stopped-gateway host pays the doomed strict round-trip once, not per query. A retry that also fails reports the ORIGINAL strict error. #decision
- [gotcha] The remote fix must stay a FALLBACK, never an unconditional `-readonly` drop: the sqlite3 CLI without `-readonly` CREATES a missing database file (verified, sqlite 3.54.0). Unconditional would plant an empty state.db in Hermes's data dir on hosts that have none and turn "not installed" into "installed but empty". The relaxed form therefore carries a shell `[ ! -f path ]` guard that echoes the same "unable to open database file" text `HermesDataService.humanize` keys off, so absent-vs-unreadable survives. #charter
- [fact] sqlite3 CLI behaviour pinned by the remote tests (3.54.0): `-readonly` on a sidecar-less WAL db → exit 1 "unable to open database file (14)"; the `PRAGMA query_only=1;` form reads it and creates the sidecar; a write through it → exit 1 "attempt to write a readonly database". Cover: `RemoteSQLiteBackendWALFallbackTests` (8 tests — 5 argv/SQL-shape via a recording transport, 3 end-to-end against the real sqlite3 CLI). #sqlite

## Relations
- relates_to [[Absent-vs-unreadable is the discriminator every Scarf JSON store owes its writers]]
- relates_to [[Hermes Integration]]
