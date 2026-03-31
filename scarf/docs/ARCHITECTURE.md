# Scarf — Architecture

## Pattern: MVVM-Feature

Per project standards, every feature is a self-contained module owning Models, ViewModels, and Views.

```
scarf/
  Core/
    Services/           Hermes data access (SQLite, file I/O, ACP)
    Models/             Plain data structs for Hermes entities
  Features/
    Dashboard/
      Views/            DashboardView
      ViewModels/       DashboardViewModel
    Sessions/
      Views/            SessionsView, SessionDetailView
      ViewModels/       SessionsViewModel
    Activity/
      Views/            ActivityView
      ViewModels/       ActivityViewModel
    Chat/
      Views/            ChatView
      ViewModels/       ChatViewModel
    Memory/
      Views/            MemoryView
      ViewModels/       MemoryViewModel
    Skills/
      Views/            SkillsView
      ViewModels/       SkillsViewModel
    Cron/
      Views/            CronView
      ViewModels/       CronViewModel
    Logs/
      Views/            LogsView
      ViewModels/       LogsViewModel
    Settings/
      Views/            SettingsView
      ViewModels/       SettingsViewModel
  Navigation/
    AppCoordinator.swift
    SidebarView.swift
```

## Navigation

`AppCoordinator` is `@Observable` and injected via `.environment()` at the app root. It owns:
- `selectedSection: SidebarSection` — which feature is active
- `selectedSessionID: String?` — drill-down into a session

One `NavigationSplitView` at top level, driven by the coordinator. Leaf views read but never own navigation state.

## Services

### HermesDataService
- Opens `~/.hermes/state.db` read-only via SQLite3 C API
- Queries `sessions` and `messages` tables
- Provides session list, message history, search (FTS5), and aggregate stats
- Polling-based refresh (watches WAL modification time)

### HermesFileService
- Reads config.yaml (simple line parser for the YAML subset we need)
- Reads/writes memory markdown files
- Reads cron jobs.json, gateway_state.json, session JSON files
- Reads skill directory structure

### HermesLogService
- Tails log files using file handle + periodic polling
- Parses log level from line format

### ACPClient
- Spawns `hermes acp` via Foundation `Process`
- Writes JSON-RPC to stdin, reads from stdout
- Streams events: ToolCallStart, ToolCallProgress, AgentMessage, AgentThought
- Manages session lifecycle

### HermesFileWatcher
- Uses `DispatchSource.makeFileSystemObjectSource` on key directories
- Triggers refresh callbacks when Hermes writes new data

## Dependencies

Zero external SPM packages:
- **SQLite**: System `sqlite3` C library (available on macOS, `import SQLite3` not needed — use `libsqlite3`)
- **JSON**: Foundation `JSONDecoder` / `JSONSerialization`
- **YAML**: Custom lightweight parser for flat config structure
- **Markdown**: `AttributedString(markdown:)` (built into Foundation)
- **File watching**: GCD `DispatchSource`
- **Subprocess**: Foundation `Process` + `Pipe`

## Sandbox

Disabled. This app reads directly from `~/.hermes/` which is outside any app sandbox container. The `ENABLE_APP_SANDBOX` build setting is set to `NO`.

## Concurrency

- Swift 6 strict concurrency with `@MainActor` default isolation
- Services use `nonisolated` methods with async/await for I/O
- `@Observable` ViewModels on MainActor, call into nonisolated services
- ACP client runs its read loop on a background task

## Data Flow

```
~/.hermes/state.db ──→ HermesDataService ──→ ViewModels ──→ Views
~/.hermes/config.yaml ──→ HermesFileService ──→ ViewModels ──→ Views
~/.hermes/memories/ ──→ HermesFileService ──→ ViewModels ──→ Views
~/.hermes/logs/ ──→ HermesLogService ──→ ViewModels ──→ Views
hermes acp (subprocess) ──→ ACPClient ──→ ChatViewModel ──→ ChatView
HermesFileWatcher ──→ triggers refresh on all services
```
