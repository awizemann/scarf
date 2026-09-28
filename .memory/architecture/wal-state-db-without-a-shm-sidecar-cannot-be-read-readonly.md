---
title: WAL state.db without a -shm sidecar cannot be read READONLY; the fix is a query_only fallback
type: note
permalink: scarf/architecture/wal-state-db-without-a-shm-sidecar-cannot-be-read-readonly
tags: [sqlite, state-db, wal, hermes, charter-c3, dashboard]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/Backends/LocalSQLiteBackend.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/Backends/RemoteSQLiteBackend.swift]
source_paths_inferred: false
source_sha: 617115a44db1d20a6f87b2db698c6f6c549e612f
created: 2026-09-08
updated: 2026-09-26
reviewed: 2026-09-28
reviewed_by: audit:claude-code (background)
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

- [gotcha] `PRAGMA query_only=1` does NOT stop checkpoint-on-close. A READWRITE connection that is the LAST to close a WAL db copies the WAL into the main file — a charter C3 write. Hits the local fallback handle whenever Hermes exits/crashes while Scarf is attached, and hits EVERY remote relaxed sqlite3 process (each is a short-lived connection) whenever the WAL holds frames nobody else is attached to. Reproduced 2026-09-26 (t-00ade623): local 8 KB → 368 KB, CLI 4 KB → 368 KB. A READONLY connection never checkpoints, so the strict path is unaffected. #charter
- [decision] Fix: local sets SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE right after the READWRITE open and refuses the fallback unless SQLite confirms it. Swift cannot call the variadic `sqlite3_db_config` ("Variadic function is unavailable"), so ScarfCore has a one-function C target `CSQLiteShim` (`scarf_sqlite3_disable_checkpoint_on_close`). Remote relaxed form adds `-cmd '.output /dev/null' -cmd '.dbconfig no_ckpt_on_close on' -cmd '.output stdout'` (the dot-command echoes to stdout and would break `-json`/preflight parsing) plus a `sqlite3 :memory: '.dbconfig no_ckpt_on_close on'` probe that refuses the fallback when the echo isn't ON. With the flag the WAL is left for Hermes to checkpoint; no data lost. #decision
- [fact] CLI floors: `.dbconfig no_ckpt_on_close` since SQLite 3.24.0; `-json` (already required) since 3.33.0 — so any host that can run the remote invocation supports it. An UNKNOWN `.dbconfig` name only prints a stderr warning and exits 0, which is why the probe checks the echo, not the exit code. #sqlite
- [gotcha] Apple's system SQLite keeps empty -wal/-shm files after the last close, so a sidecar-less fixture on macOS must delete them explicitly. With -wal present and -shm absent, `sqlite3 -readonly` on 3.54 still reads the db; only both-absent forces CANTOPEN. #sqlite


## Relations
- relates_to [[Absent-vs-unreadable is the discriminator every Scarf JSON store owes its writers]]
- relates_to [[Hermes Integration]]
