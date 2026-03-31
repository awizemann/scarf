# Code Compliance Remediation

Use this prompt in a fresh Claude Code session AFTER the instruction audit has been completed. Replace the two variables at the top.

---

## Project Configuration
- **PROJECT_ROOT**: `/Users/awizemann/Developer/ShabuBox`
- **PROJECT_NAME**: `ShabuBox`
- **STANDARDS_PATH**: `/Users/awizemann/Developer/standards`

## Instructions

This project has been audited against centralized standards. The audit gaps are documented in the project's instruction file (CLAUDE.md or .agent/instructions.md) under "Known Audit Gaps." Your job is to fix the violations in the actual Swift source code, working through them in priority order.

**Read the project's instruction file first** to find the audit gaps table and top files to fix.

---

### Execution Model: Serial Tiers with Verification

Work through these tiers ONE AT A TIME, in order. After completing each tier:
1. Build the project to verify no regressions
2. Report what was fixed and what remains
3. Only proceed to the next tier after a clean build

If a tier has more than ~15 files to change, break it into sub-batches of 8-10 files, building between each batch.

**Do NOT run multiple tiers in parallel** — later tiers may touch the same files as earlier ones.

---

### Tier 1: Safety-Critical (Crashes & Data Loss)

**1a. Force Unwraps (`!`)**
For each force unwrap found in the audit:
- `.first!` → `guard let first = collection.first else { return }` or `.first.map { ... }`
- `as! Type` → `as? Type` with guard/if-let and logger.error for unexpected type
- `URL(string:)!` → `guard let url = URL(string:) else { logger.error(...); return }`
- Do NOT change force unwraps inside `#Preview` blocks or test files

**1b. Bare `try?` on Critical Operations**
For each bare `try?` on `modelContext.save()`, `modelContext.fetch()`, `encode`, `decode`:
```swift
// BEFORE
let results = try? modelContext.fetch(descriptor)

// AFTER
let results: [Entity]
do {
    results = try modelContext.fetch(descriptor)
} catch {
    logger.error("Failed to fetch entities: \(error)")
    results = []  // or return, or throw, depending on context
}
```
- If the file doesn't have a logger, add one following the standard:
  - Classes/actors: `private let logger = Logger(subsystem: "com.<appname>.app", category: "TypeName")`
  - Structs/views: `private static let logger = Logger(subsystem: "com.<appname>.app", category: "TypeName")`
- Add `import os` if not already present
- For `try? modelContext.save()`, always wrap in do/catch — saves should never silently fail

**Build and verify after Tier 1.**

---

### Tier 2: Logging & Error Handling

