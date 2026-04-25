<p align="center">
  <img src="icon.png" width="128" height="128" alt="Scarf app icon">
</p>

<h1 align="center">Scarf</h1>

<p align="center">
  A native macOS companion app for the <a href="https://github.com/hermes-ai/hermes-agent">Hermes AI agent</a>.<br>
  Full visibility into what Hermes is doing, when, and what it creates.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.6+%20Sonoma-blue" alt="macOS">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
  <br>
  <em>Available in English, 简体中文, Deutsch, Français, Español, 日本語, and Português (Brasil).</em>
  <br><br>
  <a href="https://www.buymeacoffee.com/awizemann"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" height="28"></a>
</p>

## What's New in 2.5

- **ScarfGo, the iPhone companion, ships in public TestFlight.** Same Hermes server you've been running on your Mac — now reachable from your phone over SSH. Multi-server, project-scoped chat, session resume, memory editor, cron list, skills tree, settings (read), all native iOS. Pure-Swift SSH (Citadel under the hood — no `ssh` binary needed on iOS). Per-project chat writes the same Scarf-managed `AGENTS.md` block the Mac app does, so the agent boots with the same project context regardless of which client opened the session. **TestFlight invite + onboarding walkthrough:** [ScarfGo wiki page](https://github.com/awizemann/scarf/wiki/ScarfGo).
- **Portable project-scoped slash commands.** Author reusable prompt templates as Markdown files at `<project>/.scarf/slash-commands/<name>.md` with YAML frontmatter (name, description, argumentHint, optional model override). Invoke as `/<name> [args]` from chat — Scarf substitutes `{{argument}}` (with optional `default:` fallback) in the body and sends the expanded prompt to Hermes. Mac authoring tab + iOS read-only browser. Templates carry them via the new `slash-commands/` block in `.scarftemplate` bundles (schemaVersion 3).
- **Hermes v2026.4.23 chat parity.** `/steer` non-interruptive guidance command, per-turn stopwatch on assistant bubbles, numbered keyboard shortcuts (1–9) on the permission sheet, git branch chip in the chat header. The new `messages.reasoning_content` and `sessions.api_call_count` columns surface as a richer reasoning disclosure + an "API" chip on session rows.
- **Spotify + design-md skills.** Mac ships an in-app Spotify OAuth sheet (mirrors the v2.3 Nous Portal pattern); design-md gets a host-side `npx` prereq check on both platforms. SKILL.md frontmatter (`allowed_tools`, `related_skills`, `dependencies`) renders as chip rows. A "What's New" pill on the Skills tab tells you when remote skills changed since you last looked.
- **Mac global Sessions: project filter + project badges** — parity with ScarfGo's Sessions tab. The list grows a filter Menu (All projects / Unattributed / each registered project) and each row carries a tinted folder chip with the project name when attributed.
- **Human-readable cron schedules everywhere.** New `CronScheduleFormatter` in ScarfCore translates the common cron shapes into English phrases and falls back to the raw expression on anything custom. Mac and iOS render the same.
- **Under the hood** — `SessionAttributionService`, `ProjectContextBlock`, `CronScheduleFormatter`, `GitBranchService`, `SkillPrereqService`, `SkillSnapshotService`, `ProjectSlashCommandService`, and the ACP error triplet (`acpError` / `acpErrorHint` / `acpErrorDetails`) consolidated into ScarfCore so Mac and iOS consume one source of truth. 179 tests across 13 suites, three consecutive green runs. Several `try?` swallows in iOS lifecycle code now surface real failures (Keychain unlock errors no longer drop people into onboarding; partial Forget operations report what failed).
- **iOS push notifications skeleton** — `NotificationRouter` ships with foreground presentation + a lock-screen "Approve / Deny" action category gated by `apnsEnabled = false`. Lights up when Hermes ships a server-side push sender + an APNs cert.

