---
title: Core-Services
type: note
permalink: scarf-wiki/core-services
created: 2026-05-29
updated: 2026-05-29
---

# Core Services

The services in this layer are the data-and-side-effects bridge between Hermes and the SwiftUI features. Each takes a `ServerContext` (local, SSH, or Citadel) so the same service code works against a local install, a Mac SSH remote, or an iOS Citadel-driven remote.

In v2.5 most service code moved out of the Mac target into the shared **ScarfCore** SwiftPM package at [`scarf/Packages/ScarfCore/`](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore), so iOS reuses it byte-for-byte. A handful of Mac-only services (Sparkle wrapper, SwiftTerm bridge) stay in `scarf/scarf/Core/Services/`.

| Service | Isolation | Lines | Purpose |
|---|---|---|---|
| [`ACPClient`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Core/Services/ACPClient.swift) | `actor` | ~605 | Spawns `hermes acp` subprocess; JSON-RPC over stdio; async event stream for chat. |
| [`HermesDataService`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Core/Services/HermesDataService.swift) | `actor` | ~750 | Read-only SQLite queries against `state.db`; pulls atomic snapshots for remote; dedupes concurrent snapshot calls via a nested `SnapshotCoordinator` actor. _v2.5.2:_ falls back to the cached snapshot when a fresh pull fails (`isUsingStaleSnapshot` / `lastSnapshotMtime`); `fetchMessages` paginates by id desc with `HistoryPageSize` budgets; `refresh(forceFresh:)` lets chat-history reloads opt out of the fallback. |
| [`HermesEnvService`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Core/Services/HermesEnvService.swift) | `Sendable struct` | ~217 | Non-destructive `~/.hermes/.env` I/O — preserves comments and blanks; `unset` comments out instead of deleting. |
| [`HermesFileService`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Core/Services/HermesFileService.swift) | `Sendable struct` | ~620 | Parses `config.yaml` into typed nested structs (now including `platform_toolsets`); resolves `hermes` binary; enriches `$PATH` for spawned tools (brew/nvm/asdf). |
| [`HermesFileWatcher`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Core/Services/HermesFileWatcher.swift) | `@Observable` | ~122 | Local: FSEvents via `DispatchSourceFileSystemObject`. Remote: mtime polling over the SSH ControlMaster. Updates `lastChangeDate`; views observe and refresh. |
| [`HermesLogService`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Core/Services/HermesLogService.swift) | `actor` | ~173 | Tails `agent.log` / `errors.log` / `gateway.log`. Local: `FileHandle`. Remote: `ssh host tail -F` with partial-line buffering. |
| [`ModelCatalogService`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Core/Services/ModelCatalogService.swift) | `Sendable struct` | ~290 | Reads `~/.hermes/models_dev_cache.json` (~1500 models across ~110 providers) **and merges `HERMES_OVERLAYS`** — 6 provider entries (Nous Portal, OpenAI Codex, Qwen OAuth, Google Gemini CLI, GitHub Copilot ACP, Arcee) Hermes exposes via `hermes model` that aren't in the models.dev mirror. Helpers for cost + context-window display. _v2.5.2:_ `loadProvidersAsync()` and `loadModelsAsync(for:)` wrappers route the multi-MB JSON read off the MainActor — issue [#59](https://github.com/awizemann/scarf/issues/59). |
| [`NousSubscriptionService`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Core/Services/NousSubscriptionService.swift) | `Sendable struct` | ~85 | Read-only parser for `~/.hermes/auth.json` → `providers.nous`. Returns `NousSubscriptionState { present, providerIsNous, subscribed }`. Tool Gateway features gate on this. Hermes owns the write path (`hermes auth add nous`). |
| [`NousAuthFlow`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Core/Services/NousAuthFlow.swift) | `@Observable @MainActor` | ~200 | Drives the Nous Portal device-code sign-in. Spawns `hermes auth add nous --no-browser` with `PYTHONUNBUFFERED=1` (Python block-buffers without it, stalling the flow). Regex-extracts `verification_uri_complete` + `user_code` from stdout, auto-opens the browser via `NSWorkspace`, confirms success by re-reading `auth.json`, detects the `subscription_required` failure and extracts the billing URL. Parsers are `nonisolated static` for easy testing. |
| [`ProjectDashboardService`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Core/Services/ProjectDashboardService.swift) | `Sendable struct` | ~71 | Loads/saves the project registry and per-project `.scarf/dashboard.json`. |
| [`UpdaterService`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Core/Services/UpdaterService.swift) | `@MainActor @Observable` | ~41 | Thin Sparkle wrapper exposing the auto-check toggle, last-check date, and a "check now" trigger. |

