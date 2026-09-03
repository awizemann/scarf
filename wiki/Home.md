---
title: Home
type: note
permalink: scarf-wiki/home
updated: 2026-09-02
created: 2026-05-29
---

# Scarf

**The native Mac & iOS app for the [Hermes AI agent](https://github.com/hermes-ai/hermes-agent).** Full visibility into what Hermes is doing, when, and what it creates — on your Mac against one local install or many remote ones, and from your iPhone over SSH with **ScarfGo**.

**Latest release:** [v3.0.1](https://github.com/awizemann/scarf/releases/tag/v3.0.1) — post-3.0 fixes: **bot creation works for every profile** (Scarf's writer refused Hermes's own line-wrapped `profile.yaml` values), plus a parser hunt against Hermes's real serializer output — local-model reasoning overrides (`llama3:8b`) save again, long quick commands no longer silently truncate, one bad cron record no longer blanks the board — and Release builds now compile with warnings as errors. Previous: [v3.0.0](https://github.com/awizemann/scarf/releases/tag/v3.0.0) — the milestone release: Bots grows up (per-bot model pins, SOUL.md editing with conflict detection, per-bot toolset/MCP enablement, one-round-trip SSH scanning) and the whole app went through a five-lens audit (security escapes closed, five quietly-broken surfaces repaired, honest numbers, 2,374 localized keys × six languages, accessibility throughout). Earlier: [v2.24.0](https://github.com/awizemann/scarf/releases/tag/v2.24.0) introduced the Bots section with live streaming bot chats. All earlier versions: [Release Notes Index](Release-Notes-Index).

**Mobile:** [Join the ScarfGo public TestFlight](https://testflight.apple.com/join/qCrRpcTz) — see [ScarfGo](ScarfGo) for the feature tour and [ScarfGo Onboarding](ScarfGo-Onboarding) for the one-minute SSH setup.

**Targets Hermes:** v0.21.0 (v2026.8.31). Everything newer than a host's version is capability-gated or schema-detected — Hermes v0.6.0 through v0.20.6 hosts keep working exactly as before, with newer-only surfaces hidden gracefully. History: [Hermes Version Compatibility](Hermes-Version-Compatibility).

**Available in:** English, Simplified Chinese (zh-Hans), German (de), French (fr), Spanish (es), Japanese (ja), Brazilian Portuguese (pt-BR). See [Localization](Localization). _ScarfGo is English-only in v1._

## Quick links

- [Installation](Installation) — download, first launch, system requirements (Mac)
- **[ScarfGo](ScarfGo)** — the iPhone companion (public TestFlight)
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
_Last updated: 2026-09-02 — Scarf 3.0.1 (bot-creation fix + the Hermes-serializer parser hunt)._
