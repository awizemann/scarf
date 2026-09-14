---
id: t-aud27
title: **[t-aud27]** Show REASONING disclosure for reasoning_content-only messages — DONE. **OPEN QUESTION RESOLVED** against the real Hermes v0.16.0 source (`~/.hermes/hermes-agent/`): thinking models accumulate `delta.reasoning_content or delta.reasoning` and persist it ONLY as `msg["reasoning_content"]` (`chat_completion_helpers.py`); the legacy `reasoning` column is written only on DB-restore, never in the live path. So those rows have reasoning_content but NULL `reasoning` → `hasReasoning` was false → disclosure hidden. The ticket IS the real fix (not a no-op). Impl: `HermesMessage.reasoningContentAvailable` (folds into `hasReasoning`/`withToolCalls`); `messageColumnsLight`/`Skeleton` select (under v0.11) a `NULL AS reasoning_content` placeholder — keeps index 11 == reasoning_content per the t-aud01 caution — PLUS a cheap `(reasoning_content IS NOT NULL AND reasoning_content != '') AS hasReasoningContent` boolean (NOT the blob); `messageFromRow` reads the flag BY NAME (order-safe) with a full-SELECT fallback to the loaded blob. UI: iOS disclosure gated on `hasReasoning` alone (was also requiring non-empty `preferredReasoning`); macOS inline-style gated on having text (can't lazy-load → no empty brain); both rely on t-aud21's on-open lazy fetch. 3 new HermesDataServiceBackendTests; full `swift test` **613/613**; macOS + iOS BUILD SUCCEEDED, 0 warnings. NOT runtime-verified on a live thinking-model chat (no state.db with such rows here) — the only owed step.
status: archived
---

## Description



## Plan



## Artifacts