## v2.9.0 additions (Hermes Proxy)

| Service | Isolation | Purpose |
|---|---|---|
| [`HermesProxyService`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Core/Services/HermesProxyService.swift) | `@MainActor @Observable` (Mac target) | Owns the long-running `hermes proxy start --provider <p> --host 127.0.0.1 --port 8645` child process for the new Configure → Hermes Proxy sidebar. Drains stderr through a readability handler into a 200-line capped log buffer (cap chosen so a misbehaving proxy can't drive memory growth); advertises `isRunning`, `endpoint: URL?`, `routedProvider: String?`, `lastError: String?` reactively so the view binds without re-publishing fields from a separate VM. Process spawn uses `HermesFileService.enrichedEnvironment()` so PATH inheritance works when Scarf was launched from Finder. **Local-only in v2.9** — SSH-deployed hosts would need port-forward wiring on top of starting the child; the panel renders an explanatory notice on non-local contexts instead of broken controls. Static defaults `defaultPort = 8645` and `defaultHost = "127.0.0.1"` mirror `hermes_cli/proxy/server.py`. The `nonisolated func listAvailableProviders() async -> [String]` helper probes `hermes proxy providers` for the adapter list (currently nous-only in v0.14; auto-refreshes when more land). Capability-gated on `HermesCapabilities.hasHermesProxy` (>= v0.14.0); the sidebar entry stays hidden on pre-v0.14 hosts. |

## v2.7.5 additions (Kanban v3)

| Service | Isolation | Purpose |
|---|---|---|
| [`KanbanService`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Services/KanbanService.swift) | `actor` (Sendable) in ScarfCore | Async wrapper around every Hermes v0.12 `kanban` verb — `list / show / runs / stats / assignees / log / create / assign / claim / comment / complete / block / unblock / archive / dispatch / link / unlink`. Each method dispatches its CLI invocation through `Task.detached(priority: .utility)` matching the existing concurrency conventions. Errors land in [`KanbanError`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Models/KanbanError.swift) and surface as inline banners (not modal alerts) since the board is high-frequency. The `"no matching tasks"` stdout sentinel is normalized to `[]` rather than thrown. Carries a pure `static func plan(for: KanbanTransition) throws -> KanbanTransitionPlan` that maps a `(from, to)` column pair to the right verb sequence — used by drag-drop in the board view and the "Start" button in the inspector. |
| [`KanbanTenantResolver`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Core/Services/KanbanTenantResolver.swift) | `Sendable struct` (Mac target) | Mints `scarf:<slug>` tenants on first kanban interaction inside a project and persists to `<project>/.scarf/manifest.json`'s new optional `kanbanTenant` field. Slug is lowercased / hyphenated / ≤48 chars; `scarf:` prefix prevents collision with hand-typed tenants. Once minted, the tenant is **immutable across rename** so existing tasks stay attributable to the project. Bare projects (no template manifest) get a sentinel manifest with `id: scarf/<project-id>` + `version: 0.0.0` — `ProjectAgentContextService` recognizes the sentinel and refuses to surface it as a "Template" line. |
| [`KanbanTenantReader`](https://github.com/awizemann/scarf/blob/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Services/KanbanTenantReader.swift) | `Sendable struct` in ScarfCore | Cross-platform read-only projection over `<project>/.scarf/manifest.json`'s `kanbanTenant` field. The full `ProjectTemplateManifest` Codable type lives in the Mac target; this lightweight reader gives iOS a way to filter the per-project board by tenant without linking the full manifest model. |

`LocalTransport` (in ScarfCore) also gains an `environmentEnricher: (() -> [String: String])?` static in v2.7.5, mirroring `SSHTransport.environmentEnricher`. Wired by `scarfApp.swift` at launch to the same `HermesFileService.enrichedEnvironment()` login-shell probe (`zsh -l -i` → `zsh -l` fallback) the SSH transport already uses. Without this, GUI-launched Scarf inherits macOS's launch-services PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) and child processes invoking `hermes` by bare name — notably the kanban dispatcher's worker spawn — fail with `executable not found on PATH` and record `outcome=spawn_failed`. Defense-in-depth: `LocalTransport.subprocessEnvironment(forExecutable:)` always prepends the executable's own directory to PATH if missing.

## v2.5.2 additions (in ScarfCore)

| Service | Isolation | Purpose |
|---|---|---|
| `ModelPreflight` | `Sendable enum` | Pre-flight check used before opening an ACP session. Hermes resolves model+provider from `config.yaml` at session boot; on a fresh install that file is missing or has the YAML parser's `"unknown"` fallback for those keys, and the chat fails with an opaque "Model parameter is required" 400 from the upstream provider only after the user has typed a prompt. Catches the missing config here so `ChatView` can surface a real "pick a model" sheet before any ACP work starts. Treats `""` and `"unknown"` as equivalent. |
| `NousModelCatalogService` | `Sendable struct` | Fetches `GET /v1/models` from `inference-api.nousresearch.com` using the bearer token in `auth.json`. Cached at `~/.hermes/scarf/nous_models_cache.json` with a 24h TTL; survives offline runs so the picker still has something to render. Used by `ModelPickerSheet`'s nous-overlay detail view to switch from a free-form TextField to a real model list (with a "Custom…" escape hatch for IDs not yet in the API response). |
| `ProjectHermesShadowDetector` | `Sendable struct` | Probes each registered project at chat-start for project-local Hermes config (`.hermes/` dir or `hermes.yaml` file) that would shadow the server-level config. Surfaces a banner explaining the shadow when found — a quiet failure mode pre-fix where users didn't realize Hermes prefers project-local config. |
| `HermesFileService.runHermesWithStdin` | `Sendable` (extension) | Runs a `hermes` subcommand with bytes piped via stdin. Used by the new remote profile import flow to pass the zip contents through SSH stdin rather than landing them on the remote disk first. |
| `ServerTransport.cachedSnapshotPath` | protocol additive | Implementations expose the path of the most recent successful `state.db` snapshot. `HermesDataService.refresh(forceFresh:)` falls back to the cache when a fresh pull fails, so Dashboard / Sessions / Activity stay readable while the SSH connection is down. `isUsingStaleSnapshot` + `lastSnapshotMtime` surface to the UI. |

## v2.5.2 additions (iOS-only — in ScarfIOS)

| Service | Purpose |
|---|---|
| `NetworkReachabilityService` | `NWPathMonitor` singleton. ScarfGo's reconnect loop suspends attempts while offline and kicks a fresh cycle on link-up. Two new banner states above the message list — `.reconnecting` and `.offline` — render slim ScarfDesign-tinted strips so the user always knows what the chat is doing. |

## v2.5.1 additions (in ScarfCore)

| Service | Isolation | Purpose |
|---|---|---|
| `HermesProfileResolver` | `Sendable enum` | Reads `~/.hermes/active_profile` and resolves the effective Hermes home path so every derived path (`stateDB`, `sessionsDir`, `configYAML`, `memoriesDir`, `cron/jobs.json`, `auth.json`, plugins, gateway state, logs) automatically follows the active Hermes v0.11+ profile. Validation regex mirrors `hermes_cli/profiles.py` exactly (`[a-z0-9][a-z0-9_-]{0,63}`); invalid or missing profiles fall back to `~/.hermes` with a logger warning. 5-second `OSAllocatedUnfairLock`-backed cache so frequent path-set construction doesn't hammer the filesystem. Backs `HermesPathSet.defaultLocalHome`. See [#50](https://github.com/awizemann/scarf/issues/50). |
| `SSHScriptRunner` | `Sendable enum` | Single shared entry point for running multi-line shell scripts on a `ServerContext`, **without** going through `ServerTransport.runProcess`'s argument quoting (which is correct for paths but mangles scripts containing `"$VAR"` references and nested quotes). Invokes `/usr/bin/ssh ... -- /bin/sh -s` directly with the script piped via stdin so it travels as opaque bytes. macOS-only via `#if os(macOS)` (`Foundation.Process` isn't on iOS); iOS uses Citadel transports for its own flows. Used by `ConnectionStatusViewModel` (15s heartbeat) AND `RemoteDiagnosticsViewModel` so both probes always agree on what the remote sees. See [#44](https://github.com/awizemann/scarf/issues/44). |

## v2.5 additions (in ScarfCore — shared across Mac + iOS)

| Service | Isolation | Purpose |
|---|---|---|
| `SessionAttributionService` | `Sendable struct` | Owns `~/.hermes/scarf/session_project_map.json`. Records which Hermes session belongs to which project so both clients render project badges and the per-project Sessions tab. Read on every Dashboard refresh; write when project-scoped chat starts a new session. |
| `ProjectAgentContextService` | `Sendable struct` | Idempotently maintains the `<!-- scarf-project:begin -->` block in `<project>/AGENTS.md`. Surfaces project name, dashboard path, configuration field names (never values — Keychain refs only), and registered cron jobs. Bounded so template-author content outside the markers is preserved across refreshes. |
| `CronScheduleFormatter` | `Sendable enum` | Pure-Swift cron-string → English translation. Recognizes the common shapes (`*/N * * * *`, `0 H * * *`, `0 H * * 1-5`, `@hourly` / `@daily` / `@weekly` / `@monthly`); falls back to the raw expression for anything custom. Used by Mac Cron Manager + iOS Cron list. |
| `GitBranchService` | `Sendable struct` | Single SSH `git rev-parse --abbrev-ref HEAD` per session start; surfaces the project's current branch as a chip in the chat header. Nil-out gracefully on non-git dirs / missing git / SSH errors. |
| `SkillSnapshotService` | `Sendable struct` | Per-server snapshot of `[skillId: signature]` (file count + sorted file names). When the snapshot changes between visits, the Skills tab shows a "What's New" pill. Persisted to `~/Library/Application Support/com.scarf/skill-snapshots/<serverID>.json` (Mac) / `UserDefaults` (iOS). |
| `SkillPrereqService` | `Sendable struct` | Probes for a host-side binary via the transport (`which <name>`); surfaces a yellow banner on a skill detail when a prerequisite is missing. Currently feeds the `design-md` skill's `npx` check; pluggable for future prereq surfaces. |
| `ProjectSlashCommandService` | `Sendable struct` | Reads / writes `<project>/.scarf/slash-commands/<name>.md` files with YAML frontmatter; expands `{{argument}}` and `{{argument \| default: "..."}}` substitutions; renders `<!-- scarf-slash:<name> -->` markers in expanded prompts so the agent can recognize them in transcripts. Used by Mac authoring tab + iOS read-only browser. See [Slash Commands](Slash-Commands). |
| `SpotifyAuthFlow` | `@Observable @MainActor` | Drives the Spotify OAuth handshake on Mac (5-state machine: starting → waiting → verifying → success / failure). Mirrors the v2.3 `NousAuthFlow` pattern. iOS surfaces a documentation row instead — phone OAuth flows are their own UX problem. |

## v2.5 additions (iOS-only — in ScarfIOS)

| Service | Purpose |
|---|---|
| `KeychainSSHKeyStore` | Per-server Ed25519 keypair persistence in the iOS Keychain (`com.scarf.ssh-key` service). Default accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` + `kSecAttrSynchronizable=false`; in v2.5.1 a `SSHKeyICloudPreference` opt-in (System → Security toggle) flips writes to `kSecAttrAccessibleAfterFirstUnlock` + `kSecAttrSynchronizable=true` so iCloud Keychain syncs the key across the user's Apple devices ([#52](https://github.com/awizemann/scarf/issues/52)). Read / list / delete queries unconditionally pass `kSecAttrSynchronizable=kSecAttrSynchronizableAny` so they match items regardless of sync state. v2 multi-server format: account `"server-key:<UUID>"`. Auto-migrates v1 (`"primary"` account) on first `listAll`. Public `migrateAllItems(toICloudSync:)` re-saves every stored bundle with target attributes — idempotent. |
| `CitadelSSHService` | Pure-Swift Ed25519 keypair generation + connection probes via Citadel. Used by Onboarding's "Generate Key" + "Test Connection" steps. |
| `CitadelServerTransport` | Citadel-backed implementation of `ServerTransport` — drives `executeCommandStream` for resilient stdout capture (preserves output on non-zero exit) and prepends `PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH` so non-interactive sessions resolve `hermes` and its sub-tools without sourcing user shell rc files. _v2.5.2:_ exposes `cachedSnapshotPath` so `HermesDataService` can fall back to the on-disk snapshot when an SSH pull fails. |

## v2.5.2 additions (in ScarfCore)

| Service | Isolation | Purpose |
|---|---|---|
| `ProjectHermesShadowDetector` | `Sendable struct` | Detects projects whose directory contains a `<project>/.hermes/` subdirectory. Hermes' CLI uses the closest `.hermes/` as `$HERMES_HOME` when invoked from inside such a project — credentials, config, sessions all bind to the project-local copy without warning, leaving Scarf's global probes ("No AI provider credentials detected") confusingly wrong. The detector enumerates registered projects via the transport, stats `<project>/.hermes/` for existence + directory-ness, and reports auth.json / state.db presence flags per shadow. Mac Dashboard surfaces the result as a yellow banner with a per-project "Copy fix command" affordance that emits the one-line consolidation command. Read-only — no auto-migration, the user decides what to keep. |

## v2.5.2 additions (iOS-only — in ScarfIOS)

| Service | Purpose |
|---|---|
| `NetworkReachabilityService` | Process-wide `NWPathMonitor` singleton. Publishes `isSatisfied` / `isExpensive` / `transitionTick` on the main actor (the path-update handler bounces back through `Task { @MainActor in ... }`). `ChatController.handleReachabilityChange` observes `transitionTick` to suspend in-flight reconnect attempts on link-down (every retry would burn a budget slot against a guaranteed failure) and kick a fresh cycle on link-up — so airplane-mode toggles and WiFi↔cellular handoffs recover automatically. Lives in ScarfIOS rather than ScarfCore because `Network.framework` doesn't ship on Linux. |

See [ScarfCore Package](ScarfCore-Package) for the package architecture and how to add a new shared service.

## Performance instrumentation (ScarfMon, v2.7+)

A separate harness lives at [`ScarfCore/Diagnostics/`](https://github.com/awizemann/scarf/tree/main/scarf/Packages/ScarfCore/Sources/ScarfCore/Diagnostics) — `ScarfMon.measure` / `measureAsync` / `event` wrap hot call sites in the chat path, transport, SQLite backend, and disk I/O. Three modes (`off`, `signpostOnly` (default), `full`) controlled from the in-app Diagnostics → Performance panel; the default is effectively free outside an Instruments session. See [Performance Monitoring](Performance-Monitoring) for the full reference, including the user capture recipe and the developer guide for adding new measure points.

## Patterns shared across the layer

- **`ServerContext` parameterizes all I/O.** Services receive the context at init; routing local vs. SSH happens through `context.transport`. See [Transport Layer](Transport-Layer).
- **Stateful services are `actor`s.** ACPClient, HermesDataService, and HermesLogService own resources (subprocesses, file handles, SQLite connections) that need serialized access; they expose async APIs.
- **Stateless services are `Sendable struct`s.** HermesEnvService, HermesFileService, ModelCatalogService, and ProjectDashboardService have no instance state worth coordinating; each call re-reads through the transport.
- **Schema tolerance.** `HermesDataService` checks for v0.7+ columns (`reasoning_tokens`, `actual_cost_usd`, `cost_status`, `billing_provider`) and degrades gracefully on older databases.
- **Snapshot dedup.** `SnapshotCoordinator` (nested in `HermesDataService`) ensures concurrent callers from Dashboard + Sessions + Activity await the same in-flight `sqlite3 .backup` rather than each spawning a fresh one.
- **Error hints over raw stderr.** `ACPClient` keeps a 50-line stderr ring buffer and pattern-matches into `ACPErrorHint` for user-friendly messages (missing `ANTHROPIC_API_KEY`, binary not on `PATH`, rate-limited).
- **Subprocess parsers are pure and testable.** `NousAuthFlow.parseDeviceCode` and `parseSubscriptionRequired` are `nonisolated static` functions over `String` → regex capture, so tests feed fixture stdout buffers without standing up a live subprocess. Same shape `OAuthFlowController.extractAuthURL` already uses for PKCE.

## Adding a service

See [Adding a Service](Adding-a-Service) for the recipe. Short version: take `ServerContext` in `init`, decide isolation (`actor` for stateful, `struct` for stateless), expose async public methods, route I/O through `context.transport`.

---
_Last updated: 2026-04-29 — Scarf v2.5.2 (ModelPreflight + NousModelCatalogService + ProjectHermesShadowDetector + NetworkReachabilityService; ModelCatalogService async wrappers; ServerTransport.cachedSnapshotPath)_