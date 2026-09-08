---
id: t-a9ad5e67
title: Hermes capability probe: one shot, no retry, cached per home path
status: done
added: 2026-09-08
---

## Description

Found while building the P2b UI-gate journeys (t-cd7d1c11).

`HermesCapabilitiesStore.init` fires exactly one `load(force: false)` and never retries. When that probe fails or is slow, `capabilities` stays `.empty` for the life of the window, so every capability-gated sidebar row (Kanban, Bots, Curator, Models, Proxy, Peers) is silently absent — indistinguishable, to the user and to a test, from "this host is too old".

`HermesVersionCache.key(for:)` includes `context.paths.home`, so the persisted `lastKnown` never helps a fresh home: a UI test home (or a user's first run against a new Hermes home) is always a cold probe with no second chance.

Observed both ways on the same Mac minutes apart: `testKanbanCardCreateAndMoveColumn` sometimes ran the full journey and sometimes skipped after waiting 180 s for `sidebar.section.Kanban`, with the same binary and the same warm fixture home. That makes the Kanban half of the release gate non-deterministic.

Suggested: retry the probe with backoff (or re-probe when a capability-gated surface is first asked for), and surface "version not detected" somewhere the user can see rather than silently hiding rows.

## Plan



## Artifacts

Fixed on ui-gate: HermesVersionCache retries a cold miss twice (1.5 s, 4 s back-off; test-injectable `retryDelays`), logs a persistent .error line when every attempt fails, sync path unchanged. Tests: aColdMissIsRetriedAndTheRetryIsMemoized, retriesAreBoundedAndAPersistentMissStaysEmpty, noRetryDelaysMeansOneAttempt. The persisted last-known value is still keyed by home path (unchanged; an isolated home is a cold probe by design).

