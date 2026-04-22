# Scarf — macOS GUI for the Hermes AI Agent

## Project Structure

```
scarf/scarf/           Xcode project root (PBXFileSystemSynchronizedRootGroup — auto-discovers files)
  scarf/               Main app target source
    Core/Services/     HermesDataService, HermesFileService, HermesLogService, ACPClient, HermesFileWatcher
    Core/Models/       Plain structs: HermesSession, HermesMessage, HermesConfig, etc.
    Features/          MVVM-F feature modules (Dashboard, Sessions, Activity, Chat, Memory, Skills, Cron, Logs, Settings)
    Navigation/        AppCoordinator, SidebarView
  docs/                PRD, Architecture, Discovery notes
  standards/           Copied development standards (read-only reference)
```

## Architecture Rules

- **MVVM-F**: Features never import sibling features. Cross-feature goes through services.
- **AppCoordinator**: Single `@Observable` coordinator for all navigation state, injected via `.environment()`.
- **No external dependencies**: System SQLite3, Foundation JSON, AttributedString markdown.
- **Read-only DB access**: Never write to `~/.hermes/state.db`. Only write to memory files and cron jobs.
- **Sandbox disabled**: App reads `~/.hermes/` directly.
- **Swift 6 concurrency**: `@MainActor` default. Services use `nonisolated` + async/await.

## Key Paths

- Hermes home: `~/.hermes/`
- SQLite DB: `~/.hermes/state.db` (WAL mode, read-only)
- Config: `~/.hermes/config.yaml`
- Memory: `~/.hermes/memories/MEMORY.md`, `~/.hermes/memories/USER.md`
- Sessions: `~/.hermes/sessions/session_*.json`
- Cron: `~/.hermes/cron/jobs.json`
- Logs: `~/.hermes/logs/errors.log`, `~/.hermes/logs/gateway.log`
- ACP: `hermes acp` subprocess (stdio JSON-RPC)

## Build

```bash
xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Debug build
```

## Releases

Shipped via a single local script. **Never run manual `xcodebuild archive` / `notarytool` / `gh release create` steps — use the script so nothing is skipped or misordered.**

```bash
./scripts/release.sh <version>           # full release: notarize → appcast → gh-pages → tag
./scripts/release.sh <version> --draft   # draft: everything builds + notarizes, but appcast/tag are skipped
```

The script bumps version, archives Universal (arm64 + x86_64) + ARM64-only variants, signs with Developer ID, notarizes via `xcrun notarytool` (keychain profile `scarf-notary`), staples, EdDSA-signs the appcast entry with Sparkle's key, pushes the appcast to `gh-pages`, and creates a GitHub release with both zips attached. Draft mode stops after the release is uploaded so the current version stays "latest" until explicitly promoted.

**Release notes convention:** write them to `releases/v<version>/RELEASE_NOTES.md` BEFORE running the script — it's auto-included in the version-bump commit and used as the GitHub release body. If absent, a placeholder is used.

**Canonical prompts (any of these trigger the flow):**
- "Release v1.6.2" — full release
- "Release v1.6.2 as draft" — draft mode
- "Prepare v1.6.2 release notes from recent commits, then release" — generate notes first, then run

