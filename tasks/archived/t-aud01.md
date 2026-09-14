---
id: t-aud01
title: **[t-aud01]** Chat reasoning hidden on resume — FIXED. `messageColumnsSkeleton` (HermesDataService) emitted `NULL AS reasoning`, so the two-phase resume loader dropped the reasoning channel and the REASONING disclosure never rendered on resumed thinking-model chats; now selects the real `reasoning` column to match `messageColumnsLight` (still NULLs `tool_calls`, still excludes the heavy `reasoning_content`). The audit's "OOB crash / silent corruption" claim was a FALSE POSITIVE — `Row`'s subscript (`SQLValue.swift:48`) is bounds-safe (returns `.null` past end), so `messageFromRow`'s index-11 read on light/skeleton rows already degraded to nil. Added 2 regression tests (`HermesDataServiceBackendTests`, skeleton SQL shape). Verified: HermesDataServiceBackendTests 16/16; ScarfCore compiles; affected suites green in isolation. reasoning_content lazy-load split to t-aud21.
status: archived
---

## Description



## Plan



## Artifacts



