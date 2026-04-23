## What's New in 2.2.1

A patch release covering Template Configuration rendering fixes reported against v2.2.0, plus a new catalog template that packages a Hermes skill for scaffolding new Scarf projects.

### Configuration sheet — no more clipping

Two independent rendering fixes to the post-install Configuration editor and the install-flow Configure step:

- **Enum fields with long option labels.** An enum with three or four options whose labels exceeded ~20 characters — e.g. a Claude-model picker with labels like *"Claude Opus 4 (Recommended - Most Capable)"* — rendered as a segmented picker that sized to the intrinsic width of all labels concatenated. On macOS, `.pickerStyle(.segmented)` refuses to respect offered width, refuses to wrap, refuses to truncate. The result was a ~650pt picker that overflowed the sheet's 560pt viewport and clipped the entire form on both sides. Enum fields now always render as a dropdown Menu picker, which surfaces long labels in the popup list and respects the parent's offered width regardless of option count or label length.
- **Descriptions with unbreakable content.** Field descriptions rendered via inline AttributedString markdown can contain tokens SwiftUI's `Text` refuses to break mid-token (raw URLs, long paths). Added `.frame(maxWidth: .infinity, alignment: .leading)` on the sheet's inner VStack and on each field row as a secondary constraint, so description text wraps at whitespace boundaries instead of expanding the sheet width. Applied the same modifier to `TemplateInstallSheet`'s main preview VStack for symmetry — installs with README blocks or cron prompts containing long URLs now wrap cleanly too.

### New catalog entry — `awizemann/template-author`

A `.scarftemplate` whose only content is a Hermes skill (`scarf-template-author`) plus a minimal dashboard that points users at it. Installing the template drops the skill at `~/.hermes/skills/templates/awizemann-template-author/scarf-template-author/SKILL.md`, discoverable by Claude Code, Cursor, Codex, Aider, and every other agent that reads the standard `~/.hermes/skills/` directory.

The skill teaches agents how to scaffold a new Scarf-compatible project through a short interview — purpose, data source, cadence, widgets, config, secrets — then write `<project>/.scarf/dashboard.json`, `<project>/.scarf/manifest.json`, `<project>/AGENTS.md`, and `<project>/README.md`. Scaffolded projects are usable locally and cleanly exportable as `.scarftemplate` bundles via Scarf's Export flow later. [Catalog detail page →](https://awizemann.github.io/scarf/templates/awizemann-template-author/)

v1 is fully conversational / blank-slate. Pre-baked archetypes (monitor, dev-dashboard, personal-log) are deferred to a future release pending real usage data.

### Authoring guidance — SKILL.md

The `scarf-template-author` skill now tells scaffolding agents to prefer markdown link syntax (`[label](https://…)`) over raw URLs in schema field descriptions. Raw URLs work now (v2.2.1's description wrap fix above handles them gracefully), but `[Anthropic console](https://console.anthropic.com)` reads cleaner in the form than a dumped URL. Same rule extended to long paths or other unbreakable strings — wrap in inline code if they have to appear verbatim, prefer markdown links otherwise.

### Under the hood

- **`scripts/catalog.sh publish` fix.** The pre-flight `need_ghpages` check tested `[[ -d "$GHPAGES_DIR/.git" ]]` — "is `.git` a directory?" — which is true for a regular clone but false for a `git worktree add` worktree (where `.git` is a pointer file). `release.sh` creates and leaves the gh-pages worktree around, so after any release the subsequent catalog-publish call was rejected with a misleading "run `git worktree add`" error on a worktree that was already there and valid. Switched to `-e` (exists, either file or directory). Unblocks publishing the catalog immediately after a release.

### Migrating from 2.2.0

Sparkle will offer the update automatically. No config migration needed. Existing template installs are untouched.

If you've already installed `awizemann/template-author` from a pre-release build, no action needed — the catalog and bundle content are forward-compatible.

### Documentation

- [Project Templates wiki page](https://github.com/awizemann/scarf/wiki/Project-Templates) — installing, exporting, configuring, authoring, uninstalling.
- [Catalog site](https://awizemann.github.io/scarf/templates/) — two templates live: `awizemann/site-status-checker` and `awizemann/template-author`.
- [`templates/CONTRIBUTING.md`](https://github.com/awizemann/scarf/blob/main/templates/CONTRIBUTING.md) — how to submit a template via PR.