**Prerequisites (one-time, already set up on Alan's machine):** Developer ID Application cert in login Keychain (team `3Q6X2L86C4`), notarytool keychain profile `scarf-notary`, Sparkle EdDSA private key in Keychain item `https://sparkle-project.org`, `gh-pages` branch + GitHub Pages enabled. See the header of [scripts/release.sh](scripts/release.sh) and the Releases section in [README.md](README.md) for details.

## Wiki

Public documentation lives in the GitHub wiki at https://github.com/awizemann/scarf/wiki. The wiki is a separate git repo cloned to `.wiki-worktree/` in the repo root (gitignored, sibling to `.gh-pages-worktree/`). Internal dev notes stay in `scarf/docs/`; the wiki is for public-facing reference.

**Update the wiki when:**
- A new feature module is added under `scarf/scarf/scarf/Features/` → extend the relevant User Guide page.
- A new core service is added under `Core/Services/` → extend `Core-Services.md`.
- Architecture changes (AppCoordinator, transport, MVVM-F rule, sandbox) → `Architecture-Overview.md` + the specific sub-page.
- Hermes version bumps in this file → `Hermes-Version-Compatibility.md`.
- `scripts/release.sh` completes a full (non-draft) release → bump latest-version on `Home.md` + append to `Release-Notes-Index.md`.
- Keyboard shortcut or sidebar section changes → `Keyboard-Shortcuts.md` / `Sidebar-and-Navigation.md`.

**Skip for:** bug fixes with no user-observable change, pure refactors, typos, test-only changes, internal cleanups.

```bash
./scripts/wiki.sh pull                         # always first
# edit .wiki-worktree/*.md with normal tools
./scripts/wiki.sh commit "docs: describe X"   # runs secret-scan
./scripts/wiki.sh push                         # runs secret-scan again, then push
```

**Never** commit API keys, tokens, `.env` files, private keys, or real hostnames/IPs to the wiki. The script's two-pass secret-scan blocks common token patterns and a user-maintained blocklist at `scripts/wiki-blocklist.txt` (gitignored). Do not bypass without explicit approval. Full workflow on the wiki itself at `.wiki-worktree/Wiki-Maintenance.md`.

## Hermes Version

Targets Hermes v0.9.0 (v2026.4.13). Log lines may carry an optional `[session_id]` tag between the level and logger name — `HermesLogService.parseLine` treats the session tag as an optional capture group, so older untagged lines still parse.

## Project Templates

Scarf ships a `.scarftemplate` format (v1 as of 2.2.0) for sharing pre-packaged projects across users and machines. A bundle is a zip containing:

- `template.json` — manifest (id, name, version, `contents` claim)
- `README.md` — shown in the install preview sheet
- `AGENTS.md` — required; the [Linux Foundation cross-agent instructions standard](https://agents.md/) — every template is agent-portable out of the box
- `dashboard.json` — copied to `<project>/.scarf/dashboard.json`
- `instructions/…` — optional per-agent shims (`CLAUDE.md`, `GEMINI.md`, `.cursorrules`, `.github/copilot-instructions.md`)
- `skills/<name>/…` — optional; installed to `~/.hermes/skills/templates/<slug>/` (namespaced so uninstall is `rm -rf` on one folder)
- `cron/jobs.json` — optional; registered via `hermes cron create` with a `[tmpl:<id>] …` name prefix and immediately paused
- `memory/append.md` — optional; appended to `~/.hermes/memories/MEMORY.md` between `<!-- scarf-template:<id>:begin/end -->` markers

Key services: [ProjectTemplateService.swift](scarf/scarf/Core/Services/ProjectTemplateService.swift) (inspect + validate + plan), [ProjectTemplateInstaller.swift](scarf/scarf/Core/Services/ProjectTemplateInstaller.swift) (execute a plan), [ProjectTemplateExporter.swift](scarf/scarf/Core/Services/ProjectTemplateExporter.swift) (build a bundle from a project), [ProjectTemplateUninstaller.swift](scarf/scarf/Core/Services/ProjectTemplateUninstaller.swift) (reverse an install using the lock file). UI in [Features/Templates/](scarf/scarf/Features/Templates/). The `scarf://install?url=<https URL>` deep link + `file://` URLs for `.scarftemplate` files are handled by [TemplateURLRouter.swift](scarf/scarf/Core/Services/TemplateURLRouter.swift) and `onOpenURL` in `scarfApp.swift`. A `<project>/.scarf/template.lock.json` uninstall manifest is written after every install and drives the uninstall flow.

**Uninstall semantics:** driven by the lock file. Only files listed in `lock.projectFiles` are removed from the project dir; user-added files (e.g. a `sites.txt` created on first run) are preserved. If every file in the dir was installed by the template, the dir is removed too; otherwise the dir stays with just the user's files. Skills namespace is always removed wholesale (it's isolated). Cron jobs are removed via `hermes cron remove <id>` after resolving each lock-recorded name. Memory block is stripped between the `begin`/`end` markers, leaving the rest of MEMORY.md intact. No "undo" — uninstall is destructive; to re-install, run the install flow again. Uninstall UI lives on the project-list context menu and the dashboard header (only shown when the selected project has a lock file).

**Never** let a template write to `config.yaml`, `auth.json`, sessions, or any credential path — the v1 installer refuses. If you extend the format, treat the preview sheet as load-bearing: the user's only trust boundary is that the sheet is honest about everything that's about to be written.

## Template Catalog

Shipped community templates live at `templates/<author>/<name>/` (one level down — `templates/CONTRIBUTING.md` explains the submission flow for authors). The catalog site is generated from this directory and served at `awizemann.github.io/scarf/templates/` alongside the Sparkle appcast — the two coexist on the `gh-pages` branch but touch completely disjoint paths.

Pipeline:

- **Validator + regenerator:** [tools/build-catalog.py](tools/build-catalog.py) is stdlib-only Python (3.9+). It walks `templates/*/*/`, validates every `.scarftemplate` against its manifest claim (mirrors the Swift `ProjectTemplateService.verifyClaims` invariants), enforces a 5 MB bundle-size cap, scans for high-confidence secret patterns, checks `staging/` matches the built bundle byte-for-byte, and emits `templates/catalog.json`. Tested by [tools/test_build_catalog.py](tools/test_build_catalog.py) — 16 tests covering every validation path.
- **Wrapper:** [scripts/catalog.sh](scripts/catalog.sh) mirrors the `scripts/wiki.sh` shape with `check / build / preview / serve / publish` subcommands. `publish` runs a second-pass secret-scan against the rendered site before committing + pushing `gh-pages`.
- **Site source:** `site/index.html.tmpl` + `site/template.html.tmpl` are `{{TOKEN}}`-substitution templates. `site/widgets.js` (~300 lines of vanilla JS) is the dogfood — renders a `ProjectDashboard` JSON into HTML using the same widget vocabulary the Swift app uses, so each template's detail page shows a live preview of its post-install dashboard.
- **Install-URL hosting:** raw-served from `main` at `https://raw.githubusercontent.com/awizemann/scarf/main/templates/<author>/<name>/<name>.scarftemplate`. No per-template Releases ceremony.
- **CI gate:** [.github/workflows/validate-template-pr.yml](.github/workflows/validate-template-pr.yml) runs the Python validator + its own test suite on every PR that touches `templates/`, the validator, or its tests. Failures post a comment on the PR with the last 3 KB of the validator log.

Maintainer workflow on merge to main:

```bash
./scripts/catalog.sh build       # regenerate templates/catalog.json + .gh-pages-worktree/templates/
./scripts/catalog.sh publish     # secret-scan rendered output + commit + push gh-pages
```

Same cadence as `scripts/release.sh` (manual, auditable, no auto-deploy). Runs stay isolated: release.sh only touches `appcast.xml` on gh-pages; catalog.sh only touches `templates/` on gh-pages. Never push catalog output on a release cadence or vice versa.

**Schema is Swift-primary.** When `ProjectDashboardWidget.type` gains a new case or `ProjectTemplateManifest` adds a field, update Swift first, then mirror into `tools/build-catalog.py` (`SUPPORTED_WIDGET_TYPES`, `_validate_manifest`, `_validate_contents_claim`) so the web validator stays honest. The Python test suite's real-bundle test catches drift on the example template but not on the full widget vocabulary — add a synthetic fixture to `test_build_catalog.py` for any new widget type.
