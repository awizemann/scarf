# Scarf v2.15.0

**Projects grow up.** This release turns a Scarf project from "a folder your chats happen to point at" into a first-class object with its own mission control — and gives it three big new powers: **mini-apps** (sandboxed web panels that can drive your agent), a **fleet/portfolio** view that groups the same project across every machine you run it on, and **one-click Upgrade Project** that brings an existing repo up to the full experience. Project chats also now load your `AGENTS.md`, so the agent finally knows the project it's working in. It's the largest Projects update since v2.3.

## Mini-apps — sandboxed panels that drive your agent

A **mini-app** is a small web UI (plain HTML/CSS/JS) that lives inside a project and renders in a slide-in panel in the project cockpit. It's the answer to "I wish this project had a custom dashboard / approval queue / task board / chart that could actually *talk to the agent*." Mini-apps can read project data and send the agent prompts — through a tiny, versioned `window.scarf` bridge — without ever leaving the sandbox.

Two things make this safe enough to ship:

- **Everything runs in a locked-down `WKWebView.`** Non-persistent storage (no cross-app cookie or `localStorage` bleed), assets served only through a project-scoped `scarf-miniapp://` handler, navigation pinned to that scheme, and a strict Content-Security-Policy (`default-src 'none'; connect-src 'none'`) that blocks all network access. A mini-app is self-contained by construction — no external scripts, no CDNs, no `fetch()` to the internet. File reads resolve through symlink-containment so a planted link can't escape the project directory.
- **Default-deny permissions, reviewed on first open.** Every sensitive capability a mini-app declares — sending the agent prompts, reading files, querying data — is **off until you approve it**. The first time you open a mini-app, Scarf shows a permission sheet listing exactly what it wants; sensitive permissions are pre-unchecked for **agent-generated** mini-apps and unknown permissions are refused outright. Your decision is saved per `(project, mini-app)`, and changing it later live-revokes access.

When a mini-app calls `scarf.prompt(...)`, it gets its **own dedicated `hermes acp` session** (spawned lazily, torn down when the panel closes), isolated from your chats — web content can't reach into other conversations. That session is rate-limited (8 prompts/60s) to cap runaways, and because no human is watching it turn-by-turn, any tool-permission request the agent raises mid-turn is auto-denied.

**Building one:** ask the agent — the bundled **`scarf-miniapp-author`** skill scaffolds the manifest, directory, and a working starter. Or run **Upgrade Project** (below), which has the agent build a starter mini-app for you. Installed mini-apps show up in the cockpit's **Mini-apps** panel, with agent-generated ones clearly flagged.

> **v1 scope.** This release wires the read + prompt surfaces: `scarf.prompt`, `scarf.onEvent` (streamed agent output), `scarf.store` (per-app key-value), `scarf.file.read`, and `scarf.query("kanban.tasks")`. Writing surfaces (`kanban:write`, `file:write`) and outbound network (`net`) are declared in the permission model but not yet enabled — they're coming, and the sandbox already accounts for them.

## Fleet & Portfolio — your project across every machine

If you run the same repo on more than one host — your laptop and a server, say — Scarf now understands those as **one logical project**. Because a project's identity is a stable id minted once and carried in its `project.json`, cloning the repo to another machine and registering it there groups both copies under a single **Fleet** view in the cockpit.

The Fleet panel shows each host's copy side by side and flags **drift** — places where the same project disagrees across machines (a different bound model preset, a renamed board, a different cron-job count, mismatched mini-apps). When you've got one host configured the way you want, **Apply to Fleet…** pushes that config out to the others: the model preset, the Kanban board, and the project's cron jobs are recreated on the targets you select.

Apply-to-fleet is deliberately conservative. Every host is handled independently — one unreachable machine or one failed field never aborts the rest, and you get a per-host, per-field report of what was applied, skipped, or failed. Copying cron jobs **probes the target host's Hermes version first** and drops flags that an older Hermes wouldn't understand (e.g. `--deliver all` on pre-0.14) rather than failing the copy. The same version-gating now protects template-install cron jobs.

## One-click Upgrade Project

Got a project from before all this — or one you scaffolded by hand? **Upgrade Project** brings it up to the full first-class experience. A cockpit banner offers it; one click runs a fast, idempotent structural pass (mints a stable id and `project.json`, creates a Kanban board, refreshes the Scarf-managed `AGENTS.md` block, seeds a placeholder dashboard) and then hands off to chat, where the agent tailors a real dashboard, slash commands, cron jobs, and a starter mini-app to *your* project. Re-running it is a no-op, so it's safe to click.

## The cockpit — one pane for the whole project

Selecting a project now opens a single **cockpit** — mission control for everything about that project, instead of the old narrow Dashboard/Site/Slash tab bar. A unified header (name, path, bound model preset, the hosts it lives on) sits above a flat row of panels: **Dashboard, Sessions, Board, Site, Context, Cron, Memory, Secrets, Templates, Slash, Mini-apps,** and **Fleet**. Panels that don't apply to a given project hide themselves, so even a bare project gets a clean, complete control center. (Secrets shows field *names* only — values stay in the Keychain.)

## Project chats now load your AGENTS.md

Opening a chat **inside a project** finally gives the agent that project's context. Scarf now spawns `hermes acp` with the project as its working directory, so Hermes loads the project's `AGENTS.md` / `CLAUDE.md` / `.cursorrules` into the agent automatically — for new chats and for resumed, reconnected, and auto-started ones alike. No more re-explaining the repo every time.

> **A note on trust.** Opening a chat in a project now loads that project's `AGENTS.md` / `CLAUDE.md` / `.cursorrules` into the agent (so it has project context). Treat a project's context files like its code — only open chats in projects you trust. _(Correction, added later: this note originally said mini-apps do not load these files. They do — Hermes loads context files from the agent session's folder, and a mini-app's session runs in the project folder.)_

## Smaller fixes

- **Remote SSH paths are hardened against command injection** — `$` and backticks in a remote project path are now escaped before they reach the shell.
- **Window size and position persist again.** SwiftUI was saving the frame but never restoring it; Scarf now restores it manually on launch.
- **Mini-app streamed events keep their order** — agent output is delivered FIFO on the main thread instead of racing per-event tasks.

## Under the hood

- The whole release sits on a new **first-class `ScarfProject` object** — a portable `project.json` plus a per-host registry — that replaces project identity previously smeared across sessions, AGENTS.md blocks, template locks, and cron tags.
- New `scripts/build-detached.sh` launches an isolated, visually-distinct dev copy you can dogfood while you keep building.
- Test-suite isolation fixes (per-instance temp homes, de-flaked remote-SQLite tilde-home test) and a sweep making off-main helpers `nonisolated` for the app's MainActor-default isolation.

## Upgrade notes

- **Sparkle** will offer the update automatically, or use **Scarf → Check for Updates**. macOS 14.6+ deployment target unchanged. **No data migrations** — existing projects keep working; click **Upgrade Project** when you want the new structure.
- **Mini-apps** are new this release; nothing you have changes until you add or generate one. The writing/network mini-app surfaces noted above arrive in a later release.
- **iOS / ScarfGo:** this is a Mac-track release. The shared-core pieces (first-class project model) ride along, but the Projects UI is Mac-only for now.
