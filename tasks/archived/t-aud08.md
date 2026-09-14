---
id: t-aud08
title: **[t-aud08]** `SQLValueInliner` `fatalError` → throw — DONE. `inline(_:params:)` is now `throws`, raising `SQLValueInliner.InlineError.placeholderParamMismatch` instead of `fatalError` on a placeholder/param-count mismatch (was a whole-app crash for a recoverable caller bug). Both callers (`RemoteSQLiteBackend.query`/`queryBatch`, already `async throws`) gained `try`. Updated 9 happy-path tests to `throws`+`try`; added 2 error-path tests. Verified: SQLValueInlinerTests 17/17; the inline-exercising RemoteSQLiteBackend tests pass. (`RemoteSQLiteBackendTests.openWithDefaultTildeHomeExpands` fails on this machine — pre-existing isolation bug writing a fixture to the REAL `~/.hermes/state.db`; folded into t-aud22.)
status: archived
---

## Description



## Plan



## Artifacts



