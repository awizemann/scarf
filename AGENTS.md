<!-- memophant:begin -->
## Memory System (managed by Memophant)

This project uses a layered memory system so any agent session — Claude Code, Codex, Cursor,
Gemini, Copilot, or any other — is productive immediately. Memophant (a macOS app) manages it;
everything is plain files + a native MCP server (`memophant-mcp`) so you can read and write the
memory directly. This block is regenerated between the `memophant` markers — edit anything
outside them freely.

**Use this repo's memory as the single source of truth — every session, any agent.** Read it
before starting work, and record durable decisions and learnings as **notes or wiki pages** —
not in this file, and not in any session-private or model-specific memory — so every session
stays consistent and nothing is lost. Keep `AGENTS.md` and the per-agent shims (`CLAUDE.md` /
`GEMINI.md` / `.github/copilot-instructions.md` / `.cursor/rules/memophant.mdc`) **minimal**:
they point at the memory system, they don't BE the memory system. And don't hand-maintain a
SECOND guidance tier that duplicates it — ad-hoc `.claude/rules/*.md`, hand-kept convention
docs, or model-private memory. A parallel copy nobody reindexes drifts and starts feeding
stale instructions; put durable guidance in memory/wiki, reachable from here, and nowhere else.

**Memory engine — use these tools for everything you can, and get to know them before you
start.** Memophant ships an in-repo native MCP server (`memophant-mcp`) that owns the memory
backend end-to-end. When the server is loaded by your agent, the tools below show up directly.
**Before you begin a task, take stock of the `memophant` MCP tools available in this session
and read their descriptions so you know what each does.** They are the PRIMARY interface to
every tier in this repo — memory, wiki, design, code, vendors, templates: **default to them
for any read or write you can express as a tool call** (search, read, write, edit, move,
context-build), and treat ad-hoc file reads, `grep`, and hand-edits as a LAST RESORT — only
when no tool covers the need or the server is down. Hand-editing a managed-tier file when a
tool exists is a mistake: you bypass slug generation, automatic reindexing, and the
write-time secret scan and slug-dedup, and your change can be silently overwritten on the next
regen. If the MCP tools aren't present in this session, fall back to grep over `.memory/`
and `wiki/`.

- Native MCP tools (preferred): `search_memories`, `read_memory`, `view_memory`, `write_memory`,
  `edit_memory`, `move_memory`, `delete_memory`, `list_directory`, `list_memory_projects`,
  `recent_activity`, `build_context` (all accept a `project` argument, default
  scarf) — plus `search_code` (structural symbol search over THIS repo's code index;
  repo-scoped, no `project` arg).
- Fallback (only if the MCP tools above are not present in this session): grep `.memory/` and
  `wiki/` directly — `grep -rn "<query>" .memory/ wiki/`.

**1. Memophant Memory (`.memory/`) — structured atomic facts.** A searchable knowledge graph
of observations and relations. Search it before assuming; it is the source of truth for past
decisions and learnings.
- Search: invoke `search_memories(query: "<text>", project: "scarf")` via MCP.
- Record durable facts/decisions as you work with `write_memory` — pass the structure as
  FIRST-CLASS ARGUMENTS, not hand-written markdown: `observations: ["- [category] fact #tag", …]`
  (1–5 atomic facts) and `relations: [{"relation": "relates_to", "target": "Other Note"}, …]`;
  `content` is OPTIONAL short prose context (a few lines), never the place for the facts. The
  tool composes the hybrid note and validates the bullets (a malformed one is rejected with a
  fixable reason). `project: "scarf"`, committed with the repo, visible to every session.
- Why structure, not prose: observations are the tooling contract — consolidation, semantic
  search, and task auto-import read them; a prose-only note degrades silently in all three, and
  Consolidate has to spend an LLM pass distilling later what you could state now for free. Put
  `[[links]]` in `relations` (prose links are invisible to the graph). Use the canonical
  categories — decision, fact, gotcha, constraint, convention, todo, idea, done — so data-layer queries that
  group by `[category]` don't fragment; a freeform one still saves, with a nudge.
- Long-form DOCUMENTS (guides, research, specs) → the wiki tier at write time: `write_memory(project:
  "scarf-wiki", …)` for the full prose page, and keep only its distilled facts in the
  memory note with a `documented_in` relation to the page. A memory note is atomic facts + a little
  context, never a document.
