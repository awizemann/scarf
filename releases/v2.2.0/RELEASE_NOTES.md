## What's New in 2.2.0

Scarf projects can now travel. This release introduces **Project Templates** — a shareable `.scarftemplate` bundle format that packages a project's dashboard, agent instructions, skills, and cron jobs into a single file anyone can install with one click from a local file or an `scarf://install?url=…` deep link.

### Project Templates

- **Bundle format: `.scarftemplate`.** A zip archive carrying a `template.json` manifest, the project's dashboard, a required `AGENTS.md` (the [Linux Foundation cross-agent instructions standard](https://agents.md/) — reads natively in Claude Code, Cursor, Codex, Aider, Jules, Copilot, Zed, and more), a README shown in the installer, optional per-agent instruction shims (`CLAUDE.md`, `GEMINI.md`, `.cursorrules`, `.github/copilot-instructions.md`), optional namespaced skills, optional cron job definitions, and an optional memory appendix. Every bundle is agent-portable out of the box.
- **Install preview sheet.** Before anything touches disk, Scarf shows you the exact project directory that will be created, every file inside it, every skill that will be namespaced under `~/.hermes/skills/templates/<slug>/`, every cron job that will be registered (always paused — you enable each one manually), and a live diff of the memory appendix against your existing `MEMORY.md`. The manifest's content claim is cross-checked against the actual zip entries so a bundle can't hide files from the preview.
- **`scarf://install?url=…` deep links.** Register Scarf as the handler for the `scarf` URL scheme so a future catalog site can link one-click installs straight into the app. Only `https://` payloads are accepted; `file://`, `javascript:`, and `http://` are refused on principle. A 50 MB size cap keeps a malicious link from exhausting disk. The URL never auto-installs — the preview sheet is always user-confirmed.
- **Export any project as a template.** Select a project, open the new Templates menu in the Projects toolbar, fill in a handful of fields (id, name, version, description, optional author + category + tags), tick the skills and cron jobs you want to include, optionally drop in a memory snippet, and save. The exporter builds the bundle and you can hand it to anyone.
- **No-overwrite, reversible by design.** Installed templates drop a `<project>/.scarf/template.lock.json` recording exactly what they wrote — every project file, skill path, cron job name, and memory block id. Installing the same template id twice is refused at the preview step so you don't accidentally double-append to `MEMORY.md`. Uninstalling by hand is a matter of deleting the project directory, the skills namespace folder, and any `[tmpl:<id>] …` cron jobs — no hidden state.
- **Safe globals.** Skills install to `~/.hermes/skills/templates/<slug>/<skill-name>/` so they never collide with your own skills. Cron jobs are prefixed with `[tmpl:<id>]` and start paused so nothing unexpected kicks off on install. The installer **never** touches `~/.hermes/config.yaml`, `auth.json`, sessions, or any credential-bearing path.

### Using templates

- **Install from file:** Projects → Templates → *Install from File…*, pick a `.scarftemplate` from disk.
- **Install from URL:** Projects → Templates → *Install from URL…*, paste an https URL.
- **Install from the web:** click any `scarf://install?url=…` link in a browser.
- **Export:** select a project → Projects → Templates → *Export "&lt;name&gt;" as Template…*, fill the form, save.

### Under the hood

- New models in `Core/Models/ProjectTemplate.swift` (manifest, inspection, install plan, lock, errors).
- `Core/Services/ProjectTemplateService.swift` unzips, parses, and validates; `ProjectTemplateInstaller.swift` executes the plan atomically-enough (pre-flights conflicts, then writes); `ProjectTemplateExporter.swift` builds bundles from a live project + selections.
- `Core/Services/TemplateURLRouter.swift` is the process-wide landing pad for `scarf://` URLs so a cold-launch browser click still reaches the install sheet.
- Installer dispatches cron creation via `hermes cron create` (there's no direct Scarf write path for `cron/jobs.json`), then diffs before/after to pause the newly-registered jobs.
- New Swift Testing suites: `ProjectTemplateServiceTests`, `TemplateURLRouterTests`, `ProjectTemplateExportTests`.

### Uninstall

- **One-click uninstall** driven by `template.lock.json`. Right-click any template-installed project in the sidebar → **Uninstall Template…**, or click the uninstall button in the dashboard header. A preview sheet lists every file, cron job, and memory block that will be removed, and every user-created file that will be preserved.
- **User content is never removed.** Files you (or the agent) added to the project dir after install — like a `sites.txt` or `status-log.md` — are detected and listed as "keep" in the preview. The project directory itself is removed only if nothing user-owned is left inside.
- **Clean global state.** The isolated `~/.hermes/skills/templates/<slug>/` namespace is removed wholesale. Tagged cron jobs are removed via `hermes cron remove`. The memory block between the `<!-- scarf-template:<id>:begin/end -->` markers is stripped, leaving the rest of MEMORY.md intact. The project registry entry is removed last.
- **No undo.** v1 uninstall is destructive — to reinstall, run the install flow again.

### Not in this release (planned for v2.3)

- In-app catalog browser backed by a GitHub Pages `templates.json`.
- EdDSA-signed bundles reusing the Sparkle key.
- Template updates (compare installed lock against a newer bundle's version, offer a diff).
- Installing into remote `ServerContext`s (v1 is local-only).

### Migrating from 2.1.x

Sparkle will offer the update automatically. No config migration needed. Existing projects are untouched — templates are additive.
