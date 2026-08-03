<!-- memophant:begin -->
## Memory System (managed by Memophant)

This repo carries its own agent memory — plain files in git, served by the in-repo
`memophant-mcp` MCP server, managed by the Memophant macOS app. It works the same for every
agent (Claude Code, Codex, Cursor, Gemini, Copilot). This block is regenerated between the
`memophant` markers; edit anything outside them freely.

**The repo memory is the single source of truth.** Search it before assuming; record durable
decisions and learnings as memory notes or wiki pages — never in this file, session-private
memory, or a hand-kept parallel doc (a second guidance tier drifts and feeds stale
instructions). Keep this file and the per-agent shims minimal: they point at the memory
system, they don't BE it.

**Default to the `memophant` MCP tools for every read and write** — search, read, write,
edit, move, context — and read their descriptions: they document their arguments and
behavior. The engine is the gate: every durable write goes through the tool (or app)
entry points, which carry the guards — slug generation, structure validation, and the
write-time secret scan. Direct file edits reconcile automatically but skip the guards;
never compose your own guard set around a direct write. Server down → grep the tiers
directly (`grep -rn "<query>" .memory/ wiki/`).

**1. Memory (`.memory/`) — atomic facts.**
- `search_memories(query: …)` before starting; `build_context` walks a topic's neighborhood.
- Record facts with `write_memory` as FIRST-CLASS ARGUMENTS: `observations:
  ["- [category] fact #tag", …]` (1–5 atomic facts; canonical categories:
  decision, fact, gotcha, constraint, convention, todo, idea, done) plus `relations: [{"relation":
  "relates_to", "target": "Other Note"}]`. `content` is optional short context — never the
  facts. Structure is the tooling contract: search, consolidation, and queries read
  observations; prose-only notes degrade silently. `[[links]]` belong in `relations`.
- **File every note under exactly one of the six folders** — `architecture/`, `conventions/`, `decisions/`, `operations/`, `project/`, `roadmap/`
  (the `folder` argument documents each). Never the memory root, never a new folder.
- **Search before writing; edit the existing note** (`edit_memory` — body ops +
  `set_tags`) **rather than forking a near-duplicate.**
- **Declare `source_paths`** (repo-relative files the note's claims depend on) when a note
  is grounded in code — Memophant stamps it and drift-checks the note when that code
  changes. Omit for pure human decisions. Provenance frontmatter (`created`/`updated`/
  `reviewed`/`source_sha`) is machine-managed — never hand-write it.
- Long-form documents (guides, research, specs) → the wiki at write time:
  `write_memory(project: "scarf-wiki", …)`; keep the distilled facts in a memory note with
  a `documented_in` relation. `status:` only marks retirement
  (`deprecated`/`superseded`/`historical`/`resolved`); current facts carry none.

**2. Wiki (`wiki/`) — long-form reference.** Search on demand (`project: "scarf-wiki"`);
don't read it wholesale. Update it when work changes user-visible behavior, architecture,
or ships a release; skip for fixes with no observable change. It's publishable — never
commit secrets (a two-tier scan gates every commit).

**3. Design (`design/`) — the design system.** Consult before any UI work
(`project: "scarf-design"`). Reference only: prototype code under `design/` is never
the app — don't import it, copy it, or cite it as how the app works.

**4. Code (`code/` + `search_code`).** Prefer `search_code` (indexed symbol map →
file:line) over blind grep for structural questions; curated overviews live in `project:
"scarf-code"`. Grep is the fallback for unindexed languages.

**5. Documents (`documents/`) — your generated artifacts.** Every file-shaped artifact you
produce (plan, report, audit, research, export) goes here via `write_tier_file(tier:
"documents", path: "plans/YYYY-MM-DD-short-slug.md", …)` — plans BEFORE you execute. The
tier is exactly `documents/` (lowercase) at the repo root: a repo's `docs/` folder is the
project's own documentation, never yours to write into, and case-variants
(`Documents/`) silently fork the tier in git. No secrets — the folder is committed.

**6. Vendors (`vendors/`) — third-party services. Credentials live in the Keychain, never
in files or chat.** Need one? `get_vendor_credential(vendor: …, reason: …)` — the user
approves; treat it one-shot (temp file, never echo/log/persist). Found or minted one?
Store it immediately with `set_vendor_credential`. (Leave a project's own gitignored
`.env` where it is.)

**7. Templates (`templates/`) — integration recipes.** Find via
`search_memories(project: "scarf-templates")`, read the `manifest.md` + its `reference/`
files, confirm Prerequisites with the user, ADAPT each step to this codebase (never copy
blind), write the apply plan to `documents/plans/` first, then run the Verification.

**8. Tasks (`TASKS.md`) — the work board.** Read it at the start of work. Prefer the task
tools — `create_task`, `move_task(id, status)`, `update_task`, `list_tasks` — they own the
board line + `tasks/<id>.md` detail file atomically. Add tasks you discover (short
imperative titles; detail belongs in the description, not the title). Server down →
hand-move lines between `## Todo` / `## Doing` / `## Done`; the section IS the status.

**Commits: the managed tiers are Memophant's.** Never `git add`/`git commit` anything
under `.memory/`, `wiki/`, `design/`, `code/`, `sessions/`, `documents/`, `vendors/`,
`templates/`, `TASKS.md`, or `tasks/` — leave them dirty; the user commits each tier
through Memophant's secret-scanned per-tier bar. Everything outside those paths is yours
to commit normally; the boundary is by folder, not task scope. **Pre-existing dirty
managed-tier files at session start are normal background state** — don't commit,
discard, "fix", or report them (exception: flag it if your own work modified the same
files and would carry a prior session's changes forward). Find one staged in your index →
`git restore --staged` it.

**Memophant (the app)** is the management surface — browse, search, and edit every tier,
run the kanban, migrate docs, and commit/publish through the secret scan.
<!-- memophant:end -->