- **Filenames are `dashed-slug.md`** — lowercase, hyphen-separated, derived deterministically
  from the title. The display title comes from frontmatter `title:` (always), with the
  prettified filename as a fallback. So title `"GitHub Status Service"` → file
  `github-status-service.md`, and the UI renders `GitHub Status Service`. Use `write_memory`
  for new notes — it slug-generates correctly. **Always file each note under exactly one of the
  six canonical folders** (lowercase) — never omit `folder` (that drops the note at the memory
  root) and never invent a new folder or pass a description as the folder. The six:
  `architecture/` — How major systems fit together; long-lived structural truth.; `conventions/` — Coding / naming / workflow conventions the team agreed on.; `decisions/` — Discrete choices with rationale (architecture decision records).; `operations/` — Runbooks, recurring tasks, infrastructure ops, build/deploy notes.; `project/` — Project-level facts (name, owner, scope, contact, repo URL).; `roadmap/` — Forward-looking plans, milestones, follow-up queues.
- Reindex happens automatically after every write_memory / edit_memory; for direct file edits,
  use the Memophant app's "Reindex" action or restart the MCP server.
- Editing an existing note: **search first and edit the existing note rather than forking a
  near-duplicate** — use `edit_memory` (append/prepend/replace/find_replace/insert_*
  for the body; **`set_tags` for the frontmatter `tags:` list**), which reindexes that note. Don't
  hand-edit frontmatter on disk: search reads the index as-is, so the change stays invisible to
  search until a reindex.
- Frontmatter Memophant manages automatically: `created`/`updated` (set on write, bumped on
  edit), `reviewed`/`reviewed_by` + `source_sha` (the last verification and the commit it was
  checked against — Memory Health flags the note when that code drifts).
- **Declare `source_paths` when a note is grounded in code.** Pass the repo-relative file(s) the
  note depends on to `write_memory` (`source_paths: ["path/one.swift", …]`) and Memophant stamps
  them against the current commit so drift is detectable. Omit for pure human-decision notes.
  A note with no `source_paths` can't be drift-checked — this is the signal that keeps memory honest.
- Set `status` only to flag a retired state — `deprecated`/`superseded`/`historical`/`resolved`;
  an active, current fact needs none.

**2. Wiki (`wiki/`) — long-form reference docs.** Guides, architecture deep-dives, runbooks, and
design notes. Deliberately kept OUT of this auto-loaded file to save context — search it on demand
rather than reading it wholesale.
- Search: `search_memories(query: "<text>", project: "scarf-wiki")` via MCP, or grep:
  `grep -rn "<query>" wiki/`.
- Pages are markdown with dashed filenames; links are `[Title](Page-Name)`. `Home.md` is the
  landing page and `_Sidebar.md` is the navigation.

**Maintaining the wiki.** Update it when work changes user-visible behavior, adds a feature or
service, changes architecture, or ships a release. Skip for bug fixes with no observable change,
pure refactors, typos, and test-only changes.
- The wiki is meant to be publishable, so every commit/publish runs a mandatory two-tier
  secret-scan (token/key patterns block; secret-like assignments warn). **Never commit secrets to
  the wiki.** Details in `wiki/Wiki-Maintenance.md`.

**3. Design (`design/`) — the design system.** A folder of robust design Markdown (design system,
principles, component specs, UX/HIG conventions) you reference before any UI or design work. Kept
OUT of this auto-loaded file to save context — search it on demand.
- Search: `search_memories(query: "<text>", project: "scarf-design")` via MCP, or grep:
  `grep -rn "<query>" design/`.
- Plain `.md` files (any name) — add your own or import a design skill; no special structure required.
- **Reference only — never the app.** `design/` may hold prototype or hand-off code
  (`.swift`, `.jsx`, `.tsx`, …) next to the Markdown. Treat ALL of it as something to build
  FROM, never as the real application: don't import, copy, or edit those files as if they were
  source, and don't cite them as how the app works. The app lives in the repo's own source and
  the Code tier — `search_code` deliberately excludes `design/` for exactly this reason.

**4. Code (`code/` + `search_code`) — structural queries, not blind grep.** A queryable map of
THIS repo's source: curated `code/` markdown overviews (module purpose, key types) + an indexed
symbol map under `.memophant/code/` (gitignored). **Prefer the code index over `grep` for any
structural question.** The fastest "where is `<symbol>`?" is the **`search_code` MCP tool**
(`search_code(query: "<symbol or fragment>")` → file:line · kind · name, FTS5/BM25-ranked); the
`memophant code <verb>` CLI (find / refs / outline / imports / status) covers the rest. Fall back
to `grep` only when the index is stale/missing or the language isn't indexed (Phase 1 = Swift).
- Curated overviews: `search_memories(query: "<text>", project: "scarf-code")` via MCP, or
  `grep -rn "<query>" code/`.

