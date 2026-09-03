---
created: 2026-09-03
updated: 2026-09-03
source_sha: 7b1be630ce477231a804649efe75285f95c410b5
source_paths: scarf/Packages/ScarfCore/Sources/ScarfCore/Services, scarf/scarf/Core/Services
source_paths_inferred: false
---

# Services Layer — Hermes Integration & Business Logic

Services are the integration boundary with Hermes. They live in two places:
- **ScarfCore** — Cross-platform business logic: `BotsService`, `CuratorService`, `BotAgentConfigService`, `FleetService`, config readers, backends.
- **macOS target** (`scarf/Core/Services/`) — Analytics, catalog caching, app-specific services.

## Core Services (ScarfCore)

**BotsService** (`Services/BotsService.swift:18`) — Bot lifecycle management.
- `scan()` returns `[BotRosterEntry]` (name, avatar, last-active timestamp).
- `create(name:soul:toolset:mcpEnabled:modelPin:)` creates a new bot profile.
- `edit(id:)` updates an existing bot's SOUL.md and settings.
- Stateless; no caching — each call hits `state.db` and reads profile.yaml.

**BotAgentConfigService** (`Services/BotAgentConfigService.swift:59`) — Bot-scoped model + provider config.
- Merges global `config.yaml` model defaults with per-bot overrides from `profile.yaml:ui_meta['hermes-bots'][botID]['model_pin']`.
- Returns typed `BotAgentConfig` with pinned model ID, rationale, and fallback chain.

**CuratorService** (`Services/CuratorService.swift:21`) — Skill curation (archive, prune, consolidate).
- Polls `HERMES_HOME/skills/` for idle skills.
- `archive()`, `restore()`, `prune()`, `purge()` state transitions.
- Reads curator state from `.json` files; invokes CLI commands to write.

**FleetService** (`Services/FleetService.swift:??`) — Multi-server project grouping.
- Takes an injected `[ServerContext]` (all servers the user has added).
- Groups projects by `rootPath` (the "portfolio dimension") across servers (the "fleet dimension").
- Flags config drift; enables one-click model preset push to entire fleet.

**Backends** (`Services/Backends/`) — SQL query abstraction.
- `HermesQueryBackend` — Protocol for querying `state.db`.
- `LocalSQLiteBackend` — Opens the local `~/.hermes/state.db` file directly.
- `RemoteSQLiteBackend` — Fetches atomic snapshots from remote via SSH and queries them locally.

**Config Reading** (`Services/HermesConfigReader.swift`, `scarf/Core/Services/HermesConfig.swift`)
- ScarfCore's `HermesConfigReader` (remote-only) reads raw YAML and falls back through SSH, scp, direct file.
- The Mac target's `HermesConfig` parses the YAML into typed structs (models, providers, workflows, etc.).
- **Never duplicate the parser** — always route through the one source of truth. [[mac-config-reads-go-through-hermesconfig]]

## macOS-Specific Services

**Analytics** (`scarf/Core/Services/Analytics.swift:34`) — The injectable seam for ScarfAnalytics.
- Provides `CoreBridge: ScarfAnalyticsRecording` implementation.
- Calls the Stats framework to record usage events.
- ScarfCore never imports Stats; only the Mac app bridges them. [[analytics-via-swift-stats]]

**CatalogService** (`scarf/Core/Services/CatalogService.swift:51`) — Template catalog caching.
- Fetches and caches `catalog.json` from a remote source.
- `load()` returns cached version if fresh, fetches otherwise.

## Key Patterns

**Nonisolated public methods** — Every service's public methods are `nonisolated`, so blocking I/O (file reads, SSH round-trips, SQL queries) doesn't freeze the UI. Callers dispatch to background via `.task`.

**Service injection via ServerContext** — Services accept `ServerContext` in their initializer, allowing the same code to work against local `~/.hermes` or a remote host over SSH.

**Config reads survive invisible config.yaml** — If `config.yaml` doesn't exist, fallback chain provides sensible defaults. [[config-reads-must-survive-an-invisible-config-yaml]]

**YAML dotted-key parsing** — `ConfigDottedKeySegment` (`Services/ConfigDottedKeySegment.swift:43`) parses keys like `models.openai.api_key` into a parse tree, allowing the config editor to display and modify deeply-nested keys.

## Testing Services

Inject mock `ServerContext.local(home: tempDir)`. Services use this to read test fixtures from the temp home, leaving production unchanged.