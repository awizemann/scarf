---
title: After a timed wait in a test, unwrap with #require — a trap kills the whole scarfTests host
type: note
permalink: scarf/conventions/after-a-timed-wait-in-a-test-unwrap-with-require-a-trap
source_paths: [scarf/scarfTests/ChatViewModelEnvironmentHintTests.swift, scarf/scarfTests/BotsViewModelTests.swift, scarf/scarfTests/HermesP7fCronPeersTests.swift]
source_paths_inferred: false
source_sha: 6cd59436d8fbf968f77b919a6eda5177810f7039
created: 2026-10-05
updated: 2026-10-05
---

- [convention] In scarfTests, any value read after a timed poll (`waitUntil`, `settle`, `waitForLoad`, a `for _ in 0..<200` sleep loop) must be unwrapped with `try #require(...)`, never `!`, `.first!`, or `array[n]`. Under heavy machine load (load average 160–450 seen 2026-10-05) the wait times out, the force-unwrap or out-of-range subscript traps, and the trap takes down the whole scarfTests host — hundreds of unrelated in-flight tests then report "Crash: scarf". #testing
- [convention] A helper that boots state and returns it (e.g. `ChatViewModelEnvironmentHintTests.boot`) must `try #require(booted, ...)`, not `#expect(booted)`, so callers never see half-built state.
- [pattern] Element n of an array that may be short: `try #require(items.dropFirst(n).first, "why")`, or `try #require(items.count == k)` before indexing.
- [done] 2026-10-05 swept: ChatViewModelEnvironmentHintTests, BotsViewModelTests (bots[0]/rows[0]), HermesP7fCronPeersTests (calls.items[n]).
- relates_to [[hermes-v0-21-1-compatibility-decisions]] (earlier `spans[1]` host crash)
- relates_to [[mac-scarftests-run-green-only-serially-and-an-unsigned-test]]

## Relations
- relates_to [[hermes-v0-21-1-compatibility-decisions]]
- relates_to [[mac-scarftests-run-green-only-serially-and-an-unsigned-test]]