**5. Documents (`documents/`) — per-project file store.** Arbitrary files alongside the codebase
(PDFs, reports, briefs) — project context that isn't memory/wiki/design/code. Schema-less;
committed with the repo. Browse/add via the Memophant app's Documents tier.
- **The tier is exactly `documents/` (lowercase) at the repo root.** A repo's `docs/`, `doc/`,
  or `documentation/` folder is the project's OWN hand-authored documentation — it is NOT this
  tier: never save agent-generated artifacts there, and never relocate the user's docs into
  `documents/`. Don't create case-variants (`Documents/`, `Docs/`) either — the macOS
  filesystem resolves them to the same folder but git tracks whichever case it first saw,
  silently forking the tier.
- **Write through `write_tier_file(tier: "documents", path: "plans/….md", content: …)`**
  rather than raw file writes — it resolves against the repo root (immune to your working
  directory) and containment-checks the path. Browse with `list_tier_files(tier:
  "documents")`, read with `read_tier_file(tier: "documents", path: …)`. Raw file writes are
  the fallback only when the MCP server is down.

**Plans AND generated documents go in `documents/`.** Whenever you produce a file-shaped
artifact for this project — a plan, design proposal, audit report, comparison matrix,
meeting summary, research brief, exported data, analysis write-up, scratch notes the user
asked you to keep — save it under `documents/`. This is the durable home for
agent-generated content; without it, the user has to copy/paste from the chat transcript
to keep anything you produce.
- **Plans** (intent BEFORE action — refactor plans, migration plans, feature scoping,
  architecture proposals): `documents/plans/YYYY-MM-DD-short-kebab-slug.md`. Save BEFORE
  you start executing so the file survives the session and gives the next agent (and
  the user) a permanent record of the intent — not just the diff.
- **Reports / analyses / write-ups** (work output): pick a sensible subfolder by kind —
  `documents/reports/`, `documents/audits/`, `documents/research/`, `documents/exports/`
  — or land flat in `documents/` if no clear category. Same ISO-date kebab-slug filename
  convention.
- **Scratch / drafts**: `documents/scratch/` if the user explicitly asks you to keep
  something rough; otherwise don't write it.
- Default to Markdown (`.md`); use other formats only when the user asks (PDF / CSV /
  JSON / etc. — all welcome, the folder is schema-less).
- This is durable history; `.memory/` is for the eventual SHIPPED decision (after the
  work lands). Code outputs still go in the actual codebase, not here.
- **No credentials or secrets in `documents/`** — the folder is committed with the repo.

**6. Vendors (`vendors/`) — per-project third-party service registry.** One markdown record per
vendor (`vendors/<slug>.md`) for the services this project depends on. **Credentials live in the
iCloud Keychain, NEVER in the vendor file** (the file's `keychain_ref` is the item NAME, not the
secret; the writer secret-scans records on save, overridable per-hit for example keys).
- **Need the actual credential?** Call `get_vendor_credential(vendor: "<slug>", project:
  "scarf", reason: "<why>")` instead of asking the user to paste it — Memophant prompts
  for approval and returns it in the tool result (never echoed). Treat it ONE-SHOT: write to a
  `mktemp` file, reference the path, don't echo/log/persist. Requires the app running.
- **Encountered OR created a credential? Store it as a vendor — don't leave it loose.** Stash any
  secret you read or mint with `set_vendor_credential(vendor, credential, project, reason)` rather
  than leaving it in chat/scratch/shell; Memophant approves, creates the record if missing, and
  stores it in the Keychain (never the file). Fetch it back with `get_vendor_credential`. (Don't
  relocate a secret the project deliberately keeps in a gitignored `.env` it already loads.)
- Search via `search_memories(query: "<text>", project: "scarf-vendors")`.

**7. Templates (`templates/`) — reusable integration recipes.** Folder-per-template at
`templates/<slug>/` with a `manifest.md` (Prerequisites / Steps / Variables / Verification) +
an optional `reference/` of verbatim source files. A template is documentation + recipe, NOT a
turn-key install — the next agent READS it and ADAPTS the patterns to its own codebase.
- **`/memophant-template <description>`:** find the slug (`search_memories(query, project:
  "scarf-templates")` — the templates tier isn't reachable via `list_directory`/
  `read_memory`), read its `manifest.md` + the `reference/` files it points at, confirm the
  Prerequisites with the user, ADAPT each step to THIS project, run the Verification. Plan-first
  applies — write the apply plan to `documents/plans/` before executing.
