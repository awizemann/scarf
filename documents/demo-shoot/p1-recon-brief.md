# Phase 1 Recon Brief — Demo Project Surface (Harness in Scarf)

Purpose: ground Phase 2+ (build `.scarf/dashboard.json`, a mini-app, seed Kanban/cron for the
`harness` repo) in exact, code-verified contracts. All citations are `file:line` in the Scarf repo
(`/Users/awizemann/Developer/Scarf`) unless marked `[harness]` or `[local]`.

---

## 1. `dashboard.json` contract

**Model**: `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectDashboard.swift`
**Loader**: `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectDashboardService.swift`

### Top-level `ProjectDashboard` (ProjectDashboard.swift:113-136)
| field | type | required? |
|---|---|---|
| `version` | Int | required (decode fails if missing — no `decodeIfPresent`) |
| `title` | String | required |
| `description` | String? | optional |
| `updatedAt` | String? | optional, free-form string (not parsed as a Date anywhere in this struct) |
| `theme` | `{ accent: String? }` | optional |
| `sections` | `[DashboardSection]` | required |

Decoding is **plain `Codable`** (synthesized, no custom `init(from:)`), so any missing required
key (`version`, `title`, `sections`) throws and `loadDashboard` returns `nil` for the whole file
(ProjectDashboardService.swift:91-96, logged via `os.Logger`, never surfaced to UI as an error —
the project just falls back to "no dashboard").

**Size ceiling**: files > 4 MB (`maxJSONBytes`, ProjectDashboardService.swift:17) are treated as
missing (not decoded) — logged as a warning. Not a concern for a demo dashboard.

### `DashboardSection` (ProjectDashboard.swift:148-165)
- `title: String` — required; **doubles as the `Identifiable.id`** (ProjectDashboard.swift:149),
  so two sections with the same title collide in SwiftUI `ForEach` — keep section titles unique.
- `columns: Int?` — optional; `columnCount` computed property defaults to `3` when nil
  (ProjectDashboard.swift:164).
- `widgets: [DashboardWidget]` — required.

### `DashboardWidget` (ProjectDashboard.swift:167-273)
`id` = `type + ":" + title` (line 168) — **type+title pairs must be unique within a section's
render** or SwiftUI ForEach identity collides.

`type: String` is a **free string, not an enum** — nothing in `ProjectDashboard.swift` validates
it against a known set. Validation/dispatch happens at render time in the SwiftUI view
(`scarf/scarf/Features/Projects/Views/ProjectsView.swift:498` has a `switch`/`case "webview":`
etc.) — an unrecognized `type` silently renders nothing (or a fallback), it does not throw. Same
looseness for `format`, `chartType`, `color`, `icon` (all free strings/SF Symbol names, unchecked
at decode time).

All widget fields are optional (`String?`, `[String]?`, etc.) except `type` and `title`, so a
single `DashboardWidget` struct is the union of every widget type's fields:

