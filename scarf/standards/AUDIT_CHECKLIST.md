# Audit Checklist

Copy this template per project. Check each item, note gaps, and record severity.

**Project**: _______________
**Date**: _______________
**Auditor**: _______________

---

## 01 Architecture

- [ ] Uses MVVM-F with feature modules (Models/ViewModels/Views per feature)
- [ ] AppCoordinator centralizes all navigation state
- [ ] No navigation state duplication between AppCoordinator and AppState
- [ ] Directory layout matches convention (`App/`, `Core/`, `Features/`, `Services/`, `Shared/`)
- [ ] Protocol-driven service interfaces (not concrete types)
- [ ] @Observable macro used (not ObservableObject/@Published) in new code
- [ ] No deep-nested NavigationStack in leaf views

## 02 SwiftData

- [ ] VersionedSchema + SchemaMigrationPlan in use
- [ ] No bare `Schema([...])` — uses `Schema(versionedSchema:)` + `migrationPlan:`
- [ ] Each VersionedSchema lists ALL active models
- [ ] Skeleton Records for immediate UI feedback (`status = .processing`)
- [ ] `#Index` macro on frequently queried fields
- [ ] UUID primary keys on all models
- [ ] `createdAt` / `updatedAt` timestamps on all models
- [ ] Soft delete pattern (`isArchived` + `archivedAt`) where applicable
- [ ] Money stored as `Int64` minor units + `currencyCode` (ISO 4217)
- [ ] Explicit join tables for many-to-many (CloudKit-friendly)
- [ ] Safe fetch wrappers used (no bare `try?` on `modelContext.fetch()`)
- [ ] DataStoreActor for background queries (not @Query in views)

## 03 Storage & Sandboxing

- [ ] NSFileCoordinator for ALL file ops within library root
- [ ] No prohibited `FileManager.default` calls (check lookup table)
- [ ] TOCTOU anti-patterns eliminated (no `fileExists` before idempotent ops)
- [ ] Security-scoped bookmarks for user-selected external folders
- [ ] Filename sanitization from external sources (`PathUtilities`)
- [ ] Inbox pattern (`_InBox/`) for new documents
- [ ] System folders use singular prefix (`_InBox`, `_Deleted`, `_Duplicate`)
- [ ] LLM prompt injection sanitization on document text (if AI features exist)

## 04 Swift Conventions

- [ ] No `print()` in production code — `os.Logger` exclusively
- [ ] `print()` only in `#Preview` blocks and test helpers
- [ ] Logger subsystem follows `"com.<appname>.app"` pattern
- [ ] Logger category matches type name
- [ ] Classes/actors: `private let logger = Logger(...)`
- [ ] Structs/views: `private static let logger = Logger(...)`, accessed via `Self.logger`
- [ ] Every `catch` block: logs / rethrows / returns `Result.failure` (no empty catches)
- [ ] `modelContext.save()` always in `do/try/catch` with logging
- [ ] No bare `try?` on important operations (only for truly ignorable ops, with comment)
- [ ] Multi-step operations (3+ steps) have rollback or are idempotent
- [ ] File size limits: services ~1,000 lines, views ~800 lines
- [ ] No force unwrapping (`!`) in SwiftUI code
- [ ] No `DispatchQueue` when Swift Concurrency works
- [ ] No `Combine` in new code — use `@Observable` + async/await
- [ ] No UIKit types (use AppKit: `NSImage`, `NSWorkspace`)
- [ ] All `Task`/`Task.detached` closures are `@Sendable`
- [ ] No sync file I/O on `@MainActor`
- [ ] `os_unfair_lock` for thread-safe flags (not `NSLock`)

## 05 Design System

