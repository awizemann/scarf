# SwiftData Standard

Applies to: InControl, ShabuBox, Threader, Modeler

---

## 1. Schema Versioning

Every SwiftData model change goes through `VersionedSchema` + `SchemaMigrationPlan`. No exceptions.

### Rules

| Rule | Detail |
|------|--------|
| Always version | Every model or stored-property addition, removal, or rename requires a new `VersionedSchema` enum and a corresponding `MigrationStage` in the migration plan. |
| Never modify existing versions | Once a `VersionedSchema` is shipped, treat it as immutable. Create a new version instead. |
| List ALL active models | Each `VersionedSchema.models` array must contain every model that should exist after that version. Omitting a model drops its table on migration. |
| No unversioned schemas | Never pass `Schema([...])` directly to `ModelContainer`. Always use `Schema(versionedSchema:)` with `migrationPlan:`. |

### ModelContainerFactory

```swift
// Correct
let schema = Schema(versionedSchema: AppSchemaV3.self)
let config = ModelConfiguration(schema: schema)
let container = try ModelContainer(
    for: schema,
    migrationPlan: AppMigrationPlan.self,
    configurations: [config]
)

// Wrong -- unversioned, no migration plan
let container = try ModelContainer(for: MyModel.self)
```

### Migration Stages

Use **lightweight** stages for structural changes (additions, removals, renames). These are the only stages compatible with CloudKit `.automatic` sync.

```swift
// Lightweight -- safe for CloudKit .automatic
.lightweight(fromVersion: AppSchemaV1.self, toVersion: AppSchemaV2.self)
```

Use **custom** stages only when data must be transformed (splitting a field, computing a derived value). Custom stages require CloudKit sync mode `.none` -- coordinate with the sync layer before adding one.

```swift
// Custom -- requires CloudKit .none
.custom(
    fromVersion: AppSchemaV2.self,
    toVersion: AppSchemaV3.self,
    willMigrate: { context in
        // transform data here
        try context.save()
    },
    didMigrate: nil
)
```

### Decision Table

| Change type | Stage | CloudKit compatible |
|-------------|-------|---------------------|
| Add model | lightweight | Yes |
| Add optional property | lightweight | Yes |
| Remove property | lightweight | Yes |
| Rename property (`@Attribute(originalName:)`) | lightweight | Yes |
| Split field into two | custom | No -- use `.none` sync |
| Backfill computed values | custom | No -- use `.none` sync |

---

## 2. Skeleton-First Pattern

Create the record with `status = .processing` immediately so the UI shows it right away. Fill in real data as background processing completes.

```swift
// 1. Insert skeleton record -- instant UI feedback
let record = MyRecord(name: placeholder, status: .processing)
modelContext.insert(record)
try modelContext.save()

// 2. Process in background
let result = await heavyWork()

// 3. Update the record
record.name = result.name
record.status = .ready
try modelContext.save()
```

The user sees the record appear in the list immediately. As processing finishes, the record fills in and the status indicator clears.

---

## 3. Indexing

Add `#Index` on fields that appear in predicates, sort descriptors, or frequent lookups.

```swift
@Model
final class Task {
    var title: String
    var dueDate: Date?
    var status: String
    var projectID: UUID?
    var updatedAt: Date
    // ...
}

// Declare indexes for query performance
extension Task {
    static let indexes: [[IndexColumn<Task>]] = [
        [\.dueDate],
        [\.projectID],
        [\.status],
        [\.updatedAt]
    ]
}
```

### Minimum Indexes by Domain

| Entity | Indexed fields |
|--------|---------------|
| Task | dueDate, projectID, columnID, status, updatedAt |
| Expense | date, projectID, categoryID, status |
| Opportunity | stageID, targetCloseDate, updatedAt |
| ExternalLink | provider, externalID, (entityType + entityID) |

---

## 4. Query Patterns

### Use DataStoreActor for Background Queries

All views should use background actor queries. Do not use `@Query` or synchronous `DataStore` calls for production data access.

```swift
// Proven pattern: background actor query + main-thread model resolution
let (ids, count) = try await dataStoreActor.fetchItemsWithCount(page: page, limit: limit)

await MainActor.run {
    loadedItems = modelContext.items(from: ids)
}
```

### Prefer Database-Level Filtering

Use `#Predicate` for filtering whenever possible. In-memory filtering fetches all matching rows into memory and becomes a scalability problem at 10k+ records.