| field | used by | notes |
|---|---|---|
| `value: WidgetValue?` | stat, progress | `WidgetValue` decodes **String OR Double** (ProjectDashboard.swift:294-329) — tries Double first, falls back to String, else throws `typeMismatch` (which propagates up and fails the **entire file's decode**, since `ProjectDashboard` has no custom lenient decoder). For `progress` widgets, the doc example uses a bare number `0.73` — that decodes fine as `.number`. |
| `icon: String?` | stat, list | SF Symbol name, unvalidated |
| `color: String?` | stat, progress, chart series | free string; the docs list a fixed palette (red/orange/yellow/green/blue/purple/pink/teal/indigo/mint/brown/gray) but the code does not enforce it — an unrecognized color name is a renderer concern, not a decode concern |
| `subtitle: String?` | stat | |
| `label: String?` | progress | |
| `content: String?`, `format: String?` | text | `format` free string ("markdown"/"plain" per docs, unenforced) |
| `columns: [String]?`, `rows: [[String]]?` | table | **name collides with `DashboardSection.columns` (Int?)** — different type, different widget, easy to confuse when hand-authoring JSON |
| `chartType: String?`, `xLabel/yLabel: String?`, `series: [ChartSeries]?` | chart | `ChartSeries` = `{name, color?, data: [ChartDataPoint]}`; `ChartDataPoint` = `{x: String, y: Double}` (ProjectDashboard.swift:333-362) |
| `items: [ListItem]?` | list | `ListItem = {text, status?}`; `status` is a free string parsed leniently via `ListItemStatus(raw:)` (ProjectDashboard.swift:386-422) — synonyms accepted (`ok`/`up`→success, `down`/`error`/`failed`/`critical`→danger, `active`/`blue`→info, etc.); unrecognized strings silently fall back to plain/neutral text, no error |
| `url: String?`, `height: Double?` | webview, image | webview: any URL (local server, `file://`, remote); image: `url` = remote, `path` = local (comment at ProjectDashboard.swift:199) |
| `path: String?`, `lines: Int?` | **v2.7**: `markdown_file`, `log_tail`, local `image` | `path` resolved **relative to the project root** (dir containing `.scarf/`); comment mandates renderers reject `..` segments after normalization to prevent escaping the project boundary (ProjectDashboard.swift:203-206) — this is a security-relevant field the current `docs/DASHBOARD_SCHEMA.md` doesn't mention at all |
| `jobId: String?` | **v2.7**: `cron_status` | must match a `HermesCronJob.id` |
| `cells: [StatusGridCell]?`, `gridColumns: Int?` | **v2.7**: `status_grid` | `StatusGridCell = {label, status?, tooltip?}`; same `ListItemStatus` vocabulary as `list` |
| `sparkline: [Double]?` | **v2.7**: optional trend overlay on `stat` widgets | |

### Divergence from `scarf/docs/DASHBOARD_SCHEMA.md`
The doc (read in full — `scarf/docs/DASHBOARD_SCHEMA.md`) **only documents 7 widget types**: stat,
progress, text, table, chart, list, webview. It is silent on the **v2.7 widgets that are fully
live in the model**: `markdown_file`, `log_tail`, `cron_status`, `status_grid`, and the `sparkline`
field on `stat`. Trust the code — these are real, decodable, renderable widget types/fields; the
doc is stale. Phase 2 can use v2.7 widgets (e.g. `status_grid` for cockpit-style health, `log_tail`
for a build log, `cron_status` keyed to a seeded cron job) but should not expect
`docs/DASHBOARD_SCHEMA.md` to describe them accurately.

The doc's webview description (tabbed Dashboard/Site UI, webview auto-filtered out of the grid)
**is accurate** — confirmed at `scarf/scarf/Features/Projects/Views/ProjectCockpitView.swift:198-212`
(`siteWidget` = first widget with `type == "webview"` across all sections; `hasSite` gates the Site
cockpit panel) and `ProjectsView.swift:455-457` (webview filtered out of the dashboard grid).

### File location & watching
`ProjectEntry.dashboardPath` = `path + "/.scarf/dashboard.json"` (ScarfProject.swift... actually
`ScarfProject.swift` — see `ProjectDashboard.swift:75`). Watched as part of the whole `.scarf/`
directory unit by `HermesFileWatcher` (comment at ProjectDashboard.swift:77-82) — any file
added/removed/renamed under `.scarf/` triggers a dashboard refresh, not just `dashboard.json`
itself.

---

## 2. Mini-app contract

**Manifest model**: `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/MiniAppManifest.swift`
**Permissions**: `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/MiniAppPermission.swift`
**Discovery/loading**: `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppService.swift`
**Bridge (JS API surface)**: `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppBridge.swift`,
`scarf/scarf/Features/Projects/MiniApp/ScarfMiniAppBridge.swift`

### On-disk location
`<project>/.scarf/miniapps/<id>/miniapp.json` (MiniAppService.swift:37-50). The mini-app's own dir
is `<project>/.scarf/miniapps/<id>/` and is the scope root for the `scarf-miniapp://` custom
scheme handler (comment, MiniAppService.swift:14-18) — **the directory name is canonical**: on
load, `manifest.id` is forcibly overwritten to the directory name regardless of what the JSON
claims (MiniAppService.swift:87-89), so a manifest can't spoof a different mini-app's id/dir.

### `<id>` validation (MiniAppService.swift:58-67)
Single path component, `[A-Za-z0-9._-]` only, non-empty, ≤ 64 chars, no leading dot. Use this
charset when Phase 2 picks a mini-app id (e.g. `harness-runs` is safe; `harness/runs` is not).

### `miniapp.json` schema (MiniAppManifest.swift:23-99, lenient decode)
| field | required? | default |
|---|---|---|
| `id` | **required** | — (but overwritten by dir name on load anyway) |
| `name` | **required** | — |
| `version` | optional | `"1.0.0"` |
| `entry` | optional | `"index.html"` |
| `minBridgeVersion` | optional | `"1.0"` — checked at mount against `scarf.version`; mismatch → degraded load or refusal (comment, line 29-30) |
| `permissions` | optional | `[]` (**default-deny** — comment line 32) |
| `panelHint` | optional | `nil`; `{preferredWidth: Double?, placement: String?}`, advisory only |
| `generated` | optional | `false` — `true` marks agent-written apps, which get stricter defaults (no `net`, no `file:write`) until the user explicitly elevates (line 35-36) |

Unknown JSON keys are ignored (forward-compat comment, line 21-22). A **minimal valid manifest**
is just `{"id": "x", "name": "X"}` plus an `index.html` at the mini-app dir root.

### Permission model (MiniAppPermission.swift, wire form = flat string)
Default-deny; every bridge surface a mini-app touches must be declared and user-approved before
first run (comment lines 5-10). Web content can **never** reach secrets, `config.yaml`,
`auth.json`, arbitrary filesystem, or Hermes tools regardless of declaration.

Enumerated permissions (rawValue in parens):
- `prompt` (`"prompt"`) — send to bound ACP session, rate-limited host-side. **sensitive**.
- `events` (`"events"`) — subscribe to streamed ACP events. not sensitive.
- `query(kind)` (`"query:<kind>"`) — read a whitelisted data kind (e.g. `kanban.tasks`, `sessions`,
  `messages`, `cron.jobs`, `insights.tokens`). Only `kanban.tasks` is in
  `nonSensitiveQueryKinds` (line 86) — **every other kind is sensitive by default**, including
  ones not yet wired.
- `kanbanWrite` (`"kanban:write"`) — move/create kanban tasks. **sensitive**; read-only is the v1
  default per the file's own comment (line 27-28) — i.e. kanban write is a stated but
  not-yet-default-granted surface.
- `fileRead` (`"file:read"`) — read files under project root. not sensitive.
- `fileWrite` (`"file:write"`) — write files under project root. **sensitive**.
- `store` (`"store"`) — per-(project, mini-app) KV via `scarf.store.get/set`. not sensitive.
- `net` (`"net"`) — outbound network, only via allowlist. **sensitive**.
- `unknown(raw)` — any unrecognized string, preserved verbatim, always treated sensitive/denied
  (line 98).

`isSensitive` (lines 93-104) drives what's auto-denied for `generated: true` mini-apps and what
the permission-preview sheet highlights. For a **hand-authored (non-agent-generated) demo
mini-app**, `generated: false` is the right choice if the screenshot flow wants permissions
pre-granted without the stricter agent-generated gate — confirm against the actual grant-store UI
flow before relying on this for the screenshot (not verified in this recon pass — see Blockers).

### v1-wired permissions
Per the task's own framing ("expect read + prompt"): confirmed wired at the model layer are
`fileRead`, `store`, `events`, `query(kanban.tasks)`, and `prompt` (rate-limited). `kanbanWrite`,
`fileWrite`, and `net` exist in the enum/sensitivity table but are explicitly called out as
deferred-behind-explicit-grant (`kanbanWrite`, line 27-28) or gated (`net`, `fileWrite`) — Phase 2
should treat only `fileRead` + `store` + `events` + `query:kanban.tasks` + `prompt` as safely
demoable without extra elevation UI, per the comments in this file. (Bridge-side enforcement of
each permission was not independently traced in this pass beyond the model/enum layer — see
`MiniAppBridge.swift` / `ScarfMiniAppBridge.swift` for the actual dispatch if Phase 2 needs to
verify a specific call is honored.)

### JS bridge surface (`window.scarf`)
Referenced by permission names above (`scarf.prompt`, `scarf.onEvent`, `scarf.query(kind, …)`,
`scarf.file.read`, `scarf.file.write`, `scarf.store.get/set`, `scarf.version`). Full method
signatures live in `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/MiniAppBridge.swift` and
`scarf/scarf/Features/Projects/MiniApp/ScarfMiniAppBridge.swift` (280 lines) — not fully inlined
here; read those two files directly when Phase 2 writes the actual JS calls.

### Minimal valid mini-app bundle
```
<project>/.scarf/miniapps/<id>/
  miniapp.json      # { "id": "<id>", "name": "..." }  (id will be overwritten to dir name anyway)
  index.html         # entry, default "index.html"
  (any other assets referenced by index.html, scoped under this dir)
```

---

## 3. `projects.json` registry contract

**Model**: `ProjectRegistry` / `ProjectEntry`, `ProjectDashboard.swift:5-109` (despite the
filename, the registry types live in this file, not a separate one).
**Service**: `ProjectDashboardService.loadRegistry`/`saveRegistry`, `ProjectDashboardService.swift:29-77`.

Path: `~/.hermes/scarf/projects.json` (confirmed live on this machine — see §6).

### `ProjectRegistry`
`{ "projects": [ProjectEntry] }` — flat wrapper, no version field at the registry level.

### `ProjectEntry` (custom Codable, lenient — ProjectDashboard.swift:86-108)
| field | required? | notes |
|---|---|---|
| `name` | required | also serves as `Identifiable.id` (line 16) |
| `path` | required | absolute path |
| `folder` | optional, defaults `nil` | sidebar grouping; v2.3 schema v2 addition, v2.2 files decode fine |
| `archived` | optional, defaults `false` | soft-archive/hide-from-sidebar; **only encoded when `true`** (line 104-106, `encode` skips the key when `false`) — so old rows stay minimal on rewrite |
| `uuid` | optional, defaults `nil` | stable per-project id, the registry's index into `<path>/.scarf/project.json`; **excluded from `Equatable`/`Hashable`** by hand (lines 54-73) so back-filling it doesn't disturb sidebar selection identity; minted + back-filled by `ProjectStore` on first migration |

Confirmed live shape (`~/.hermes/scarf/projects.json`, §6): exactly these keys, `uuid` present on
every row already (this machine has been through the v2.3+ migration).

### Registry write path
`saveRegistry` (ProjectDashboardService.swift:61-77) `mkdir -p`s the `.hermes/scarf` dir, encodes,
then **pretty-prints + sorts keys** via a `JSONSerialization` round-trip "because agents may read
this file" (comment line 68) — Phase 2's cron/kanban seeding should expect (and can rely on)
pretty, sorted-key JSON if it writes this file directly, though the recommended path is Scarf's
own install/registration flow, not a hand-write.

### Canonical `ScarfProject` record (richer, separate file)
`<path>/.scarf/project.json` — `ScarfProject` struct, `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ScarfProject.swift:36-275`.
This is the "first-class" per-project record (`ProjectStore.swift`) that the registry entry
merely indexes via `uuid`. Minimal decodable record is `{id, name, rootPath}` (lines 216-220);
everything else (`modelPresetId`, `board`, `cronJobIds`, `memoryNamespace`, `secretsScope`,
`templateLockRef`, `hostBindings`, `miniApps`) defaults on decode. Notably:
- `board: String?` — Kanban tenant/board slug (ScarfProject.swift:80-83), mirrors
  `KanbanTenantResolver`'s `scarf:<slug>` convention.
- `cronJobIds: [String]` — cron jobs tagged `[proj:<id>]` (index only, not authoritative — derived
  by scanning `jobs.json` names, see `ProjectStore.cronJobIds`, ProjectStore.swift:293-302).
- `miniApps: [MiniAppRef]` — `{id, generated}` only; full manifest loaded separately
  (ScarfProject.swift:109-118, 141-165). **Granted permissions deliberately do NOT travel here** —
  a clone must re-approve mini-app permissions itself (line 117-118).

`ProjectStore.derive(from:)` (ProjectStore.swift:140-177) builds a `ScarfProject` for a registry
row lacking one by reading `manifest.json` (model preset id), `KanbanTenantReader` (board),
`template.lock.json` presence, cron job name-prefix scan, `config.json` secret key names, and
`MiniAppService.discoverRefs`. This runs automatically/idempotently — Phase 2 does not need to
hand-write `project.json`; registering in `projects.json` (or Scarf's own "add project" flow) plus
having a `manifest.json`/`.scarf/` dir is enough for `derive()` to populate the rest lazily.

### Cockpit panel gating (which of Dashboard / Board / Site show up)
`scarf/scarf/Features/Projects/Views/ProjectCockpitView.swift:205-212`:
```swift
let hasKanban   = capabilitiesStore?.capabilities.hasKanban ?? false   // line 205 — HERMES capability, not per-project
let hasDashboard = viewModel?.dashboard != nil                         // line 206 — .scarf/dashboard.json parsed successfully
let hasSite     = siteWidget != nil                                    // line 207 — dashboard has a `type: "webview"` widget anywhere
case .dashboard: return hasDashboard
case .board:     return hasKanban
case .site:      return hasSite
```
- **Dashboard panel**: gated purely on whether `dashboard.json` exists AND parses (§1) — no
  per-project opt-in flag.
- **Board (Kanban) panel**: gated on the *server's* Hermes capability flag `hasKanban`
  (`HermesCapabilities.hasKanban`), **not** on whether this specific project has any tasks — i.e.
  it's an all-or-nothing per-server toggle, not a per-project one. (`ProjectKanbanTab.swift:10`
  confirms the same capability gate.)
- **Site panel**: gated on the dashboard containing a `webview` widget (see §1).
- **Fleet** panel is unconditional (multi-host view); **Mini-apps** launch surface is separate,
  populated from `MiniAppService.discover` — not one of the three tab-gated panels above but its
  own list/launcher (`MiniAppLaunchView.swift`).

So: for the demo, dropping a `.scarf/dashboard.json` (§1) turns on Dashboard (+Site if it has a
webview widget); Board turns on automatically if the Scarf-connected Hermes server has Kanban
enabled server-wide (verify via `hermes kanban --help`, confirmed present — §6) — no per-project
switch to flip for Kanban.

---

## 4. Kanban + cron binding

### Kanban tenant mechanics
- **Manifest field**: `<project>/.scarf/manifest.json` → `kanbanTenant: String?`, read by
  `KanbanTenantReader.tenant(forProjectPath:)`
  (`scarf/Packages/ScarfCore/Sources/ScarfCore/Services/KanbanTenantReader.swift:19-28`). This is
  the per-project board/tenant slug, mirrored onto `ScarfProject.board`
  (ScarfProject.swift:80-83, "mirrors `KanbanTenantResolver`'s `scarf:<slug>` convention").
- Convention: `scarf:<slug>` (comment, ScarfProject.swift:81-82) — i.e. a project's board is
  typically tagged as tenant `scarf:<project-slug>` inside the one global `kanban.db`.
- **hermes CLI**: `hermes kanban --board <slug> create ...` / `list` / `show` / `assign` / etc.
  (`hermes kanban --help` output, §6) — `--board` is the top-level flag that scopes to a
  tenant/board. Kanban is "durable SQLite-backed task board shared across Hermes profiles… one
  board per project/workstream" (help text).
- Task↔project binding beyond the board slug (e.g. whether individual tasks also carry a
  `[proj:<uuid>]`-style tag the way cron jobs do) was **not directly verified in `HermesKanbanTask`
  model this pass** — `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/HermesKanbanTask.swift`
  exists and should be read before Phase 2 writes task-seeding code, to confirm the exact fields
  `hermes kanban create` accepts/needs (title, board, description, etc.).

### Cron job → project binding
- **Tag convention**: cron job `name` is prefixed `[proj:<ScarfProject.id uuidString>]` (new) or
  `[tmpl:<templateId>]` (legacy, template-based) — `ProjectStore.cronJobIds`
  (`ProjectStore.swift:293-302`) scans `jobs.json` for names `hasPrefix`-matching either prefix to
  build the project's `cronJobIds` index. **This is a naming convention scanned at read time, not
  a stored foreign key** — Phase 2 seeding a cron job for the harness project should prefix the job
  `name` with `[proj:<harness ScarfProject id>]` for it to show up under the project's Cron panel.
- **jobs.json location & shape**: `context.paths.cronJobsJSON` → confirmed live at
  `~/.hermes/cron/jobs.json` (§6). Top-level `CronJobsFile = {jobs: [HermesCronJob], updated_at}`
  (`HermesCronJob.swift:334-359`).
- **`HermesCronJob` fields** (`HermesCronJob.swift:3-125`, CodingKeys 52-72): `id`, `name`,
  `prompt`, `skills`, `model`, `schedule` (`CronSchedule`), `enabled`, `state`, `deliver`,
  `next_run_at`, `last_run_at`, `last_error`, `script` (pre-run script; decodes legacy
  `pre_run_script` too but always **encodes** as `script` — line 57-62 comment explains Hermes
  itself only ever persisted `"script"`), `delivery_failures`, `last_delivery_error`,
  `timeout_type`, `timeout_seconds`, `silent`, **`workdir`** (v0.12+ — cwd for the job's
  terminal/file/code_exec tools and where AGENTS.md/CLAUDE.md get injected from, line 22-26),
  `context_from` (v0.12+, chain prior job output), `no_agent` (v0.13+ watchdog-only mode),
  `attach_to_session` (v0.18+). Any other key round-trips verbatim via `extra: [String: JSONValue]`
  (line 43-50) — the model explicitly never strips unknown Hermes-owned fields on rewrite.
- **`CronSchedule`** (`HermesCronJob.swift:257-329`): `kind` (e.g. `"cron"`, `"interval"`,
  presumably `"once"` — not enumerated as a closed set in this struct), `run_at`, `display`,
  `expr` (cron expression — canonical key; legacy `expression` decoded as fallback but never
  encoded, per comment 261-266), `minutes` (required for `kind == "interval"`, comment 267-269).
- **What Phase 2 would write to seed jobs**: append `HermesCronJob` entries to
  `~/.hermes/cron/jobs.json`'s `jobs` array with `name` prefixed `[proj:<harness-project-uuid>]`,
  `workdir` set to `/Users/awizemann/Developer/harness`, and a `schedule` (e.g.
  `{kind:"cron", expr:"0 8 * * 1", display:"0 8 * * 1"}`) — but **the safer/more correct path is
  the `hermes` CLI itself** (there is a `hermes cron` surface implied by
  `ProjectStore`'s comment "uninstall removes via `hermes cron remove`" at ScarfProject.swift:87)
  rather than hand-editing the live jobs.json this session is actively using (§6 shows this
  machine's jobs.json has real, in-use jobs — do not corrupt it).

---

## 5. Harness repo survey `[harness]`

Path: `/Users/awizemann/Developer/harness`

**What it does** (from `README.md`): Harness is a native macOS developer tool that drives an iOS
Simulator, a macOS app, or a web app with an AI agent to run "user tests" — not scripted UI tests
but real-user simulation. You write a goal in plain language and a persona; an LLM agent (Claude,
GPT, Gemini, or local Ollama models) reads screenshots, clicks/types/scrolls, and pursues the
goal, narrating what it sees and flagging UX friction, stopping on success/failure/give-up. Every
run produces three artifacts: whether the goal completed, the replayable path of screens+actions,
and timestamped friction events. v0.7.0 (alpha) adds an MCP server (`harness-mcp`) with both
autonomous run tools and new no-LLM-loop step-level UI session tools (`start_ui_session` /
`observe_ui` / `act_ui` / `end_ui_session` / `list_ui_sessions`) for an external client to drive a
target directly.

**Real numbers for a demo dashboard**:
- **Version**: `0.7.0` (README badge + release tag)
- **License**: MIT
- **Platforms**: macOS 14+ · targets iOS Simulator, macOS apps, and Web apps
- **Language**: Swift 6
- **Tests**: 41 test files under `Tests/HarnessTests/`, **303 `@Test` functions** (grep count,
  Swift Testing framework — not XCTest). README's own claim is "275 unit tests passing (+46 across
  this release's two feature commits)" as of the v0.7.0 write-up — the two numbers are close but
  not identical (grep count is current-tree truth; README prose is a point-in-time release note).
  **Use the 303 grep-count or re-run `swift test`/xcodebuild test for an exact current pass count**
  before putting a number on a dashboard stat widget.
- **Releases**: 8 tags on disk under `releases/` and matching `git tag`: v0.1.0, v0.2.0, v0.2.1,
  v0.3.0, v0.3.1, v0.5.0, v0.6.0, v0.7.0 (note: no v0.4.0 — gap in the sequence).
- **Xcode targets** (`project.yml`): `Harness` (macOS app), `HarnessTests`, `HarnessCLI` (dev-time
  driver), `HarnessMCP` (MCP server) — 4 targets, plus `HarnessDesign` as a sources path folded
  into the app target (mock/reference screens excluded from compilation) and a `Sparkle`
  dependency for auto-update.
- Other repo structure worth citing for a table/list widget: `AGENTS.md`, `CLAUDE.md`,
  `CONTRIBUTING.md`, `GEMINI.md`, `docs/`, `standards/`, `site/` (landing page + screenshots used
  in the README hero image), `wiki/`, `vendor/WebDriverAgent` (submodule).

---

## 6. Local `~/.hermes` state `[local]`

- **`~/.hermes` exists**: yes, full profile directory present and actively in use (state.db,
  sessions/, kanban.db, cron/, etc. all populated with real timestamps through 2026-08-13 today).
- **Hermes version**: `Hermes Agent v0.20.0 (2026.8.3)`, installed at
  `/Users/awizemann/.hermes/hermes-agent`, binary on PATH at `/Users/awizemann/.local/bin/hermes`,
  Python 3.11.15, OpenAI SDK 2.24.0 (`hermes --version` output).
- **`~/.hermes/scarf/projects.json` exists** and currently lists **5 real projects**: `cdo-tracker`,
  `news-tracker`, `stocker`, `memory-reflection` (path = `~/.hermes` itself — a self-referential
  project), plus two leftover **Scarf UI-test fixtures** (`HackerNews Daily Digest` /
  `HackerNews Daily Digest 2`, paths under
  `~/Library/Containers/com.scarfUITests.xctrunner/...`) that look like they should have been
  cleaned up by the test harness but weren't — worth flagging separately, not a Phase-1 blocker.
  Every row already carries a `uuid` (this machine is past the v2.3 registry migration). **Harness
  is not yet registered** — Phase 2 needs to add a `harness` entry (name/path/uuid) to this file
  (via Scarf's UI/install flow, not a hand-edit, to keep it in the pretty-printed sorted-key format
  `saveRegistry` produces).
- **`~/.hermes/scarf/` also has**: `miniapp_grants.json` (1385 bytes — real granted-permission
  state exists already, useful to inspect before Phase 2 assumes a clean-slate grant flow),
  `model_presets.json`, `session_project_map.json`, `slash-commands/` dir.
- **Cron jobs**: real, live jobs exist in `~/.hermes/cron/jobs.json` — e.g. `alan-news-tracker`
  (paused, weekly `0 8 * * 0`) and a Stocker weekly trading review job that explicitly reads that
  project's `.scarf/dashboard.json` as an input to its prompt (a nice precedent pattern for a
  Harness cron job later: "summarize test pass rate from dashboard.json"). **Do not modify this
  file directly** — it's live production state for this user's actual profile, not a sandbox.
  Multiple timestamped backups also exist under `~/.hermes/skills/.curator_backups/*/cron-jobs.json`
  and `~/.hermes/state-snapshots/*/cron/jobs.json` (unrelated to Phase 2, just noting they exist).
- **Kanban availability**: `hermes kanban --help` responds — full subcommand set present
  (`init, boards, create, swarm, list, show, assign, ..., dispatch, daemon, watch, stats, ...`).
  Kanban is described as "Durable SQLite-backed task board shared across Hermes profiles... one
  board per project/workstream." `~/.hermes/kanban.db` exists and is actively sized (114 KB, with
  WAL files showing recent activity) — Kanban is live and usable on this machine, not something
  that needs bootstrapping. `hermes kanban boards` (not run this pass) would list existing
  board/tenant slugs — worth running before Phase 2 to see if a `scarf:harness` tenant already
  needs creating vs. already exists from a prior experiment.

---

## Fresh-eyes re-verification (the three most load-bearing claims)

Re-checked directly against source a second time, independent of the notes above:

1. **Dashboard schema field names** — re-read `ProjectDashboard.swift:113-273` in full a second
   time. Confirmed: `ProjectDashboard` requires `version`, `title`, `sections` (no
   `decodeIfPresent`, standard synthesized `Codable`); `DashboardWidget` requires only `type` +
   `title`, every other field is `Optional`. Confirmed v2.7 fields (`path`, `lines`, `jobId`,
   `cells`, `gridColumns`, `sparkline`) are real struct members, not comments/dead code — they sit
   alongside the documented fields inside the same `Codable` struct and would decode/encode
   normally. Confirmed via the section title also aliasing `Identifiable.id` (line 149) — a real
   footgun for duplicate section titles.

2. **Mini-app manifest name/format** — re-read `MiniAppManifest.swift` in full a second time and
   cross-checked against `MiniAppService.swift:75-96` (`loadManifest`). Confirmed the file is
   `miniapp.json` (not `manifest.json` — that name is reserved for the *project*-level template
   manifest at `.scarf/manifest.json`, a different file entirely, read by `KanbanTenantReader` and
   `ProjectStore.templateInfo`/`configSchemaFields`). Confirmed only `id`+`name` are hard-required
   at decode time, and confirmed the directory-name-wins-over-manifest-id behavior
   (`manifest.id = id` unconditionally after decode, line 88) — this is a security property (dir
   is the trust boundary for `scarf-miniapp://`), not incidental, and Phase 2 should not rely on
   the `id` value inside `miniapp.json` differing from the directory name.

3. **`projects.json` shape** — re-read `ProjectEntry`'s custom `Codable` a second time
   (`ProjectDashboard.swift:86-108`) and diffed it live against the actual file at
   `~/.hermes/scarf/projects.json` (cat'd in §6). The on-disk file matches the model exactly: every
   row has `name`, `path`, `uuid`; none currently sets `folder` or `archived` (both correctly
   absent since `archived` only encodes when `true`, and no row is in a folder). Confirmed
   `saveRegistry` pretty-prints + sorts keys, matching the on-disk file's visual formatting
   (2-space indent, sorted keys) — so a future hand-inspection of this file post-Phase-2 can
   confirm whether Scarf's own write path was used vs. a manual edit.

No divergences found between claims and code on re-check.

---

## Surprises / blockers for later phases

- **`docs/DASHBOARD_SCHEMA.md` is meaningfully stale** — 5 widget-related capabilities
  (`markdown_file`, `log_tail`, `cron_status`, `status_grid`, `sparkline`) exist in code and are
  fully wired into the Codable model but undocumented. Not a blocker (code is source of truth,
  confirmed working), but Phase 2 authors should read `ProjectDashboard.swift` directly, not the
  doc, when picking widget types for the harness dashboard.
- **Kanban panel visibility is server-wide, not per-project.** There's no per-project "enable
  Kanban" toggle to seed — it's gated on the whole Hermes server's `HermesCapabilities.hasKanban`.
  Confirm this capability is actually on for whatever server/gateway the demo screenshots will be
  taken against (not verified in this pass — `HermesCapabilities` wasn't traced).
- **Cron→project binding is a name-prefix convention (`[proj:<uuid>]`), not a stored field on the
  job.** Any hand-written or CLI-written seed job for harness must get this prefix exactly right
  in the job `name`, and needs harness's `ScarfProject.id` (UUID) to exist first — meaning
  Phase 2 needs to register the project (§3/§6) and let `ProjectStore.derive()` mint the UUID
  *before* it can correctly tag a cron job for it.
- **This machine's `~/.hermes` is live, real user state**, not a sandbox — `jobs.json`,
  `kanban.db`, `projects.json` all have genuine in-use data (paused news-tracker job, real Stocker
  project, etc.). Later phases must seed additively and must not corrupt/overwrite this data.
  Recommend seeding via `hermes` CLI commands (`hermes cron add`/equivalent, `hermes kanban
  create`) rather than hand-editing `jobs.json`/`kanban.db` directly, both for safety and because
  the CLI is the documented, capability-gated write path.
- **Two stale Scarf-UI-test fixture rows already sit in `projects.json`** (`HackerNews Daily
  Digest` / `HackerNews Daily Digest 2`, pointing at ephemeral xctrunner tmp paths that likely no
  longer exist on disk). Not a Phase 1 blocker but worth a cleanup pass at some point — flagged
  here rather than fixed, since this recon pass is read-only except for this brief.
- **Kanban task↔project field-level binding** (beyond the board/tenant slug) and the **exact
  `hermes kanban create` / `hermes cron` CLI argument shapes** were not independently verified —
  `HermesKanbanTask.swift` exists but wasn't read in this pass, and no cron CLI subcommand help was
  captured (only `hermes kanban --help`). Phase 2 (which actually seeds cards/jobs) should run
  `hermes kanban create --help`, `hermes cron --help` (or equivalent) directly before writing code
  against assumed flag names.
- **Mini-app bridge method signatures** (`MiniAppBridge.swift`, `ScarfMiniAppBridge.swift`, ~280
  lines each) were located but not read line-by-line — permission *names* and *sensitivity* are
  fully verified (§2), but the exact JS call surface (method names, argument shapes, return
  envelopes) needs a direct read before Phase 2 writes the demo mini-app's `index.html`/JS.
