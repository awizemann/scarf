<p align="center">
  <img src="icon-v2.5.png" width="128" height="128" alt="Scarf app icon">
</p>

<h1 align="center">Scarf</h1>

<p align="center">
  <strong>The native Mac &amp; iOS app for your <a href="https://github.com/hermes-ai/hermes-agent">Hermes AI agent</a>.</strong><br>
  See every session, project, skill, memory file, and cron job — on your Mac, and from your iPhone over SSH.
</p>

<p align="center">
  <a href="https://awizemann.github.io/scarf/">Website</a> ·
  <a href="https://github.com/awizemann/scarf/releases/latest">Download for Mac</a> ·
  <a href="https://apps.apple.com/us/app/scarfgo/id6763763341">ScarfGo on the App Store</a> ·
  <a href="https://github.com/awizemann/scarf/wiki">Wiki</a> ·
  <a href="https://awizemann.github.io/scarf/#faq">FAQ</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.6+-blue" alt="macOS 14.6+">
  <img src="https://img.shields.io/badge/iOS-18+-blue" alt="iOS 18+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/Hermes-v0.21-purple" alt="Hermes v0.21">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

<p align="center">
  <a href="https://trendshift.io/repositories/26763?utm_source=repository-badge&amp;utm_medium=badge&amp;utm_campaign=badge-repository-26763" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/repositories/26763" alt="awizemann%2Fscarf | Trendshift" width="250" height="55"/></a>
  <a href="https://trendshift.io/repositories/26763?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-26763" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/26763/daily?language=Swift" alt="awizemann%2Fscarf | Trendshift" width="250" height="55"/></a>
  <a href="https://trendshift.io/repositories/26763?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-26763" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/26763/weekly?language=Swift" alt="awizemann%2Fscarf | Trendshift" width="250" height="55"/></a>
</p>

<p align="center">
  <img src="site/landing/assets/screenshots/mac-hero.png" alt="Scarf on macOS — Dashboard" width="720">
</p>

## Why Scarf

Hermes is a terminal-and-messaging agent — powerful, but invisible. Scarf gives it a face:

- **Full visibility.** Every session, message, tool call, token, and dollar — live dashboards, full-text search, activity feeds, cost breakdowns.
- **Full control.** Chat with rich streaming (ACP) or a real terminal, edit memory and skills, manage cron, gateways, MCP servers, and every config key — from a GUI instead of YAML.
- **Your servers, no middleman.** Local `~/.hermes/` or any number of remote hosts over plain SSH (your existing `~/.ssh/config`, agent, ProxyJump). There is no companion service in the middle — nothing between your device and your Hermes host.
- **Native and safe.** Pure Swift 6 / SwiftUI — no Electron. Hermes state is opened read-only; management actions go through the `hermes` CLI, so Scarf can't corrupt your agent's data.
- **Version-adaptive.** Scarf detects each host's Hermes version and capability-gates its UI: Hermes v0.6 through v0.21 all work, and newer-only surfaces simply hide on older hosts.

Available in English, 简体中文, Deutsch, Français, Español, 日本語, and Português (Brasil).

## ScarfGo — your agent in your pocket

<p align="center">
  <a href="assets/screenshots/scarfgo-servers.png"><img src="assets/screenshots/scarfgo-servers.png" alt="ScarfGo — Servers list" width="140"></a>
  <a href="assets/screenshots/scarfgo-chat.png"><img src="assets/screenshots/scarfgo-chat.png" alt="ScarfGo — Chat with Hermes" width="140"></a>
  <a href="assets/screenshots/scarfgo-project-dashboard.png"><img src="assets/screenshots/scarfgo-project-dashboard.png" alt="ScarfGo — Project dashboard" width="140"></a>
  <a href="assets/screenshots/scarfgo-skills.png"><img src="assets/screenshots/scarfgo-skills.png" alt="ScarfGo — Skills browser" width="140"></a>
  <a href="assets/screenshots/scarfgo-system.png"><img src="assets/screenshots/scarfgo-system.png" alt="ScarfGo — System tab" width="140"></a>
</p>

