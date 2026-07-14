---
title: Home
type: note
permalink: scarf-wiki/home
updated: 2026-07-14
---

# Scarf

A native macOS companion app for the [Hermes AI agent](https://github.com/hermes-ai/hermes-agent). Full visibility into what Hermes is doing, when, and what it creates — across one local install or many remote ones.

**Latest release:** [v2.17.0](https://github.com/awizemann/scarf/releases/tag/v2.17.0) — **Local models.** Scarf now runs against **Ollama, LM Studio, vLLM, llama.cpp, or any OpenAI-compatible endpoint** via a new **Remote | Local** model picker: it discovers the models actually installed on the daemon (local, or a remote server's over SSH), shows each one's size and context window, and **blocks models under Hermes's 64K minimum** before you pick so you never hit a cryptic chat-time failure. Attach an image to a model that can't see images and it warns you first. Bundled with a **chat-session reliability overhaul** — four ways a chat could silently stall or lose output, all fixed — and a settings-dropdown fix. Fully compatible with your current Hermes; no version bump required. See [v2.17.0 release notes](https://github.com/awizemann/scarf/blob/main/releases/v2.17.0/RELEASE_NOTES.md).

**Previous release:** [v2.16.2](https://github.com/awizemann/scarf/releases/tag/v2.16.2) — Mac remote windows can **view any Hermes profile** (Sessions, Memory, Cron, and Chat scoped per-window without touching the server's `active_profile`) — Scarf's **first merged community contribution**, from [@JonLaliberte](https://github.com/JonLaliberte) ([#126](https://github.com/awizemann/scarf/issues/126), [PR #127](https://github.com/awizemann/scarf/pull/127)). The v2.16.x line also brought remote **SSH ControlMaster self-healing** ([#123](https://github.com/awizemann/scarf/issues/123)) and **Hermes-in-Docker config reads** ([#112](https://github.com/awizemann/scarf/issues/112)). See [v2.16.2 release notes](https://github.com/awizemann/scarf/blob/main/releases/v2.16.2/RELEASE_NOTES.md).

**Earlier release:** [v2.15.0](https://github.com/awizemann/scarf/releases/tag/v2.15.0) — **Projects grow up** (skips 2.14; a feature release, not a Hermes-compat one), the biggest Projects update since v2.3. A project becomes a first-class object with its own **cockpit** — one pane for Dashboard, Sessions, Board, Site, Context, Cron, Memory, Secrets, Templates, Slash, Mini-apps, and Fleet — and gains three powers: **[Mini-apps](Mini-Apps)** (sandboxed web panels that drive the agent through a versioned `window.scarf` bridge, in a locked-down `WKWebView` with default-deny permissions reviewed on first open and an isolated rate-limited agent session), **[Fleet & Portfolio](Fleet-&-Portfolio)** (the same repo across multiple hosts grouped as one logical project, with drift surfaced and **Apply to Fleet** to push model preset / board / cron), and **one-click Upgrade Project** (a fast structural pass then an agent hand-off that tailors a dashboard, slash commands, cron, and a starter mini-app). **Project chats now load your `AGENTS.md`** automatically (treat a project's context files like its code — only open chats in projects you trust), plus SSH-path command-injection hardening and a window-frame persistence fix. See [v2.15.0 release notes](https://github.com/awizemann/scarf/blob/main/releases/v2.15.0/RELEASE_NOTES.md).

**Earlier release:** [v2.13.0](https://github.com/awizemann/scarf/releases/tag/v2.13.0) — ScarfGo (iOS) gains **Hermes profile switching** (per-connection scoping that never touches the host's `active_profile`) plus an iOS remote-chat/Settings reliability fix (one pooled SSH connection per server instead of one per read). The Skills "What's New" pill now keys its baseline per (server, profile). See [v2.13.0 release notes](https://github.com/awizemann/scarf/blob/main/releases/v2.13.0/RELEASE_NOTES.md).

**Earlier release:** [v2.12.0](https://github.com/awizemann/scarf/releases/tag/v2.12.0) — coordinated catch-up to **Hermes v0.17.0** (the largest Hermes release yet, though Scarf needed only a focused slice), bundled with a **remote-chat performance fix**: typing into a session on an SSH host no longer lags or spikes CPU now that watcher-driven reads run off the main thread ([#119](https://github.com/awizemann/scarf/issues/119)). The v0.17 audit found the upstream surface entirely stable (zero mandatory changes), so it's a feature catch-up plus pre-existing-bug fixes — four broken Health/Settings CLI actions and the Curator "Prune" rebuilt as the reversible **"Archive idle skills"** — alongside new **WhatsApp Business Cloud API** + **SimpleX** gateway setup forms, Telegram rich-messages / status toggles, an opt-in curator-consolidation toggle, and a max-concurrent-sessions cap, all capability-gated (pre-v0.17 hosts render the v2.11.0 surface byte-identical). v2.11.0 before it caught up to **Hermes v0.16.0** (the `messages.active` soft-delete filter on `/undo`, live ACP session titles, a `rewind_count` badge). See [v2.12.0 release notes](https://github.com/awizemann/scarf/blob/main/releases/v2.12.0/RELEASE_NOTES.md) and the full [Release Notes Index](Release-Notes-Index) for everything earlier.
**Latest mobile:** [Join the public TestFlight](https://testflight.apple.com/join/qCrRpcTz). The link is live now but only accepts new beta testers once Apple's Beta Review approves the first build — see [ScarfGo](ScarfGo) for the full feature tour.
**Targets Hermes:** v0.17.0 (v2026.6.19) — the v0.17 audit found the upstream surface (state.db schema, ACP wire protocol, CLI verbs, config keys, model catalog) entirely stable, so Scarf's v0.17 support (shipped in v2.12.0) is a feature catch-up: WhatsApp Business Cloud API + SimpleX gateway setup forms, Telegram rich-messages / online-offline status toggles, an opt-in curator-consolidation toggle, and a max-concurrent-sessions cap — layered on the v0.16 wave from v2.11.0 (the `messages.active` soft-delete filter, live ACP session titles, the `rewind_count` badge). Later releases don't move the target: v2.15/2.16 are feature/reliability releases, and **v2.17.0's local-model support runs on the same v0.17 line** (with one caveat — on Hermes before 0.18, local models' *auxiliary* features like auto-titles, compression, and image-vision routing degrade until an upstream fix ships; your main chat works). v0.16 / v0.15 / v0.14 / v0.13 / v0.12 / v0.11 / v0.10 still work for everything that didn't change — Scarf detects the host's Hermes version and hides newer-only surfaces gracefully.
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
_Last updated: 2026-07-14 — Scarf v2.17.0 (local models; chat-session reliability overhaul)._