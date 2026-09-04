---
id: t-e5bc2ad4
title: Sidebar restructure: projects list in a well, collapsible sections, no secondary project sidebar
status: done
added: 2026-09-04
priority: high
---

## Description

Alan's spec (2026-09-04): (1) Projects becomes an inline LIST of projects in the main sidebar under a Projects header, the whole section in a well/container to stand out; (2) all other sections get collapse/expand — Monitor, Bots, Interact expanded by default; Configure, Manage collapsed by default (state persisted); (3) the secondary project sidebar is removed when in the projects area — the main-sidebar list is the navigation; (4) a New Project button within the projects list launches the existing new-project wizard. Precursor to the next release (after dogfooding this + t-05f33e75 + t-7e98ca69).

## Plan



## Artifacts

Implemented 2026-09-04. Build + tests green (scarfTests 745/745, ScarfCore 2176/2176, ScarfIOS builds clean).

New files:
- `scarf/scarf/Navigation/SidebarProjectsWell.swift` — the projects list in a well; absorbs everything the deleted second sidebar uniquely had (filter field, folder DisclosureGroups, Archived section, per-project context menu, add/remove) plus a "New Project" button wired to the existing `NewProjectSheet`, a compact registry-damage row, and the app's single mutation-failure alert. Also hosts `SidebarProjectNavigator`, the tested selection-routing seam.
- `scarf/scarf/Navigation/SidebarSectionCollapseStore.swift` — one UserDefaults key per section title; Monitor/Bots/Interact default expanded, Configure/Manage default collapsed.
- `scarf/scarfTests/SidebarRestructureTests.swift` — 9 tests (defaults, round-trip, namespacing, selection routing).

Changed: `SidebarView.swift` (well first, collapsible hand-rolled section headers with AX value/hint), `ContentView.swift` + `ProjectsView.swift` (shared `ProjectsViewModel` from the coordinator cache; HSplitView → full-width cockpit).
Deleted: `scarf/scarf/Features/Projects/Views/ProjectsSidebar.swift`.

Memory: extended the AppCoordinator VM-cache note and the macOS accessibility conventions note; added `conventions/sidebar-collapse-state-one-userdefaults-key-per-section`.

Known trade: replacing `List(selection:)` with Button rows loses arrow-key list navigation (rows stay Full-Keyboard-Access reachable). Recorded in the accessibility note.