```swift
// Good -- database-level filtering
let predicate = #Predicate<Task> { $0.status == "active" && $0.projectID == targetID }
let descriptor = FetchDescriptor(predicate: predicate)
let results = try modelContext.fetch(descriptor)

// Bad -- fetches everything, filters in Swift
let all = try modelContext.fetch(FetchDescriptor<Task>())
let filtered = all.filter { $0.status == "active" }
```

If in-memory filtering is unavoidable (e.g., complex path-prefix matching), add a `fetchLimit` cap and document why database-level filtering was not possible.

```swift
// Acceptable only with justification and cap
var descriptor = FetchDescriptor<Item>(predicate: basePredicate)
descriptor.fetchLimit = 500 // Cap to prevent unbounded memory
let items = try modelContext.fetch(descriptor)
// In-memory filter required: destinationPath prefix matching not supported by #Predicate
let filtered = items.filter { $0.destinationPath.hasPrefix(targetPath) }
```

---

## 5. Safe Fetch

Never use bare `try?` on `modelContext.fetch()`. Use the safe wrappers that log failures.

```swift
// Good -- logs the error, returns empty array on failure
let items = dataStore.safeFetch(descriptor, operation: "loading active tasks")

// Good -- logs the error, returns 0 on failure
let count = dataStore.safeFetchCount(descriptor, operation: "counting inbox items")

// Bad -- silently swallows fetch errors
let items = try? modelContext.fetch(descriptor)
```

`safeFetch` and `safeFetchCount` wrap the call in `do/try/catch`, log with `logger.error()` including the operation name, and return a safe default (empty array or zero).

---

## 6. Data Modeling Conventions

### Primary Keys

All entities use `UUID` primary keys.

```swift
@Attribute(.unique) var id: UUID = UUID()
```

### Timestamps

Every entity carries automatic timestamps.

```swift
var createdAt: Date = Date()
var updatedAt: Date = Date()
```

Update `updatedAt` on every mutation.

### Soft Delete

Prefer archiving over hard deletion for auditability and sync safety.

```swift
var isArchived: Bool = false
var archivedAt: Date?
```

### Money

Store monetary values as `Int64` minor units (cents) plus an ISO 4217 currency code. Never use floating-point for money.

```swift
var amountMinor: Int64      // e.g., 1999 = $19.99
var currencyCode: String    // e.g., "USD"
```

### Kanban Ordering

Use `sortIndex: Double` for position within a column. Doubles allow cheap insertion between two items without rewriting the entire list.

```swift
var sortIndex: Double

// Insert between items at 1.0 and 2.0
newItem.sortIndex = 1.5
```

### Many-to-Many Relationships

Use explicit join tables instead of native SwiftData many-to-many. This is CloudKit-friendly and supports auditing.

```swift
@Model
final class EntityTag {
    @Attribute(.unique) var id: UUID = UUID()
    var entityType: String
    var entityID: UUID
    var tagID: UUID
    var createdAt: Date = Date()
}
```

---

## 7. Actor Safety

Isolate SwiftData models within the appropriate actor to prevent data races.

### Logger in @Model Classes

`@Model` classes are actor-isolated, but `Logger` is not `Sendable`. Declare the logger at file scope with `nonisolated(unsafe)` to avoid concurrency warnings.

```swift
private nonisolated(unsafe) let logger = Logger(
    subsystem: "com.yourapp",
    category: "MyModel"
)

@Model
final class MyModel {
    // Use `logger` freely inside the class
}
```

For structs (including SwiftUI views), use `private static let logger` instead.

---

## 8. Error Handling in Models

### Encode / Decode

Never use `try?` on encode or decode operations. A silent failure here means corrupted or lost data.

```swift
// Good
do {
    let data = try JSONEncoder().encode(value)
    self.storedData = data
} catch {
    logger.error("Failed to encode value: \(error)")
    self.storedData = Data() // explicit fallback
}

// Bad -- silently drops data
self.storedData = try? JSONEncoder().encode(value)
```

### modelContext.save()

Always wrap saves in `do/try/catch`. Save failures indicate data corruption or constraint violations -- they must never be silently ignored.

```swift
do {
    try modelContext.save()
} catch {
    logger.error("Save failed: \(error)")
}
```

### When bare try? Is Acceptable

Only for truly ignorable, idempotent operations. Always include a comment.

```swift
// Ignorable: removing file before overwrite
try? FileManager.default.removeItem(at: tempURL)

// Ignorable: sleep cancellation
try? await Task.sleep(for: .seconds(1))
```
