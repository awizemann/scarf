---
title: Capability-gated panes must reload on re-detect and canonicalise saved provider aliases
type: note
permalink: scarf/conventions/capability-gated-panes-must-reload-on-re-detect-and
tags: [capabilities, conventions, hermes-v0-21-5]
source_paths: [scarf/scarf/Features/MCPServers/Views/MCPServersView.swift, scarf/scarf/Features/MCPServers/ViewModels/MCPServersViewModel.swift, scarf/scarf/Features/Settings/Views/Components/ModelPickerSheet.swift]
source_paths_inferred: false
source_sha: 12018c8f8fa9d17404a94138589a6d39f7a61d97
created: 2026-09-26
updated: 2026-09-26
reviewed: 2026-09-27
reviewed_by: audit:claude-code (background)
---

## Observations
- [convention] A pane whose parse or UI depends on HermesCapabilities must re-load in `.onChange(of: capabilitiesStore?.capabilities)`, not only in `.onAppear`: the `hermes --version` probe is async on first connect and a host upgrade is re-detected mid-session, and a `hasLoaded` latch otherwise freezes the first (often `.empty`) reading. Precedents: HealthView, SkillsView, MCPServersView #capabilities
- [convention] A view model that reloads after its own mutations must reuse the capabilities it was last given (store them on the VM); a bare `load(force: true)` that falls back to `.empty` silently reverts every gated reading #capabilities
- [convention] Match a saved `model.provider` against a loaded catalog literally first, and canonicalise via `ModelCatalogService.canonicalProviderID(_:capabilities:)` only when nothing matches — alias spellings (chatgpt, kimi, moonshot) are never catalog rows. Pattern: `ModelPickerSheet.resolveInitialProviderID`; ModelPresetEditSheet may still need it #model-picker

## Relations
- relates_to [[Hermes v0.21.4/v0.21.5 Compatibility Decisions]]
- relates_to [[Hermes Capability Gating Pattern]]
