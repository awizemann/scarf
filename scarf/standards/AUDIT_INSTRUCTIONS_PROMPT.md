# Audit & Remediate Project Instructions Against Centralized Standards

Use this prompt in a fresh Claude Code session for each project. Replace the two variables at the top.

---

## Project Configuration
- **PROJECT_ROOT**: `/Users/awizemann/Developer/ShabuBox`
- **PROJECT_NAME**: `ShabuBox`

## Instructions

This project follows centralized standards at `/Users/awizemann/Developer/standards/`. Read `INDEX.md` first, then audit this project against all 11 standards and fix violations.

### Phase 1: Discovery (Parallel Agents)

Launch up to 3 explore agents IN PARALLEL, each covering a subset of standards:

**Agent 1 — Code Quality & Conventions (Standards 04, 02, 01)**
Search the project's Swift source files (exclude build/, .build/, SourcePackages/, Pods/) for:
- `print(` in production code (not #Preview, not test files) → should be os.Logger
- Force unwraps (`!`) — patterns like `.first!`, `as!`, `URL(...)!` (not `!=`, `!==`)
- Bare `try?` followed by `modelContext`, `.fetch(`, `.save(`, `encode`, `decode`
- `DispatchQueue` usage (should prefer @MainActor / Swift Concurrency)
- `ObservableObject` / `@Published` (should be @Observable in new code)
- `import Combine` (should use async/await)
- `NSLock` (should use os_unfair_lock)
- `@Query` in view files (should use DataStoreActor)
- Files over 800 lines (views) or 1000 lines (services) — report names and line counts
- Logger subsystem strings — check consistency (should be `"com.<appname>.app"`)
- Logger declaration patterns — classes should use `private let`, structs/views should use `private static let`
- Schema versioning — check for bare `Schema([` without `versionedSchema:`
Report exact file paths, line numbers, and counts for each category.

**Agent 2 — Storage, Security & File Operations (Standards 03, 08)**
Search the project's Swift source files for:
- `FileManager.default` in service/feature files (should use FileCoordinatorService)
- `fileExists` calls — classify each as valid (display-only, migration gate, cache) or TOCTOU anti-pattern
- Direct file operations without NSFileCoordinator in library root paths
- Bare `try?` on fetch/save in sync-related code
- Missing `autoreleasepool` in loops processing images/thumbnails/PDFs
- `Date()` allocations in hot paths without `#if DEBUG`
- Backup/restore structs — check if @Model fields have corresponding Backup* fields
- Migration code — check for rollback contracts
Report exact file paths, line numbers, and counts.

**Agent 3 — Design System & UI (Standards 05, 06, 09)**
Search the project's Swift source files for:
- Hardcoded colors: `Color(` with literal values, `.foregroundColor(.red/blue/etc)`, `NSColor(calibratedRed:`, `NSColor(red:`
- Hardcoded fonts: `.font(.system(size:` instead of theme tokens
- Hardcoded spacing: `.padding(` with literal numeric values (not theme tokens like DS.Spacing or AppTheme)
- Hardcoded corner radii: `.cornerRadius(` or `RoundedRectangle(cornerRadius:` with literal values
- Hardcoded shadows: `.shadow(` with literal values instead of theme tokens
- Hardcoded animations: `.animation(.easeInOut(duration:` with literal values instead of theme tokens
- Views with 20+ @State variables (performance risk)
- Missing accessibility: interactive elements without `.accessibilityLabel`
Report counts per category and the worst-offending files.

### Phase 2: Report

After all agents complete, compile a single audit report with:

1. **Summary table** — category, violation count, severity (Critical/High/Medium/Low)
2. **Top 10 files to fix** — ranked by total violations across all categories
3. **Per-standard breakdown** — what's compliant, what's not, specific file:line references
4. **Recommendations** — prioritized remediation order

### Phase 3: Backfill Project Instructions

1. **Backup first**: Copy every instruction/guideline file (.md files in .claude/rules/, CLAUDE.md, .agent/, docs/ that contain instructions) to `/Users/awizemann/Developer/standards/backups/{PROJECT_NAME}/2026-03-26/`

2. **Update the project's main instruction file** (CLAUDE.md or .agent/instructions.md):
   - Add a Standards section at the top referencing `/Users/awizemann/Developer/standards/`
   - Remove any rules that are now fully covered by the centralized standards (architecture patterns, SwiftData conventions, file operation rules, error handling rules, logging rules, testing rules, design system principles, etc.)
   - KEEP all project-specific content: build commands, key file paths, project-specific services, critical lessons, known hotspots, app-specific pipeline/processing details, unique integrations
   - Add a "Known Audit Gaps" section with the violation counts from the audit
   - Add a "Top Files to Fix" section listing the worst offenders

3. **Update any supplementary instruction files** (.claude/rules/*.md, design system docs, etc.):
   - Add a header line referencing the corresponding centralized standard
   - Keep project-specific details (hotspot lists, violation counts, app-specific patterns)
   - Remove duplicated generic rules

### Important Rules
- This is a READ + WRITE task — you should make the file changes
- Do NOT modify any Swift source code — only .md instruction/guideline files
- Do NOT delete any files — only edit them
- Preserve all project-specific content (PRDs, screen layouts, data schemas, development plans, critical lessons)
- When in doubt about whether content is project-specific or generic, keep it
