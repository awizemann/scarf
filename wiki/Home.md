---
title: Home
type: note
permalink: scarf-wiki/home
updated: 2026-10-05
created: 2026-05-29
---

# Scarf

**The native Mac & iOS app for the [Hermes AI agent](https://github.com/NousResearch/hermes-agent).** Full visibility into what Hermes is doing, when, and what it creates — on your Mac against one local install or many remote ones, and from your iPhone over SSH with **ScarfGo**.

**Latest release:** [v3.6.0](https://github.com/awizemann/scarf/releases/tag/v3.6.0) — **Trust and readability.** **ScarfGo now verifies SSH host keys**: it remembers each server's key on first connect and refuses one that changes, showing both fingerprints and a **Trust New Key** step (before, it accepted any key; the Mac app always checked). Both apps got a **contrast pass** to WCAG AA: a deeper light-mode orange, dark text on orange buttons in dark mode, darker status text, and brick-red destructive actions. The **privacy policy and in-app text now match the code**, so Live Voice asks for consent once more (Hermes's replies and status lines also go to OpenAI) and the Mac's analytics are called "usage statistics", not "anonymous". Scarf has required **macOS 15** since v2.20.0, and the update feed now says so, so Sonoma Macs are no longer offered updates that can't open. All earlier versions: [Release Notes Index](Release-Notes-Index).

**Mobile:** [Download ScarfGo on the App Store](https://apps.apple.com/us/app/scarfgo/id6763763341) — free. Prefer beta builds? [Join the public TestFlight](https://testflight.apple.com/join/qCrRpcTz). See [ScarfGo](ScarfGo) for the feature tour and [ScarfGo Onboarding](ScarfGo-Onboarding) for the one-minute SSH setup.

**Targets Hermes:** v0.21.5 (v2026.9.24), with surfaces gated on their own floors — Hermes Voice playback and chained voice conversation on v0.20.1+, GPT-Live on v0.21.3, multiplex-by-default routing and the v0.21.4 CLI changes on v0.21.4, parked profiles and the standalone warning on v0.21.5. Everything newer than a host's version is capability-gated or schema-detected — Hermes v0.6.0 through v0.21.5 hosts keep working exactly as before, with newer-only surfaces hidden gracefully. History: [Hermes Version Compatibility](Hermes-Version-Compatibility).

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
_Last updated: 2026-10-05 — Scarf 3.6.0 (ScarfGo SSH host-key verification, WCAG AA contrast pass across both apps, privacy policy and Live Voice consent corrected to match the code, macOS 15 minimum in the update feed)._
