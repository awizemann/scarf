---
title: MainActor + @Observable deinit Task cleanup needs `nonisolated(unsafe) var`, not plain `nonisolated`
type: note
permalink: scarf/conventions/mainactor-observable-deinit-task-cleanup-needs-nonisolated
created: 2026-09-18
updated: 2026-09-18
---

Discovered hardening `PushToTalkController` (ScarfIOS, `@MainActor @Observable`) to cancel an `AVAudioSession.interruptionNotification` observer `Task` on teardown. Real iOS xcodebuild is the only thing that caught this — `swift build`/`swift test` for this package run against its macOS platform target and silently skip everything inside `#if os(iOS)`, so they gave a false pass on both wrong attempts below. Always validate a fix like this against the actual iOS scheme (`xcodebuild ... -scheme "scarf mobile" -destination "generic/platform=iOS Simulator"`), not just the package tests.

## Observations
- [gotcha] `deinit` on a `@MainActor` class is always nonisolated (no `isolated deinit` in this codebase's Swift mode) — referencing a MainActor-isolated stored property from `deinit` fails with "main actor-isolated property can not be referenced from a nonisolated context", even just to call `.cancel()` on a `Task` property
- [gotcha] Plain `nonisolated var` does NOT fix it for a *mutable* stored property — a real iOS xcodebuild (not `swift build`) fails with the hard error "'nonisolated' cannot be applied to mutable stored properties". This reproduced twice, with and without `@ObservationIgnored` on the property, so it isn't an `@Observable`-macro-specific interaction — it's a general Swift rule about `nonisolated` and mutable stored properties on an actor-isolated type
- [gotcha] A compiler NOTE seen once suggested dropping `(unsafe)` for this exact `Task<Void, Never>?` property ("'nonisolated(unsafe)' has no effect ... consider using 'nonisolated'") — that note is misleading for a mutable `var`; trust the hard error from a real iOS build over it
- [convention] Correct pattern: `@ObservationIgnored private nonisolated(unsafe) var xTask: Task<Void, Never>?` for a long-lived `Task` a MainActor class starts in `init()` and must cancel in `deinit` (e.g. a `NotificationCenter.default.notifications(named:)` async-sequence listener). `@ObservationIgnored` isn't required for the error above but skips pointless Observation-tracking on a property view bodies never read. Set the property from MainActor-isolated code (legal), cancel with `xTask?.cancel()` in `deinit` — safe despite no compiler-enforced synchronization because `Task.cancel()` is documented thread-safe from any context

## Relations
- relates_to [[Push-to-talk dictation (ScarfIOS): on-device-only privacy contract + lifecycle teardown pattern]]
