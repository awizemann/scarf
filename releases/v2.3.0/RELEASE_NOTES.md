## What's New in 2.3.0

The projects sidebar stops being a flat list and becomes a workspace. Folders, rename + archive + search + keyboard jumps, a per-project Sessions tab with a one-click New Chat button, and — the big architectural piece — every project-scoped chat now automatically carries Scarf-managed context into the agent itself, so the agent knows what project it's operating in without any user prompting.

### Projects sidebar grows up

- **Folders.** Group related projects with folders. Right-click any project → *Move to Folder…* — pick an existing folder or create a new one on the fly. Folders are soft: any folder name that isn't referenced by at least one project just disappears, so there's no "empty folder" state to clean up.
- **Rename** a project from the context menu. Preserves everything else — the path, folder assignment, archive flag, and any running cron attribution stay intact. Rejects duplicate names + empty input with an inline warning.
- **Archive / Unarchive.** Hide projects you don't actively use without deleting anything. The sidebar's bottom bar gains a Show Archived toggle so they're one click away when you need them.
- **Search.** ⌘F focuses a filter field at the top of the sidebar. Fuzzy-matches on name, path, and folder label, live as you type.
- **Keyboard jumps.** ⌘1 through ⌘9 jump to the first nine top-level projects. Pairs cleanly with Scarf's existing window-level shortcuts.

Registry migration is non-destructive — `~/.hermes/scarf/projects.json` gains two optional fields (`folder`, `archived`), and a file written by v2.3 is still parseable by v2.2.1 (unknown-keys are ignored), so downgrade works if you ever need it.

### Per-project Sessions tab

