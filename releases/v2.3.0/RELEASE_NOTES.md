## What's New in 2.3.0

Two themes land together in this release. The projects sidebar stops being a flat list and becomes a workspace — folders, rename + archive + search + keyboard jumps, a per-project Sessions tab, and every project-scoped chat now automatically carries Scarf-managed context into the agent itself. And Scarf catches up to **Hermes v0.10.0's Tool Gateway**: paid Nous Portal subscribers can now route web search, image generation, TTS, and browser automation through their subscription without separate API keys — and they can sign in entirely from Scarf, no terminal needed.

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
- **Tool Gateway services.** `NousSubscriptionService` reads `~/.hermes/auth.json` to detect the subscription state. `NousAuthFlow` spawns `hermes auth add nous --no-browser` (with `PYTHONUNBUFFERED=1` so the device-code block surfaces immediately — Python block-buffers otherwise), parses the verification URL + user code with two line-anchored regexes, auto-opens the approval page via `NSWorkspace`, and confirms success by re-reading `auth.json`. `NousSignInSheet` drives the four-state UI (starting / waiting-for-approval / success / failure-with-billing-link). `CredentialPoolsOAuthGate` is the testable helper that routes providers to the right OAuth flow based on their overlay auth-type.
- **Catalog overlay merge.** `ModelCatalogService` gains a static `overlayOnlyProviders` table mirroring the 6 entries from `HERMES_OVERLAYS` in `hermes-agent/hermes_cli/providers.py`. `HermesProviderInfo` carries `isOverlay` and `subscriptionGated` flags so the picker can render them distinctly.
- **Config parsing.** `HermesConfig` gains `platformToolsets: [String: [String]]`; `HermesFileService` parses the `platform_toolsets.<platform>` block from `config.yaml` as written by `hermes setup tools`.
- **36 new Swift tests** across `ProjectRegistryMigrationTests`, `ProjectsViewModelTests`, `SessionAttributionServiceTests`, `ProjectAgentContextServiceTests` (22 for v2.3 projects work) + `ToolGatewayTests`, `NousAuthFlowParserTests`, `CredentialPoolsGatingTests` (14 for Tool Gateway). Total: 120 tests, all green against v2.3-projects + Tool Gateway combined.

### Icon tweak

App icon files renamed from iOS-template suffixes to macOS-native filenames + paired `Contents.json` update. Pure naming; no visual change at any rendered size.

### Tool Gateway — Nous Portal support

Hermes v0.10.0 introduced a **Tool Gateway**: paid [Nous Portal](https://portal.nousresearch.com) subscribers route web search (Firecrawl), image generation (FAL / FLUX 2 Pro), text-to-speech (OpenAI TTS), and browser automation (Browser Use) through their subscription. No separate API keys, no credential pool juggling. Scarf 2.3 surfaces the whole flow natively.

- **Nous Portal appears in the model picker.** Our picker used to read only the models.dev cache, which doesn't list Nous — so it was invisible. Scarf now merges Hermes's `HERMES_OVERLAYS` table on top of the cache, surfacing **six previously-hidden providers**: Nous Portal, OpenAI Codex, Qwen OAuth, Google Gemini CLI, GitHub Copilot ACP, and Arcee. Subscription-gated providers sort first, with a **Subscription** pill so they're visually distinct from BYO-key providers.
- **In-app sign-in.** Click *Sign in to Nous Portal* in the picker (or in the Auxiliary tab's fallback, or Credential Pools for the `nous` provider) and Scarf runs the device-code flow: opens the approval page in your browser, shows the device code in a large monospaced badge you can copy, and auto-detects success by re-reading `~/.hermes/auth.json`. No six-step terminal dance. Subscription-required failures surface a **Subscribe** button that opens the portal's billing page directly.
- **Per-task gateway routing.** The Auxiliary tab's 8 sub-model tasks (vision, web_extract, compression, session_search, skills_hub, approval, mcp, flush_memories) each gain a "Nous Portal" toggle. Enabling it flips `auxiliary.<task>.provider` to `nous` — Hermes derives gateway routing from that, no separate `use_gateway` key needed.
- **Health surface.** A new **Tool Gateway** card in Health shows subscription state, `platform_toolsets` wiring, and which aux tasks are currently routed through Nous.
- **Credential Pools dead-end fixed.** Before: selecting `nous` in the Add Credential sheet and clicking *Start OAuth* silently stalled (the PKCE URL regex never matched the device-code output). Now the sheet detects Nous and routes to the dedicated sign-in flow. For the other non-PKCE providers (OpenAI Codex, Qwen OAuth, Google Gemini CLI, GitHub Copilot ACP), the button disables with an inline hint pointing to `hermes auth add <provider>` — no more silent failures. PKCE providers (Anthropic, etc.) behave exactly as before.
- **Messaging Gateway rename.** Scarf's pre-existing "Gateway" section (Slack / Discord / inbound messaging) is renamed throughout to **Messaging Gateway** to disambiguate from the new Tool Gateway. Same feature, clearer name. Sidebar, dashboard card, menu-bar status, log-source filter, and Settings → Agent section header all updated. Internal enum cases and file paths (`gateway_state.json`, `gateway.log`) are unchanged.

If you don't use Hermes v0.10.0 or don't have a Nous subscription, nothing in your flow changes — the Tool Gateway surface only activates when it's relevant. Sign-in state reads `~/.hermes/auth.json` in read-only mode; Scarf never writes to the credential file.

### Migrating from 2.2.x

Sparkle will offer the update automatically. No config migration needed. Existing template installs are untouched — the v2.3 additions (folders, archive, sidecar) are purely additive; a v2.2.1 projects.json loads cleanly.

If you had any chat sessions attributed to projects in a pre-release v2.3 build, the forward-only attribution model means those sidecar entries surface correctly in the new Sessions tab on first launch.

**Hermes version.** The Tool Gateway features target [Hermes v0.10.0](https://github.com/NousResearch/hermes-agent/releases/tag/v2026.4.16) or newer. If you're on v0.9.0 the rest of Scarf 2.3 works, but Nous Portal won't appear in the picker (it's sourced from `HERMES_OVERLAYS` in v0.10.0+) and the Tool Gateway card won't have subscription data to show. Updating Hermes is `pipx upgrade hermes-agent` or the equivalent for your install method.

### Documentation

- **[Project Templates wiki page](https://github.com/awizemann/scarf/wiki/Project-Templates)** — gained a "How the agent sees the project" section covering the AGENTS.md injection pattern.
- **[Hermes Version Compatibility](https://github.com/awizemann/scarf/wiki/Hermes-Version-Compatibility)** — bumped recommended minimum to v0.10.0, new subsection covering Tool Gateway feature gating.
- **[Core Services](https://github.com/awizemann/scarf/wiki/Core-Services)** — new rows for `NousSubscriptionService` and `NousAuthFlow`, updated `ModelCatalogService` entry noting overlay merge.
- **Root `CLAUDE.md`** — new subsection "Project-scoped chat + Scarf-managed AGENTS.md context (v2.3)" under Project Templates, plus the Tool Gateway subsection under Hermes Version covering the overlay table and per-task gateway contract.
- **`scarf-template-author` skill** — pitfall bullet added so future scaffolding agents preserve the marker region when authoring new templates.

### Thanks

Thanks to the users who exercised this release through several layout iterations, caught the `fetchSessions` short-circuit on a fresh VM, and pushed on the "agent doesn't know what project it's in" question until the AGENTS.md mechanism clicked. Several of these fixes are small on their own but add up to a much tighter per-project workflow.
