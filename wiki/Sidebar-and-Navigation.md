---
title: Sidebar-and-Navigation
type: note
permalink: scarf-wiki/sidebar-and-navigation
created: 2026-05-29
updated: 2026-05-29
---

# Sidebar and Navigation

Navigation state lives in a single `@Observable` coordinator. The sidebar is a `List` bound to it; feature views observe it. There is no router, no NavigationStack stack tracking, no global state library — just one source of truth for "where am I?".

## AppCoordinator

[`AppCoordinator.swift`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Navigation/AppCoordinator.swift) holds three pieces of state:

- `selectedSection: SidebarSection` — defaults to `.dashboard`.
- `selectedSessionId: String?` — optional deep link into the Sessions browser.
- `selectedProjectName: String?` — optional deep link into a project dashboard.

It is injected at the root of each window via `.environment(coordinator)` in `ContextBoundRoot` so any view can read it with `@Environment(AppCoordinator.self) private var coordinator`.

Each Scarf window has its **own** `AppCoordinator` — selection in one window doesn't bleed into another. The coordinator is paired with one [`ServerContext`](Architecture-Overview) for the lifetime of the window.

## SidebarSection

`SidebarSection` ([`AppCoordinator.swift`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Navigation/AppCoordinator.swift)) is the source of truth for every sidebar item. Each case has a `rawValue` (display name) and an `icon` (SF Symbol name). **25 cases** grouped into **5 sidebar headers** (the order is hardcoded in `SidebarView.swift`). v2.6 introduced two capability-gated items: **Curator** (under Interact) and **Kanban**. v2.7.5 **moved Kanban from Manage → Monitor** to reflect that the board surfaces runtime work-in-progress, not configuration — it now sits at the bottom of the Monitor group alongside Dashboard / Insights / Sessions / Activity. v2.9 adds **Hermes Proxy** under Configure on Hermes v0.14+ — wraps the `hermes proxy start` OpenAI-compatible local server (default `http://127.0.0.1:8645/v1`) so Codex / Aider / Cline / VS Code Continue can talk to a Hermes-managed subscription. See [Hermes Proxy](Hermes-Proxy) for the full surface.

### Monitor (5 — Hermes v0.12+ shows Kanban)

| Section | Icon |
|---|---|
| Dashboard | `gauge.with.dots.needle.33percent` |
| Insights | `chart.bar` |
| Sessions | `bubble.left.and.bubble.right` |
| Activity | `bolt.horizontal` |
| Kanban (v0.12+) | `rectangle.split.3x1` |

### Projects (1)

| Section | Icon |
|---|---|
| Projects | `square.grid.2x2` |

Projects has its own header — not a Manage sub-item — because per-project work (Dashboard / Sessions / Site / Slash Commands tabs, template install) is a top-level workflow surface in v2.5.

### Interact (4)

| Section | Icon |
|---|---|
| Chat | `text.bubble` |
| Memory | `brain` |
| Curator | `wand.and.stars` |
| Skills | `lightbulb` |

**Curator** (v2.6, Hermes v0.12+ only) wraps `hermes curator` — status panel, run / pause / resume, three leaderboards (least-recently-active / most-active / least-active), inline pin toggle, restore-archived sheet, last-run REPORT.md inline. Capability-gated on `HermesCapabilities.hasCurator` so the row disappears entirely on pre-v0.12 hosts.

### Configure (7 — Hermes v0.13+ shows Models, v0.14+ shows Hermes Proxy)

| Section | Icon |
|---|---|
| Platforms | `dot.radiowaves.left.and.right` |
| Personalities | `theatermasks` |
| Quick Commands | `command.square` |
| Credential Pools | `key.horizontal` |
| Plugins | `app.badge.checkmark` |
| Webhooks | `arrow.up.right.square` |
| Profiles | `person.2.crop.square.stack` |
| Models (v0.13+) | `cpu` |
| Hermes Proxy (v0.14+) | `shippingbox.and.arrow.backward` |

**Models** is the user-facing surface for per-project model presets + the mid-chat switcher (capability-gated on `hasACPSetSessionModel` from v0.13). **Hermes Proxy** wraps `hermes proxy start` — local OpenAI-compatible server that attaches your OAuth-authenticated upstream credentials so third-party tools (Codex CLI, Aider, Cline, VS Code Continue) can hit your Hermes-managed subscription (capability-gated on `hasHermesProxy` from v0.14; local-server only in v2.9).

### Manage (7)

| Section | Icon |
|---|---|
| Tools | `wrench.and.screwdriver` |
| MCP Servers | `puzzlepiece.extension` |
| Messaging Gateway | `antenna.radiowaves.left.and.right` |
| Cron | `clock.arrow.2.circlepath` |
| Health | `stethoscope` |
| Logs | `doc.text` |
| Settings | `gearshape` |

