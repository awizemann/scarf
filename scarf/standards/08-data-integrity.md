# 08 — Data Integrity

Rules for preventing data loss during backup, restore, migration, and sync operations.

---

## 1. Backup/Restore Serialization Parity

Every persisted `@Model` field must have a corresponding field in its `Backup*` struct. When adding a field to a model, update both directions:

- `Backup*.init(from:)` -- read from model
- `Backup*.toModel()` -- write to new model
- The top-level backup container struct if it is a new model type

**No silent data dropping.** Never assign `[]` or `nil` to backup fields unconditionally. If a field must be skipped:

- Add a `// WORKAROUND:` comment with the reason
- Log at `.warning` level
- Document what data is lost and how it can be recovered

**Roundtrip testing required.** Any change to a `@Model` class or its `Backup*` struct requires a test that:

1. Creates a model with all fields populated
2. Converts to the backup representation and back
3. Asserts all fields match

**Known gaps.** When a backup struct intentionally omits fields, add a `// TODO:` comment listing the missing fields and the reason. Track these as technical debt. Do not ship new backup structs with undocumented omissions.

---

## 2. Migration Safety

### Rollback Contract

Multi-step migrations must:

- **Store original state** before any destructive step (rename, delete, overwrite)
- **Wrap all steps** in a single `do/catch` that calls `rollback()` on failure
- **Test `rollback()` independently** -- it is its own code path and needs its own coverage
- **Never mark migration complete** until all verification passes

### Verification Must Throw

Validation methods (e.g., `verifyDataIntegrity()`) must `throw` on failure, not just log. The caller's `catch` block handles rollback. A log-only verification is a no-op for safety -- the migration proceeds as if everything succeeded.

### No New Steps Without Rollback Coverage

Before adding a step to any migration coordinator, verify that `rollback()` handles the new state and cleans up any artifacts the step creates.

---

## 3. CloudKit Sync Safety

### Explicit Conflict Resolution

Do not use last-write-wins without user notification. When the sync provider returns a conflict:

- Log conflict details
- Either merge deterministically (union for arrays, latest timestamp for scalars) or queue for user resolution
- Never silently discard either version

### Safety Guards

Maintain these defensive patterns:

| Guard | Purpose |
|-------|---------|
| Abort if >80% of records affected | Prevents runaway repair/cleanup from wiping the dataset |
| Self-refreshing flag | Prevents recursive sync notification loops |
| 0.25s debounce on notification handlers | Prevents rapid-fire processing of batched notifications |

### Fetch Error Handling

Use safe fetch wrappers (e.g., `safeFetch()`, `safeFetchCount()`) in all sync and monitor code paths. Never use bare `try?` on fetch calls -- errors in sync paths must be logged and handled, not silently swallowed.

---

## 4. SwiftData Version Coexistence

V1 and V2 schema versions cannot share live model types in the same process. Attempting to register both causes a "Duplicate checksums" crash.

When planning a schema version transition:

- Use `VersionedSchema` and `SchemaMigrationPlan`
- Test the migration path from V1 to V2 in isolation
- Confirm the old schema version is fully removed before the new one is registered
- Never modify existing schema versions -- always create a new one
