---
title: Performance-Monitoring
type: note
permalink: scarf-wiki/performance-monitoring
created: 2026-05-29
updated: 2026-05-29
---

# Performance Monitoring (ScarfMon)

Scarf ships an always-on, opt-in performance instrumentation harness called **ScarfMon**. It records timing samples and event counts at known hot spots so users hitting "feels slow" can capture a baseline, share it with maintainers, and have a concrete signal to act on instead of a vague report.

This page is for both groups:

- **Users** who want to help diagnose perceived slowness.
- **Developers** who want to add measure points to their own code or extend the harness.

## TL;DR

- **It's free when off.** Default mode (`signpostOnly`) emits Apple `os_signpost` events, which the runtime elides outside an Instruments session.
- **It's privacy-respecting.** Sample names are `StaticString` (compile-time literals), so user content can't leak through metric tags. Nothing leaves the device unless the user explicitly hits **Copy as JSON**.
- **It's open source.** All the plumbing lives in [`ScarfCore/Diagnostics/`](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Diagnostics).

## How to turn it on

### Mac

`Settings → Advanced → Performance Diagnostics`. The picker has three modes:

| Mode | What it records | Cost |
|---|---|---|
| **Off** | Nothing | One branch + return per call |
| **Signpost only** (default) | `os_signpost` events to the `com.scarf.mon` subsystem | Zero outside Instruments |
| **Full** | Signposts + a 4096-entry in-memory ring + `os.Logger` debug stream | One ring write per call |

Switching to **Full** unlocks the in-app summary table (top 20 buckets by p95) and the **Copy as JSON** button.

### iOS

`Settings → Diagnostics → Performance`. Same three-mode picker, same panel layout, same `Copy as JSON` action. The mode is persisted across launches in `UserDefaults` under key `ScarfMonMode`.

### From a Terminal (any mode)

```bash
log stream --predicate 'subsystem == "com.scarf.mon"' --info --debug
```

Streams every signpost / log line live. Useful for catching events that happen before you can flip the panel toggle.

## How to read the data

The in-app panel groups samples by `(category, name)` and shows for each:

- **count** — total samples of that name in the buffer
- **p50 / p95 / max** — for `interval` samples, percentile durations
- **bytes** — running total when the call site reported a payload size

For a full export, hit **Copy as JSON**. Each line is one sample with `category`, `name`, `kind` (`event` or `interval`), `timestampMs`, `durationNanos`, `count`, and optional `bytes`. Compact JSON, valid JSON array — pipe through `jq` or paste into a feedback thread.

## What's measured today (v2.7+)