**2a. Replace `print()` with `os.Logger`**
For each `print()` call in production code (not #Preview, not test files):
- Add a logger declaration if the file doesn't have one (follow the struct vs class pattern from standards)
- Replace `print("message")` → `logger.error("message")` or `logger.warning("message")` or `logger.info("message")` based on context:
  - Error/failure messages → `logger.error()`
  - Expected failure paths → `logger.warning()`
  - Informational/debug → `logger.info()` or `logger.debug()`
- Add `import os` if not already present
- Do NOT touch `print()` inside `#Preview` blocks

**2b. Logger Subsystem Consistency**
If the audit found multiple subsystem strings:
- Standardize ALL Logger declarations to use the canonical subsystem (check the project's instruction file for the correct one)
- Search and replace across all files

**2c. Logger Declaration Pattern**
- Classes/actors should use: `private let logger = Logger(...)`
- Structs (including SwiftUI views) should use: `private static let logger = Logger(...)` accessed via `Self.logger`
- Nested structs must declare their own logger

**Build and verify after Tier 2.**

---

### Tier 3: File Operations & Concurrency

**3a. FileManager.default Violations**
For each `FileManager.default` call inside the library root (iCloud container):
- Replace with the appropriate coordinated API:
  - Read → `FileCoordinatorService.shared.coordinatedRead()`
  - Write → `FileCoordinatorService.shared.coordinatedWrite()`
  - Move → `FileCoordinatorService.shared.coordinatedMove()`
  - Delete → `SafeFileOperations.shared.coordinatedDelete()`
  - Create directory → `AsyncFileManager.shared.createDirectory()`
  - List directory → `AsyncFileManager.shared.contentsOfDirectory()`
- Leave allowed exceptions: `.url(forUbiquityContainerIdentifier:)`, `.temporaryDirectory`, app bundle reads
- If the project doesn't have FileCoordinatorService/AsyncFileManager, skip this sub-tier and note it

**3b. fileExists TOCTOU Anti-Patterns**
For each `fileExists` that precedes a file operation:
- `if fileExists { removeItem }` → `try? removeItem` (ignore ENOENT)
- `if fileExists { moveItem }` → `try moveItem` in do/catch
- `if !fileExists { createDirectory }` → `createDirectory(withIntermediateDirectories: true)`
- Leave valid uses: display-only warnings, migration gates, cache hit checks

**3c. DispatchQueue → @MainActor**
For `DispatchQueue.main.async { }` calls:
- If inside an async context: replace with `await MainActor.run { }` or mark the closure `@MainActor`
- If the containing function should be main-actor-isolated: add `@MainActor` to the function
- Be careful with this one — only change if you're confident the surrounding code supports it
- Skip if the DispatchQueue usage is for intentional delayed execution or debouncing

**Build and verify after Tier 3.**

---

### Tier 4: Design System Token Compliance

**This tier is the largest. Break into batches of 8-10 files, building between each.**

Before starting, read the project's design system / theme file to understand available tokens. Search for files like `*Theme.swift`, `*Tokens.swift`, `DS.swift`, `DesignSystem/` directory.

**4a. Hardcoded Font Sizes**
- `.font(.system(size: 14))` → `.font(AppTheme.Typography.body)` (or the project's equivalent token)
- Map common sizes to the nearest semantic token
- If no matching token exists, add one to the theme file first, then use it

**4b. Hardcoded Colors**
- `Color(.red)` or `Color(nsColor: ...)` → `AppTheme.Colors.error` (or equivalent)
- `NSColor(calibratedRed: ...)` → theme token
- Leave system semantic colors that are already correct (e.g., `.primary`, `.secondary`)
- Leave colors defined in the theme file itself

**4c. Hardcoded Spacing**
- `.padding(8)` → `.padding(AppTheme.Spacing.sm)` (or equivalent)
- `.padding(.horizontal, 16)` → `.padding(.horizontal, AppTheme.Spacing.md)`
- Map numeric values to nearest token: 4→xxs, 8→xs/sm, 12→sm, 16→md, 20→lg, 24→xl, 32→xxl
- If the project's tokens use different names, use those

**4d. Hardcoded Corner Radii**
- `.cornerRadius(8)` → `AppTheme.CornerRadius.sm` (or equivalent)
- `RoundedRectangle(cornerRadius: 12)` → `RoundedRectangle(cornerRadius: AppTheme.CornerRadius.md)`

**4e. Hardcoded Shadows & Animations**
- `.shadow(radius: 4)` → `.themeShadow(.subtle)` (or equivalent modifier)
- `.animation(.easeInOut(duration: 0.3))` → `.animation(AppTheme.Animation.standard)` (or equivalent)

**Build and verify after each batch of 8-10 files in Tier 4.**

---

### Tier 5: Structural Improvements (Large Files & @Query Migration)

**This tier involves the most complex changes. One file at a time, build after each.**

**5a. Oversized Files (>800 lines for views, >1000 for services)**
For each oversized file from the audit:
- Identify logical sections that can be extracted into separate files
- Create new files with extracted views/helpers
- Use `@MainActor enum HelperName` with static methods for extracted logic
- Use separate `struct SubViewName: View` for extracted views
- Keep the parent file as the coordinator, passing state via bindings and callbacks
- Follow the state ownership matrix from `09-performance.md`:
  - Component owns: pagination, view preferences, selection, loading state
  - Parent owns: navigation, global search, preview state
  - Pass as bindings: shared filters
  - Pass as callbacks: navigation actions

**5b. @Query → DataStoreActor Migration**
This is an architectural change — only do if the project already has a DataStoreActor pattern established:
- Replace `@Query var items: [Entity]` with a DataStoreActor-based fetch
- Add `.task { await loadItems() }` to trigger the fetch
- Store results in `@State private var items: [Entity] = []`
- If the project doesn't have DataStoreActor infrastructure, skip this and note it

**Build and verify after each file in Tier 5.**

---

### Final Verification

After all tiers are complete:
1. Run a full build: `xcodebuild -scheme {SCHEME} -destination 'platform=macOS' build`
2. Run tests if available: `xcodebuild test -scheme {SCHEME} -destination 'platform=macOS'`
3. Re-run the audit searches from the original audit to get updated violation counts
4. Update the project's instruction file — change the "Known Audit Gaps" table with new counts (hopefully zeros or much lower)
5. Report a before/after comparison table

---

### Rules

- **Always build between tiers** — do not proceed if the build is broken
- **Never change test files** unless they have print() statements (Tier 2a only)
- **Never change #Preview blocks**
- **Never change files in build/, .build/, SourcePackages/, Pods/**
- **Preserve existing behavior** — these are refactors, not feature changes
- **When uncertain about a change, skip it** and note it in the report rather than risk breaking something
- **Add imports** (`import os`, `import OSLog`) only when needed for Logger
- **Do not refactor surrounding code** — only fix the specific violation pattern
- **If a file has multiple violation types, fix them all in one pass** to avoid repeated reads/writes
- **Keep changes minimal** — the goal is compliance, not improvement
