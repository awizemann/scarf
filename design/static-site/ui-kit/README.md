# Scarf macOS UI Kit

A high-fidelity React recreation of the Scarf macOS app, built against the codebase at `awizemann/scarf` (SwiftUI). It mirrors the real navigation hierarchy from `SidebarView.swift` and the visual rhythm of the actual SwiftUI views (`Dashboard`, `RichChat`, `Sessions`, `Projects`, `Insights`, etc.).

This kit is **cosmetic** — it gets the visuals exactly right but doesn't replicate the Swift business logic. Use it as a starting point for new flows, mocks, or marketing screenshots.

## Run

Open `index.html` in a browser. No build step.

## Components

| File | What it covers |
|---|---|
| `Common.jsx` | `Btn`, `Pill`, `Card`, `StatCard`, `Field`, `TextInput`, `Toggle`, `EmptyState`, `ContentHeader` |
| `Sidebar.jsx` | Sectioned sidebar (Monitor / Projects / Interact / Configure / Manage) — exact section/item list from `SidebarView.swift` |
| `Dashboard.jsx` | Status row, 7-day stats, recent sessions, recent activity |
| `Sessions.jsx` | Filterable, sortable session table |
| `Insights.jsx` | Token-usage chart, by-model and by-tool-kind breakdowns |
| `Projects.jsx` | Project grid with template / cron / health badges |
| `Chat.jsx` | Three-pane Rich Chat — list, transcript with reasoning + tool-call cards, composer |

## Faithful to the source

Replicated 1:1:

- **Sidebar grouping** — five named sections from `SidebarView.swift` in the same order.
- **Tool-kind colors** — `read=green / edit=blue / execute=orange / fetch=purple / browser=indigo / other=gray`, the same tokens used in `ToolCallCard.swift`.
- **Reasoning disclosure** — collapsed orange "REASONING · N tokens" header that expands to italic muted text, matching `RichAssistantMessageView`.
- **Tool-call card chrome** — left tone-rule, monospace name + truncated arg, success/error/spinner trailing, expandable code preview.
- **Status pills** — green/red dot with same word vocabulary (`Running` / `Errored` / `Idle`).
- **Type rhythm** — SwiftUI `largeTitle / title1 / title2 / headline / subhead / body / caption` mapped to `--text-*` tokens.

## Substitutions

- **Icons** — Lucide for the web. SF Symbols aren't redistributable; Lucide is the closest stroked-line set. Documented in `/README.md` → ICONOGRAPHY.
- **Fonts** — system stack first, then Inter (display/text) and JetBrains Mono (mono) loaded from Google Fonts. On macOS users will see SF Pro / SF Mono.
- **Window chrome** — three traffic-light dots painted by hand. The starter `macos-window.jsx` was tried first but its sidebar slot didn't match Scarf's layout, so the chrome is inlined in `index.html`.

## What's intentionally left blank

The placeholder view wired to every sidebar item that isn't one of the five built screens — Activity, Memory, Skills, Platforms, Personalities, Quick Commands, Credentials, Plugins, Webhooks, Profiles, Tools, MCP Servers, Gateway, Cron, Health, Logs, Settings. Each lands on a polite `EmptyState` so navigation is still satisfying. Build any of them by following `Sessions.jsx` (table view) or `Projects.jsx` (card grid) — Scarf is consistent enough that those two patterns cover almost every CRUD pane.
