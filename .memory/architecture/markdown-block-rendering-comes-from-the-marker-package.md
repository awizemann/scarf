---
title: Markdown block rendering comes from the Marker package
type: note
permalink: scarf/architecture/markdown-block-rendering-comes-from-the-marker-package
source_paths: [scarf/scarf/Core/Utilities/MarkdownContentView.swift, scarf/scarf.xcodeproj/project.pbxproj, scarf/scarfTests/MarkdownContentViewParseTests.swift]
source_paths_inferred: false
source_sha: ad0ae4671d479a80f21bd3a621364348fc3743fd
created: 2026-07-22
updated: 2026-08-20
reviewed: 2026-09-18
reviewed_by: audit:claude-code (background)
---

## Observations
- [fact] Scarf's MarkdownContentView delegates block parsing to the Marker package (remote pin from: 0.9.0); only the Foundation-only Marker core product is linked #markdown #dependency
- [fact] GFM tables (gh#134) and task-item checkboxes render since this swap; tables map to Scarf's vendor-free MarkdownTableModel and draw as a SwiftUI Grid #gh134 #tables
- [gotcha] Marker uses defaultIsolation(MainActor) — any new pure namespace there must be explicitly nonisolated or off-main callers trap in dispatch_assert_queue #concurrency
- [fact] Marker 0.9.0 (adopted 2026-08-20) parses whitespace-padded task checkboxes ("[ x]", "[x ]", "[  ]", "[ X ]"; bare "[]" is not a box) — pinned by MarkdownContentViewParseTests #tables #tests
- [fact] Marker 0.9.0's dark-mode/appearance-adaptive theming lives entirely in the MarkerEditor product, which Scarf does not link — Scarf's own SwiftUI markdown rendering is already appearance-adaptive, so no dark-mode work was needed #theming

## Relations
- relates_to [[scarf/architecture/streaming-chat-ui-upserts-are-throttled-to-50ms-acp-chunk]]
- relates_to [[scarf/architecture/chat-transcript-activitybubble-segmentation]]