See the full [v2.5.0 release notes](https://github.com/awizemann/scarf/releases/tag/v2.5.0), the [ScarfGo wiki page](https://github.com/awizemann/scarf/wiki/ScarfGo), and [Platform Differences](https://github.com/awizemann/scarf/wiki/Platform-Differences) for what is and isn't shared between Mac and iOS.

### Previously, in 2.3

- **Projects sidebar grows up** — group projects into folders, rename / archive / unarchive in place, filter the list with ⌘F, jump to the first nine with ⌘1–⌘9. Archived projects hide by default; a toggle in the bottom bar surfaces them. Non-destructive on the v2.2 registry file — downgrade stays clean.
- **Per-project Sessions tab** — alongside Dashboard and Site. Shows chats attributed to the project, with a **New Chat** button that spawns `hermes acp` with the project's directory as the session cwd and attributes the result via a Scarf-owned sidecar (`~/.hermes/scarf/session_project_map.json`). Click any listed session to resume it with project context automatically restored.
- **Agent actually knows what project it's in** — the architectural headline. Every project-scoped chat gets a Scarf-managed block auto-injected into the project's `AGENTS.md` before the session starts. Hermes reads AGENTS.md from the session's cwd at startup and picks up the block as part of its system prompt. Ask the agent *"what project am I in?"* and it answers with the project name, directory, template id + version, configuration field names, and registered cron jobs — pulled from the injected block. Secret-safe (field names only, never values), idempotent, bounded to `<!-- scarf-project:begin/end -->` markers so template-author content outside the block is preserved across refreshes.
- **Project indicator in Chat** — folder chip in `SessionInfoBar` and `Chat · <ProjectName>` in the nav title when you're in a project-scoped chat. Resumed sessions keep the indicator by looking up the attribution sidecar at resume time.
- **Tool Gateway — Nous Portal support** — Hermes v0.10.0 introduced subscription-routed tools (web search, image gen, TTS, browser automation). Scarf 2.3 merges Hermes's provider-overlay table into the model picker so **Nous Portal + 5 other previously-invisible providers** now appear, and ships a dedicated **Sign in to Nous Portal** sheet that runs the device-code flow end-to-end in-app — no terminal. Each of the 8 auxiliary sub-model tasks gets a per-task Nous toggle, a Tool Gateway card lands in Health, and Credential Pools' silent-fail dead-end for device-code providers is closed. Scarf's existing messaging-gateway section is renamed **Messaging Gateway** to disambiguate from the new Tool Gateway.
- **Window-layout cleanup** — switching to Chat or a Sessions tab no longer grows the window past the screen. `.windowResizability(.contentMinSize)` + targeted `idealHeight` caps keep the window's floor at a sensible content minimum while letting users freely drag larger or smaller.

See the full [v2.3.0 release notes](https://github.com/awizemann/scarf/releases/tag/v2.3.0). Earlier release summaries (1.6 / 2.0 / 2.1 / 2.2) live at [Release Notes Index](https://github.com/awizemann/scarf/wiki/Release-Notes-Index) on the wiki.

## Multi-server, one window per server

Scarf 2.0 is a multi-window app. Each window is bound to exactly one Hermes server — your local `~/.hermes/` is synthesized automatically, and you can add remotes via **File → Open Server…** → **Add Server** (host, user, port, optional identity file). Open a second window for a different server and the two run side-by-side with independent state.

Remote Hermes is reached over system SSH — the same `~/.ssh/config`, ssh-agent, ProxyJump, and ControlMaster pooling your terminal uses. File I/O flows through `scp`/`sftp`; SQLite is served from atomic `sqlite3 .backup` snapshots cached under `~/Library/Caches/scarf/snapshots/<server-id>/`; chat (ACP) tunnels as `ssh -T host -- hermes acp` with JSON-RPC over stdio end-to-end. Everything in the feature list below works against remote identically to local.

### Remote setup requirements

The remote host must have:

1. **SSH access** — key-based auth via your local ssh-agent. Scarf never prompts for passphrases; run `ssh-add` once in Terminal before connecting.
2. **`sqlite3`** on the remote `$PATH` — needed for the atomic DB snapshots. Install on the remote with `apt install sqlite3` (Ubuntu/Debian), `yum install sqlite` (RHEL/Fedora), or `apk add sqlite` (Alpine).
3. **`pgrep`** on the remote `$PATH` — used by the Dashboard "is Hermes running" check. Standard on every distro; install `procps` if missing.
4. **`~/.hermes/` readable by the SSH user**. When Hermes runs as a separate user (systemd service, Docker container), the SSH user needs read access to `config.yaml` and `state.db`. Either (a) SSH as the Hermes user, (b) `chmod` Hermes's home to be group-readable and add your SSH user to that group, or (c) set the **Hermes data directory** field when adding the server to point at the right location (e.g. `/var/lib/hermes/.hermes`).

### Troubleshooting remote connections

If the connection pill is green but the Dashboard shows "Stopped", "unknown", or empty values, the SSH user can't read the Hermes state files. Open **Manage Servers → 🩺 Run Diagnostics** (or click the yellow "Can't read Hermes state" pill in the toolbar). The diagnostics sheet runs fourteen checks in one SSH session — connectivity, `sqlite3` presence, read access to `config.yaml` and `state.db`, the effective non-login `$PATH` — and tells you exactly which one fails and why, with remediation hints for each. Use the **Copy Full Report** button to paste the full output into a bug report.

For the common "Hermes isn't at the default path" case (systemd services, Docker), **Test Connection** in the Add Server sheet now probes `/var/lib/hermes/.hermes`, `/opt/hermes/.hermes`, `/home/hermes/.hermes`, and `/root/.hermes` when it can't find `state.db` at `~/.hermes/`, and offers a one-click fill if it finds any of them.

## Features

Scarf mirrors Hermes's surface area through a sidebar-based UI. Sections below map 1:1 to the app's sidebar.

### Monitor

- **Dashboard** — System health, token usage, cost tracking, recent sessions with live refresh
- **Insights** — Usage analytics with token breakdown (including reasoning tokens), cost tracking, model/platform stats, top tools bar chart, activity heatmaps, notable sessions, and time period filtering (7/30/90 days or all time)
- **Sessions Browser** — Full conversation history with message rendering, model reasoning/thinking display, tool call inspection, full-text search, rename, delete, and JSONL export. Subagent sessions are filtered from the main list and accessible via parent session drill-down
- **Activity Feed** — Recent tool execution log with filtering by kind and session, detail inspector with pretty-printed arguments and tool output display

### Interact

- **Live Chat** — Two modes: **Rich Chat** streams responses in real-time via the Agent Client Protocol (ACP) with iMessage-style bubbles, markdown rendering, tool call visualization, thinking/reasoning display, permission request dialogs, and a one-click `/compress` focus sheet (when Hermes advertises the command); **Terminal** runs `hermes chat` with full ANSI color and Rich formatting via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). Both modes support session persistence, resume/continue previous sessions, auto-reconnection with session recovery, and voice mode controls
- **Memory Viewer/Editor** — View and edit Hermes's MEMORY.md and USER.md with live file-watcher refresh, external memory provider awareness (Honcho, Supermemory, etc.), and profile-scoped memory support with profile picker
- **Skills Browser** — Browse installed skills by category with file content viewer and required config warnings. **New in 1.6:** Browse the Skills Hub, search by registry (official, skills.sh, well-known, GitHub, ClawHub, LobeHub), install, check for updates, and uninstall — all from the app

### Configure *(new in 1.6)*

- **Platforms** — Native GUI setup for all 13 messaging platforms (Telegram, Discord, Slack, WhatsApp, Signal, Email, Matrix, Mattermost, Feishu, iMessage, Home Assistant, Webhook, CLI). Per-platform forms write credentials to `~/.hermes/.env` and behavior toggles to `~/.hermes/config.yaml`. WhatsApp and Signal pairing use an inline SwiftTerm terminal for QR scan and signal-cli daemon management
- **Personalities** — List defined personalities, pick the active one, and edit `SOUL.md` inline with markdown preview
- **Quick Commands** — Editor for custom `/command_name` shell shortcuts with dangerous-pattern detection (`rm -rf`, `mkfs`, etc.)
- **Credential Pools** — Per-provider credential rotation with a fixed OAuth flow (URL extraction + browser open + code paste) and proper `--type api-key` handling. API keys never stored in UI state — only last-4 preview. Strategy picker (fill_first / round_robin / least_used / random)
- **Plugins** — Install via Git URL or `owner/repo`, update, remove, enable/disable. Reads `~/.hermes/plugins/` directly for reliable state
- **Webhooks** — Create, list, test-fire, and remove webhook subscriptions. Detects the "platform not enabled" state and links to gateway setup
- **Profiles** — Switch between multiple isolated Hermes instances. Create, rename, delete, export (zip), import. Safe-switch warning reminds users to restart Scarf after activating a different profile

### Manage

- **Tools** — Enable/disable toolsets per platform with a connectivity-aware platform menu (green/orange/grey/red dots for connected/configured/offline/error). **Fixed in 1.6:** all 13 platforms now appear (was previously stuck on CLI)
- **MCP Servers** — Manage Model Context Protocol servers Hermes connects to. Add via curated presets (GitHub, Linear, Notion, Sentry, Stripe, and more) or fully custom (stdio command + args, or HTTP URL with optional bearer auth). Per-server detail view with enable/disable toggle, environment variable + header editor, tool-include/exclude filters, resources/prompts toggles, request and connect timeouts, OAuth token detection + clearing, and one-click "Test Connection" that runs `hermes mcp test` and surfaces the discovered tool list. Gateway-restart banner appears after config changes that require a reload
- **Gateway Control** — Start/stop/restart the messaging gateway, view platform connection status, manage user pairing (approve/revoke)
- **Cron Manager** — View scheduled jobs with pre-run scripts, delivery failure tracking, timeout info, and `[SILENT]` job indicators. **New in 1.6:** full write support — create, edit, pause, resume, run-now, and delete jobs from the app
- **Health** — Component-level status and diagnostics. **New in 1.6:** inline "Run Dump" and "Share Debug Report" buttons (the latter with an upload-confirmation dialog before sending to Nous support)
- **Log Viewer** — Real-time log tailing for agent.log, errors.log, and gateway.log with level filtering, component filter (Gateway / Agent / Tools / CLI / Cron), clickable session-ID pills that filter to a single session, and text search
- **Settings** — **Restructured in 1.6** into a 10-tab layout: General, Display, Agent, Terminal, Browser, Voice, Memory, Aux Models, Security, Advanced. Exposes ~60 previously hidden config fields including all 8 auxiliary model tasks, container limits, full TTS/STT provider settings, human-delay simulation, compression thresholds, logging rotation, checkpoints, website blocklist, Tirith sandbox, and delegation. One-click **Backup & Restore** via `hermes backup` / `hermes import`. Model picker replaces the old free-text model field, backed by the models.dev cache (111 providers, all major models) with a "Custom…" escape hatch

### Project Dashboards

Custom, agent-generated dashboards for any project. Define stat boxes, charts, tables, progress bars, checklists, rich text, and embedded web views in a simple JSON file — Scarf renders them with live refresh. Let your Hermes agent build and maintain project-specific visualizations automatically. See [Project Dashboards](#project-dashboards-1) below for the full schema.

### System

- **Hermes Process Control** — Start, stop, and restart the Hermes agent directly from Scarf
- **Menu Bar** — Status icon showing Hermes running state with quick actions

## Requirements

- macOS 14.6+ (Sonoma) for Scarf
- iOS 18.0+ for [ScarfGo](https://github.com/awizemann/scarf/wiki/ScarfGo) (the iPhone companion, public TestFlight from v2.5)
- Xcode 16.0+ to build from source
- [Hermes agent](https://github.com/hermes-ai/hermes-agent) v0.6.0+ installed at `~/.hermes/` on each target host (v0.11.0+ recommended for full v2.5 feature support — `/steer`, new state.db columns, design-md/spotify skills, SKILL.md frontmatter chips)
- For remote servers: SSH access (key-based), `sqlite3` on the remote (for atomic DB snapshots), and the `hermes` CLI resolvable from the remote user's `PATH` or at a path you specify per server. ScarfGo requires the same on every Hermes host it connects to.

### Compatibility

Scarf reads Hermes's SQLite database and parses CLI output from `hermes status`, `hermes doctor`, `hermes tools`, `hermes sessions`, `hermes gateway`, and `hermes pairing`. Automatic schema detection provides backward compatibility with older databases while supporting new features in newer Hermes versions.

| Hermes Version | Status |
|----------------|--------|
| v0.6.0 (2026-03-30) | Verified |
| v0.7.0 (2026-04-03) | Verified |
| v0.8.0 (2026-04-08) | Verified |
| v0.9.0 (2026-04-13) | Verified |
| v0.10.0 (2026-04-16) | Verified (Tool Gateway introduced) |
| v0.11.0 (2026-04-23) | **Verified — current target (recommended for full v2.5 feature support)** |

Scarf 2.5 targets Hermes v0.11.0 for `/steer`, the new state.db columns (`messages.reasoning_content`, `sessions.api_call_count`), the new skills (design-md, spotify), the SKILL.md frontmatter chip surfaces, and the `hermes memory reset` toolbar action. Earlier Hermes versions remain supported for monitoring, sessions, file-based features, and ACP chat; v0.11-specific behavior degrades gracefully on older agents (`/steer` is harmless, new columns silently nil out).

If a Hermes update changes the database schema or CLI output format, Scarf may need to be updated. Check the [Health](#features) view for compatibility warnings.

## Install

### Pre-built Binary (no Xcode required)

Download the latest build from [Releases](https://github.com/awizemann/scarf/releases):

- `Scarf-vX.X.X-Universal.zip` — Apple Silicon + Intel (recommended)
- `Scarf-vX.X.X-ARM64.zip` — Apple Silicon only (smaller download)

1. Unzip and drag **Scarf.app** to Applications
2. Launch normally — builds are Developer ID signed and notarized, so Gatekeeper accepts them on first launch

Scarf checks for updates automatically on launch via [Sparkle](https://sparkle-project.org) and daily thereafter. You can disable automatic checks or trigger a manual check from **Settings → General → Updates** or the menu bar icon.

### Build from Source

```bash
git clone https://github.com/awizemann/scarf.git
cd scarf/scarf
open scarf.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Release -arch arm64 -arch x86_64 ONLY_ACTIVE_ARCH=NO build
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
    Insights/     Usage analytics and activity patterns
    Sessions/     Conversation browser with rename, delete, export
    Activity/     Tool execution feed with inspector
    Projects/     Agent-generated project dashboards with widget rendering
    Chat/         Rich ACP chat and embedded terminal with voice controls
    Memory/       Memory viewer and editor
    Skills/       Skill browser by category
    Tools/        Toolset management per platform
    MCPServers/   MCP server registry, presets, OAuth, tool filters, test runner
    Gateway/      Messaging gateway control and pairing
    Cron/         Scheduled job viewer
    Logs/         Real-time log viewer
    Settings/     Structured config editor
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
| `hermes acp` | ACP subprocess (JSON-RPC stdio) | Real-time chat |
| `hermes chat` | Terminal subprocess | Interactive |
| `hermes tools` | CLI commands | Enable/Disable |
| `hermes sessions` | CLI commands | Rename/Delete/Export |
| `hermes gateway` | CLI commands | Start/Stop/Restart |
| `hermes pairing` | CLI commands | Approve/Revoke |
| `hermes mcp` | CLI commands | Add/Remove/Test MCP servers |
| `mcp-tokens/*.json` | JSON (per-server OAuth) | Detect/Delete |
| `.scarf/dashboard.json` | JSON (per-project) | Read-only |
| `scarf/projects.json` | JSON (registry) | Read/Write |

The app opens `state.db` in read-only mode to avoid WAL contention with Hermes. Management actions (tool toggles, session rename/delete/export) go through the Hermes CLI.

### Dependencies

| Package | Purpose |
|---------|---------|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Terminal emulator for the Chat feature |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Auto-updates from the GitHub-hosted appcast |

Everything else uses system frameworks: SQLite3 C API, Foundation JSON, AttributedString markdown, SwiftUI Charts, GCD file watching.

## How It Works

Scarf watches `~/.hermes/` for file changes and queries the SQLite database for sessions, messages, and analytics. Views refresh automatically when Hermes writes new data.

The Chat tab has two modes. **Rich Chat** communicates with Hermes via the Agent Client Protocol (ACP) — a JSON-RPC connection over stdio — streaming responses in real-time with automatic reconnection and session recovery on connection loss. **Terminal** mode spawns `hermes chat` in a pseudo-terminal for the full interactive CLI experience with proper ANSI rendering. Sessions persist across navigation in both modes — switch tabs and come back without losing your conversation.

Management actions (renaming sessions, toggling tools, editing memory) call the Hermes CLI or write directly to the appropriate files, keeping Scarf and Hermes in sync.

The app sandbox is disabled because Scarf needs direct access to `~/.hermes/` and the ability to spawn the Hermes binary.

## Project Dashboards

Project Dashboards turn Scarf into a customizable monitoring hub for all your projects. You define a simple JSON file in your project folder describing what to display — stat boxes, charts, tables, progress bars, checklists, rich text, and embedded web views — and Scarf renders it as a live-updating dashboard. Your Hermes agent can generate and maintain these dashboards automatically.

### What You Can Build

- **Development dashboards** — test coverage, build status, open issues, sprint progress
- **Data project trackers** — pipeline metrics, data quality scores, processing throughput
- **Deployment monitors** — deploy history tables, uptime stats, error rate charts
- **Research dashboards** — experiment results, key findings, paper status checklists
- **Agent activity views** — cron job results, content generation stats, task completion rates
- **Embedded web apps** — local dev servers, HTML reports, Grafana dashboards, any web-based tool your agent generates
- **Any project status** — if your agent can measure it, Scarf can display it

### Quick Start

**1. Create the dashboard file**

Create `.scarf/dashboard.json` in any project folder:

```json
{
  "version": 1,
  "title": "My Project",
  "description": "Project status at a glance",
  "sections": [
    {
      "title": "Overview",
      "columns": 3,
      "widgets": [
        {
          "type": "stat",
          "title": "Test Coverage",
          "value": "87%",
          "icon": "checkmark.shield",
          "color": "green",
          "subtitle": "+2.1% this week"
        },
        {
          "type": "progress",
          "title": "Sprint Progress",
          "value": 0.73,
          "label": "73% complete",
          "color": "blue"
        },
        {
          "type": "list",
          "title": "Tasks",
          "items": [
            { "text": "Write unit tests", "status": "done" },
            { "text": "Update API docs", "status": "active" },
            { "text": "Deploy to prod", "status": "pending" }
          ]
        }
      ]
    }
  ]
}
```

**2. Register your project**

In Scarf, go to **Projects** in the sidebar and click the **+** button to add your project folder. Or have your agent add it directly to the registry at `~/.hermes/scarf/projects.json`:

```json
{
  "projects": [
    { "name": "my-project", "path": "/Users/you/Developer/my-project" }
  ]
}
```

**3. View in Scarf**

Select your project in the Projects sidebar — the dashboard renders immediately. Scarf watches the file for changes and refreshes automatically whenever the JSON is updated.

### Widget Types

| Type | Description | Key Fields |
|------|-------------|------------|
| `stat` | Key metric with large value display | `value`, `icon`, `color`, `subtitle` |
| `progress` | Progress bar with label | `value` (0.0–1.0), `label`, `color` |
| `text` | Rich text block | `content`, `format` ("markdown" or "plain") |
| `table` | Data table with headers | `columns`, `rows` |
| `chart` | Line, bar, or pie chart | `chartType`, `series` (each with `name`, `color`, `data`) |
| `list` | Checklist with status indicators | `items` (each with `text`, `status`: done/active/pending) |
| `webview` | Embedded web browser | `url`, `height` (default 400) |

The `webview` widget embeds a live web browser directly in your dashboard — perfect for displaying local dev servers, HTML reports, or any web-based tool your agent generates.

When a dashboard includes a webview widget, Scarf adds a tabbed interface: **Dashboard** shows your normal widgets, **Site** shows the web content full-canvas with clean margins — using the entire available space in the app. This gives you the best of both worlds: compact metrics at a glance, and a full embedded browser when you need it.

```json
{
  "type": "webview",
  "title": "Project Report",
  "url": "http://localhost:8000/dashboard",
  "height": 500
}
```

- `url`: Any URL — typically a local server (`http://localhost:...`) or file path
- `height`: Height in points when displayed as an inline widget card (default: 400). The Site tab always uses full available space regardless of this setting.

**Colors**: red, orange, yellow, green, blue, purple, pink, teal, indigo, mint, brown, gray

**Icons**: Any [SF Symbol](https://developer.apple.com/sf-symbols/) name (e.g., `checkmark.shield`, `cpu`, `doc.text`, `chart.bar`)

### Agent-Generated Dashboards

The real power is letting your Hermes agent build and update dashboards automatically. Add instructions like this to your agent's context:

> Analyze this project and create a `.scarf/dashboard.json` dashboard with relevant metrics and status. Use stat widgets for key numbers, charts for trends, tables for structured data, lists for task tracking, and a webview widget if the project has a local web server or HTML reports. Register the project in `~/.hermes/scarf/projects.json` if not already registered.

Your agent can update the dashboard as part of cron jobs, after builds, or whenever project state changes. Since Scarf watches the file, updates appear in real-time.

### Dashboard Schema Reference

```json
{
  "version": 1,
  "title": "Required — dashboard title",
  "description": "Optional — subtitle text",
  "updatedAt": "Optional — ISO 8601 timestamp",
  "sections": [
    {
      "title": "Section Name",
      "columns": 3,
      "widgets": [{ "type": "...", "title": "..." }]
    }
  ]
}
```

Each section defines a grid with 1–4 columns. Widgets flow left-to-right, wrapping to new rows. See [DASHBOARD_SCHEMA.md](scarf/docs/DASHBOARD_SCHEMA.md) for the full schema reference with examples of every widget type.

## Releases

Scarf ships through GitHub releases — the App Store is not supported because Scarf spawns the user-installed `hermes` binary and reads `~/.hermes/` directly, both of which App Sandbox forbids.

Each release goes through a single local script: [scripts/release.sh](scripts/release.sh). The script archives a universal binary, signs it with the Developer ID Application cert, submits to `notarytool`, staples the ticket, produces the distribution zip, signs an appcast entry with Sparkle's EdDSA key, pushes an updated `appcast.xml` to the `gh-pages` branch, creates the GitHub release, and tags `main`.

The Sparkle appcast is served from [awizemann.github.io/scarf/appcast.xml](https://awizemann.github.io/scarf/appcast.xml).

Signing prerequisites (one-time):

- `Developer ID Application` certificate in the login Keychain
- `scarf-notary` keychain profile registered via `xcrun notarytool store-credentials`
- Sparkle EdDSA private key in Keychain item `https://sparkle-project.org` (back this up — without it, shipped apps can never receive updates)

## Template Catalog

Community-contributed Scarf project templates live under [`templates/`](templates/) in this repo and are browsable at **[awizemann.github.io/scarf/templates/](https://awizemann.github.io/scarf/templates/)** with live dashboard previews and one-click `scarf://install?url=…` links.

- **Install from the web** — click "Install with Scarf" on any template's detail page; the app takes over from there.
- **Install from a local file** — Scarf → Projects → Templates → Install from File…, or double-click any `.scarftemplate` in Finder.
- **Author a template** — see [`templates/CONTRIBUTING.md`](templates/CONTRIBUTING.md) for the full walkthrough. Fork, drop a template under `templates/<your-github-handle>/<your-name>/`, open a PR; CI validates the bundle automatically.

The catalog's site is a static HTML + vanilla JS build generated by [`tools/build-catalog.py`](tools/build-catalog.py) and driven by [`scripts/catalog.sh`](scripts/catalog.sh) (check / build / preview / publish). Appcast and main landing page are independent — updating the catalog never disturbs Sparkle.

## Contributing

Contributions are welcome. Please open an issue to discuss what you'd like to change before submitting a PR.

1. Fork the repo
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -m 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

For template submissions, see [`templates/CONTRIBUTING.md`](templates/CONTRIBUTING.md) — same flow, with a catalog-specific checklist + automated CI validation.

## Support

If you find Scarf useful, consider buying me a coffee.

<a href="https://www.buymeacoffee.com/awizemann"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" height="40"></a>

## License

[MIT](LICENSE)
