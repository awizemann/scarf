---
title: Markdown block rendering comes from the Marker package
type: note
permalink: scarf/architecture/markdown-block-rendering-comes-from-the-marker-package
source_paths: [scarf/scarf/Core/Utilities/MarkdownContentView.swift, scarf/scarf.xcodeproj/project.pbxproj, scarf/scarfTests/MarkdownContentViewParseTests.swift]
source_paths_inferred: false
source_sha: 99fad45e86e91a3e877e2b48641294278e9c1dd4
created: 2026-07-22
updated: 2026-07-22
---

Since gh#134 (v2.17.x), `MarkdownContentView` no longer hand-rolls block parsing. Block classification comes from the **Marker** package (github.com/awizemann/Marker — Alan's reusable Markdown engine, extracted from TrapperKeeper), consumed as a **pinned remote package (`from: 0.8.1`, upToNextMajor)** — no local checkout required to build; develop Marker changes in `~/Developer/Marker`, then push + tag and bump the pin. Only the pure `Marker` core product is linked (Foundation-only; no tree-sitter, no AppKit). Note: `Package.resolved` is gitignored in this repo by existing convention, so the pbxproj requirement is the only pin.

**Pipeline:** `MarkdownContentView.parseBlocks(from:)` strips YAML frontmatter, runs `Marker.MarkdownParser.parse`, then maps Marker blocks onto Scarf's own `MarkdownBlock` enum using Marker's `contentText` (marker-stripped projection, added to Marker for this integration). The mapping deliberately preserves the pre-Marker rendering semantics: each paragraph source line is its own `.paragraph` (line breaks render as breaks), blockquote lines join with a space, consecutive blanks collapse, bullet indent = leading-spaces/2. Tables map to Scarf's vendor-free `MarkdownTableModel` and render as a SwiftUI `Grid`; GFM task items (`- [ ]`) render with a checkbox glyph. Streaming mode still skips the block pipeline entirely (inline-only) — tables materialize on finalize.

**Gotchas:**
- Marker sets `defaultIsolation(MainActor.self)`. Its pure namespaces must carry an explicit `nonisolated` or they become MainActor-isolated and crash off-main callers with a `dispatch_assert_queue` trap (Scarf's test suite runs off-main and caught exactly this). Fixed upstream for MarkdownParser/MarkdownInline/MarkdownCodeBlock/MarkdownCodeLanguage/DocumentOutline; keep this in mind when Marker adds new namespaces.
- Scarf and Marker both declare a type named `MarkdownBlock`; inside Scarf, the unqualified name is Scarf's, `Marker.MarkdownBlock` is the engine's.
- As of 2026-07-22 the Marker commits (contentText + nonisolated fixes) are local-only, ahead of origin/main; latest published tag is 0.8.0. If Scarf ever needs to build without the sibling checkout, push Marker, tag 0.9.0, and switch the pbxproj to a pinned remote reference.

Related: [[chat-text-selectable-across-paragraphs]] (the coalescing layer above this parser is unchanged).


## Observations
- [fact] Scarf's MarkdownContentView delegates block parsing to the Marker package (remote pin from: 0.8.1); only the Foundation-only Marker core product is linked #markdown #dependency
- [fact] GFM tables (gh#134) and task-item checkboxes render since this swap; tables map to Scarf's vendor-free MarkdownTableModel and draw as a SwiftUI Grid #gh134 #tables
- [gotcha] Marker uses defaultIsolation(MainActor) — any new pure namespace there must be explicitly nonisolated or off-main callers trap in dispatch_assert_queue #concurrency
- [fact] Marker 0.8.1 (pushed + tagged 2026-07-22) carries contentText and the nonisolated fixes; Scarf pins from: 0.8.1 as a remote package — Package.resolved is gitignored, the pbxproj requirement is the pin #release

## Relations
- relates_to [[chat-text-selectable-across-paragraphs]]