Every project now has a **Sessions** tab alongside Dashboard and Site. It shows chats attributed to this specific project — the sidecar at `~/.hermes/scarf/session_project_map.json` maintains the session-to-project mapping (Hermes's `state.db` has no column for this, so Scarf owns the record).

- **New Chat** — spawns `hermes acp` with the project's directory as the session's working directory, attributes the resulting session to the project, and takes you straight into the chat view.
- **Click any listed session to resume it** in the Chat tab; the project indicator comes along automatically.
- Forward-only attribution: sessions you've already started via the CLI or via the global Chat sidebar section continue to live in the global Sessions view unchanged; they simply aren't attributed to any project.

File descriptors are released cleanly on tab-disappear, matching Scarf's other Hermes-DB-reading VMs.

### Agent context injection via AGENTS.md

The architectural headline of this release. Hermes has no native "project" concept and ACP's wire protocol drops extra session params. But Hermes DOES auto-read `AGENTS.md` from the session's cwd at startup (priority: `.hermes.md` → `HERMES.md` → `AGENTS.md` → `CLAUDE.md` → `.cursorrules`, first match wins, 20KB cap). So Scarf leans on that.

Every time you start a project-scoped chat, Scarf writes a managed block into `<project>/AGENTS.md`:

```
<!-- scarf-project:begin -->
## Scarf project context

You are operating inside a Scarf project named "<Project Name>". …

- Project directory: …
- Dashboard: …
- Template: <id> v<version>
- Configuration fields: field_a, api_token (secret — name only, value stored in Keychain)
- Registered cron jobs: [tmpl:<id>] <name> — schedule …
…
<!-- scarf-project:end -->
```

Ask a fresh chat *"what project am I in?"* and the agent answers with the project name, dashboard path, template id, and current cron schedule — pulled from the block Hermes injected into its system prompt automatically.

**Invariants the block guarantees:**

- **Secret-safe.** Surfaces config field *names* with type hints; never values. A project whose config.json has Keychain-ref URIs renders the fields as `api_token (secret — name only, value stored in Keychain)`. Keychain URIs and plaintext values never appear in the block. Locked in by an explicit test (`refreshListsFieldNamesNotValues`).
- **Idempotent.** Two consecutive refreshes with unchanged state produce byte-identical output. The write is skipped entirely when no delta — no unnecessary file-watcher churn.
- **Bounded.** Everything outside the `<!-- scarf-project -->` markers is preserved across every refresh. Template-author AGENTS.md content lives safely below the block; hand-edits are never clobbered.
- **Non-fatal.** A failed block refresh doesn't block the chat from starting — logged + the session proceeds without the extra context.
- **Bare-project friendly.** Projects without an AGENTS.md (plain directories added via the + button) get one created with just the block. Agent awareness works even without template scaffolding.

**Template-author contract:** leave the `<!-- scarf-project -->` region alone in your bundled `AGENTS.md`. Put template-specific instructions below it so they're preserved across refreshes. The `scarf-template-author` scaffolding skill already teaches this pattern to future agents doing project scaffolding.

**Known caveat:** if any parent directory of your project contains a `.hermes.md` or `HERMES.md`, that file takes priority over the project's AGENTS.md in Hermes's discovery order — the Scarf block gets shadowed. No fix in 2.3 — planned for 2.4 pending design input on handling authored `.hermes.md` files.

### Chat UI — project awareness everywhere

Once the cwd, attribution, and AGENTS.md pieces land, the UI follows:

- **Folder chip in `SessionInfoBar`** at the start of the bar (before the working dot + title) shows the active project name with a folder icon.
- **Navigation title** reads `Chat · <ProjectName>` when scoped, plain `Chat` otherwise — macOS `Subject — Detail` convention.
- **Resumed sessions keep the indicator.** Whether you click a session in the project's Sessions tab or come in from a future deep-link, the attribution is looked up at resume time and the chip renders from the same state.

### Window-layout fixes

A pre-existing issue — untracked until v2.3's heavier Chat/Sessions content exposed it — where the window grew past the screen when you switched to content-heavy sections. Fixed by:

- Setting `WindowGroup.windowResizability(.contentMinSize)` so the window's floor (not ceiling) is derived from content.
- Capping `idealHeight` on `RichChatView` and `ProjectSessionsView` so their plain-VStack children (deliberate choice to dodge a LazyVStack whitespace bug) don't report screen-exceeding ideals upward through `NavigationSplitView.detail`.

Window now stays at a user-draggable size and persists across section switches.

### Under the hood

- New models: `SessionProjectMap` — `~/.hermes/scarf/session_project_map.json` serialization (`SessionAttributionService` manages it).
- New services: `SessionAttributionService` (reads + writes the sidecar), `ProjectAgentContextService` (writes the AGENTS.md marker block, tests cover prepend/replace/idempotency/secret-redaction).
- New view models: `ProjectSessionsViewModel` (per-project session list with attribution filter), `ChatViewModel` gains `currentProjectPath` + `currentProjectName`.
- `HermesFileWatcher` now watches the attribution sidecar — file-system events propagate through the VMs as they do for every other Scarf-written file.
- `ProjectsViewModel` gains `moveProject / renameProject / archiveProject / unarchiveProject / folders` — rename preserves selection; archive clears it; reorders driven by `localizedCaseInsensitiveCompare` for locale-aware ordering.
- **22 new Swift tests** across `ProjectRegistryMigrationTests`, `ProjectsViewModelTests`, `SessionAttributionServiceTests`, `ProjectAgentContextServiceTests`. Total: 93 tests.

### Icon tweak

App icon files renamed from iOS-template suffixes to macOS-native filenames + paired `Contents.json` update. Pure naming; no visual change at any rendered size.

### Migrating from 2.2.x

Sparkle will offer the update automatically. No config migration needed. Existing template installs are untouched — the v2.3 additions (folders, archive, sidecar) are purely additive; a v2.2.1 projects.json loads cleanly.

If you had any chat sessions attributed to projects in a pre-release v2.3 build, the forward-only attribution model means those sidecar entries surface correctly in the new Sessions tab on first launch.

### Documentation

- **[Project Templates wiki page](https://github.com/awizemann/scarf/wiki/Project-Templates)** — gained a "How the agent sees the project" section covering the AGENTS.md injection pattern.
- **Root `CLAUDE.md`** — new subsection "Project-scoped chat + Scarf-managed AGENTS.md context (v2.3)" under Project Templates, covering the sidecar, the marker contract, invariants, and the template-author contract.
- **`scarf-template-author` skill** — pitfall bullet added so future scaffolding agents preserve the marker region when authoring new templates.

### Thanks

Thanks to the users who exercised this release through several layout iterations, caught the `fetchSessions` short-circuit on a fresh VM, and pushed on the "agent doesn't know what project it's in" question until the AGENTS.md mechanism clicked. Several of these fixes are small on their own but add up to a much tighter per-project workflow.
