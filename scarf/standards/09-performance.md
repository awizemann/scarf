# 09 — Performance

Patterns for keeping SwiftUI views responsive, queries efficient, and memory bounded.

---

## 1. Component Extraction Pattern

### Problem

SwiftUI views with high complexity (1000+ lines, dozens of `@State` variables) cause slow task scheduling (3-4s) and expensive view reconciliation. Database queries are typically fast -- the bottleneck is view complexity.

### Solution: Isolated Components

Break monolithic views into isolated child components. The parent becomes a lightweight coordinator with minimal state. Each child owns its section-specific state locally.

```
CoordinatorView (minimal state)
  |- SectionAListView (isolated state)
  |- SectionBListView (isolated state)
  |- SectionCListView (isolated state)
  `- SectionDListView (isolated state)
```

### Proven Results

| Operation | Before | After | Improvement |
|-----------|--------|-------|-------------|
| Pagination | 3,800ms | 37ms | ~100x |
| Filter change | 3,500ms | 45ms | ~78x |
| Sort change | 3,200ms | 52ms | ~62x |
| Search | 3,600ms | 35ms | ~103x |

### Implementation Steps

1. **Identify state to extract** (section-specific): current page, loaded items, loaded total count, loading flags, sort option, items per page, view mode, multi-select mode, selected IDs.

2. **Keep in parent** (shared across sections): navigation selection, search text, preview item, root configuration.

3. **Create a dedicated view file** for each section:
   - Receive `modelContext` and data actor from environment
   - Accept bindings from parent for shared state
   - Use local `@State` for section-specific state
   - Use callbacks for parent actions (`onItemTap`, `onAction`)

4. **`.task(id:)` must include ALL dependencies:**
   ```swift
   .task(id: "\(currentPage)-\(itemsPerPage)-\(searchText)-\(sortOption)-\(filter)") {
       await loadItems()
   }
   ```
   Forgetting any dependency (e.g., `itemsPerPage`) means changing it will not trigger a reload.

5. **Use background actor queries** (see Section 3 below).

6. **Use `@ViewBuilder` computed properties** for complex toolbars and conditional layouts to prevent SwiftUI type-checker timeouts.

### Common Issues

| Issue | Solution |
|-------|----------|
| Items per page not reloading | Add `itemsPerPage` to `.task(id:)` |
| Faulted SwiftData objects | Filter with `object.modelContext != nil` |
| Search not debouncing | Add debounce task + `onChange` handler (700ms) |
| Modal shows empty state | Add `.task` to refresh data on modal appear |

---

## 2. State Ownership Matrix

| Owner | State |
|-------|-------|
| **Component owns** | Pagination, view preferences, selection, loading flags |
| **Parent owns** | Navigation, global search, preview/modal, root config |
| **Pass as bindings** | Filters affecting multiple sections, shared search text |
| **Pass as callbacks** | Navigation actions, preview actions |

Target: ~10 `@State` variables per view. If a view exceeds this, it is a candidate for extraction.

---

## 3. Background Actor Query Pattern

All views should use background actor queries instead of `@Query` or synchronous data store calls.

```swift
// Background actor query
let (ids, count) = try await actor.fetchItemsWithCount(page:, limit:)
// Main thread model conversion
loadedItems = modelContext.items(from: ids)
```

### Filtering Rules

- Use database-level `#Predicate` filtering whenever possible.
- If in-memory filtering is unavoidable, add a `fetchLimit` cap and document why the predicate approach does not work.
- Any new filter dimension must default to database-level filtering. In-memory filtering of unbounded result sets is a scalability risk.

---

## 4. View Complexity Limits

| Metric | Guideline |
|--------|-----------|
| `@State` variables per view | ~10 (target) |
| Service file size | ~1,000 lines max |
| View file size | ~800 lines max |

When the Swift type-checker times out on a view body, extract sub-expressions into `@ViewBuilder` computed properties or separate files.

---

## 5. Memory Management

- **`autoreleasepool`** in all loops processing images, thumbnails, or PDFs. Synchronous only -- no `await` inside the pool.
- **No `Date()` allocations in hot paths** without `#if DEBUG`. Use `os_signpost` intervals for production performance measurement.
- **Cap PDF rendering** at 4096px maximum dimension.
- **Never cache large arrays.** Use database-level filtering with predicates. Fetch on demand.

---

## 6. Refactoring Priority Matrix

Use this template when prioritizing refactoring work:

```
HIGH IMPACT + LOW RISK = DO FIRST
|- Extract shared components (reusable controls, footers, toolbars)
|- Create centralized observable state
`- Async file operations

HIGH IMPACT + MEDIUM RISK = DO NEXT
|- Async model saves
|- ViewModel extraction from large views
`- Async processing pipelines

MEDIUM IMPACT + MEDIUM RISK = DO LATER
|- Replace remaining @Query usage with actor pattern
`- Async indexing/background services
```

### Metrics to Track

| Metric | Measure |
|--------|---------|
| Initial load time | Target < 100ms |
| `@State` count in coordinator views | Target ~10 |
| Duplicate code lines | Target < 50 |
| Views using synchronous queries | Target 0 |
| Main thread blocking operations | Target 0 |

---

## 7. Lazy Loading

- **Never cache large arrays.** Always query the database for the current page.
- **Database-level filtering** with `#Predicate` is the default. Index frequently queried fields.
- **`fetchLimit` cap** when in-memory filtering is unavoidable. Document the reason.
- **Debug logging** with `Date()` must be gated behind `#if DEBUG`. Do not add `Date()` timing to methods called per-page without the guard.