| Category | Name | Where | What it tells you |
|---|---|---|---|
| `chatRender` | `mac.ChatView.body` | [Mac ChatView](https://github.com/awizemann/scarf/tree/main/scarf/scarf/Features/Chat/Views/ChatView.swift) | Full chat tab body re-eval count |
| `chatRender` | `mac.RichChatMessageList.body` | [RichChatMessageList](https://github.com/awizemann/scarf/tree/main/scarf/scarf/Features/Chat/Views/RichChatMessageList.swift) | Whether the message-list `ForEach` is re-issuing |
| `chatRender` | `mac.RichMessageBubble.body` | [RichMessageBubble](https://github.com/awizemann/scarf/tree/main/scarf/scarf/Features/Chat/Views/RichMessageBubble.swift) | Per-bubble re-evals — divide by `acpEvent` count to spot wasted re-renders |
| `chatRender` | `ios.ChatView.body` / `ios.MessageBubble.body` | iOS `ChatView.swift` | Same signal on iOS |
| `chatStream` | `mac.sendViaACP` | [Mac ChatViewModel](https://github.com/awizemann/scarf/tree/main/scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift) | User tap → first prompt write (carries prompt byte count) |
| `chatStream` | `mac.sendPrompt` | Same | User tap → response complete (interval) |
| `chatStream` | `mac.acpEvent` / `mac.handleACPEvent` | Same | Per-event arrival + handle cost |
| `chatStream` | `firstByte` / `firstThoughtByte` | [RichChatViewModel](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/RichChatViewModel.swift) | Time-to-first-token. Splits Hermes "thinking" from streaming render |
| `chatStream` | `finalizeStreamingMessage` | Same | End-of-turn finalize cost (target: < 1 ms) |
| `chatStream` | `ios.send` / `ios.startResuming` / `ios.acpEvent` / `ios.handleACPEvent` | iOS `ChatView.swift` | Same shape on iOS |
| `sessionLoad` | `mac.startACPSession` / `ios.startResuming` | Both targets | Session boot cost |
| `sessionLoad` | `mac.fetchSkeletonMessages` / `.rows` / `.transportError` | [HermesDataService](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift) | Phase 1 of v2.8 two-phase chat loader — user+assistant rows only, ~few KB on the wire regardless of tool_calls blob size |
| `sessionLoad` | `mac.fetchToolCallSkeleton` / `.rows` / `.transportError` | Same | Phase L Activity skeleton fetch — metadata-only, ~3 KB for 50 rows |
| `sessionLoad` | `mac.hydrateToolCalls` / `.rows` / `.cancelled` / `.pageTimeout` / `.singleTimeout` | Same | Phase 2a paged hydration. `pageTimeout` → batch fell back to single-id retry; `singleTimeout` → individual whale row skipped |
| `sessionLoad` | `mac.hydrateToolResults` / `mac.hydrateTools.skippedToolResults` / `.dropped` / `.complete` | Same | Phase 2b tool-result content hydrate. `skippedToolResults` fires when the opt-in setting is off (default); `dropped` fires when the parent task cancelled mid-page |
| `sessionLoad` | `mac.lazyToolResult.fetched` | Same | Inspector pane lazy-fetched a single tool result on user expand |
| `sessionLoad` | `mac.fetchMessages.transportError` | Same | Skeleton fetch tripped the SSH timeout — chat surfaces the partial-result banner |
| `sessionLoad` | `mac.loadRecentSessions.coalesced` | [Mac ChatViewModel](https://github.com/awizemann/scarf/tree/main/scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift) | A second caller awaited the in-flight load instead of spawning a parallel SSH round-trip |
| `sqlite` | `sqlite.query` / `sqlite.queryBatch` | [RemoteSQLiteBackend](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Services/Backends/RemoteSQLiteBackend.swift) | Per-call latency over SSH (carries row count + stdout bytes) |
| `transport` | `ssh.streamScript` (iOS) / `ssh.run` (Mac) | [CitadelServerTransport](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfIOS/Sources/ScarfIOS/CitadelServerTransport.swift), [SSHScriptRunner](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHScriptRunner.swift) | SSH round-trip time |
| `transport` | `ssh.cancelled` | [SSHScriptRunner](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Transport/SSHScriptRunner.swift) | Parent task cancellation reached the ssh subprocess (v2.8) — terminated within 100ms instead of running to its 30s deadline |
| `sessionLoad` | `mac.fetchSessionPreviews` / `.rows` / `.transportError` | [HermesDataService](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift) | Sidebar preview fetch — already substr-bounded, instrumented in v2.8 for visibility |
| `diskIO` | `loadConfig` / `loadCronJobs` | [HermesFileService](https://github.com/awizemann/scarf/tree/main/scarf/scarf/Core/Services/HermesFileService.swift) | Hot disk reads. `loadConfig` also logs caller stack frames in Full mode |
| `diskIO` | `memory.load` / `.bytes` | [MemoryViewModel](https://github.com/awizemann/scarf/tree/main/scarf/scarf/Features/Memory/ViewModels/MemoryViewModel.swift) | Memory tab open — 4 sequential SFTP reads on remote (config + profiles + memory + user). v2.8 instrumented. |
| `diskIO` | `cron.load` / `.jobs` | [CronViewModel](https://github.com/awizemann/scarf/tree/main/scarf/scarf/Features/Cron/ViewModels/CronViewModel.swift) | Cron tab open — jobs.json + skills walk + selected job's output. v2.8 instrumented. |
| `diskIO` | `skills.load` / `.count` | [SkillsViewModel](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/SkillsViewModel.swift) | Skills tab open — full SkillsScanner walk (one stat + SKILL.md read per skill dir). v2.8 instrumented. |
| `diskIO` | `curator.load` / `.bytes` | [CuratorViewModel](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Sources/ScarfCore/ViewModels/CuratorViewModel.swift) | Curator tab open — `hermes curator status` CLI + state file + REPORT.md. v2.8 instrumented. |

Adding a new measure point is two lines (see Developer Guide below).

### v2.8 perf architecture: skeleton-then-hydrate + cancellation propagation

Two patterns landed in v2.8 that anyone touching remote-context code should know about:

**Skeleton-then-hydrate.** Heavy SSH fetches (`fetchMessages`, `fetchRecentToolCalls`) used to pull the FAT column set in one shot, which routinely tripped the 30s SSH timeout on chats with multi-page tool result blobs. The new pattern: a fast skeleton fetch projects only the columns needed to render placeholder rows (NULLs the heavy ones at the SQL level), then a paged background hydration fills the rest in. Used by chat-resume (`fetchSkeletonMessages` + `hydrateAssistantToolCalls`) and Activity (`fetchRecentToolCallSkeleton` + same hydrate). Pages run in 5-id batches; if a page times out, an L1 single-id retry isolates the whale so the rest of the batch still hydrates.

**Cancellation propagation through SSH.** `Task.detached { … }` doesn't inherit cancellation from the awaiting parent, and `Task<…> { … }` (unstructured) also drops the signal. Without explicit bridging, cancelling a chat-load Task only unwinds Swift state — the underlying ssh subprocess kept running for the full 30s, pinning a remote sqlite query and a ControlMaster session slot. v2.8 wires `withTaskCancellationHandler` through `SSHScriptRunner` and `RemoteSQLiteBackend.query` so parent cancellation reaches the `Process` and calls `proc.terminate()` within 100ms. New `ssh.cancelled` event surfaces this.

**In-flight coalescing.** `loadRecentSessions` (Mac chat sidebar) coalesces against an in-flight task. File-watcher deltas during streaming used to stack 2-3 parallel `loadRecentSessions` tasks; now subsequent callers await the active one. New `mac.loadRecentSessions.coalesced` event tracks how often the dedup fires.

## Capture recipe for a useful baseline

1. Build + run the latest version.
2. Flip the panel to **Full**.
3. Optionally, in another terminal: `log stream --predicate 'subsystem == "com.scarf.mon"'`.
4. Hit **Reset** in the panel.
5. Run the specific scenario you want to measure (one chat turn, one session boot, one specific click).
6. Hit **Copy as JSON** *before* doing anything else — the ring is FIFO with a 4096-entry capacity, so a long idle session will eventually overwrite earlier samples.
7. Paste the JSON in a [GitHub issue](https://github.com/awizemann/scarf/issues) or feedback thread, with one sentence describing what you were doing.

The maintainers will use the same JSON shape to grep for outliers.

## Privacy

ScarfMon is privacy-conscious by construction:

- **No remote upload.** The ring buffer never leaves the device. The `Copy as JSON` button puts the dump on the system clipboard; the user decides whether to paste it anywhere.
- **No content.** Sample names are `StaticString` (compile-time literals), so prompt text, response text, file paths, etc. cannot accidentally end up in a metric.
- **No PII.** Optional `bytes` field tracks payload *size*, never payload *contents*.
- **Symbol-only stack traces.** When `Full` mode logs caller stack frames (e.g. for the `loadConfig` mystery-caller hint), they are mangled Swift symbols + offsets. No memory addresses, no file paths.
- **Subsystem isolation.** All output uses subsystem `com.scarf.mon`, so users can grep / filter / disable independently of Scarf's general logs.

## Developer guide — adding a measure point

The public API has three primitives:

```swift
// Synchronous interval — duration is recorded
ScarfMon.measure(.diskIO, "loadX") {
    // your work
}

// Async interval — same shape
try await ScarfMon.measureAsync(.sqlite, "query") {
    try await actualQuery()
}

// One-shot event — count + optional payload size
ScarfMon.event(.chatStream, "firstByte", count: 1, bytes: chunk.utf8.count)
```

### Picking a category

Categories are a fixed enum in [`ScarfMon.swift`](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Diagnostics/ScarfMon.swift):

| Category | When to use |
|---|---|
| `chatRender` | View-body re-evals, scroll, layout work |
| `chatStream` | ACP events, prompt sends, finalize |
| `sessionLoad` | Session boot / resume / load |
| `transport` | SSH round-trips, network |
| `sqlite` | DB queries, snapshot pipeline |
| `diskIO` | File reads / writes |
| `render` | Other rendering (dashboards, sidebars) |
| `other` | Catch-all — promote to a real category if it grows |

Adding a new category is a one-line case in `ScarfMon.Category` plus a row in this page.

### Picking a name

- Names must be `StaticString` (compile-time literal) — the type system enforces this.
- Conventionally prefixed with the platform (`mac.`, `ios.`) when the same logical operation has both shapes; bare names are fine for cross-platform code.
- Use `dot.notation` to group related events (`sqlite.query`, `sqlite.queryBatch`, `sqlite.query.rows`).
- Stable: rename = breaking change for any saved JSON dumps users have shared.

### Body counters in SwiftUI views

Inside `var body: some View`, the idiom is:

```swift
var body: some View {
    let _: Void = ScarfMon.event(.chatRender, "mac.ChatView.body")
    return VStack { … }
}
```

The `let _: Void = …` works inside `@ViewBuilder` (it's a local declaration, not a view-producing expression) and fires every time SwiftUI re-evaluates the body. Use sparingly — these are sentinel events for diagnosing render storms, not for routine operation.

### Verifying the cost

Default `signpostOnly` mode is effectively free. To prove it locally:

```swift
let n = 1_000_000
let t = ContinuousClock().measure {
    for _ in 0..<n {
        ScarfMon.measure(.other, "noop") { 1 + 1 }
    }
}
// t should be < ~50ms total — about 50ns per call when off
```

When the backend set is empty, the wrapper is `@inline(__always)` and short-circuits without taking a clock reading.

## Architecture

Three pluggable backends behind one dispatcher:

```
┌─────────────────────────────────────────────────┐
│ ScarfMon.measure / measureAsync / event         │
│   ↓ (one os_unfair_lock per emit, no allocs)   │
├─────────────────────────────────────────────────┤
│ ScarfMonSignpostBackend  (always on)            │
│ ScarfMonRingBuffer       (Full mode only)       │
│ ScarfMonLoggerBackend    (Full mode only)       │
└─────────────────────────────────────────────────┘
```

Boot wiring lives in [`ScarfMonBoot.swift`](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Diagnostics/ScarfMonBoot.swift) — `ScarfMonBoot.configure(mode:)` is called once at app launch from both `ScarfApp.init` (Mac) and `ScarfIOSApp.init` (iOS).

The ring buffer is fixed at 4096 entries × ~80 bytes per sample = ~320 KB resident — enough for several minutes of streaming-chat activity at 200 samples/s without overwriting interesting context. When the buffer is full, the oldest sample is overwritten.

Tests live at [`ScarfMonTests.swift`](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Tests/ScarfCoreTests/ScarfMonTests.swift) — 11 cases covering ring ordering / wrap / reset, summary aggregation, percentiles, install / isActive transitions, the throw path on `measureAsync`, boot mode switches, and JSON export round-trips.

## Reading the in-app summary table

Each row is one `(category, name)` bucket. Columns:

- **category** — the enum case
- **name** — the call site name
- **count** — total samples
- **p50 / p95 / max** — for `interval` samples, percentile durations in ms
- **bytes** — running total of any reported payload sizes

Default sort is **p95 descending** so the slowest hot path is at the top. The table caps at 20 rows; for the full picture, **Copy as JSON**.

## When to use Instruments instead

The in-app panel is for "I want a quick number to share." For deep work, attach Instruments and pick the **Time Profiler** template — every `ScarfMon.measure(...)` call shows up as a signpost event in the **Points of Interest** track. Filter the track by `subsystem: com.scarf.mon`. Pair with Time Profiler in the same trace and you'll see exactly which Swift functions are hot at the moment ScarfMon recorded a slow `sqlite.query`.

## Roadmap

ScarfMon currently covers the chat hot path, transport, SQLite, and a slice of disk I/O. Next planned coverage areas:

- **Sessions list / Dashboard** — render counts, snapshot loads.
- **Project switcher / file watcher** — debounce + tick rates.
- **Image encoding** — vision uploads.
- **Memory / Skills surfaces** — reads + parse.
- **Cron / Curator panes** — read paths during pollings.

Adding any of these is a 1–2 line measure point at the call site. See the developer guide above.

## Related pages

- [Architecture Overview](Architecture-Overview) — where ScarfCore + Diagnostics fits in the stack
- [Core Services](Core-Services) — the services ScarfMon instruments today
- [Hermes Paths](Hermes-Paths) — the file paths `loadConfig` / `loadCronJobs` reach for
- [Privacy Policy](Privacy-Policy) — what data the apps access