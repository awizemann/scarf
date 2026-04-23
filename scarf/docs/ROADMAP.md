# Scarf — Feature Roadmap

## Tier 1 — High Value, Data Already Available

### 1. Insights Dashboard
Rich usage analytics pulled from the sessions and messages SQLite tables:
- Overview stats: sessions, messages, tool calls, tokens, active time, avg session duration
- Model breakdown: sessions and tokens per model
- Platform breakdown: CLI vs Telegram vs Discord usage
- Top tools chart: ranked tool usage with call counts and percentages
- Activity patterns: sessions by day-of-week, peak hours heatmap
- Notable sessions: longest, most messages, most tokens, most tool calls
- Time period selector: last 7/30/90 days

### 2. Tool Management Panel
- List all toolsets with enabled/disabled status and descriptions
- Toggle switches to enable/disable tools (via `hermes tools enable/disable`)
- Per-platform tool configuration
- MCP tool status

### 3. Session Management Enhancements
- Rename sessions from the Sessions browser (via `hermes sessions rename`)
- Delete sessions (via `hermes sessions delete`)
- Export sessions to JSONL (via `hermes sessions export`)
- Session stats card (total count, DB size, per-platform breakdown)

## Tier 2 — Medium Value, New Service Code Required

### 4. Skills Hub
- Search remote registries for new skills (6 sources)
- Install/uninstall skills from GUI
- Skill update indicator
- Trust level badges (builtin, local, hub)

### 5. Gateway Control Center
- Start/stop/restart gateway from GUI
- Real-time status: PID, uptime, connected platforms
- Pairing management: view approved users, approve/revoke
- Platform status per messaging service

### 6. System Health View
- Mirror `hermes status` and `hermes doctor` output
- API key validation, auth provider status, external tools
- Update available indicator

## Tier 3 — Nice to Have

### 7. Profile Management
- List/create/switch profiles (isolated Hermes instances)

### 8. Plugin Management
- Install from Git, enable/disable, update

### 9. MCP Server Management
- Add/remove/test MCP servers, toggle tools per server

### 10. Config Editor
- Structured form editor for config.yaml with validation

---

## Projects System Evolution (post-v2.2.1)

A parallel backlog specific to the Projects feature. Ordered by dependency: organization first, then per-project attribution via sidecar, then observability built on that attribution, then polish, then platform bets.

### Shipping in v2.3 (planned — plan file at `~/.claude/plans/`)

- **Folder hierarchy in the sidebar.** `ProjectEntry` gains optional `folder: String?`. `DisclosureGroup`-based sidebar.
- **Rename + archive + search.** Registry verbs + a fuzzy ⌘F search + soft-archive (`archived: Bool?`) with Show/Hide toggle.
- **⌘1–⌘9 project jumps.**
- **Per-project Sessions tab** alongside Dashboard / Site. Filters the global sessions list by a new `~/.hermes/scarf/session_project_map.json` sidecar that Scarf populates when it starts a chat with a project context.
- **New Chat button** on the Sessions tab — spawns `hermes acp` with `cwd = project.path` and attributes the resulting session in the sidecar.

### v2.4+ — per-project observability

Depends on v2.3's sidecar being stable. All features below are "filter the existing data by the sidecar's project mapping."

- **Per-project activity feed.** Extend `ActivityViewModel` with a `projectPath` filter that maps through the sidecar. Dashboard widget type `recent-activity`.
- **Per-project token / cost rollup.** `InsightsViewModel.computeAggregates()` already sums over sessions; add a project filter. Widget binding `project.tokens` exposes it to agent-driven dashboards.
- **Per-project cron-job filter.** Cron sidebar gains a project dropdown. Template-installed jobs already carry `[tmpl:<id>]` prefixes; match against installed template manifests to attribute.
- **Desktop notifications for cron completion.** When a project-attributed cron job finishes (success or failure), fire a `UNUserNotification`. Per-project mute.

### v2.5+ — platform bets

Bigger investments with longer arcs.

- **Hermes upstream: `sessions.cwd` column.** Propose adding a nullable `cwd` (or `workspace_id`) column to Hermes's sessions table, populated on session create. Scarf would prefer the canonical column when available and fall back to the sidecar for pre-upgrade sessions. Requires coordinated Hermes release; filed under platform bets because it cuts the sidecar's blind spot (CLI-started sessions never enter the sidecar today).
- **Per-project memory slice.** Hermes reads `MEMORY.md` from a known path. Explore whether Scarf can spawn `hermes acp` with an overridden memory path (per-project `<project>/.scarf/MEMORY.md`) so projects get isolated context. Needs a Hermes-side env var or flag.
- **Per-project skills namespace.** Today user-authored skills are flat under `~/.hermes/skills/`. A `~/.hermes/skills/project/<slug>/` namespace parallel to the existing `templates/` namespace would let users install skills *into* a project without a template. Uninstall = drop the folder.
- **Cross-project meta-dashboards.** A portfolio view that aggregates widgets from multiple projects — total token spend, combined activity feed, project-health matrix. Useful at 20+ projects.
- **Project backup / restore.** One-click zip of `<project>/` + sidecar entries + related Keychain secrets, restorable on another machine. Richer than the existing Export flow (which carries the template shape only).

### Continuous — UX polish

Small, shippable at any time. Each is a half-day-to-one-day item.

- **Drag-and-drop to reorder** projects within a folder and between folders. Would be the first use of `.onDrag`/`.onDrop` in the codebase; establishes the pattern.
- **Tags as a secondary axis.** Keep folders as primary, add multi-valued string tags + filter chips at the sidebar top. Decide only if folders feel insufficient after v2.3 lands.
- **Favorites / pin** — bubble a project to the top of its folder.
- **Recent projects collection** — auto-populated "Recents" row at the top of the sidebar.
- **Color labels or SF Symbol icons** per project (Finder-tag-style).
- **Project dashboard starter templates** — "blank", "monitor", "feed", "timeline" shapes when creating a bare project (distinct from `.scarftemplate` sharing flow).
- **Opportunistic session backfill.** When Scarf loads any session that isn't in the sidecar, peek at first tool call's `working_directory` or `cwd` hint; if it matches a registered project path, write a sidecar entry. Heuristic, not perfect — useful as an "it just works" improvement after v2.3 ships.

### Research / verification gaps

Noted during v2.3 planning; chase when relevant:

- `DisclosureGroup` inside `List(.sidebar)` on macOS — occasional animation glitches with many-rows-expanding. Early prototype will confirm before full commit.
- Concurrent sidecar writers from multiple Scarf windows on the same `~/.hermes` — atomic replace handles per-write; reload behavior may lag. Acceptable; revisit if users report stale attribution.
- Do Hermes sessions ever persist `cwd` anywhere in `state.db` today that we've missed? If so, we can skip the sidecar and use it directly. Worth a one-hour investigation before starting v2.4 observability work.
