---
title: UI gate: section root identifiers and the Smoke/Full/Live test plans
type: note
permalink: scarf/conventions/ui-gate-section-root-identifiers-and-the-smoke-full-live
tags: [testing, xcuitest, a11y, release, test-plans]
source_paths: [scarf/scarf/ContentView.swift, scarf/scarfUITests/UITestIsolation.swift]
source_paths_inferred: false
source_sha: 09bc6bed5dd25c3aa33c4d09c861cd37c8bc0383
created: 2026-09-08
updated: 2026-09-08
reviewed: 2026-09-08
reviewed_by: claude-fable-5-1
---

Shipped 2026-09-08 (t-e732e091, UI gate phase 1b). Smoke = SectionSweepUITests only, ~143 s of test time on Alan's Mac (~2:50 wall with an incremental build); Full = scarfTests + scarfUITests (the scheme default, so bare `xcodebuild test` now runs UI tests too); Live = Full plus `SCARF_UITEST_LIVE=1`. Run one with `xcodebuild test -project scarf/scarf.xcodeproj -scheme scarf -destination 'platform=macOS' -testPlan <Smoke|Full|Live>`.

## Observations
- [convention] Every routed section is addressable as `<SidebarSection.rawValue>.root` — carried by a 1×1 transparent marker OVERLAY on ContentView's detail container (not an identifier on the container itself, which rewrites every descendant's identifier — see the runner-gotchas note), so a newly routed section is sweepable with no per-view edit and in-section identifiers survive #testing #a11y
- [convention] The section list crosses into the UI-test bundle as `scarf/scarfUITests/Resources/Sections.json` (the bundle links neither the app nor ScarfCore); `SectionCatalogTests` in scarfTests fails the fast UNIT run if it drifts from `SidebarSection.allCases` or its order #testing
- [convention] User-facing load-failure banners carry `error.banner`; the section sweep asserts none is on screen after switching, which is how a rendered-but-broken section fails the gate #testing
- [convention] Full takes the whole scarfUITests target (Live-gated suites skip themselves via `ScarfUITestCase.requireLive()`), so an ordinary journey never edits a plan. Live (changed 2026-09-08) lists ONLY the Live-gated suites — ChatJourneyUITests, LiveGateUITests — in its selectedTests with `SCARF_UITEST_LIVE=1`: re-running all of Full a second time doubled the exposure to runner-side failures ("Lost connection to the application" then "Not authorized for performing UI testing actions" on every later test) for no coverage. A new Live-only suite must be added to Live.xctestplan #testing
- [gotcha] The sweep forces sidebar sections open with `-sidebar.section.collapsed.<Title> 0` launch args (NSArgumentDomain, never written back). Those values arrive as the STRING "0", which `object(forKey:) as? Bool` rejects — the override silently did nothing until `SidebarSectionCollapseStore.storedBool` coerced strings (2026-09-08). Never fall back to clicking headers: the app under test shares com.scarf.app with the installed copy, so a click persists into the DEVELOPER's real UserDefaults, which `SCARF_HERMES_HOME` does not isolate; the sweep now fails loudly on a collapsed header instead #testing #gotcha

## Relations
- relates_to [[UI release gate: XCUITest is the gate, Harness is exploratory, fixture home built by the hermes CLI]]
- relates_to [[Fast test-iteration commands (swift test vs xcodebuild)]]
- relates_to [[Sidebar collapse state: one UserDefaults key per section, never one blob]]