- **No raw credentials in manifests/references** (placeholders only; real secrets live in
  Vendors/Keychain — a template references one via `vendor_refs:` in its manifest frontmatter).
  Create/share templates from the Memophant app (Templates tier → "Extract template…").

**8. Tasks (`TASKS.md`) — the work board.** A repo-resident kanban in plain Markdown: `## Todo`,
`## Doing`, `## Done` sections, each a checklist (`- [ ]` / `- [x]`). It travels with the repo and
is yours to edit directly.
- **Read `TASKS.md` at the start of work.** When you pick up a task, move its line into `## Doing`;
  when you finish, move it into `## Done` (and flip the checkbox to `- [x]`).
- **Prefer the `memophant` MCP task tools** — `create_task` (title + optional description/plan),
  `move_task(id, status)`, `update_task`, `list_tasks`. They own the `t-xxxxxx` id + the board line
  + the `tasks/<id>.md` detail file atomically, so a board-only orphan (or prose dumped onto the
  board) can't happen. Hand-editing `TASKS.md` (below) still works as a fallback when the server's down.
- Add tasks you discover to `## Todo` with a SHORT imperative title — the board card shows the
  title verbatim, so don't pack a paragraph into it. When a task needs real detail, annotate the
  line `(id: t-xxxxxx)` (`t-` + 6 random hex) and create `tasks/t-xxxxxx.md` with frontmatter
  (`id`, `title`, `status: todo`, `added: YYYY-MM-DD`) and a `## Description` holding the detail
  (plus empty `## Plan` / `## Artifacts`). The board shows the title; the card body reads the
  Description. Optional `(source: <note>)` / `(added: YYYY-MM-DD)` line annotations are preserved.
- Memophant renders this as a live kanban, so your edits to `TASKS.md` show up on the board as you
  work — keep it current.
- **A task's status is the section its line sits in — change it by MOVING the line, here in
  `TASKS.md`.** A task may have a detail file at `tasks/<id>.md` carrying a mirrored `status:` /
  `priority:`; that's a Memophant-managed mirror you don't need to touch. (If an out-of-band edit
  makes the two disagree, Memophant reconciles by last-edit-wins — but the board line is canonical.)

**Commits for `.memory/`, `wiki/`, `design/`, `code/`, `sessions/`, `documents/`,
`vendors/`, `templates/`, `TASKS.md`, and `tasks/` are owned by Memophant.** When you write_memory, edit a wiki/design/code page, move a
task on the board, drop a file into `documents/`, or import a session, those files become dirty
in git — **do NOT `git add` or `git commit` them yourself.** The user runs each tier's commit
through Memophant's commit modal, which routes every change through the two-tier secret scan
and stages per-tier paths in isolation (so a stray edit elsewhere can't piggyback into a memory
commit).
- **Yours to commit:** application code, configs, scripts, infrastructure — anything OUTSIDE the
  tier folders above. Use plain `git add` / `git commit` like any other repo.
- **Memophant's to commit:** anything under `.memory/`, `wiki/`, `design/`, `code/`,
  `sessions/`, `documents/`, `vendors/`, `templates/`, `TASKS.md`, and `tasks/`. After your task, **leave these files
  dirty** if the work touched them — Memophant's commit bar shows per-tier "uncommitted"
  chips with counts so the user decides when to commit each tier with its own secret-scanned
  message.
- The boundary is by FOLDER, not by your task scope. Editing
  `Memophant/Services/Wiki/PublishWikiSheet.swift` is app code → yours. Editing
  `wiki/Publish-Pipeline.md` is the wiki tier → Memophant's.
- If you find a Memophant-owned file already staged in your session's index, `git restore
  --staged` it before continuing — don't carry it into your commit.
- **Pre-existing dirty Memophant-owned files at session start are normal**, not a problem to
  fix. Memophant batches them into per-tier commits the user makes through the app's commit
  bar. Don't suggest committing them, don't propose discarding them, and don't mention them
  in your end-of-task summary as something for the user to address — the user already knows
  and that's how Memophant works. Treat them as background state when you read `git status`
  to understand the repo. (Exception: if your own work modified the SAME files and you'd
  unintentionally be carrying forward a prior session's abandoned changes, flag that
  specifically.)

**Memophant (the app)** is the management surface: browse, search, and edit notes, wiki and design
pages, track and run tasks on the kanban, migrate existing docs into memory, and commit/publish
with the secret-scan.
<!-- memophant:end -->