**Kanban** (v2.6 introduced read-only; v2.7.5 lifted to full read/write) is the Mac board view over `hermes kanban`. Capability-gated on `HermesCapabilities.hasKanban` — pre-v0.12 hosts hide the row entirely. v2.7.5 ships a `Board | List` toggle: the **Board** mode renders a five-column drag-and-drop layout (Triage / Up Next / Running / Blocked / Done; archived hides behind a header toggle) with optimistic-merge state, a side-pane inspector (Comments / Events / Runs / Log tabs), inline assignee picker, health banners for unassigned + last-failed-run states, and a New Task sheet that defaults assignee to the active local profile and auto-fires `kanban dispatch` after create. The **List** mode preserves the v2.6 read-only flat table for narrow windows and accessibility. Drag-drop maps to verbs through a pure `KanbanService.plan(for:)` transition planner: `(.upNext, .running) → [.dispatch]`, `(.blocked, .running) → [.unblock, .dispatch]`, etc. — `dispatch` (not `claim`) is the right verb for a GUI client because Scarf doesn't host workers; the gateway-running dispatcher does. See [Architecture Overview](Architecture-Overview) for the tenant-as-project-key strategy and [Hermes Version Compatibility](Hermes-Version-Compatibility) for the version gate.

**Kanban v0.15 maturation wave** _(v2.10.0+, Hermes v0.15+, gated on `hasKanbanV015` / `hasKanbanSessionFilter`)_:

- **Server-side sort** — a sort picker on the board header drives `--sort` (priority / created / status / assignee / title / updated) so ordering matches the dispatcher's actual run order without a client-side ordering sidecar.
- **New lifecycle card actions** — **Promote** (`todo` / `blocked` → `ready`), **Schedule / Park**, and **Delete-permanently** (hard-delete an archived task via `archive --rm`) as card context actions.
- **Two new columns** — **Scheduled** (parked tasks) and **Review** (post-work verification); both collapse when empty, matching the existing Triage / Archived collapse behavior.
- **Worktree + model surfacing** — per-task git worktree `--branch` on create; the inspector shows a task's branch and its (read-only) `model_override`.
- **Precise chat-scoped board** — when opened from a chat, the board now filters by the originating ACP `session_id` (stamped automatically by Hermes), replacing the old tenant + time-window approximation. A **"This chat ⇄ All tasks"** scope toggle widens the view, and the scope pill renders even for global chats with no project tenant.
- **Multi-board plumbing** — `--board` is wired through `KanbanService`; a board-switcher UI and the `swarm` create-sheet are follow-ups.

The Gateway item's `displayName` is **"Messaging Gateway"** — disambiguates from the v2.3 Tool Gateway (Nous Portal subscription routing) which is a Health-tab surface, not its own sidebar item. The enum case is still `.gateway` and the persisted state file path (`~/.hermes/gateway_state.json`) is unchanged.

## SidebarView

[`SidebarView.swift`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/Navigation/SidebarView.swift) is a `List` with hardcoded `Section` headers. Selection is two-way bound to `coordinator.selectedSection`:

```swift
List(selection: $coordinator.selectedSection) {
    Section("Projects")  { … }
    Section("Monitor")   { …, kanban (v0.12+) }
    Section("Interact")  { …, curator (v0.12+) }
    Section("Configure") { … }
    Section("Manage")    { … }
}
.listStyle(.sidebar)
```

There is no search bar, no collapsible-section state to persist — every section is always expanded.

## Routing

`ContentView`'s `detailView` is a single `switch coordinator.selectedSection` over every `SidebarSection` case, returning the right view for the current selection. New features add one case here (see [Adding a Feature Module](Adding-a-Feature-Module)).

## Multi-window

Each window is bound to one `ServerContext` and one `AppCoordinator`. The window menu (and `⌘1…⌘9` keyboard shortcuts) opens additional windows for other servers — see [Keyboard Shortcuts](Keyboard-Shortcuts). Closing a window destroys its coordinator; reopening reads the section back from defaults.

## ScarfGo (iOS) navigation

ScarfGo uses a different model — a 5-tab `TabView` rather than a sidebar. The tabs (Dashboard | Projects | Chat | Skills | System) are wrapped in their own `NavigationStack`s so push navigation (Cron editor, Memory detail, Project detail, Settings) stays scoped to the tab. Cross-tab signalling (Dashboard row → Chat tab resume, Project Detail → in-project chat handoff, notification deep-link → Chat) flows through `ScarfGoCoordinator`.

`.tabViewStyle(.sidebarAdaptable)` is wired so the system can switch to a sidebar layout on larger devices — but as of v2.5 the iOS target ships **iPhone-only** (`TARGETED_DEVICE_FAMILY = 1`, `SUPPORTS_MACCATALYST = NO`, `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO`). iPad polish is on the [ScarfGo Roadmap](ScarfGo-Roadmap) but not in scope for v2.5.

The Mac sidebar's "System" / advanced sections collapse into the iOS **System** tab (server identity, Memory link, Cron link, Settings link, Disconnect / Forget). See [Platform Differences](Platform-Differences) for the full Mac↔iOS feature matrix.

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (audit pass: 5 sidebar groups not 4, 22 cases not 23, Projects own group, Messaging Gateway display name, iPhone-only iOS target)_