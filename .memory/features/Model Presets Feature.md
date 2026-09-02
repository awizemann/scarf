---
title: Model Presets Feature
type: note
permalink: scarf/features/model-presets-feature
tags: [models, presets, acp]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ModelPreset.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelPresetService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectModelPresetReader.swift, scarf/scarf/Core/Services/ProjectModelPresetBinding.swift, scarf/scarf/Features/Models/Views/ModelPresetsView.swift]
source_sha: 73ff36e8d264366ed074a105fe88d39d73b27f7b
created: 2026-05-29
updated: 2026-05-29
reviewed: 2026-09-02
reviewed_by: audit:claude-code (background)
---

## Observations
- [purpose] Scarf-owned overlay: users save named ModelPreset (id/name/modelID/providerID/notes) and bind one per project. Sits alongside global config.yaml default — unbound projects inherit unchanged #scope
- [storage] Presets persisted at ~/.hermes/scarf/model_presets.json (versioned ModelPresetStore envelope, mirrors SessionProjectMap shape). Path centralized as HermesPathSet.modelPresetsJSON #paths
- [service] ModelPresetService is a Sendable actor in ScarfCore: pure file I/O (list/get/upsert/delete). Missing file → empty list (not error); corrupt JSON → ModelPresetServiceError.corruptStore. Methods dispatch via Task.detached(priority:.utility) to keep MainActor off the read path #concurrency
- [binding] ProjectTemplateManifest gains optional modelPresetID: String? (UUID-as-string) at <project>/.scarf/manifest.json. Bound by id, NOT name — renames don't break bindings. Writer: ProjectModelPresetBinding (Mac). Cross-platform reader: ProjectModelPresetReader in ScarfCore #projects
- [application] PRIMARY surface is ACP session/set_model RPC, not env vars. HERMES_INFERENCE_MODEL is only read by oneshot.py for -z mode; ACP's _make_agent ignores it. Apply via ACPClient.setSessionModel(sessionId:modelID:) immediately after newSession returns sessionId, BEFORE unlocking the prompt #application #pitfalls
- [mid-chat] ChatModelBadge in SessionInfoBar shows active preset name or 'Default'. Tap → popover lists presets + 'Use global default'. Optimistic UI: badge flips immediately, reverts on RPC failure. 'Use global default' resolves config.yaml model name and sends that — there is no clear-override verb on session/set_model #ui
- [gating] Single flag HermesCapabilities.hasACPSetSessionModel (>= v0.13.0). Pre-v0.13 hosts hide: .models sidebar entry, 'Set Model…' context-menu in ProjectsSidebar, ChatModelBadge, and iOS ProjectDetailView 'Model:' line #gating
- [iOS] iOS surface is read-only — ProjectDetailView shows compact 'Model: <preset name>' line when binding exists. No CRUD or per-project rebinding in v1 (Mac-only) #ios
- [cron-deferred] Per-cron-job model override is DEFERRED. `hermes cron create/edit` accept no --model flag; top-level `hermes -m` only applies to -z/--tui. HermesCronJob.model: String? data field exists but no CLI write path #deferred
- [anti-patterns] Don't invent env-var injection in ACPClient+Mac.swift (silent no-op). Don't pass -m to `hermes acp` subcommand (top-level flag, ACP rejects). Don't bind by preset name (renames break refs). Don't try to 'clear' via RPC (no verb) #pitfalls

## Relations
- uses_capability [[Hermes Capability Gating Pattern]]
- relates_to [[Project-Scoped Chat and AGENTS.md Context]]
