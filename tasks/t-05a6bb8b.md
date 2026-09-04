---
id: t-05a6bb8b
title: Stabilize MiniAppAgentSessionTests under parallel load (intermittent waitFor timeouts)
status: done
added: 2026-09-04
priority: low
---

## Description

MiniAppAgentSessionTests intermittently times out (waitFor at MiniAppAgentSessionTests.swift:486) when the full scarfTests suite runs in parallel — seen 2026-09-04 across unrelated batches (S1 run and post-G2 run), always green in isolation and on rerun. Serialize the suite or scale its deadlines to load; a suite that fails one run in three erodes trust in real failures.

## Plan



## Artifacts

**Done.** Diagnosed the contention before padding anything.

What it actually contends on: nothing of its own. The suite is entirely in-memory (a `FakeACPChannel` actor + a real `ACPClient`) — no file, no port, no subprocess. It has nine tests each spinning a 10-15 ms polling loop against a 2 s deadline, and in the full run those loops share cores with suites that spawn real `Process`es (same cross-suite CPU/scheduler contention as the t-aud32 `RemoteSQLiteBackend` race). Every assertion is about WHETHER a turn resolves, never how fast — so the only thing that ever failed was the hang guard.

Fix (both halves of the contention):
1. `@Suite(.serialized)` — removes the contention the suite creates for itself (nine concurrent polling loops → one). It cannot stop sibling suites: `.serialized` covers a suite and its subgroups, not the rest of the run, so this alone would not have been enough.
2. A `Deadline` enum scaling the hang guards by `activeProcessorCount` (1x at 8+ cores, up to 4x on a single core): 2 s → 15 s precondition, 3 s → 20 s operation on this machine. A timeout here exists only to stop a leaked continuation hanging CI, so headroom costs nothing on a green run.

File: `scarf/scarfTests/MiniAppAgentSessionTests.swift` (suite trait, `Deadline`, both helper defaults; no call site passed an explicit timeout).

Verified: four consecutive full `scarfTests` runs, 723 tests / 93 suites, green every time (previously ~1 failure in 3). Plus ScarfCore 2155/2155 and an iOS build.

Memory: `scarf/conventions/acp-turn-completion-is-sendprompt-s-return-not-a-stream-promptcomplete-event` — new section on scaling hang-guard deadlines for the parallel suite.

