---
title: Model Presets Feature
type: note
permalink: scarf/features/model-presets-feature
tags: [models, presets, acp]
source_paths: [scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelPresetService.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift]
source_paths_inferred: false
source_sha: 18806e7c4dbac0ffd6ff7e91c12d27440d0a8cc5
created: 2026-05-29
updated: 2026-09-12
reviewed: 2026-09-19
reviewed_by: audit:claude-code (background)
---

## Observations
- [purpose] Scarf-owned overlay: users save named ModelPreset (id/name/modelID/providerID/notes) and bind one per project. Sits alongside global config.yaml default — unbound projects inherit unchanged #scope
- [storage] Presets persisted at ~/.hermes/scarf/model_presets.json (versioned ModelPresetStore envelope, mirrors SessionProjectMap shape). Path centralized as HermesPathSet.modelPresetsJSON #paths
- [service] ModelPresetService is a Sendable actor in ScarfCore: pure file I/O (list/get/upsert/delete). Missing file → empty list (not error); corrupt JSON → ModelPresetServiceError.corruptStore. Methods dispatch via Task.detached(priority:.utility) to keep MainActor off the read path #concurrency
- [binding] ProjectTemplateManifest gains optional modelPresetID: String? (UUID-as-string) at <project>/.scarf/manifest.json. Bound by id, NOT name — renames don't break bindings. Writer: ProjectModelPresetBinding (Mac). Cross-platform reader: ProjectModelPresetReader in ScarfCore #projects
- [application] PRIMARY surface is ACP session/set_model RPC, not env vars. HERMES_INFERENCE_MODEL is only read by oneshot.py for -z mode; ACP's _make_agent ignores it. Apply via ACPClient.setSessionModel(sessionId:modelID:) immediately after newSession returns sessionId, BEFORE unlocking the prompt #application #pitfalls
- [mid-chat] ChatModelBadge in SessionInfoBar shows active preset name or 'Default'. Tap → popover lists presets + 'Use global default'. Optimistic UI: badge flips immediately, reverts on RPC failure. 'Use global default' resolves config.yaml model name and sends that — there is no clear-override verb on session/set_model #ui
- [gating] **UNGATED since P49 (round-5 decision 9, `c718237d`, 2026-09-12).** `hasACPSetSessionModel` was RETIRED and deleted: `set_session_model` is in `acp_adapter/server.py` at `:482` @ v2026.3.30 = **0.6.0**, Scarf's supported minimum, with a working body — so the "v0.13+" floor was a bug with a version number, hiding the `.models` sidebar entry, the 'Set Model…' context menu, `ChatModelBadge`, the Chat Settings item and the iOS `ProjectDetailView` 'Model:' line from every 0.6.0–0.12 host that has the RPC. All five surfaces now render unconditionally; no flag reads remain (`HermesP49Tests`). Historical: the flag was `>= v0.13.0` from the v0.15 cycle until P49 #gating
- [iOS] iOS surface is read-only — ProjectDetailView shows compact 'Model: <preset name>' line when binding exists. No CRUD or per-project rebinding in v1 (Mac-only) #ios
- [cron-deferred] Per-cron-job model override is DEFERRED. `hermes cron create/edit` accept no --model flag; top-level `hermes -m` only applies to -z/--tui. HermesCronJob.model: String? data field exists but no CLI write path #deferred
- [anti-patterns] Don't invent env-var injection in ACPClient+Mac.swift (silent no-op). Don't pass -m to `hermes acp` subcommand (top-level flag, ACP rejects). Don't bind by preset name (renames break refs). Don't try to 'clear' via RPC (no verb) #pitfalls

## Relations
- uses_capability [[Hermes Capability Gating Pattern]]
- relates_to [[Project-Scoped Chat and AGENTS.md Context]]


## t-3b855719: the actor was serializing nothing

- [gotcha] An `actor` serializes calls to ONE INSTANCE. Six call sites each constructed their own `ModelPresetService(context:)` (ChatViewModel, ChatModelBadge, ProjectModelPresetSheet, ProjectCockpitViewModel, ModelPresetsViewModel, iOS ProjectDetailView), so `model_presets.json` had six unserialized read-modify-write cycles over it — two overlapping upserts and the later full-file write dropped the earlier preset. Fixed with `ModelPresetService.shared(for: context)`, an NSLock-guarded per-`ServerContext` table; every call site now goes through it. Constructing the actor directly is still possible and still wrong. #concurrency
- [gotcha] `ModelPresetStoreReader.presetIDs()` still collapses "no store" and "unreadable store" to `[]` — the safe direction for a WRITE decision (skip, never dangle) — but it now LOGS the unreadable case and `probe()` returns `.presets/.absent/.unreadable` for callers that must tell them apart. `FleetApplyViewModel` has NOT been switched over: it would still tell the user "preset not on this host" for a host whose store merely failed to read.
