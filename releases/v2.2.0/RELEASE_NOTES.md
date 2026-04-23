## What's New in 2.2.0

Scarf projects can now travel. This release introduces **Project Templates** — a shareable `.scarftemplate` bundle format that packages a project's dashboard, agent instructions, skills, cron jobs, and a typed configuration schema into a single file anyone can install with one click. Bundles are agent-portable by design: every template ships with a cross-agent [`AGENTS.md`](https://agents.md/) so the instructions work natively in Claude Code, Cursor, Codex, Aider, Jules, Copilot, Zed, and every other agent that reads the Linux Foundation standard.

This is also the first release to ship a public **template catalog website** — a static site generated from `templates/<author>/<name>/` in this repo, previewed at [awizemann.github.io/scarf/templates/](https://awizemann.github.io/scarf/templates/), with a CI-enforced validator for community submissions.

### Project Templates

- **Bundle format: `.scarftemplate`.** A zip carrying a `template.json` manifest, the project's dashboard, a required `AGENTS.md` (the [Linux Foundation cross-agent instructions standard](https://agents.md/) — reads natively in Claude Code, Cursor, Codex, Aider, Jules, Copilot, Zed, and more), a README shown in the installer, optional per-agent instruction shims (`CLAUDE.md`, `GEMINI.md`, `.cursorrules`, `.github/copilot-instructions.md`), optional namespaced skills, optional cron job definitions, and an optional memory appendix.
- **Install preview sheet.** Before anything touches disk, Scarf shows you the exact project directory that will be created, every file inside it, every skill that will be namespaced under `~/.hermes/skills/templates/<slug>/`, every cron job that will be registered (always paused — you enable each one manually), and a live diff of the memory appendix against your existing `MEMORY.md`. Markdown fields — the README, field descriptions, cron prompts — render inline. The manifest's content claim is cross-checked against the actual zip entries so a bundle can't hide files from the preview.
- **`scarf://install?url=…` deep links.** Register Scarf as the handler for the `scarf` URL scheme so a future catalog site can link one-click installs straight into the app. Only `https://` payloads are accepted; `file://`, `javascript:`, and `http://` are refused on principle. A 50 MB size cap keeps a malicious link from exhausting disk. The URL never auto-installs — the preview sheet is always user-confirmed.
- **Install-time token substitution.** Template authors use `{{PROJECT_DIR}}`, `{{TEMPLATE_ID}}`, and `{{TEMPLATE_SLUG}}` placeholders in cron prompts; the installer resolves them to absolute paths at install time so the registered cron job works regardless of where Hermes sets CWD.
- **Export any project as a template.** Select a project, open the new Templates menu in the Projects toolbar, fill in a handful of fields (id, name, version, description, optional author + category + tags), tick the skills and cron jobs you want to include, optionally drop in a memory snippet, and save. The exporter carries the authored configuration schema forward but **never** the user's values — exports are safe on projects with live config.
- **No-overwrite, reversible by design.** Installed templates drop a `<project>/.scarf/template.lock.json` recording exactly what they wrote — every project file, skill path, cron job name, memory block id, and Keychain reference. Installing the same template id twice is refused at the preview step so you don't accidentally double-append to `MEMORY.md`.
- **Safe globals.** Skills install to `~/.hermes/skills/templates/<slug>/<skill-name>/` so they never collide with your own skills. Cron jobs are prefixed with `[tmpl:<id>]` and start paused. The installer **never** touches `~/.hermes/config.yaml`, `auth.json`, sessions, or any credential-bearing path.

### Template Configuration (schemaVersion 2)

Templates can now declare a typed configuration schema that drives a form step during install — no more "edit a `sites.txt` file to get started."

- **Typed field vocabulary.** Seven field types: `string`, `text` (multiline), `number` (with `min`/`max`), `bool`, `enum` (with `{value, label}` options), `list` (of strings, with `minItems`/`maxItems`), and `secret` (routed to the macOS Keychain). Constraints per type — `pattern` for regex, `minLength`/`maxLength` for text, etc. — are enforced at install and at edit time.
- **Configure step in the install flow.** If the template declares a schema, a **Configure** screen is inserted between "pick parent directory" and the preview sheet. Non-secret values land in `<project>/.scarf/config.json`; secrets land in the macOS Keychain with a service name of `com.scarf.template.<slug>` and an account keyed to the project-directory hash (so two installs of the same template in different dirs don't collide on Keychain entries).
- **Post-install Configuration editor.** A slider icon in the dashboard header opens the same form pre-filled with the current values. Change a site, rotate a token, toggle a feature — the cron job picks up the new values on its next run. Secrets are never echoed back ("Saved in Keychain — leave empty to keep the stored value").
- **Model recommendations.** Templates can suggest a preferred model (`claude-sonnet-4.5`, `claude-haiku-4`, `gpt-4.1`, etc.) with a rationale. Scarf surfaces the recommendation in the configure sheet without auto-switching your active model — always your call.
- **Secrets are tracked in the lock file.** Uninstalling a template runs `SecItemDelete` on every Keychain ref recorded at install, so a full clean-up leaves nothing behind. Absent entries (user already cleaned them) are no-ops.

### Template Catalog

A Sparkle-style pipeline for community-contributed templates, living on the same `gh-pages` branch as the auto-update feed.

- **Static site.** [awizemann.github.io/scarf/templates/](https://awizemann.github.io/scarf/templates/) — generated from every `templates/<author>/<name>/` directory. Each template gets a detail page showing the README, a live preview of the post-install dashboard, and the configuration schema rendered with human-readable constraint summaries. One-click install via the `scarf://install?url=…` button.
- **Stdlib-only Python validator.** `tools/build-catalog.py` is a no-external-dependencies Python script that mirrors the Swift-side schema and validation invariants (supported widget types, supported field types, `contents` claim verification, secret-with-default rejection, bundle-size cap, high-confidence secret patterns). Run it locally with `./scripts/catalog.sh check` before submitting a PR.
- **CI gate on PRs.** [`.github/workflows/validate-template-pr.yml`](https://github.com/awizemann/scarf/blob/main/.github/workflows/validate-template-pr.yml) runs the validator + its 24-test suite on every PR touching `templates/`, the validator itself, or its tests. Failing PRs get an inline comment with the last 3 KB of the validator output; passing PRs get a tailored checklist naming the specific template directory being changed.
- **Install-URL hosting.** Bundles are raw-served from `main` at `https://raw.githubusercontent.com/awizemann/scarf/main/templates/<author>/<name>/<name>.scarftemplate`. No per-template GitHub Releases ceremony.
- **Dogfood: the site uses Scarf's dashboard format.** `site/widgets.js` is ~300 lines of vanilla JS that renders a `ProjectDashboard` JSON using the same widget vocabulary the app uses, so each detail page's "live preview" is the actual dashboard the user will get.

### Example template: `awizemann/site-status-checker`

Ships as the first catalog entry and exercises every v2.2 surface. [See it in the catalog →](https://awizemann.github.io/scarf/templates/awizemann-site-status-checker/)

- Configure step asks for a list of URLs and a per-URL timeout.
- A paused cron job runs daily at 09:00 (editable from the Cron sidebar), does HTTP GETs with 3-redirect follow, writes a timestamped results table to `status-log.md`, updates the dashboard's Sites Up / Sites Down / Last Checked stat widgets plus the Watched Sites list, and rewrites the Site tab's webview URL to the first configured site.
- Works in any agent — the `AGENTS.md` is the single source of truth; no per-agent shim needed.

### Site tab

A dashboard with at least one `webview` widget now exposes a **Site** tab next to Dashboard. Useful for templates that watch something renderable (a site, a preview endpoint, a Grafana panel). The `site-status-checker` example rewrites the webview URL to the first configured site on every cron run, so the tab stays in sync with live config.

### Using templates

- **Install from file:** Projects → Templates → *Install from File…*, pick a `.scarftemplate` from disk.
- **Install from URL:** Projects → Templates → *Install from URL…*, paste an https URL.
- **Install from the web:** click any `scarf://install?url=…` link in a browser.
- **Export:** select a project → Projects → Templates → *Export "&lt;name&gt;" as Template…*, fill the form, save.
- **Edit config post-install:** slider icon in the dashboard header.
- **Uninstall:** right-click the project in the sidebar → *Uninstall Template (remove installed files)…*, or click the uninstall icon in the dashboard header. The preview sheet lists every file, cron job, Keychain secret, and memory block that will be removed, plus every user-created file that will be preserved.

### UX clarifications

- **Remove from List vs. Uninstall Template.** Sidebar context-menu labels clarified so you can see at a glance whether a click is destructive. *Remove from List (keep files)…* is registry-only — nothing on disk is touched, cron jobs stay, Keychain secrets stay. A confirmation dialog spells this out before the click lands. *Uninstall Template (remove installed files)…* is the full, lock-driven cleanup.
- **Post-uninstall "folder kept" banner.** When the uninstaller preserves the project directory because the cron wrote a `status-log.md` (or the user dropped files in there), the success view now explicitly lists the preserved paths with a pointer to delete the folder from Finder if desired.
- **Run Now no longer blocks on agent runs.** The Cron sidebar's Run Now button used to show a "Run failed" toast whenever an agent job ran longer than 60 s — even when the job was finishing correctly in the background. Run Now now shows "Agent started — dashboard will update when it finishes" immediately and the dashboard watcher picks up the completed state when it lands (timeout bumped to 300 s for the catch-stuck-process case).

### Uninstall

- **One-click uninstall** driven by `template.lock.json`. The preview sheet lists every file, cron job, Keychain ref, and memory block that will be removed, and every user-created file that will be preserved.
- **User content is never removed.** Files you (or the agent) added to the project dir after install — like a `sites.txt` or `status-log.md` — are detected and listed as "keep" in the preview. The project directory itself is removed only if nothing user-owned is left inside.
- **Clean global state.** The isolated `~/.hermes/skills/templates/<slug>/` namespace is removed wholesale. Tagged cron jobs are removed via `hermes cron remove`. Every recorded Keychain ref is cleared via `SecItemDelete`. The memory block between the `<!-- scarf-template:<id>:begin/end -->` markers is stripped, leaving the rest of MEMORY.md intact. The project registry entry is removed last.
- **No undo.** Uninstall is destructive — to reinstall, run the install flow again.

### Under the hood

- New models in `Core/Models/ProjectTemplate.swift` (manifest, inspection, install plan, lock file v2) and `Core/Models/TemplateConfig.swift` (schema + typed values + Keychain ref model).
- `Core/Services/ProjectTemplateService.swift` unzips, parses, and validates; `ProjectTemplateInstaller.swift` executes the plan with preflight + fail-fast semantics; `ProjectTemplateUninstaller.swift` reverses an install driven by the lock file; `ProjectTemplateExporter.swift` builds bundles from a live project + selections.
- `Core/Services/ProjectConfigService.swift` owns load/save/validation of `<project>/.scarf/config.json` + secret resolution; `Core/Services/ProjectConfigKeychain.swift` is the thin `SecItemAdd`/`Copy`/`Delete` wrapper (the only Keychain consumer in Scarf today).
- `Core/Services/TemplateURLRouter.swift` is the process-wide landing pad for `scarf://` URLs so a cold-launch browser click still reaches the install sheet.
- New Swift Testing suites covering 57 tests across the service / installer / uninstaller / exporter / config / Keychain / URL-router paths.
- New Python validator (`tools/build-catalog.py`) + test suite (`tools/test_build_catalog.py`, 24 tests) mirrors the Swift invariants for the CI gate and the site generator. Schema is Swift-primary — additions go to Swift first, Python mirrors.
- `scripts/catalog.sh` wraps the validator with `check / build / preview / serve / publish` subcommands that parallel the `scripts/release.sh` shape.

### Migrating from 2.1.x

Sparkle will offer the update automatically. No config migration needed. Existing projects are untouched — templates are additive. If you had a v2.2.0-dev install of the earlier `project-templates` branch, uninstall and reinstall any previously-installed templates to pick up the schema-version-2 lock file.

### Documentation

- [Project Templates wiki page](https://github.com/awizemann/scarf/wiki/Project-Templates) — installing, exporting, configuring, authoring, uninstalling.
- [Catalog site](https://awizemann.github.io/scarf/templates/) — the public catalog with live dashboard previews.
- [`templates/CONTRIBUTING.md`](https://github.com/awizemann/scarf/blob/main/templates/CONTRIBUTING.md) — how to submit a template via PR.
- [Architecture notes in root `CLAUDE.md`](https://github.com/awizemann/scarf/blob/main/CLAUDE.md#project-templates) — service-layer map, Keychain scheme, schema-drift discipline.

### Thanks

Thanks to everyone who tested drafts of the install flow, caught the "Run Now blocks on agent" bug, and pushed on the Remove-vs-Uninstall UX until it was clear. A 2.3 follow-up will extend the catalog validator to enforce per-field-type constraints at PR-time (currently enforced on install but not at submission).
