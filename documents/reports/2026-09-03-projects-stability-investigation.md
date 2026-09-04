# Projects Stability Investigation — raising projects to a first-class citizen

Date: 2026-09-03 · Author: Claude (investigation for Alan) · Status: findings + recommendation, no changes made

## Why now

Projects are core to Scarf but were deliberately built agent-driven and loosely structured. In practice agents keep breaking them: components don't update, the sidebar/menus break, dashboards break. This report maps how projects actually work today, documents live breakage found on this machine, identifies root causes, and recommends how to make projects first-class — including whether to build tools / an MCP server for project CRUD.

## 1. How projects work today (verified against source)

**Registry** — `~/.hermes/scarf/projects.json` (`HermesPathSet.swift:94-95`). Schema: `ProjectRegistry { projects: [ProjectEntry] }`; `ProjectEntry { name, path, folder?, archived, uuid? }` (`ProjectDashboard.swift:5-108`). `ProjectEntry.id` **is the display name** — name is the identity key for SwiftUI selection, dedupe, rename, remove; `ProjectStore.indexInRegistry` matches by **path**; the stable UUID is a back-filled optional. Three identity keys coexist.

**Canonical record** — `<project>/.scarf/project.json` (`ScarfProject`, written/read by `ProjectStore`). The registry is the fast-list index; the record is canonical. `derive()` migrates legacy projects lazily.

**Sidecar files agents write directly**: `.scarf/dashboard.json`, `manifest.json`, `config.json`, `slash-commands/*.md`, `miniapps/<id>/miniapp.json`, plus `AGENTS.md` (managed block rendered by `ProjectContextBlock.renderManagedBlock`).

**Refresh** — `HermesFileWatcher`: FSEvents locally, mtime polling over SSH; watches the registry plus each project's `dashboard.json` and `.scarf/` dir; 0.5s coalescing. Known gap: in-place appends to sidecar files aren't detected (`HermesFileWatcher.swift:191-195`). iOS has no watcher (pull-to-refresh only).

**Agent interface** — there is none, structurally. Two accurate bundled skills (`scarf-template-author` 1.3.0, `scarf-miniapp-author` 1.0.0, installed by `SkillBootstrapService`) tell the agent to author files by hand. The load-bearing instruction is `scarf-template-author/SKILL.md:452`: *append an entry to `~/.hermes/scarf/projects.json` yourself — read, parse, append, write back*. No schema validation, no UUID, no atomicity. Every user-facing CRUD operation (add, scaffold, install, rename, archive, upgrade…) exists only as Swift services behind the UI; **none is exposed to agents**.

## 2. Live breakage found on this machine (2026-09-03)

