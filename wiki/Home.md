---
title: Home
type: note
permalink: scarf-wiki/home
updated: 2026-09-22
created: 2026-05-29
---

# Scarf

**The native Mac & iOS app for the [Hermes AI agent](https://github.com/hermes-ai/hermes-agent).** Full visibility into what Hermes is doing, when, and what it creates — on your Mac against one local install or many remote ones, and from your iPhone over SSH with **ScarfGo**.

**Latest release:** [v3.3.0](https://github.com/awizemann/scarf/releases/tag/v3.3.0) — **Scarf gets a voice.** A two-way [voice conversation](Chat#voice-conversation-mac-and-scarfgo) with Hermes on the Mac and in ScarfGo, following the host's own `voice.voice_chat_mode`: **chained** (Hermes's default) is free, on-device speech-to-text with the reply read aloud by the host's TTS provider or the system voice (Hermes v0.20.1+), and **GPT-Live** uses OpenAI's real-time voice model on the host's key (Hermes v0.21.3+, one-time privacy consent per device, running cost shown). Every request is still a normal Hermes turn. Plus **Hermes Voice playback** (replies spoken by the server's configured TTS provider), **ScarfGo dictation** (on-device only; thanks to @danmarauda for PR #143), **honest session costs** (an unknown cost is a dash, not "$0.00"), chat windows that stop `hermes acp` when closed, a Kanban badge that no longer leaks counts between chats, and ScarfGo reassembling multi-byte text correctly across SSH packets. Previous: [v3.2.0](https://github.com/awizemann/scarf/releases/tag/v3.2.0) — **Hermes v0.21.2** and the largest correctness pass yet: every v0.21.1 surface a Mac client can use, all capability-gated; six rounds of adversarial audit fixed **settings that showed the wrong value**, **buttons that reported success over a refusal**, **twelve wrong capability floors**, and **blocking work on the main actor**; a real UI release gate (Smoke/Full/Live XCUITest plans). Earlier: [v3.1.0](https://github.com/awizemann/scarf/releases/tag/v3.1.0) — projects grow up: four rounds of adversarial auditing on the projects surface, atomic writes on every transport, a Project Doctor, signed mini-app grants, a redesigned sidebar and per-project auto-accept edits. All earlier versions: [Release Notes Index](Release-Notes-Index).

**Mobile:** [Download ScarfGo on the App Store](https://apps.apple.com/us/app/scarfgo/id6763763341) — free. Prefer beta builds? [Join the public TestFlight](https://testflight.apple.com/join/qCrRpcTz). See [ScarfGo](ScarfGo) for the feature tour and [ScarfGo Onboarding](ScarfGo-Onboarding) for the one-minute SSH setup.

**Targets Hermes:** v0.21.2 (v2026.9.11), with the voice surfaces gated on their own floors — Hermes Voice playback and chained voice conversation on v0.20.1+, GPT-Live on v0.21.3 (v2026.9.14). Everything newer than a host's version is capability-gated or schema-detected — Hermes v0.6.0 through v0.21.3 hosts keep working exactly as before, with newer-only surfaces hidden gracefully. History: [Hermes Version Compatibility](Hermes-Version-Compatibility).

**Available in:** English, Simplified Chinese (zh-Hans), German (de), French (fr), Spanish (es), Japanese (ja), Brazilian Portuguese (pt-BR). See [Localization](Localization). _ScarfGo is English-only in v1._

## Quick links

- [Installation](Installation) — download, first launch, system requirements (Mac)
- **[ScarfGo](ScarfGo)** — the iPhone companion (free on the App Store; TestFlight for betas)
- **[ScarfGo Onboarding](ScarfGo-Onboarding)** — SSH keys, paste-public-key, connection test
- [Platform Differences](Platform-Differences) — Mac vs iOS feature matrix
- [First Run](First-Run) — what Scarf expects in `~/.hermes/`
- [Projects & Profiles](Projects-and-Profiles) · [Mini-Apps](Mini-Apps) · [Fleet & Portfolio](Fleet-and-Portfolio) — the Projects cockpit
- [Project Templates](Project-Templates) — `.scarftemplate` bundles, install / export / author
- **[Slash Commands](Slash-Commands)** — author project-scoped slash commands (v2.5+)
- **[Hermes Proxy](Hermes-Proxy)** — OpenAI-compatible local server for Codex / Aider / Cline / VS Code Continue (v2.9+, Hermes v0.14+)
- **[Design System](Design-System)** — ScarfColor / ScarfFont / components reference
- [Architecture Overview](Architecture-Overview) — MVVM-F, services, transport, ScarfCore
- [Performance Monitoring](Performance-Monitoring) — ScarfMon: opt-in perf instrumentation
- [Servers & Remote](Servers-and-Remote) — adding remote Hermes hosts over SSH
- [Localization](Localization) — supported languages + how to contribute a new one
- [Release Notes Index](Release-Notes-Index) — every version's notes
- [Troubleshooting: Update "improperly signed"](Troubleshooting-Sparkle-Update) — recovery if Sparkle rejects an update
- [Privacy Policy](Privacy-Policy) · [Support](Support) — what data the apps access; how to get help
- [Wiki Maintenance](Wiki-Maintenance) — how this wiki is edited and kept in sync

## What Scarf does

Scarf mirrors Hermes's surface area through a sidebar UI, with **Projects first** — selecting a project opens a unified cockpit (Dashboard, Sessions, Board, Site, Context, Cron, Memory, Secrets, Templates, Slash, Mini-apps, Fleet):

- **Projects** — cockpit, agent-generated dashboards, Kanban, mini-apps, fleet drift + apply.
- **Monitor** — Dashboard, Insights, Sessions, Activity. See what Hermes is doing.
- **Interact** — Chat (ACP rich chat + real terminal), Memory, Curator, Skills.
- **Configure** — Platforms, Personalities, Quick Commands, Credential Pools, Plugins, Webhooks, Profiles, Models, Hermes Proxy.
- **Manage** — Tools, MCP Servers, Messaging Gateway, Cron, Health, Logs, Settings.

Capability-gated sections (Kanban, Curator, Models, Proxy, and many settings) appear only when the connected host's Hermes version supports them.

Scarf 2.0+ is a multi-window app — one window per Hermes server, local or remote. Remote hosts are reached over plain SSH using your existing `~/.ssh/config`, agent, ProxyJump, and ControlMaster.

## Project status

Open-source (MIT), actively maintained. See [Roadmap](Roadmap) for what's coming.

---
_Last updated: 2026-09-22 — Scarf 3.3.0 (voice conversation in chained and GPT-Live modes, Hermes Voice playback, ScarfGo dictation, honest session costs)._
