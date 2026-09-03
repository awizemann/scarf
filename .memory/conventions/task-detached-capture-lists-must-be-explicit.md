---
title: Task.detached capture lists must be explicit
type: note
permalink: scarf/conventions/task-detached-capture-lists-must-be-explicit
tags: [concurrency, swift6, conventions, rule, audit-2026-06-13]
created: 2026-06-13
updated: 2026-09-02
---

## Observations

- [rule] 🚨 **An IO-service protocol is declared `nonisolated` — at its requirements — and so is every conformer, live AND mock.** The app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a bare `protocol BotsBackend: Sendable` is implicitly MainActor while every call site sits inside `Task.detached`. Fix at the DECLARATION (`nonisolated func …` on each requirement, `nonisolated struct/final class` on `LiveBotsBackend`/`LiveBotAgentBackend`/`HermesEnvService` and on `MockBotsBackend`/`MockBackend`/`NoopBotsBackend`) — never by removing the detachment or hopping to the main actor, which would put blocking transport IO on the UI thread. Marking the mocks is load-bearing: a MainActor mock lets tests pass under an isolation production does not have. #rule #concurrency
- [rule] The same applies to constants and pure value types the default isolation captures — `nonisolated static let` for shared constants (`toolsetPlatform`, `maxConcurrentHosts`, `macDefaultsKey`, `ansiPattern`), `nonisolated` on pure-data structs read off the main actor (`UpdateStatus`, `BotDraft`, `HermesWebhook`) and on NSLock-guarded `@unchecked Sendable` boxes (`ACPHandle`) whose whole point is cross-actor use. #rule #concurrency
- [gotcha] `[self]` in a NESTED `Task`'s capture list does not silence `#SendableClosureCaptures` when the outer closure captured `self` weakly — the inner list still reads the outer *var*. Bind a local `let owner = self` and capture `[owner]`. #concurrency
- [gotcha] `NSLock.lock()`/`unlock()` are unavailable from an `async` function even with no `await` between them; hoist the critical section into a synchronous helper returning an outcome enum. #concurrency
- [check] These only appear in a CLEAN whole-module compile of the app target: `swift test` on ScarfCore never compiles it, and an incremental Debug build never re-emits a warning in an untouched file. Run `xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Release build` before a release cut. #build
- [history] 2026-09-02 (commit 8b4ae88): 46 promoted diagnostics cleared across 20 files ahead of the 3.0.0 archive; Release, Debug and the iOS target now build with zero warnings. #history

- [rule] 🚨 Every `Task.detached` must carry an explicit capture list — `[weak self]` by default (use optional chaining), or `[self]` only when the task is short-lived and the owner is guaranteed to outlive it. Referencing `self` solely inside a nested `await MainActor.run { }` STILL counts as a capture and must be explicit. #rule
- [pattern] Under Swift 6 strict concurrency the implicit form is a compile error (a warning under the project's current `SWIFT_APPROACHABLE_CONCURRENCY`). When fixing one site in a file, audit the whole file — these violations cluster.
- [check] Quick audit: `grep -rn 'Task.detached {' --include="*.swift" scarf` then check each for a `[ … ]` capture list.
- [history] 2026-06-13 Cycle 1: `MCPServersViewModel.swift` 9 sites (96/118/136/148/165/207/240/265/279; correct pattern at L63), `PluginsViewModel.swift:110,140` (correct at L46), `RichChatInputBar.swift:535,574`. #history

## Relations
- relates_to [[Scarf Architecture Rules]]
- relates_to [[Store cancellable handles for off-main remote work]]
