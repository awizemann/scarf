---
title: Adding-a-Service
type: note
permalink: scarf-wiki/adding-a-service
created: 2026-05-29
updated: 2026-05-29
---

# Adding a Service

Services mediate between Hermes (filesystem, SQLite, subprocess) and feature ViewModels. As of v2.5 there are **two homes** for a service depending on whether iOS needs it:

| Home | When to use | Path |
|---|---|---|
| **`ScarfCore` package** | The service does pure I/O against Hermes (transport reads, parsing, attribution, formatting) — **default choice**, since iOS likely needs it too. | [`scarf/Packages/ScarfCore/Sources/ScarfCore/Services/`](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Services) |
| **Mac target** (`scarf/Core/Services/`) | The service depends on AppKit, Sparkle, NSWorkspace, AppleScript, or anything else iOS can't link. | [`scarf/scarf/scarf/Core/Services/`](https://github.com/awizemann/scarf/tree/main/scarf/scarf/scarf/Core/Services) |
| **`ScarfIOS` package** | iOS-only — needs Citadel, iOS Keychain, UIKit. | [`scarf/Packages/ScarfIOS/Sources/ScarfIOS/`](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfIOS/Sources/ScarfIOS) |

When in doubt, **start in ScarfCore.** Promote to a target only when you hit a framework restriction. See [ScarfCore Package](ScarfCore-Package) for the package boundary rationale.

The recipe below applies regardless of home.

## Pick the isolation

| Pattern | When | Examples in repo |
|---|---|---|
| `actor` | The service owns mutable state across calls (a subprocess, file handles, an open SQLite connection, a snapshot dedup table). | [`ACPClient`](Core-Services), [`HermesDataService`](Core-Services), [`HermesLogService`](Core-Services). |
| `Sendable struct` | The service is stateless — every call re-reads through the transport. | [`HermesFileService`](Core-Services), [`HermesEnvService`](Core-Services), [`ModelCatalogService`](Core-Services). |
| `@MainActor @Observable` | Rare — only when the service IS UI-observable state (Sparkle wrapper). | [`UpdaterService`](Core-Services). |

If you're not sure, start with `Sendable struct`. Promote to `actor` only when you find yourself wanting to cache mutable state across calls.

## Skeleton: stateless struct

```swift
import Foundation

struct MyHermesService: Sendable {
    let context: ServerContext
    private var transport: any ServerTransport { context.transport }

    func loadSomething() async throws -> SomethingType {
        let data = try await transport.readFile(context.paths.somethingFile)
        return try JSONDecoder().decode(SomethingType.self, from: data)
    }

    func saveSomething(_ value: SomethingType) async throws {
        let data = try JSONEncoder().encode(value)
        try await transport.writeFile(context.paths.somethingFile, data: data)
    }
}
```

## Skeleton: actor for stateful work

```swift
actor MyStatefulService {
    let context: ServerContext
    private var cache: [String: Value] = [:]

    init(context: ServerContext) {
        self.context = context
    }

    func get(_ key: String) async throws -> Value {
        if let cached = cache[key] { return cached }
        let value = try await fetchFromHermes(key: key)
        cache[key] = value
        return value
    }

    func invalidate() {
        cache.removeAll()
    }

    private func fetchFromHermes(key: String) async throws -> Value {
        // Use context.transport for I/O.
    }
}
```

## Conventions

- **Take `ServerContext` in `init`.** Never hardcode `ServerContext.local` — services must work against any window's bound server.
- **Route I/O through `context.transport` or the `context.read*/write*/runHermes` helpers.** Never use `FileManager`, `Process`, or `NSWorkspace.open` directly for Hermes paths — those break on remote (and break the rule from the project's [feedback memory](Wiki-Maintenance)). On iOS specifically, `Process` doesn't exist at all — services in ScarfCore must stay platform-agnostic.
- **Surface errors as `throws` or `Result`.** Don't swallow them; the UI knows what to do with them.
- **Don't log to `print`** — use `os.Logger` (`logger.error()` for unexpected, `logger.warning()` for expected). v2.5's logger conversion sweep removed the last `print("[Scarf] …")` calls; new code should follow.
- **Don't do synchronous file I/O on `@MainActor`.** Either dispatch via `Task.detached { }.value`, or expose async methods.

## Wiring the service into a feature

Two patterns:

**Per-ViewModel** (most common for stateless services):

```swift
@Observable
final class MyFeatureViewModel {
    private let service: MyHermesService
    init(context: ServerContext) {
        self.service = MyHermesService(context: context)
    }
}
```

**Shared via Environment** (for stateful services that multiple features want to share):

In `scarfApp.swift`'s `ContextBoundRoot`:

```swift
@State private var fileWatcher: HermesFileWatcher

ContentView()
    .environment(fileWatcher)
```

Then in any view:

```swift
@Environment(HermesFileWatcher.self) private var fileWatcher
```

Use Environment for things every window has exactly one of — file watcher, server registry, updater service. Use per-ViewModel construction for everything else.

## Tests

Service code that uses transport is testable with a mock transport. ScarfCore ships a `MockTransport` and the test suite exercises the contract — see [Testing](Testing). Add tests in `scarf/Packages/ScarfCore/Tests/ScarfCoreTests/` for ScarfCore services; in `scarf/scarfTests/` for Mac-only ones.

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (ScarfCore / Mac / ScarfIOS placement matrix; logger sweep note)_