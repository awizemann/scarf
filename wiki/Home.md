---
title: Home
type: note
permalink: scarf-wiki/home
updated: 2026-08-12
created: 2026-05-29
---

# Scarf

A native macOS companion app for the [Hermes AI agent](https://github.com/hermes-ai/hermes-agent). Full visibility into what Hermes is doing, when, and what it creates — across one local install or many remote ones.

**Latest release:** [v2.19.0](https://github.com/awizemann/scarf/releases/tag/v2.19.0) — **The Hermes 0.20 settings backlog, closed — and a browser picker that finally works.** The Settings → Browser backend picker had been writing a config key Hermes never read (`browser.backend` never existed upstream — every selection was silently ignored); it now writes `browser.cloud_provider` with the real provider list, and Auto-detect genuinely clears the key on 0.19+ hosts. New surfaces, each gated to the Hermes version its key shipped in: a **gateway profile-routing rules editor** (route messages to profiles by platform/guild/channel/thread, mirroring Hermes's specificity-ranked matching, written losslessly), **title generation**, **per-task reasoning effort**, **smart approval policy**, **secrets sources** (CLI vault + Bitwarden encrypted cache), **voice STT/TTS tuning**, and **telemetry + SQLite journal knobs**. Version detection is now one cached, persisted probe per server — capability-gated UI appears instantly at launch and survives transient probe failures. Two independent adversarial audits ran before the cut; the fresh-eyes pass validated every key name, default, and version floor against Hermes source and found zero mismatches. See [v2.19.0 release notes](https://github.com/awizemann/scarf/blob/main/releases/v2.19.0/RELEASE_NOTES.md).

**Previous release:** [v2.18.1](https://github.com/awizemann/scarf/releases/tag/v2.18.1) — **Power settings for Hermes 0.20.** Compression tuning (absolute token threshold, guaranteed recent-message tail, idle compaction, progress notices), a **per-model reasoning-effort table** (pin `max`/`ultra` on your heavyweight model, `low` on your fast one — written via Scarf's surgical YAML editor, since `hermes config set` can't write dictionaries), and an **excluded-providers** list that hides unused providers from every picker. The YAML write path was adversarially audited before the cut: two corruption-class edge cases (inline flow syntax on stock configs, CRLF/commented section headers) were caught and fixed pre-ship, hardening the existing gateway allowlist writes too. All gated to v0.20 hosts. See [v2.18.1 release notes](https://github.com/awizemann/scarf/blob/main/releases/v2.18.1/RELEASE_NOTES.md).

**Earlier release:** [v2.18.0](https://github.com/awizemann/scarf/releases/tag/v2.18.0) — **Hermes v0.20 parity.** Full compatibility with Hermes v0.19 "Quicksilver" and v0.20 "Herald" (~5,700 upstream commits audited), plus the best new surfaces: **pinned sessions + last-activity** in the sidebar, a **per-model cost breakdown** on the Dashboard, **Markdown/HTML/Quarto/trace session exports** with secret redaction, **allowlist suggestions** mined from your approval history, **cron run history**, and chat's compaction summaries folded into a tidy disclosure. Remote chats also load dramatically faster — tool-call hydration batches into one SSH round-trip ([#136](https://github.com/awizemann/scarf/pull/136), community-contributed by [@LiamVan6868](https://github.com/LiamVan6868)) — and the compatibility audit's CLI sweep fixed six long-standing bugs, headlined by Skill uninstall/update which had never worked from the UI. Everything is capability-gated: pre-0.20 hosts behave exactly as before. See [v2.18.0 release notes](https://github.com/awizemann/scarf/blob/main/releases/v2.18.0/RELEASE_NOTES.md).

**Earlier release:** [v2.17.2](https://github.com/awizemann/scarf/releases/tag/v2.17.2) — **Markdown tables render.** The one block type Scarf's renderer couldn't draw now renders as real grids everywhere markdown appears — Skill editor preview, chat replies, memory notes, widgets ([#134](https://github.com/awizemann/scarf/issues/134), reported by [@steveisakson](https://github.com/steveisakson)). Block parsing now comes from [Marker](https://github.com/awizemann/Marker), the reusable Markdown engine extracted from TrapperKeeper: GFM grid tables with per-column alignment and inline formatting inside cells, plus real checkbox glyphs for `- [ ]` task items — with the previous rendering semantics preserved line-for-line under a parity test suite. Also carries the ScarfGo [#133](https://github.com/awizemann/scarf/issues/133) connection fixes (per-server-entry SSH key resolution + cellular login-timeout retries) in the shared iOS package, shipping with the next TestFlight build. See [v2.17.2 release notes](https://github.com/awizemann/scarf/blob/main/releases/v2.17.2/RELEASE_NOTES.md).

**Earlier release:** [v2.17.1](https://github.com/awizemann/scarf/releases/tag/v2.17.1) — **"Export…" now always means "save to my Mac."** Session export against a remote server used to silently do nothing — the save panel's Mac path was handed to a CLI running on the far host. Scarf now pipes the export back over stdout and writes it where you chose, with every failure surfaced and the detail-sheet export button fixed ([#129](https://github.com/awizemann/scarf/issues/129), [PR #130](https://github.com/awizemann/scarf/pull/130) by [@JonLaliberte](https://github.com/JonLaliberte) — their **second** merged contribution 🎉). Profile export follows ([#132](https://github.com/awizemann/scarf/issues/132)): the zip streams down to your chosen destination chunk-by-chunk (a ~300 MB profile never passes through memory), retiring the remote-path sheet whose "Verify" green-lit paths with missing parent directories ([#131](https://github.com/awizemann/scarf/issues/131)). See [v2.17.1 release notes](https://github.com/awizemann/scarf/blob/main/releases/v2.17.1/RELEASE_NOTES.md). See the full [Release Notes Index](Release-Notes-Index) for everything earlier.

**Latest mobile:** [Join the public TestFlight](https://testflight.apple.com/join/qCrRpcTz). The link is live now but only accepts new beta testers once Apple's Beta Review approves the first build — see [ScarfGo](ScarfGo) for the full feature tour.
**Targets Hermes:** v0.20.0 (v2026.8.3) — target unchanged in v2.19.0, which closes the remaining 0.20 settings backlog with per-key version floors (0.18/0.19/0.20). First shipped in Scarf v2.18.0 after a full source audit of the v0.18.2 → v0.20.0 delta (~5,700 commits spanning v0.19 "Quicksilver" and v0.20 "Herald"). The v0.20 line brings the `/compress` rename, the reworded curator status, new sessions/messages schema columns (pinned, last-activity, per-model usage — all schema-detected), new providers (Fireworks AI, Google Vertex AI, the returned Vercel AI Gateway), the Buzz gateway platform, and new CLI verbs (`approvals suggest`, `cron runs`, `sessions export --format`). Prior targets: v0.18.2 (Scarf v2.16.0), v0.17.0 (v2.12.0), v0.16.0 (v2.11.0). Everything newer-than-host is capability-gated or schema-detected — Hermes v0.6.0 through v0.19.x hosts keep working exactly as before, with newer-only surfaces hidden gracefully.
**Available in:** English, Simplified Chinese (zh-Hans), German (de), French (fr), Spanish (es), Japanese (ja), Brazilian Portuguese (pt-BR). See [Localization](Localization). _ScarfGo is English-only in v1._

## Quick links

- [Installation](Installation) — download, first launch, system requirements (Mac)
- **[ScarfGo](ScarfGo)** — the iPhone companion (public TestFlight from v2.5)
- **[ScarfGo Onboarding](ScarfGo-Onboarding)** — SSH keys, paste-public-key, connection test
- [Platform Differences](Platform-Differences) — Mac vs iOS feature matrix
- [First Run](First-Run) — what Scarf expects in `~/.hermes/`
- [Project Templates](Project-Templates) — `.scarftemplate` bundles, install / export / author
- **[Slash Commands](Slash-Commands)** — author project-scoped slash commands (v2.5+)
- **[Hermes Proxy](Hermes-Proxy)** — OpenAI-compatible local server for Codex / Aider / Cline / VS Code Continue (v2.9+, Hermes v0.14+)
- **[Design System](Design-System)** — ScarfColor / ScarfFont / components reference
- [Architecture Overview](Architecture-Overview) — MVVM-F, services, transport, ScarfCore
- [Performance Monitoring](Performance-Monitoring) — ScarfMon: opt-in perf instrumentation, how to capture a baseline
- [Servers & Remote](Servers-and-Remote) — adding remote Hermes hosts over SSH
- [Localization](Localization) — supported languages + how to contribute a new one
- [Release Notes Index](Release-Notes-Index) — every version's notes
- [Troubleshooting: Update "improperly signed"](Troubleshooting-Sparkle-Update) — recovery if Sparkle rejects an update
- [Privacy Policy](Privacy-Policy) · [Support](Support) — what data the apps access; how to get help
- [Wiki Maintenance](Wiki-Maintenance) — how this wiki is edited and kept in sync

## What Scarf does

Scarf mirrors Hermes's surface area through a sidebar-based UI grouped into four sections:

- **Monitor** — Dashboard, Insights, Sessions, Activity. See what Hermes is doing.
- **Interact** — Chat, Memory, Skills. Talk to Hermes and shape what it knows.
- **Configure** — Platforms, Personalities, Quick Commands, Credential Pools, Plugins, Webhooks, Profiles, Servers. Set Hermes up.
- **Manage** — Tools, MCP Servers, Gateway, Cron, Health, Logs, Settings. Operate Hermes.

Scarf 2.0 is a multi-window app — one window per Hermes server, local or remote. Remote hosts are reached over plain SSH using your existing `~/.ssh/config`, agent, ProxyJump, and ControlMaster.

## Project status

Open-source (MIT), 160+ stars, actively maintained. See [Roadmap](Roadmap) for what's coming.

---
_Last updated: 2026-08-12 — Scarf v2.19.0 (0.20 settings backlog closed; browser provider fix; profile routing)._