---
title: Sidebar collapse state: one UserDefaults key per section, never one blob
type: note
permalink: scarf/conventions/sidebar-collapse-state-one-userdefaults-key-per-section
tags: [navigation, swiftui, macos, userdefaults]
source_paths: [scarf/scarf/Navigation/SidebarSectionCollapseStore.swift, scarf/scarf/Navigation/SidebarView.swift, scarf/scarf/Navigation/SidebarProjectsWell.swift]
source_paths_inferred: false
source_sha: 94c88e7f1322110b4bfd71534d632d453bdc177e
created: 2026-09-04
updated: 2026-09-04
reviewed: 2026-09-12
reviewed_by: audit:claude-code (background)
---

From t-e5bc2ad4 (2026-09-04), which made every main-sidebar nav section collapsible and moved the project list into a well. The persistence shape is the part that is easy to get wrong in a capability-gated sidebar.

## Observations
- [decision] Sidebar collapse state persists as ONE UserDefaults key per section title (`sidebar.section.collapsed.<Title>`), not one array of collapsed titles — sections are capability-gated and appear when the window's Hermes host changes, so "absent" has to keep meaning "use this section's default"; with a blob, a section the user has never seen inherits whatever the blob happened to say #navigation
- [gotcha] Read the key via the `storedBool()` helper, which coerces both NSNumber (from UserDefaults writes) and String values (from NSArgumentDomain command-line overrides like `-sidebar.section.collapsed.Manage 0`) to Bool; never use `bool(forKey:)` which maps "never written" to false and forces default-collapsed sections (Configure, Manage) open on first launch. The String-to-Bool path exists so UI test sweeps can force all sections open via args without touching saved preferences #userdefaults #testing
- [convention] Persist an explicit choice even when it equals the current default; only the OBSERVED `@Observable` mirror gets the equality guard. Skipping the write means a later change to the defaults table silently moves a section the user had already placed #userdefaults
- [constraint] Collapse state is a per-user UI convenience, not trust-bearing — UserDefaults is correct, no Keychain and no integrity MAC; a missing or corrupt value simply falls back to the section default. It is shared app-wide rather than per-window, because two windows disagreeing about whether Configure is open reads as a bug #navigation
- [gotcha] A `ScrollView` given a flat `.frame(maxHeight:)` is greedy along its scroll axis and reserves the FULL height even for short content — clamping a nested list needs `.frame(height: min(cap, estimatedContentHeight))`, or a barely-over-threshold list draws a slab of empty container under it #swiftui
- [note] The Projects section header now functions as a nav button to the Projects cockpit (accessibility ID `sidebar.section.Projects`), fixing a gap where the cockpit was unreachable on empty registries and UI tests couldn't select the section #testing #accessibility

## Relations
- relates_to [[Cache feature VMs in AppCoordinator to stop re-fetch on sidebar section switches]]
- relates_to [[macOS Accessibility Label Conventions]]
