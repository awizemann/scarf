# 04 — Swift Conventions

Centralized Swift standards for InControl, ShabuBox, Threader, and Modeler.
All four apps target macOS, use Swift 6, SwiftUI, and SwiftData.

---

## 1. Swift 6 Concurrency Rules

| Rule | Details |
|------|---------|
| Shared mutable state | Must be `@MainActor` or actor-isolated. No unprotected shared vars. |
| `@Sendable` closures | All closures in `Task`, `Task.detached`, and `withCheckedThrowingContinuation` must be `@Sendable`. |
| async/await | Prefer over callbacks and closures in all new code. |
| Progress reporting | Use `AsyncThrowingStream`, not callback-based progress handlers. |
| DispatchQueue | Never use when Swift Concurrency works. No `DispatchQueue.main.async` -- use `@MainActor` instead. |
| File I/O on @MainActor | Prohibited. Dispatch via `Task.detached { }.value` or an async file manager. |
| Boolean flags | Use `os_unfair_lock` for thread-safe boolean flags (not `NSLock`). |
| Logger in @Model classes | `private nonisolated(unsafe) let logger = Logger(...)` at file scope. Required because `@Model` classes are not Sendable. |

---

## 2. Logging Standard

**No `print()` in production code.** Use `os.Logger` exclusively.
`print()` is only acceptable in `#Preview` blocks and test helpers.

### Subsystem and Category

- **Subsystem**: `"com.<appname>.app"` -- always a static string literal. Never use `Bundle.main.bundleIdentifier ?? "..."` or any dynamic expression.
- **Category**: The type name (e.g., `"EmailSyncService"`, `"ConversationView"`).

### Declaration Patterns

| Context | Declaration | Access |
|---------|-------------|--------|
| Class or actor | `private let logger = Logger(subsystem: "com.<app>.app", category: "ClassName")` | `logger` |
| Struct or SwiftUI view | `private static let logger = Logger(subsystem: "com.<app>.app", category: "StructName")` | `Self.logger` |
| Nested struct (e.g., sheet inside a view) | Declares its own `private static let logger`. Cannot reference the parent's `Self.logger`. | `Self.logger` |
| `@Model` class | `private nonisolated(unsafe) let logger = Logger(subsystem: "com.<app>.app", category: "ModelName")` | `logger` |

### Enum Interpolation

`os.Logger` string interpolation requires types conforming to specific protocols. For enums and other non-conforming types:

```swift
logger.info("State changed to \(String(describing: newState))")
```

### Log Levels

| Level | Use |
|-------|-----|
| `.info` | Normal operational flow |
| `.warning` | Expected failures (file not found, timeout, network unavailable) |
| `.error` | Unexpected failures (encoding bugs, logic errors, constraint violations) |
| `.debug` | Verbose or sensitive output (only visible in debug builds) |

### Never Log

- Tokens or credentials
- Full API response bodies
- Log status codes and error types only

---

## 3. Error Handling

### Catch Blocks

Every `catch` must do at least one of:

1. Log with `logger.error()` or `logger.warning()`
2. Re-throw
3. Return `Result.failure`

**No empty catch blocks.** Ever.

### modelContext.save()

Always wrap in explicit error handling:

```swift
do {
    try modelContext.save()
} catch {
    logger.error("Failed to save context: \(error)")
}
```

Never use bare `try? modelContext.save()` -- save failures indicate data corruption or constraint violations.

### Bare try?

Acceptable only for truly ignorable operations:

- `try? await Task.sleep(...)`
- `try? FileManager.default.removeItem(...)` before an overwrite
- Other idempotent operations

**Always add a comment explaining why the error is ignorable.**

### Multi-Step Operations

Any operation with 3+ sequential steps that modify state (migration, batch import, sync) must:

- Implement rollback, **or**
- Be idempotent

Verification after the operation must throw on failure (not just log) so the caller can roll back.

---

## 4. File Size Limits

| File type | Max lines | Action when approaching limit |
|-----------|-----------|-------------------------------|
| Services | ~1,000 | Extract helper types |
| Views | ~800 | Extract sub-views into separate files; move single-use `@State` into the sub-view |

### Extraction Pattern

Prefer `@MainActor enum HelperName` with static methods for stateless extraction:

```swift
@MainActor
enum EmailMessageStorageHelper {
    static func store(_ message: Message, in context: ModelContext) throws {
        // ...
    }
}
```

---

## 5. Anti-Patterns -- What NOT to Do

| Anti-Pattern | Correct Approach |
|-------------|-----------------|
| Force unwrapping (`!`) | Use `guard let`, `if let`, or nil-coalescing. Exception: IBOutlets (none in SwiftUI). |
| `DispatchQueue.main.async` | Use `@MainActor` |
| Combine (`ObservableObject` / `@Published`) | Use `@Observable` macro + async/await in all new code |
| UIKit types | macOS uses AppKit: `NSImage`, `NSWorkspace`, etc. |
| Hardcoded paths | Derive from configuration or `AppState` directories |
| Synchronous file I/O on main thread | Dispatch to background via `Task.detached` or async file manager |
| `print()` in production | Use `os.Logger` |
| Bare `try?` on important operations | Use `do/try/catch` with logging. Bare `try?` only for ignorable ops (with comment). |
| `@AppStorage` with `URL.absoluteString` | Document that reconstruction requires `URL(string:)`, **not** `URL(fileURLWithPath:)`, because the stored value includes the `file://` scheme. |
| `Date()` allocations in hot paths | Use `os_signpost` or gate behind `#if DEBUG`. Do not add `Date()` timing to actor methods without a debug guard. |
| `ObservableObject` / `@Published` in new code | Use `@Observable` macro exclusively |
