---
title: Keyboard-Shortcuts
type: note
permalink: scarf-wiki/keyboard-shortcuts
created: 2026-05-29
updated: 2026-05-29
---

# Keyboard Shortcuts

Scarf exposes a focused set of shortcuts. The defining patterns are **window switching** (⌘1…⌘9), **standard dialog flow** (Return / Esc), and a handful of context-specific actions inside views.

## Window / server switching

| Keys | Action | Defined in |
|---|---|---|
| ⌘1 | Open the local server window | [`scarfApp.swift`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/scarfApp.swift) |
| ⌘2 … ⌘9 | Open remote server window 2 through 9 (in registry order) | [`scarfApp.swift`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/scarfApp.swift) |
| ⌘⇧S | Open the Manage Servers picker | [`scarfApp.swift`](https://github.com/awizemann/scarf/blob/main/scarf/scarf/scarfApp.swift) |
| ⌘Q | Quit Scarf | macOS standard, declared in `scarfApp.swift` |

You can have a local window and up to 8 remote windows reachable by ⌘ + number. Beyond that, use Manage Servers (⌘⇧S).

## In-view shortcuts

| Keys | Where | Action |
|---|---|---|
| ⌃B | Chat | Toggle the sessions sidebar inside Chat |
| ⌘S | Personalities (SOUL.md editor) | Save the current SOUL.md |
| **1**…**9** _(v2.5+)_ | Chat permission sheet | Approve / deny by option number — Hermes's request-permission sheet binds 1–9 to the option buttons. Visible "1. " / "2. " prefixes hint the binding. Power users approve / deny without reaching for the mouse. |

## Dialog defaults

These follow the macOS convention; Scarf is consistent across every dialog:

| Keys | Behavior |
|---|---|
| Return | Confirm — fires the `.defaultAction` button (Save, Add, Create, Run, etc.). |
| Esc | Cancel — fires the `.cancelAction` button. |

Sheets that follow this pattern include: project create / rename, session rename, MCP server add, Add Server, Add Cron Job.

## Standard system shortcuts

These work in Scarf because they're macOS standards, not because Scarf binds them explicitly:

| Keys | Action |
|---|---|
| ⌘W | Close window |
| ⌘M | Minimize window |
| ⌘N | New window (opens a new local window) |
| ⌘⌥N | New window without tabs (when tabbing is on) |
| ⌘, | Open Settings (Settings is part of `scarfApp.swift`'s scene config) |
| ⌘C / ⌘V | Copy / paste — works inside text fields, message bubbles, log lines |
| ⌘F | Search inside the Sessions browser and Logs view |

## What there isn't

There's no command palette and no global shortcuts beyond ⌘ + number for windows. The sidebar is mouse / arrow-key navigated; there's no ⌘1 / ⌘2 within a window for switching sections.

If you'd like to see additional shortcuts, file an issue — keyboard accessibility is welcome contribution territory.

## ScarfGo (iOS)

iPhone has no Mac keyboard, so the binding tables above don't apply. The numbered permission-sheet hints (1. / 2. / …) still render on iOS but as hierarchy cues — the row tap target is the action.

If you connect a Bluetooth keyboard or an iPad with a Magic Keyboard, you get system iOS shortcuts (⌘C copy, ⌘W close sheet, ⌘N new chat in some flows). No app-specific bindings yet — on the [ScarfGo Roadmap](ScarfGo-Roadmap).

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (numbered approval shortcuts + iOS note)_