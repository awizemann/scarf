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
