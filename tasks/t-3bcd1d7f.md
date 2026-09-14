---
id: t-3bcd1d7f
title: Add a source→catalogue localization coverage test
status: todo
added: 2026-09-11
---

## Description

`LocalizationCatalogTests` gates the catalogue INTERNALLY — it proves every key already in `scarf/scarf/Localizable.xcstrings` carries all six locales, has matching format specifiers, and so on. Nothing proves the reverse direction: that every `String(localized:)` / `LocalizedStringKey` literal in the sources HAS an entry in the catalogue.

That hole is how P39 shipped two user-facing strings (`SettingsViewModel.managedBannerText`, the managed-banner accessibility label in `SettingsView`) with no catalogue entry at all — invisible to every existing gate. The round-4 review caught it by hand; P39's remediation added the entries (`fix(p39): the round-4 review of P39's own two commits`) plus a targeted three-key assertion in `HermesManagedLockP39bTests`, and the round-4 brief explicitly deferred building the general gate.

What it needs: a scan of `scarf/scarf/`, `scarf/Scarf iOS/` and `scarf/Packages/ScarfCore/Sources/` for `String(localized: "…")` and bare-literal `LocalizedStringKey` sites (`Text("…")`, `.help("…")`, `.accessibilityLabel("…")`, `Button("…")`, `Label("…", systemImage:)`), each mapped to its catalogue key with `\(x)` → `%@`, asserting presence. `LocalizationCatalogTests` already has a partial version of the machinery (`recoveredKeysArePresent`, `iosOnlyKeysAreStillInTheCatalog`) to build on. The calibration problem is real — interpolation, multi-line literals and non-UI strings all need exclusions — which is why it is its own task and not a drive-by.

## Plan

## The `.help(…)` backlog P50 handed over (2026-09-12, count corrected by P50b)

P50 was asked to decide whether the round-5 report's "18 unlocalized `.help(…)` literals" were a mechanical six-locale pass. They are not, so they are filed here.

**P50 said 28 sites across 20 files. The real number is 21 across 15 files.** P50's scan mapped every `\(x)` to `%@`, so every `.help(…)` carrying an `Int` interpolation — whose catalogue key is `%lld` — was reported missing when it is present, and the scan's string parser stopped at the first `"` so a literal containing an escaped `\"` was truncated into a key that could never match. Re-run by P50b with `%lld`/`%@` inference over every interpolation (a key is present when ANY assignment of the two specifiers is in the catalogue) and an escape- and interpolation-aware literal reader:

- `Features/Chat/Views/RichChatInputBar.swift:126`
- `Features/CredentialPools/Views/CredentialPoolsView.swift:548`
- `Features/Gateway/Views/GatewayView.swift:183`
- `Features/Health/Views/HealthView.swift:91`
- `Features/Health/Views/HermesCapabilitiesPanel.swift:43`
- `Features/Kanban/Views/KanbanInspectorPane.swift:855`
- `Features/MCPServers/Views/MCPServerDetailView.swift:112`
- `Features/Plugins/Views/PluginsView.swift:323`
- `Features/Settings/Views/Tabs/AdvancedTab.swift:59`, `:129`, `:141`, `:287`, `:292`
- `Features/Settings/Views/Tabs/AgentTab.swift:227`, `:237`
- `Features/Settings/Views/Tabs/DisplayTab.swift:118`, `:143`, `:158`
- `Features/Settings/Views/Tabs/VoiceTab.swift:32`
- `Features/Skills/Views/SkillsView.swift:70`
- `Navigation/SidebarProjectsWell.swift:198`

Nine sites P50 listed are already catalogued and are OFF the list: `RichChatInputBar:497`, `KanbanCardView:367`, `ChatSessionListPane:546`, `SessionsView:794`, `DashboardView:709`, `SessionInfoBar:394`, `ProfileRoutesSection:293`, `RichMessageBubble:296`, and the two `SessionInfoBar` escaped-quote literals (`:170`, `:181`) the old parser mangled. `HermesCapabilitiesPanel:43` is NEW to the list — P50's scan missed it.

**One of the reviewer's nine is not catalogued and stays:** `MCPServerDetailView:112` is `.help("Sign in")`, and the catalogue holds `"Sign In"` (capital I) — a different key. That one is a real miss, and the cheapest of the 21.

Why this belongs here and not in a drive-by: several carry `^[%@ time](inflect: true)` morphology in their sibling keys, and the key spelling for those is exactly the calibration problem this task exists to solve.

**The machinery already exists.** `scarf/scarfTests/HermesP50bTests.swift` (`FleetApplyExecutorCatalogueP50bTests`) is the working, tested version of it, scoped to one file: `localizedLiterals(in:)` reads `String(localized: "…")` literals interpolation- and escape-aware (so `set board \(source.board ?? "")` survives), and `candidateKeys(for:)` enumerates the `%lld`/`%@` assignments. Generalise those two functions to `Text(…)`, `.help(…)`, `.accessibilityLabel(…)`, `Button(…)`, `Label(…, systemImage:)` across `scarf/scarf/`, `scarf/Scarf iOS/` and `scarf/Packages/ScarfCore/Sources/`, then make it a gate and backfill the 21.

`KanbanInspectorPane.swift:257` (the completion-contract `.help`) is NOT in this list — P50 verified it was fixed in P46 and carries all six locales.

## Artifacts



