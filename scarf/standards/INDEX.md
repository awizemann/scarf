# macOS App Suite — Centralized Standards

**Version**: 1.0
**Last Updated**: 2026-03-26
**Applies To**: InControl, ShabuBox, Threader, Modeler, and all future macOS apps in the suite

---

## Standards Files

| # | File | Description |
|---|------|-------------|
| 01 | [architecture.md](01-architecture.md) | MVVM-F pattern, AppCoordinator, directory layout (single-platform and multiplatform) |
| 02 | [swiftdata.md](02-swiftdata.md) | SwiftData persistence, schema versioning, Skeleton Records, query patterns, data modeling conventions |
| 03 | [storage-and-sandboxing.md](03-storage-and-sandboxing.md) | iCloud storage, NSFileCoordinator, TOCTOU prevention, sandboxing, path security |
| 04 | [swift-conventions.md](04-swift-conventions.md) | Swift 6 concurrency, os.Logger standard, error handling, file size limits, anti-patterns |
| 05 | [design-system.md](05-design-system.md) | Visual design principles, material tiers, typography, spacing, layout, components, checklists |
| 06 | [editor-patterns.md](06-editor-patterns.md) | Tabbed editor architecture, form components, Quick Entry, completion checklists |
| 07 | [ai-integration.md](07-ai-integration.md) | Native-first AI, LLM protocol layer, pipeline architecture, prompt injection defense |
| 08 | [data-integrity.md](08-data-integrity.md) | Backup/restore parity, migration rollback contracts, CloudKit sync safety |
| 09 | [performance.md](09-performance.md) | Component extraction pattern, state ownership, view complexity, memory management |
| 10 | [testing.md](10-testing.md) | Swift Testing framework, protocol mocking, timing rules, cancellation testing |
| 11 | [multiplatform.md](11-multiplatform.md) | iOS companion apps, shared libraries, CloudKit sync, platform-adaptive UI |
| -- | [AUDIT_CHECKLIST.md](AUDIT_CHECKLIST.md) | Per-project audit template (~70 checkboxes) for gap detection |

---

## Project Conformance Matrix

| Standard | InControl | ShabuBox | Threader | Modeler |
|----------|:---------:|:--------:|:--------:|:-------:|
| 01 Architecture | Good | Good | Good | Good |
| 02 SwiftData | Good | Partial | Good | Basic |
| 03 Storage/Sandboxing | Partial | Best | Good | N/A |
| 04 Swift Conventions | Partial | Good | Best | Good |
| 05 Design System | Best (principles) | Best (tokens) | Minimal | Minimal |
| 06 Editor Patterns | Best | Gap | Gap | Gap |
| 07 AI Integration | Good | Best | Good | Different |
| 08 Data Integrity | Gap | Best | Gap | Gap |
| 09 Performance | Gap | Best | Gap | Gap |
| 10 Testing | Basic | Good | Implicit | Basic |
| 11 Multiplatform | Ready | Best | Partial | N/A |

**Legend**: Best = reference implementation | Good = compliant | Partial = some coverage | Gap = not documented | N/A = not applicable

---

## How to Use These Standards

### For New Projects
Add this to your project's `CLAUDE.md`:
```markdown
## Standards
This project follows the centralized standards at `/Users/awizemann/Developer/standards/`.
See INDEX.md for the full list. Project-specific details below.
```

### For Existing Projects
1. Run the audit checklist against your project
2. Identify gaps
3. Update project CLAUDE.md to reference standards and remove duplicated rules
4. Keep only project-specific content (PRD, screen layouts, key file paths, critical lessons)

### Backups
Pre-edit snapshots of all modified project files are stored in `backups/{ProjectName}/{YYYY-MM-DD}/`.