**ScarfGo** is the native iPhone companion — the same Hermes servers you run from your Mac, reachable from your phone. Multi-server, project-scoped chat with session resume, project dashboards, skills browsing + Hub install, memory editor, cron, and per-server Hermes profile switching. Hold the composer's mic button to dictate — on-device speech-to-text only, never a server fallback (thanks to [@danmarauda](https://github.com/danmarauda)) — or start a Live Voice conversation with Hermes when your host supports it. Pure-Swift SSH (Citadel) — the Ed25519 private key is generated on-device, lives in the iOS Keychain, and never leaves the phone.

<p align="center">
  <a href="https://apps.apple.com/us/app/scarfgo/id6763763341"><img src="site/landing/assets/download-on-the-app-store.svg" alt="Download ScarfGo on the App Store" height="48"></a>
</p>

**ScarfGo is now on the App Store — free.** Want beta builds on the edge? [Join the public TestFlight →](https://testflight.apple.com/join/qCrRpcTz)

Connecting takes about a minute: add a server (same details as `ssh user@host`), tap **Generate Key**, paste the public key into the host's `~/.ssh/authorized_keys`, tap **Test connection**. Full walkthrough: [ScarfGo Onboarding](https://github.com/awizemann/scarf/wiki/ScarfGo-Onboarding) · feature tour: [ScarfGo](https://github.com/awizemann/scarf/wiki/ScarfGo) · Mac-vs-iOS matrix: [Platform Differences](https://github.com/awizemann/scarf/wiki/Platform-Differences).

## Privacy

Scarf for macOS collects **anonymous usage statistics** (event names + fixed-vocabulary properties, never content, paths, or hostnames) to guide development. A random per-install identifier is stored on your Mac and sent only as a hash, so active installs can be counted without identifying you. Opt out any time in **Settings → Advanced → Usage Analytics**. ScarfGo for iOS collects nothing. Details in the [Privacy Policy](https://awizemann.github.io/scarf/privacy/). The one voice feature that sends data to a third party is [Live Voice (GPT-Live mode)](https://github.com/awizemann/scarf/wiki/Chat#voice-conversation-mac-and-scarfgo), and only when you start it: your voice streams directly from your Mac or phone to OpenAI, with recent chat messages as context, and both apps ask before the first session.

## What's New in 3.3.0

- **Voice conversation on Mac and ScarfGo** — a waveform button next to Send starts a two-way spoken conversation with Hermes, following the host's own `voice.voice_chat_mode`: *chained* (Hermes's default) is free, on-device speech-to-text with the reply read aloud by the host's TTS provider or the system voice (Hermes v0.20.1+); *GPT-Live* uses OpenAI's real-time voice model on the host's key (Hermes v0.21.3+, one-time privacy consent per device, running cost shown). Every request is still a normal Hermes turn. The chained listener cancels its own echo so it never hears Hermes's reply as your next question.
- **Hermes Voice playback** — replies spoken through the connected server's configured text-to-speech provider (Settings → Voice → Playback Engine, Hermes v0.20.1+). **ScarfGo dictation** — hold the mic, on-device only. Thanks to [@danmarauda](https://github.com/danmarauda) for PR #143.
- **Costs that tell the truth** — an unknown session cost shows a dash instead of "$0.00"; included costs show a genuine zero; the Dashboard's per-model breakdown says it reports all time.
- **Chat windows clean up** — closing a window stops `hermes acp` and its SSH channel; config reads leave the main actor; the Kanban badge resets per chat and pauses in the background; the composer is named for VoiceOver, respects IME composition, and enforces the image cap.
- **ScarfGo** — multi-byte text reassembled correctly across SSH packets; host scripts sent on stdin so they never appear in `ps`.
- Full notes: [releases/v3.3.0/RELEASE_NOTES.md](releases/v3.3.0/RELEASE_NOTES.md).

## What's New in 3.2.0

- **Hermes v0.21.2** — every v0.21.1 surface a Mac client can use (paused cron create, failure delivery, dispatch diagnostics, Kanban Review exits and completion contracts, MCP device-code OAuth, credential-pool reorder, fast-mode tiers, Perplexity/Keenable web backends), all capability-gated; v0.21.2 verified at the tag and on a live host, with Backup Now passing `--keep 0` so Hermes's new prune never deletes a backup you kept.
- **Settings that tell the truth** — the YAML reader was oracled against PyYAML across hundreds of thousands of documents and every disagreement on the keys Scarf reads is fixed; wrong defaults corrected; writers no longer emit YAML Hermes rejects or corrupt a config with a block scalar.
- **Buttons that report what Hermes did** — every shelled verb is judged on its output with three honest states; Restore from backup works again.
- **Gated to the version that shipped it** — twelve capability floors corrected in both directions; `/goal` and `/subgoal` no longer pretend to be commands.
- **The app stops blocking itself** — backup, restore, logs, streaming spawns and shell probes off the cooperative pool and the main actor, with a sweep that keeps them off.
- **A real UI release gate** — Smoke, Full and Live XCUITest plans, green on Hermes v0.21.1 and v0.21.2.
- Full notes: [releases/v3.2.0/RELEASE_NOTES.md](releases/v3.2.0/RELEASE_NOTES.md).

## What's New in 3.1.0

- **A sidebar built around your projects** — projects live at the top of the sidebar in their own panel with folders, filtering, the full context menu, and a New Project button; the other sections collapse and expand, and Scarf remembers your arrangement.
- **Project chats stop nagging** — flip "Auto-accept edits" in a project's Chat Settings and chats bound to that project apply edits without prompting (sensitive paths still ask, enforced by Hermes); or hit the approval dialog's new "Allow edits for this session" button. The setting is cryptographically bound to your machine, so an agent can't grant itself the bypass.
- **Mini-apps can open links** — a new `open_url` permission hands links to your default browser: https-only, confirmed per host by name (Open once / Always allow), never without your click. The sandbox itself stays sealed.
- **Projects that can't be destroyed** — atomic writes on every transport (iOS SFTP included), quarantine-and-refuse instead of overwrite on damage, rolling backups, a cross-process write lock, a Project Doctor that reconciles and repairs, and trust re-verified at time of use (uninstall containment, per-project keychain binding, signed mini-app grants).
- **Agents get real tools** — the bundled scarf-projects MCP server covers the full project surface, including `project_set_config` with secrets routed straight to the Keychain; skills and slash commands now steer agents to tools instead of hand-editing JSON.
- **Much faster while agents stream** — an unchanged watcher tick dropped from ~55–70 SSH round-trips to ~4; registry work moved fully off the main thread.
- **Accessibility** — damage and repair announcements, severity spoken on doctor findings, Audio Graphs for charts, non-color status channels, and text that scales in dense widgets.
- **Heads-up**: mini-apps re-ask for their permissions once after upgrading (grants are now signed); project keychain secrets migrate automatically on next read.

Full notes: [v3.1.0](https://github.com/awizemann/scarf/releases/tag/v3.1.0) · **all previous releases:** [Release Notes Index](https://github.com/awizemann/scarf/wiki/Release-Notes-Index).

## Features

Scarf mirrors Hermes's whole surface through a sidebar UI. Sections marked ⚙ are capability-gated — they appear only when the connected host's Hermes version supports them.

### Projects — mission control per repo

Projects sit first in the sidebar because that's how you actually work. Selecting one opens a unified **cockpit**: Dashboard, Sessions, Board, Site, Context, Cron, Memory, Secrets, Templates, Slash commands, Mini-apps, and Fleet.

- **Project dashboards** — agent-generated JSON dashboards with stat boxes, charts, tables, progress bars, checklists, and embedded web views, live-refreshed. See [Project Dashboards](#project-dashboards) below.
- **Kanban board** ⚙ — full read/write board over Hermes's Kanban, per-project tenants, chat-scoped views.
- **Mini-apps** — sandboxed HTML/CSS/JS panels inside a project that can drive your agent through a rate-limited, permission-gated bridge (locked-down `WKWebView`, default-deny permissions reviewed on first open).
- **Fleet & Portfolio** — the same repo on several machines groups into one logical project; Scarf flags config drift and can push model presets, boards, and cron to the whole fleet.
- **Templates** — install `.scarftemplate` bundles from the [community catalog](https://awizemann.github.io/scarf/templates/), a local file, or a `scarf://install` link; export your own.
- **Project chats load your context** — chats spawn Hermes with the project as cwd, so `AGENTS.md` / `CLAUDE.md` / `.cursorrules` load automatically, on Mac and iOS alike.

### Monitor

- **Dashboard** — system health, token usage, cost tracking (per-model breakdown on Hermes 0.20), recent sessions.
- **Insights** — usage analytics: token/cost trends, model + platform stats, top tools, activity heatmaps, 7/30/90-day filtering.
- **Sessions** — full conversation history with reasoning display, tool-call inspection, full-text search, pin/rename/delete, and Markdown/HTML/Quarto/JSONL export with secret redaction.
- **Activity** — live tool-execution feed with filtering and a detail inspector.

### Interact

- **Chat** — two modes: **Rich Chat** streams over the Agent Client Protocol (ACP) with markdown, tool-call visualization, thinking display, permission prompts, and per-session edit-approval modes; **Terminal** runs `hermes chat` in a real terminal ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)). Both persist sessions, resume, and auto-reconnect.
- **Voice** — talk to Hermes instead of typing it. **Hermes Voice playback** ⚙ speaks assistant replies through the connected server's own configured text-to-speech provider, falling back to the system voice (Settings → Voice → Playback Engine, Hermes v0.20.1+; thanks to [@danmarauda](https://github.com/danmarauda)). **Voice conversation** ⚙ is a full two-way spoken conversation on Mac and ScarfGo, and every real request still goes to Hermes, which answers with your model and full toolset. With Hermes's default *chained* mode it's free and needs no key: your speech becomes text on your device (on-device only), and the reply is read aloud by the host's text-to-speech provider or the system voice (Hermes v0.20.1+). With Hermes's *GPT-Live* mode an OpenAI voice model listens and talks in real time (Hermes v0.21.3+, about $0.05/min on the host's own OpenAI key); your voice then streams directly from your device to OpenAI, so Scarf asks once before the first session. See the [wiki](https://github.com/awizemann/scarf/wiki/Chat#voice-conversation-mac-and-scarfgo) for setup and privacy details.
- **Memory** — view/edit MEMORY.md and USER.md with live refresh and profile-scoped memory.
- **Curator** ⚙ — Hermes's skill curator: status, archive idle skills, consolidation controls.
- **Skills** — browse installed skills, search the Skills Hub across registries, install/update/uninstall from the app.

### Configure

- **Platforms** — native setup forms for Hermes's messaging platforms (Telegram, Discord, Slack, WhatsApp, Signal, iMessage, Matrix, ntfy, and more) including QR pairing flows.
- **Personalities · Quick Commands · Credential Pools · Plugins · Webhooks · Profiles** — every Hermes identity/extension surface, with safe write paths.
- **Models** ⚙ — the model picker as a first-class pane, with local-model discovery (Ollama, LM Studio, vLLM, llama.cpp — local or over SSH), context-window guards, and vision-capability warnings.
- **Hermes Proxy** ⚙ — launch Hermes's OpenAI-compatible local proxy and point Codex CLI / Aider / Cline / Continue at it.

### Manage

- **Tools · MCP Servers · Messaging Gateway · Cron · Health · Logs · Settings** — toolset toggles per platform; full MCP server management (presets, OAuth, mTLS, test-connection); gateway start/stop + pairing; full cron CRUD with run history; health diagnostics with one-click fixes; live log tailing with session-ID filtering; and a structured Settings editor covering essentially every `config.yaml` key Hermes exposes — written through a lossless YAML editor that preserves everything it doesn't model.

## Multi-server: one window per server

Scarf is a multi-window app — each window binds to one Hermes server. Your local `~/.hermes/` appears automatically; add remotes via **File → Open Server… → Add Server**. Remote hosts are reached over system SSH (your `~/.ssh/config`, ssh-agent, ProxyJump, ControlMaster); SQLite is served from atomic snapshots; chat tunnels as `ssh -T host -- hermes acp`. Everything works against remote identically to local.

**Remote host requirements:** key-based SSH (run `ssh-add` once), `sqlite3` and `pgrep` on the remote `PATH`, and `~/.hermes/` readable by the SSH user. If the Dashboard shows "Stopped" or empty values on a green connection, open **Manage Servers → 🩺 Run Diagnostics** — fourteen checks in one SSH session, each with a remediation hint. Details: [Servers & Remote](https://github.com/awizemann/scarf/wiki/Servers-and-Remote).

## Requirements & compatibility

- **macOS 14.6+** (Scarf) · **iOS 18+** (ScarfGo) · Xcode 16+ to build from source.
- **[Hermes](https://github.com/hermes-ai/hermes-agent) v0.6.0+** on each host. Current target: **v0.21.2** (v2026.9.11) — every newer surface is capability-gated or schema-detected, so older hosts keep working with newer-only UI hidden.

| Hermes | Status |
|--------|--------|
| v0.6.0 – v0.17.0 (2026-03 → 2026-06) | Verified — full feature history in the [wiki compatibility page](https://github.com/awizemann/scarf/wiki/Hermes-Version-Compatibility) |
| v0.18.x (2026-07) | Verified — `messages.compacted` schema detection, MoA + Vertex providers |
| v0.19.x "Quicksilver" | Verified — audited as part of the v0.18.2 → v0.20.0 source delta; the ACP chat composer's `/compact` becomes `/compress` at v0.19.1 (the CLI table has said `compress` since v0.3.0), so Scarf sends the spelling each host actually understands |
| v0.20.0 "Herald" (2026-08-03) | Verified — pinned sessions, per-model cost, new exports, cron run history, profile routing |
| v0.20.4 "Herald" (2026-08-18) | Verified — curator ledger/purge, project skills, unread sessions, MCP catalog + identity headers, personalities-in-code |
| v0.20.5 (2026-08-19) | Verified — full-output `--version` probe, unlimited max turns, unseeded `stt.provider`, profile display names, OpenCode Free |
| v0.20.6 (2026-08-27) | Verified — cron incidents/doctor/Run Now, bot-chat delivery, `browser close-profile`, curator pin/unpin diagnostics, essential `hermes-agent` skill |
| v0.21.0 "Pantheon" (2026-08-31) | Verified — Peers (`hermes peer`), dotted-key escaping, MCP catalog 20 → 65 servers, turn-lease default 1800 → 5s, two new providers |
| v0.21.2 (2026-09-11) | **Verified — current target** — the state.db reliability patch; schema, ACP wire and every Scarf argv unchanged at the tag; `hermes backup --keep 0` passed so Hermes's new prune default never deletes your older backups |
| v0.21.1 (2026-09-07) | Verified — Tavily back, `perplexity` web backend, bounded `service_tier` modes, shared-metrics telemetry, `plugins compat --json`, cron `--paused`/`--failure-deliver`, MCP device-code OAuth, `messages_fts` 8 KB tool-content prefix |

Scarf reads Hermes's SQLite database and CLI output with automatic schema detection. If a Hermes update changes either, the Health view shows compatibility warnings.

## Install

### Pre-built binary (recommended)

Download from [Releases](https://github.com/awizemann/scarf/releases): `Scarf-vX.X.X-Universal.zip` (Apple Silicon + Intel) or `-ARM64.zip` (smaller). Unzip, drag **Scarf.app** to Applications, launch — builds are Developer ID signed and notarized. Updates arrive automatically via [Sparkle](https://sparkle-project.org).

<details>
<summary><strong>"Scarf.app is damaged" on first launch?</strong></summary>

The bundle is fine — every release passes `codesign --verify --strict --deep` and `spctl --assess` before shipping. Remove only the quarantine attribute:

```bash
xattr -d com.apple.quarantine /Applications/Scarf.app
```

Or extract with `ditto -xk` instead of double-clicking the zip. **Do not** run `xattr -rc` (strips codesign xattrs) or `codesign --force --deep --sign -` (corrupts Sparkle's nested signatures). If a clean re-download + quarantine removal doesn't fix it, open an issue with `codesign --verify --verbose=4 --strict` output captured before any mitigation.
</details>

### Build from source

```bash
git clone https://github.com/awizemann/scarf.git
cd scarf/scarf
open scarf.xcodeproj
```

No Apple Developer account? Use [`./scripts/local-build.sh`](scripts/local-build.sh) for an unsigned Debug build — see [BUILDING.md](BUILDING.md).

## Project Dashboards

Drop a `.scarf/dashboard.json` into any project and Scarf renders a live-updating dashboard — stat boxes, charts, tables, progress bars, checklists, rich text, and embedded web views. The real power is letting your Hermes agent generate and maintain it (from cron, after builds, whenever state changes — Scarf watches the file):

```json
{
  "version": 1,
  "title": "My Project",
  "sections": [{
    "title": "Overview",
    "columns": 3,
    "widgets": [
      { "type": "stat", "title": "Test Coverage", "value": "87%", "icon": "checkmark.shield", "color": "green" },
      { "type": "progress", "title": "Sprint", "value": 0.73, "label": "73% complete" },
      { "type": "list", "title": "Tasks", "items": [{ "text": "Deploy to prod", "status": "pending" }] }
    ]
  }]
}
```

Register the project by appending `{ "name": "...", "path": "..." }` to `~/.hermes/scarf/projects.json` (or click **Projects → +**). Widget types: `stat` (with optional `sparkline`), `progress`, `text`, `table`, `chart`, `list`, `webview` (embeds a full browser tab for local dev servers, reports, Grafana, …), `markdown_file`, `log_tail`, `cron_status`, `status_grid`, `kanban_summary`, and `image`. Full schema + examples: [DASHBOARD_SCHEMA.md](scarf/docs/DASHBOARD_SCHEMA.md).

## Architecture

MVVM-Feature, Swift 6 strict concurrency, and only two external dependencies ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) and [Sparkle](https://github.com/sparkle-project/Sparkle)) — everything else is system frameworks. Mac app, iOS app, and the shared `ScarfCore`/`ScarfDesign`/`ScarfIOS` packages live in one Xcode project. Hermes state (`state.db`, `config.yaml`, logs, memory, skills) is read directly — `state.db` strictly read-only to avoid WAL contention — and management actions go through the `hermes` CLI. The app sandbox is disabled because Scarf must read `~/.hermes/` and spawn the Hermes binary (which is also why it can't ship on the App Store).

Deep dives: [Architecture Overview](https://github.com/awizemann/scarf/wiki/Architecture-Overview) · [Transport Layer](https://github.com/awizemann/scarf/wiki/Transport-Layer) · [Data Model](https://github.com/awizemann/scarf/wiki/Data-Model) · [ACP Subprocess](https://github.com/awizemann/scarf/wiki/ACP-Subprocess).

## Releases

Scarf ships through GitHub Releases via one local script ([scripts/release.sh](scripts/release.sh)): universal archive → Developer ID signing → notarization → stapling → Sparkle EdDSA-signed appcast on `gh-pages` → GitHub release + tag. The appcast is served from [awizemann.github.io/scarf/appcast.xml](https://awizemann.github.io/scarf/appcast.xml).

## Contributing

Contributions are welcome — several of Scarf's best recent fixes were community PRs. Open an issue to discuss before submitting a PR; see [CONTRIBUTING.md](CONTRIBUTING.md) for the architecture rules, the zero-warnings bar, and the 8-step recipe for **contributing a new language**. Template submissions have their own flow with CI validation: [templates/CONTRIBUTING.md](templates/CONTRIBUTING.md).

## Support

Questions → the [website FAQ](https://awizemann.github.io/scarf/#faq) or the [Wiki](https://github.com/awizemann/scarf/wiki) · bugs → [GitHub issues](https://github.com/awizemann/scarf/issues).

If Scarf is useful to you:

<a href="https://www.buymeacoffee.com/awizemann"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" height="40"></a>

## License

[MIT](LICENSE)
