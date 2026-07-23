---
title: Projects-and-Profiles
type: note
permalink: scarf-wiki/projects-and-profiles
created: 2026-05-29
updated: 2026-06-28
---

# Projects & Profiles

Two distinct concepts in adjacent sidebar items. **Projects** are agent-generated dashboards for any directory. **Profiles** are isolated Hermes installations.

## Projects

A project is any directory you tell Scarf about — typically a code repo, but anything works. Each project gets a custom dashboard composed of widgets defined in `<project>/.scarf/dashboard.json`.

**Widget types** (canonical vocabulary lives at [`tools/widget-schema.json`](https://github.com/awizemann/scarf/blob/main/tools/widget-schema.json); each type maps to a Swift view under [`scarf/scarf/Features/Projects/Views/Widgets/`](https://github.com/awizemann/scarf/tree/main/scarf/scarf/Features/Projects/Views/Widgets)):

| Type | Since | Purpose |
|---|---|---|
| `stat` | v2.2 | Single metric: value + label + optional icon, color, and inline `sparkline: [Number]` trend (v2.7+). |
| `progress` | v2.2 | Progress bar with label (0.0..1.0). |
| `text` | v2.2 | Inline markdown / plain text block. |
| `table` | v2.2 | Columns + rows of strings. |
| `chart` | v2.2 | Line / bar / area / pie with `ChartSeries[]` of `ChartDataPoint{x, y}`. |
| `list` | v2.2 | Bulleted list with optional **typed** status badges per item — see Status badges below. |
| `webview` | v2.2 | Embedded web view (URL + height). Including any webview also exposes a Site tab. |
| `markdown_file` | v2.7 | Renders a markdown file from `<project>/<path>`. Refreshes when any file under `.scarf/` changes. |
| `log_tail` | v2.7 | Tails the last `lines` of a file (default 20), monospaced; ANSI codes stripped. |
| `cron_status` | v2.7 | Last run / next run / state for a Hermes cron job by `jobId`, plus a small log tail. |
| `image` | v2.7 | Local image (`path` relative to project root) or remote `url`. |
| `status_grid` | v2.7 | Compact NxM grid of colored cells, one per service / item. Reuses the typed status enum. |

**Status badges (typed in v2.7):** `list` items and `status_grid` cells accept a `status` field that maps to a colored badge. Canonical values are `success`, `warning`, `danger`, `info`, `pending`, `done`, `neutral`. Common synonyms also work (`ok` / `up` → success, `down` / `error` / `failed` → danger, `active` → info, `complete` → done). Unknown strings render as plain text — old dashboards that used ad-hoc statuses keep working byte-identically.

**Auto-refresh (v2.7):** Scarf watches each project's entire `<project>/.scarf/` directory, not just `dashboard.json`. So when a cron job atomically writes `<project>/.scarf/reports/uptime.md` (write-temp + rename), the `markdown_file` widget pointing at it refreshes automatically. _Limitation:_ in-place appends to an existing file (`>> file.log`) don't tick the watcher — the cron job should write atomically, or `touch dashboard.json` after each run to force a refresh. Remote (SSH-attached) projects share the same coverage via 3-second mtime polling.

**The Hermes pattern:** ask your agent to build and maintain the dashboard for you. "Update `.scarf/dashboard.json` to show test pass rate, lines of code, and the open PR list." Scarf renders the result; the agent maintains it.

The full schema is documented in [`scarf/docs/DASHBOARD_SCHEMA.md`](https://github.com/awizemann/scarf/blob/main/scarf/docs/DASHBOARD_SCHEMA.md) in the main repo.

**Adding a project:** click + in the Projects sidebar, pick a directory. The project is registered in `~/.hermes/scarf/projects.json`; the dashboard JSON lives in `<project>/.scarf/dashboard.json` (which you should add to your project's `.gitignore` if it's user-specific).

**Per-project tabs** _(v2.3+, v2.5, v2.7.5)_: clicking a project row reveals a tabbed detail view — **Dashboard**, **Sessions**, **Site** (when the dashboard has a webview widget), **Kanban** (v2.7.5+, Hermes v0.12+ only), and **Slash Commands** (v2.5). The Sessions tab lists chats attributed to the project; **New Chat** spawns `hermes acp` with the project's directory as the session cwd and writes a Scarf-managed block into `<project>/AGENTS.md` so the agent boots with project context. Attribution survives across Mac and ScarfGo via the shared `SessionAttributionService`. See [Slash Commands](Slash-Commands) for the per-project authoring tab.

### Projects grow up _(v2.15)_

v2.15 promotes a project from "a folder with a dashboard" to a **first-class object** with one unified pane and three new powers.

**First-class project object.** A project is now backed by a portable `<project>/.scarf/project.json` record (stable id minted once, name, bound model preset, board/tenant, cron job ids, memory namespace, secret-field *names*, template lock, host bindings, registered mini-apps) plus a fast per-host index at `~/.hermes/scarf/projects.json`. The stable id is what links the same repo across machines — see [Fleet & Portfolio](Fleet-&-Portfolio).

**The cockpit — one pane for the whole project.** Selecting a project now opens a single **cockpit** (it supersedes the older Dashboard/Site/Slash tab strip). A unified header shows the project name, path, bound model preset, and the hosts the project lives on; below it a flat row of panels, each of which hides itself when it doesn't apply:

- **Dashboard** · **Sessions** · **Board** (Kanban) · **Site** (a dashboard webview widget, full-canvas)
- **Context** — read-only preview of the Scarf-managed `AGENTS.md` block the agent actually sees
- **Cron** — project-attributed jobs (`[proj:<id>]` / `[tmpl:<id>]`) with state + schedule
- **Memory** — the project's `MEMORY.md` block (if it owns one)
- **Secrets** — secret config field **names** only (values stay in the Keychain)
- **Templates** — installed template id/version + uninstall manifest
- **Slash** — project-scoped slash commands
- **[Mini-apps](Mini-Apps)** — sandboxed web panels that can drive the project's agent
- **[Fleet](Fleet-&-Portfolio)** — the project across every host it's registered on (multi-host only)

**One-click Upgrade Project.** Got a project from before all this, or one scaffolded by hand? A cockpit banner offers **Upgrade Project**. One click runs a fast, idempotent structural pass — mints the stable id + `project.json`, creates a Kanban board, refreshes the `AGENTS.md` block, seeds a placeholder dashboard — then hands off to chat, where the agent (via the bundled `scarf-template-author` and `scarf-miniapp-author` skills) tailors a real dashboard, slash commands, cron jobs, and a starter mini-app to your project. Re-running it is a no-op, so it's safe to click.

**Per-project Kanban** _(v2.7.5)_: each project gets its own Kanban board scoped to a Scarf-minted `scarf:<slug>` tenant. The slug is derived from the project name (lowercased, hyphenated, ≤48 chars), persisted to `<project>/.scarf/manifest.json`'s new optional `kanbanTenant` field on first kanban interaction, and **immutable across rename** so existing tasks stay attributable. `ProjectAgentContextService` adds a `Kanban tenant: scarf:<slug>` line inside the AGENTS.md scarf-managed block at every chat-start, instructing the agent to pass `--tenant <slug>` on `hermes kanban create` so agent-spawned tasks land on the right project board automatically. Bare projects (no template manifest) get a sentinel manifest written with `id: scarf/<project-id>` + `version: 0.0.0` + just the `kanbanTenant` set — `ProjectAgentContextService` recognizes the sentinel and refuses to surface it as a "Template" line, so a project that's never been template-installed doesn't suddenly start advertising a fake template to the agent. iOS gets a read-only board on the same project tab as a horizontally-paged segmented `Picker` of single-column lists. The new `kanban_summary` dashboard widget shows the top three `running` / `blocked` / `todo` tasks plus a glance footer (`"12 todo · 3 running · 5 blocked"`); add `{ kind: kanban_summary, max_rows: 3 }` to `dashboard.json` to include it. See [Sidebar and Navigation](Sidebar-and-Navigation) for the global Kanban surface.

**Kanban v0.15 wave** _(v2.10.0+, Hermes v0.15+)_: the board gains server-side `--sort`, Promote / Schedule (park) / Delete-permanently (`archive --rm`) card actions, new Scheduled + Review columns (collapse when empty), per-task worktree `--branch` on create + a read-only `model_override` line in the inspector, and `--board` multi-board plumbing in the service layer (board switcher UI is a follow-up). The biggest change for project boards: tasks are now scoped by the originating ACP **`session_id`** (stamped by Hermes) rather than the tenant + time-window approximation, so a board opened from a project chat shows exactly that session's tasks — even ones the agent created without tagging the `scarf:<slug>` tenant — with a "This chat ⇄ All tasks" scope toggle to widen it. The tenant slug above is still minted and injected for cross-session attribution, but session scoping is now authoritative for the per-chat view. Gated on `HermesCapabilities.hasKanbanV015` / `hasKanbanSessionFilter`; pre-v0.15 hosts keep the v2.7.5 tenant-scoped board. See [Chat](Chat) for the chat-header Kanban chip.

**Sharing a project:** as of v2.2.0, projects can be packaged into `.scarftemplate` bundles and shared with anyone — see [Project Templates](Project-Templates). Export turns a live project into a redistributable bundle; install unpacks one and sets up the dashboard, skills, cron jobs, configuration schema, and (in v2.5+) project-scoped slash commands in a single preview-and-confirm step. The public catalog lives at [awizemann.github.io/scarf/templates/](https://awizemann.github.io/scarf/templates/).

## Profiles

A profile is an isolated Hermes installation — separate config, sessions, memory, skills, the lot. Useful for keeping work / personal context separate, or for testing a config change without disturbing your main instance. Hermes ships profiles as of **v0.11.0**.

**How profile storage actually works** _(v0.11+, as Scarf reads it in v2.5.1+):_

- The "default" profile is `~/.hermes/` itself — backward compatible, zero migration.
- Named profiles live under `~/.hermes/profiles/<name>/`, each a fully independent `HERMES_HOME`. Each profile carries its own `state.db`, `sessions/`, `config.yaml`, `.env`, `memories/`, `cron/`, `skills/`, `gateway_state.json`, etc.
- The active profile is recorded in `~/.hermes/active_profile` — a single-line text file containing the profile name, or absent / empty when default is active. `hermes profile use <name>` writes that file; the Hermes CLI then sets `HERMES_HOME` accordingly per invocation.
- **Scarf v2.5.1+ reads `active_profile`** via [`HermesProfileResolver`](Core-Services) and routes every derived path through it — `state.db`, `sessions/`, `config.yaml`, `memories/`, `cron/jobs.json`, `auth.json`, plugins, gateway state, logs, all of it. So switching profiles on the host with `hermes profile use coder` and relaunching Scarf correctly reads the new profile's data. The chat session info bar surfaces a small profile chip when not on default so you can tell at a glance which profile Scarf is reading from.
- Pre-2.5.1 Scarf hardcoded `~/.hermes` and ignored `active_profile`, which silently read the wrong DB after a profile switch (issue [#50](https://github.com/awizemann/scarf/issues/50)). If you're on 2.5.0 or older, upgrade.

**Operations** (all wrap `hermes profile ...` via `context.runHermes`):

- **Switch** — make a profile active. Scarf shows a "restart Scarf to fully apply" reminder; the resolver re-reads `active_profile` on launch and on each `HermesPathSet` construction (5s cache).
- **Create / rename / delete** — straightforward.
- **Export** — zips the profile directory; useful for backup or moving to a new machine. _v2.5.2+:_ on remote contexts a path-input + Verify sheet captures the destination zip path on the SSH host (mirrors the Add Project sheet's pattern from #54).
- **Import** — unzip into a new profile slot. _v2.5.2+:_ on remote contexts a path-input + Verify sheet captures the source zip path on the SSH host. Local context still uses `NSOpenPanel`. Drives `hermes profile import <zip>` over SSH; bytes are piped via `HermesFileService.runHermesWithStdin` (rather than landing on the remote disk first) when invoked from the local-file-on-Mac flow.

On the **Mac**, remote SSH contexts don't auto-resolve `active_profile` — `HermesPathSet.defaultRemoteHome` stays at the configured remote home. If you're using profiles on a remote, set the **Hermes data directory** field in Manage Servers to point at `~/.hermes/profiles/<name>` for that server context. Issue [#53](https://github.com/awizemann/scarf/issues/53)'s degraded-pill diagnostics will tell you when this is the cause of an empty dashboard.

### ScarfGo (iOS) profile switching _(#120)_

ScarfGo has a built-in **profile switcher** (System → Profiles) so you don't have to hand-edit the remote home per server. Pick a profile and the phone re-scopes everything it shows — dashboard, memory, cron, sessions, gateway, skills, and chat — to that profile.

Crucially, the switch is **per-connection and view-only**: it does **not** run `hermes profile use` or touch the host's `active_profile`, so your Mac app, terminal, and the running gateway are undisturbed. It works by pointing this phone's reads at the profile's home and prepending `HERMES_HOME=<root>/profiles/<name>` to its `hermes` invocations (chat + CLI) — Hermes' own per-invocation home mechanism. The **Default** entry returns to the root profile; the switcher also shows which profile the **server itself** is on (its `active_profile`) when it differs from what you're viewing. Creating, renaming, deleting, and import/export stay on the Mac app.

## Related pages

- [Mini-Apps](Mini-Apps) — sandboxed web panels (v2.15) that drive a project's agent via the `window.scarf` bridge.
- [Fleet & Portfolio](Fleet-&-Portfolio) — the same project across multiple hosts (v2.15): drift detection + Apply to Fleet.
- [Project Templates](Project-Templates) — `.scarftemplate` bundles (schemaVersion 3 in v2.5), the install / export / author flows, the public catalog.
- [Slash Commands](Slash-Commands) — project-scoped slash commands authored in the per-project Slash Commands tab.
- [Hermes Paths](Hermes-Paths) — `~/.hermes/profiles/` and the projects registry.
- [Memory & Skills](Memory-and-Skills) — memory is profile-scoped.
- [Settings](Gateway-Cron-Health-Logs) — exposes "Backup & Restore" buttons (`hermes backup` / `hermes import`) at the profile level.

---
_Last updated: 2026-06-28 — Scarf v2.15.0 (projects grow up: first-class project object, the cockpit single pane, one-click Upgrade Project; links to the new Mini-Apps and Fleet & Portfolio pages)_