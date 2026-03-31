# 10 — Testing

Standards for writing reliable, deterministic, and maintainable tests in Swift projects.

---

## 1. Framework

Use the **Swift Testing** framework for all new tests:

- `@Suite` for test groupings
- `@Test` for individual test cases
- `#expect` and `#require` for assertions

Do not use XCTest for new tests. Existing XCTest suites may be migrated incrementally.

---

## 2. Mocking

Use **protocol-oriented mocking**:

- All services expose a protocol interface (e.g., `protocol FileManaging`)
- Concrete implementations conform to the protocol
- Tests swap real implementations for mock/stub versions
- This enables isolated unit testing without side effects

```swift
protocol DataProviding: Sendable {
    func fetchItems(page: Int, limit: Int) async throws -> [Item]
}

struct MockDataProvider: DataProviding {
    var items: [Item] = []
    func fetchItems(page: Int, limit: Int) async throws -> [Item] {
        Array(items.prefix(limit))
    }
}
```

---

## 3. Timing

**No timing-dependent tests.** Never rely on fixed `sleep` durations.

Use polling with early exit:

```swift
for _ in 0..<20 {
    if await service.isComplete { break }
    try await Task.sleep(for: .milliseconds(100))
}
#expect(await service.isComplete)
```

- Maximum 20 iterations at 100ms each (2s total timeout)
- Break as soon as the condition is met
- Assert after the loop, not inside it

---

## 4. Singleton Isolation

Shared state must be clean before each test:

1. Call the service's cleanup/reset method
2. `await Task.yield()` to let pending work complete
3. Then run assertions

```swift
await SharedService.shared.reset()
await Task.yield()

// Now safe to test
await SharedService.shared.doWork()
#expect(await SharedService.shared.result == expected)
```

Reset shared state between tests to prevent ordering dependencies.

---

## 5. Cooperative Cancellation

Verify that long-running tasks respond to `Task.isCancelled`:

- Start a long operation in a `Task`
- Cancel it mid-flight
- Assert that cancellation produces expected cleanup (partial results discarded, temporary files removed, state reset)

```swift
let task = Task { await service.processLargeDataset() }
try await Task.sleep(for: .milliseconds(50))
task.cancel()
let result = await task.value
#expect(result == .cancelled)
```

---

## 6. Roundtrip Tests

**Required** for any change to backup/restore logic or serialization formats.

Every roundtrip test must:

1. Create a model instance with **all fields populated** (no defaults)
2. Encode to the serialization format (backup struct, JSON, etc.)
3. Decode back to a model instance
4. Assert every field matches the original

Do not skip optional fields -- populate them with non-nil values to verify they survive the round trip.

---

## 7. Integration Tests

For systems that communicate with subprocesses or external services:

- Test the **request/response cycle** end to end
- For subprocess protocols (e.g., JSON-lines over stdin/stdout), verify:
  - Request serialization produces valid output
  - Response deserialization handles all message types (progress, result, error)
  - Error responses are surfaced correctly
- Use mock subprocess runners or in-process test servers when possible

---

## 8. Logging in Tests

**No `print()` in production code or test helpers.** Use `os.Logger` with an appropriate test subsystem:

```swift
private let logger = Logger(subsystem: "com.app.tests", category: "ServiceTests")
```

`print()` is only acceptable in `#Preview` blocks for quick debugging during development.

Rationale: `os.Logger` output is filterable, has log levels, and does not pollute test console output with unstructured noise.