1. **Corrupt registry entry**: `shabubox-seo-tracker` (created 2026-09-02 by an agent) carries `"uuid": "SHABUBOX-SEO-TRACKER-2026-09-03"` — not a UUID. The agent hand-wrote the registry per skill Step 8 and invented the field.
2. **Half-formed project**: same project has no `.scarf/project.json`, no `upgrade.json`, ad-hoc `reports/` and `runs/` dirs, and a manifest with `"config": 0` where healthy manifests differ. Its dashboard.json is schema-correct (agent evidently copied a healthy sibling).
3. **A hallucinated skill is installed**: `~/.hermes/skills/scarf/scarf-project-workflows/` (2026-06-08, predates the real skills) documents **fake CLI commands** (`hermes scarf-template-author`, `scarf install`, `scarf deploy`, `hermes scarf-project-auditing`), a **wrong dashboard schema** (`widgets` at top level, `metric`/`status` types Scarf doesn't render), and links to scarf.sh — the unrelated analytics company. It competes for activation with the real skills on every project task. This alone plausibly explains a big share of "agents constantly break them."

## 3. Root causes (with in-tree evidence)

- **R1 — No safe write path for agents.** Agents mutate the registry and sidecars with raw file writes; the only guidance is prose in a skill. The skill can't enforce anything.
- **R2 — Reader fragility amplifies every bad write.** One malformed byte in `projects.json` → `loadRegistry` logs and returns an **empty registry** (`ProjectDashboardService.swift:42-47`): sidebar, iOS list, chat picker, `ProjectStore.list()`, kanban tenant resolution all go empty with no user-visible error — and a subsequent UI save **persists the empty list over the file**. Malformed `project.json` → silent nil → `derive()` **overwrites it**.
- **R3 — Identity is fragile.** Name-as-id + path-matched index + optional UUID; `derive(from:)` mints a **fresh UUID per call** until persisted (`ProjectStore.swift:181`), a hazard already flagged in `ProjectTemplateInstaller.swift:302-309`; the rename-drops-UUID regression (`ProjectsViewModel.swift:131-137`) already happened once.
- **R4 — Errors have no surface.** Registry mutators can't report failure (`ProjectsViewModel.swift:79-86` comment); parse failures are os_log-only except the one dashboard case.
- **R5 — Schema truth is scattered.** Widget vocabulary hand-synced across Swift renderer, `site/widgets.js`, and `tools/widget-schema.json` (validator only runs at catalog build); sentinel-manifest suppression duplicated in three readers; registry path constant duplicated in `KanbanTenantResolver.swift:117`.
- **R6 — Stale/wrong agent guidance persists.** Nothing audits `~/.hermes/skills` for junk skills that claim Scarf's name.

## 4. Recommendation — two layers, in this order

### Layer A: Make Scarf defensively self-healing (do this regardless of the agent-API decision)

The registry is agent-writable forever (old skills, other tools, remotes) — Scarf must survive bad input, not just discourage it.

1. **Never destroy on parse failure.** Malformed `projects.json` → quarantine (`projects.json.corrupt-<ts>`), keep last-known-good in memory, surface a banner ("Projects registry is damaged — Repair"), and refuse to save an empty registry over a non-empty file.
2. **Per-entry salvage decode.** Decode entries individually; a row with an invalid `uuid`/field is kept with the bad field dropped (and flagged), instead of nuking the whole list. The shabubox case should cost one warning badge, not anything more.
3. **Atomic writes + rolling `.bak`** for registry and `project.json` writes.
4. **Reconciliation pass ("Project Doctor").** One service that walks registry ↔ `.scarf/project.json` ↔ on-disk `.scarf/` scan (the enumeration design already exists in memory: checkpoints, sessions.cwd, cron, kanban, `.scarf/` scan), repairs UUIDs, backfills missing records via the existing `derive()`/`ProjectUpgradeService`, detects orphans/duplicates, and reports in the cockpit. Most pieces already exist; this is composition.
5. **Fix the known identity bugs while in there**: stop `derive(from:)` re-minting UUIDs on every unpersisted call; unify the duplicated registry-path constant and sentinel-manifest suppression; give VM mutators an error surface.

### Layer B: Yes — give agents a structured CRUD surface, as an MCP server

A Scarf-shipped **`scarf-projects` MCP server** (registered into Hermes's `mcpServers` config, which Scarf already edits) is the right shape, better than a bare CLI, because tools carry schemas the model sees, results can return validation errors the agent can react to, and it's discoverable without skill prose. Proposed initial tools, all thin wrappers over the existing Swift services (`ProjectStore`, `ProjectDashboardService`, `ProjectConfigService`, `ProjectScaffolder` bits):

- `project_list` / `project_get`
- `project_register(name, path)` — mints the UUID, writes `project.json`, upserts the registry (replaces skill Step 8 entirely)
- `project_update_dashboard(project, dashboard_json)` — validates against the real widget schema before writing; returns actionable errors
- `project_set_config` (keychain-routing preserved), `project_add_slash_command`, `project_validate` (the Doctor as a tool)

Then: bump `scarf-template-author` to instruct "use the `scarf-projects` tools; hand-edit files only if the tools are absent", and have `SkillBootstrapService` (or the Doctor) flag/remove known-bad skills like `scarf-project-workflows`.

**Constraint to decide upfront:** an MCP server runs where the agent runs. For the local server (the dominant case) Scarf can bundle a small stdio binary. For remote SSH hosts (potentially Linux), the binary can't just be the Mac one — options are (a) skill-with-schema fallback on remotes, (b) a tiny portable implementation later. Recommend shipping local-only first, capability-gated per charter C1 spirit.

**Why this ordering:** Layer A fixes the user-visible symptom class (surfaces breaking) even for existing bad state and future rogue writes; Layer B removes the cause going forward and becomes the natural attachment point for the next step — **connecting bots to projects** (a `project_bind_bot` tool + a `bots` field on `ScarfProject` slot cleanly into a structured write path; they'd be miserable as hand-edited JSON conventions).

## 5. Immediate cleanups awaiting Alan's go-ahead (state changes, not done)

1. Delete `~/.hermes/skills/scarf/scarf-project-workflows/` (hallucinated, actively harmful).
2. Repair `shabubox-seo-tracker`: fix the registry `uuid` to a real UUID, run Upgrade Project to backfill `project.json`/provenance.

## 6. Source map (key files)

- Registry model + entry: `scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ProjectDashboard.swift:5-108`
- Registry IO: `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectDashboardService.swift:29-77`
- Canonical record + store: `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectStore.swift` (derive :147-181, resurrection guard :33-45,100-123, indexInRegistry :301-313)
- User CRUD: `scarf/Features/Projects/ViewModels/ProjectsViewModel.swift`
- Upgrade: `scarf/scarf/Core/Services/ProjectUpgradeService.swift`
- Watcher: `scarf/scarf/Core/Services/HermesFileWatcher.swift`
- Agent context block: `scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectContextBlock.swift:153-218`
- Skills: `scarf/scarf/Resources/BuiltinSkills.bundle/*/SKILL.md`; bootstrap: `scarf/scarf/Core/Services/SkillBootstrapService.swift`
- Widget schema drift: `tools/widget-schema.json`, `tools/build-catalog.py:59-72`
