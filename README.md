# Scarf

A native macOS companion app for the [Hermes AI agent](https://github.com/hermes-ai/hermes-agent). Scarf gives you full visibility into what Hermes is doing, when, and what it creates — replacing CLI opacity with a clean, native interface.

![macOS](https://img.shields.io/badge/macOS-26.2+-blue) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Dashboard** — System health, token usage, cost tracking, recent sessions at a glance
- **Sessions Browser** — Full conversation history with message rendering, tool call inspection, and full-text search (FTS5)
- **Activity Feed** — Real-time tool execution log with filtering by kind (read/edit/execute/fetch/browser) and detail inspector
- **Live Chat** — Embedded terminal running `hermes chat` with full ANSI color and Rich formatting via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
- **Memory Viewer/Editor** — View and edit Hermes's MEMORY.md and USER.md with live refresh
- **Skills Browser** — Browse all installed skills by category with file content viewer
- **Cron Manager** — View scheduled jobs, their status, prompts, and output
- **Log Viewer** — Real-time tailing of error and gateway logs with level filtering
- **Settings** — Read-only config display with raw YAML viewer and Finder path links
- **Menu Bar** — Status icon showing Hermes running state with quick actions

## Requirements

- macOS 26.2+
- Xcode 26.3+
- [Hermes agent](https://github.com/hermes-ai/hermes-agent) installed at `~/.hermes/`

## Building

```bash
git clone https://github.com/yourusername/scarf.git
cd scarf/scarf
open scarf.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Debug build
```

## Architecture

Scarf follows the **MVVM-Feature** pattern with zero external dependencies beyond SwiftTerm:

```
scarf/
  Core/
    Models/       Plain data structs (HermesSession, HermesMessage, HermesConfig, etc.)
    Services/     Data access (SQLite reader, file I/O, log tailing, file watcher)
  Features/       Self-contained feature modules
    Dashboard/    System overview and stats
    Sessions/     Conversation browser with detail view
    Activity/     Tool execution feed with inspector
    Chat/         Embedded terminal via SwiftTerm
    Memory/       Memory viewer and editor
    Skills/       Skill browser by category
    Cron/         Scheduled job viewer
    Logs/         Real-time log viewer
    Settings/     Configuration display
  Navigation/     AppCoordinator + SidebarView
```

### Data Sources

Scarf reads Hermes data directly from `~/.hermes/`:

| Source | Format | Access |
|--------|--------|--------|
| `state.db` | SQLite (WAL mode) | Read-only |
| `config.yaml` | YAML | Read-only |
| `memories/*.md` | Markdown | Read/Write |
| `cron/jobs.json` | JSON | Read-only |
| `logs/*.log` | Text | Read-only |
| `gateway_state.json` | JSON | Read-only |
| `skills/` | Directory tree | Read-only |
| `hermes chat` | Terminal subprocess | Interactive |

The app **never writes** to `state.db` — it opens in read-only mode to avoid WAL contention with Hermes.

### Dependencies

| Package | Purpose |
|---------|---------|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Terminal emulator for the Chat feature |

Everything else uses system frameworks: SQLite3 C API, Foundation JSON, AttributedString markdown, GCD file watching.

## How It Works

Scarf is a passive observer. It watches `~/.hermes/` for file changes and polls the SQLite database for new sessions and messages. The Chat tab spawns `hermes chat` as a subprocess in a pseudo-terminal, giving you the full interactive Hermes CLI experience with proper ANSI rendering.

The app sandbox is disabled because Scarf needs direct access to `~/.hermes/` and the ability to spawn the Hermes binary.

## Contributing

Contributions are welcome. Please open an issue to discuss what you'd like to change before submitting a PR.

1. Fork the repo
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -m 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

## License

[MIT](LICENSE)