- [ ] Centralized theme file exists (e.g., `AppTheme.swift`)
- [ ] No hardcoded colors — uses theme tokens
- [ ] No hardcoded fonts — uses Apple semantic styles or theme tokens
- [ ] No hardcoded spacing — uses spacing tokens
- [ ] No hardcoded animations — uses animation tokens
- [ ] No hardcoded corner radii — uses radius tokens
- [ ] Material tier rules followed (glass for chrome, plates for content)
- [ ] Keyboard-first: shortcuts for all primary actions
- [ ] SF Symbols exclusively for icons
- [ ] Filled variants for selected states
- [ ] Icon-only buttons have tooltip + accessibility label
- [ ] Accessibility: works with Reduce Transparency
- [ ] Accessibility: works with Increase Contrast
- [ ] Accessibility: works with Large Dynamic Type
- [ ] Accessibility: works with Reduce Motion

## 06 Editor Patterns

- [ ] Editors follow tabbed architecture (or N/A)
- [ ] Tab 0: Quick Entry with natural language input
- [ ] Tab 1: Details with core entity fields
- [ ] `ZStack` with conditional `if` rendering (not `switch`)
- [ ] `DSFormSection` for all content groups
- [ ] Wide canvas (800-900px x 600-700px)
- [ ] 0.15s tab transitions
- [ ] `.borderedProminent` on save/create button

## 07 AI Integration

- [ ] Native-first: Vision/NaturalLanguage before LLMs (or N/A)
- [ ] LLM accessed via protocol (`TextGenerating` or equivalent)
- [ ] `autoreleasepool` in image/PDF processing loops
- [ ] `Task.isCancelled` checked in long processing loops
- [ ] Prompt injection sanitization on document text
- [ ] No LLM calls on critical UI path

## 08 Data Integrity

- [ ] Backup/restore: every @Model field has Backup* struct field (or N/A)
- [ ] No silent data dropping in backup structs
- [ ] Roundtrip tests for serialization changes
- [ ] Migration steps have rollback contracts
- [ ] Verification throws on failure (not just logs)
- [ ] CloudKit conflict resolution is explicit (not silent last-write-wins)
- [ ] Safety guards: abort batch operations if >80% affected
- [ ] Debounce on sync notification handlers

## 09 Performance

- [ ] No views with 20+ @State variables
- [ ] Complex views use component extraction pattern
- [ ] DataStoreActor for background queries
- [ ] `autoreleasepool` in image/thumbnail/PDF loops
- [ ] No `Date()` allocations in hot paths without `#if DEBUG`
- [ ] `@ViewBuilder` used when type-checker times out
- [ ] Database-level `#Predicate` filtering (not in-memory)

## 10 Testing

- [ ] Swift Testing framework (`@Suite`, `@Test` macros)
- [ ] Protocol-based mock implementations for services
- [ ] No timing-dependent tests (uses polling with early exit)
- [ ] Singleton state cleaned up between tests
- [ ] Cooperative cancellation tested for long-running tasks
- [ ] Roundtrip tests for backup/restore changes
- [ ] No `print()` in test code (except `#Preview`)

## 11 Multiplatform

- [ ] Shared/ directory for all code used by both platforms (or N/A)
- [ ] ALL @Model types in Shared/ (never duplicated per platform)
- [ ] Schema versioning in Shared/
- [ ] Explicit CloudKit container ID (not `.automatic`)
- [ ] iOS entitlements use `com.apple.developer.aps-environment` (not `aps-environment`)
- [ ] `UIBackgroundModes` configured (remote-notification, fetch)
- [ ] Platform-adaptive navigation (`#if os(...)`)
- [ ] Shared design tokens with platform-specific modifiers

---

## Summary

| Standard | Status | Gaps Found | Severity |
|----------|--------|-----------|----------|
| 01 Architecture | | | |
| 02 SwiftData | | | |
| 03 Storage/Sandboxing | | | |
| 04 Swift Conventions | | | |
| 05 Design System | | | |
| 06 Editor Patterns | | | |
| 07 AI Integration | | | |
| 08 Data Integrity | | | |
| 09 Performance | | | |
| 10 Testing | | | |
| 11 Multiplatform | | | |

**Severity Levels**: Critical (data loss / crash risk) | High (correctness / maintainability) | Medium (consistency / best practice) | Low (polish / nice-to-have)
