# Scarf — macOS GUI for the Hermes AI Agent

## Project Structure

```
scarf/scarf/           Xcode project root (PBXFileSystemSynchronizedRootGroup — auto-discovers files)
  scarf/               Main app target source
    Core/Services/     HermesDataService, HermesFileService, HermesLogService, ACPClient, HermesFileWatcher
    Core/Models/       Plain structs: HermesSession, HermesMessage, HermesConfig, etc.
    Features/          MVVM-F feature modules (Dashboard, Sessions, Activity, Chat, Memory, Skills, Cron, Logs, Settings)
    Navigation/        AppCoordinator, SidebarView
  docs/                PRD, Architecture, Discovery notes
  standards/           Copied development standards (read-only reference)
```

## Architecture Rules

- **MVVM-F**: Features never import sibling features. Cross-feature goes through services.
- **AppCoordinator**: Single `@Observable` coordinator for all navigation state, injected via `.environment()`.
- **No external dependencies**: System SQLite3, Foundation JSON, AttributedString markdown.
- **Read-only DB access**: Never write to `~/.hermes/state.db`. Only write to memory files and cron jobs.
- **Sandbox disabled**: App reads `~/.hermes/` directly.
- **Swift 6 concurrency**: `@MainActor` default. Services use `nonisolated` + async/await.

## Key Paths

- Hermes home: `~/.hermes/`
- SQLite DB: `~/.hermes/state.db` (WAL mode, read-only)
- Config: `~/.hermes/config.yaml`
- Memory: `~/.hermes/memories/MEMORY.md`, `~/.hermes/memories/USER.md`
- Sessions: `~/.hermes/sessions/session_*.json`
- Cron: `~/.hermes/cron/jobs.json`
- Logs: `~/.hermes/logs/errors.log`, `~/.hermes/logs/gateway.log`
- ACP: `hermes acp` subprocess (stdio JSON-RPC)

## Build

```bash
xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Debug build
```
