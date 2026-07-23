---
title: Platform-Differences
type: note
permalink: scarf-wiki/platform-differences
created: 2026-05-29
updated: 2026-05-29
---

# Platform differences — Scarf (Mac) vs ScarfGo (iOS)

Both clients talk to the same Hermes host with the same paths and the same data. They differ where iOS's constraints make a Mac feature impractical or unnecessary. This page is the canonical "what's missing on iOS, and why" reference.

## Feature matrix

| Feature | Mac (Scarf) | iOS (ScarfGo) | Why the gap |
|---|:---:|:---:|---|
| **Dashboard** | Full (stats + recent sessions + Surfaces + Connected info) | Stripped (stats + recent + Sessions sub-tab with project filter) | iOS density. Surfaces (gateway state / pgrep / config.yaml health) read Mac-only filesystems. |
| **Chat (ACP)** | Yes | Yes | — |
| **Project-scoped chat** | Yes | Yes | Shared `ProjectContextBlock` / `SessionAttributionService` in ScarfCore. |
| **Session resume** | Yes | Yes | — |
| **Sessions list — global** | Yes, with project filter + badges (v2.5) | Yes, with project filter + badges | — |
| **Sessions list — per-project** | Yes (Projects sidebar) | No (global Sessions tab covers it) | Different navigation: Mac has a Projects sidebar, iOS has tabs + per-tab filter. Same data. |
| **Memory editor** | Yes | Yes | — |
| **Cron list (read)** | Yes | Yes | — |
| **Cron editor (write)** | Yes | No | Mac builds a richer editor sheet; iOS read-only in v1. Coming. |
| **Skills tree** | Yes | Yes (read-only) | iOS won't grow a skill editor — too cramped. |
| **Settings (read)** | Yes (full YAML) | Yes (full YAML) | — |
| **Settings (write)** | Yes (full YAML editor) | **Quick Edits (7 keys)** | iOS exposes a curated `hermes config set <key> <value>` shell-out for `model.default`, `model.provider`, `agent.approval_mode`, `agent.max_turns`, `display.show_cost`, `display.show_reasoning`, `display.streaming`. Other keys stay read-only — Mac is the canonical full-YAML editor. |
| **Slash commands — author** _(v2.5)_ | Yes (per-project tab + live preview) | **No** | Multi-line markdown editing on a phone keyboard is its own UX problem; iOS gets a read-only browser instead. |
| **Slash commands — invoke / browse** _(v2.5)_ | Yes (slash menu) | Yes (read-only browser sheet) | — |
| **Templates — install** | Yes | No | Templates are a content-creation surface; iOS won't get a UI for it in v1. Use Mac. |
| **Templates — uninstall** | Yes | No | Same. |
| **Templates — author / export** | Yes | No | Same. |
| **Messaging Gateway (Discord, etc.)** | Yes (status + config) | No | Mac-only filesystem checks (`gateway_state.json`, pgrep). Could be lifted into ScarfCore with effort. |
| **Health view** | Yes (full) | No | Mac reads `~/.hermes/logs/`, gateway state, config sanity, the `hermes dashboard` web link. Could be ported in chunks. |
| **Logs viewer** | Yes (errors + gateway tails) | No | Could ride on `HermesLogService.streamLines` (already remote-capable). Pending UX design for iOS. |
| **Tool Gateway (Nous Portal)** | Yes (provider picker + Auxiliary tab + Health surface) | Provider exists in catalog | iOS Settings is read-only, so tool-gateway routing toggles aren't editable. Use Mac. |
| **Insights / activity charts** | Yes | No | Charts are richer on bigger screens; deferred. |
| **Terminal (SwiftTerm)** | Mac doesn't have it either | No | Hermes shell mode is CLI-only; neither client wraps it. |
| **Localization** | 7 languages (en, de, es, fr, ja, pt-BR, zh-Hans — verified in `Localizable.xcstrings`) | English only | iOS strings are extracted but no translations contributed in v1. |
| **Multi-server** | Yes (one window per server) | Yes (sidebar-adaptable Tab root) | — |
| **Push notifications** | n/a (Mac uses local notifications + the menu bar) | Skeleton present, gated `apnsEnabled = false` | Push sender doesn't exist on Hermes side yet. Capability disabled in target. Flips on simultaneously when both lights are green. |
| **Sparkle auto-update** | Yes | n/a | iOS uses TestFlight / App Store. |
| **iPad support** | n/a | Wired (`.tabViewStyle(.sidebarAdaptable)`) but not smoke-tested | iPad target flag is off; layout probably free, but verify before flipping. |

## Why the iOS surface is intentionally smaller

ScarfGo is a **monitor + steer** client. It's optimised for:

- Running a chat with the agent.
- Looking at sessions, memory, scheduled jobs.
- Resuming work you started somewhere else.
- Approving or denying pending permissions (when push lands).

It's intentionally NOT optimised for:

- Authoring templates or skills.
- Editing settings to deeply tune behaviour.
- Operations work — log triage, gateway debugging, deployment.

Those belong on Mac, where you have a keyboard, real screen, and the full Hermes filesystem layout. Trying to cram them into an iPhone produces a worse Mac and a worse iPhone.

## Things that won't ever come to iOS

- **`hermes` daemon** — Hermes is Python; iOS doesn't sandbox Python well.
- **Local Hermes filesystem** — `~/.hermes/` is on a server, always.
- **Process management** — `pgrep`, `kill`, `launchctl` flows stay Mac-only.

## Things that should come to iOS but haven't yet

These are gaps without a fundamental reason; they just need engineering time:

- **Cron editor.** Add / remove jobs from the phone. The data model is shared; only the editor sheet is missing.
- ~~**Scoped Settings editor.**~~ ✅ Shipped in v2.5 — the **Quick Edits** sheet covers the 7 keys most users actually change (`model.default`, `model.provider`, `agent.approval_mode`, `agent.max_turns`, `display.show_cost`, `display.show_reasoning`, `display.streaming`). Listed here for history; arbitrary-key editing remains future work.
- **Health summary card.** A reduced version of the Mac Health view — just enough to answer "is the gateway running, is the DB reachable, is the agent crashy?"
- **Localization.** Translate the strings the Mac app already has; reuse the `.strings` files.
- **iPad layout pass.** Probably one afternoon's verification.

## Things that are intentionally **not** mirrored

| Mac feature | Why not on iOS |
|---|---|
| Project sidebar | Replaced by Sessions filter — same outcome, different navigation idiom. |
| Window-per-server | Tabs replace it. iPhone has one focus at a time anyway. |
| Sparkle | TestFlight / App Store does the same job. |
| Menu bar / Dock | iOS has neither. |
| AppleScript / URL scheme `scarf://` | iOS apps don't get the same routing surface; can be added if needed. |

---

_Last updated: 2026-04-25 — v2.5 (audit pass: Settings Quick Edits ship; locale list corrected)._