---
title: Contributing
type: note
permalink: scarf-wiki/contributing
created: 2026-05-29
updated: 2026-06-02
---

# Contributing

Thanks for your interest in contributing to Scarf. The canonical contributor guide lives in [`CONTRIBUTING.md`](https://github.com/awizemann/scarf/blob/main/CONTRIBUTING.md) in the repo. This page is a public-facing summary plus a few wiki-specific notes.

## Quick start

1. Fork and clone <https://github.com/awizemann/scarf>.
2. Open `scarf/scarf.xcodeproj` in Xcode 16+. Two app targets: `scarf` (macOS) and `scarf mobile` (ScarfGo, iOS). Both share the local SwiftPM packages [ScarfCore](ScarfCore-Package), `ScarfIOS`, and [ScarfDesign](Design-System).
3. Build and run (requires macOS 14.6+ and Hermes installed at `~/.hermes/` for the local Mac window; iOS sim or device + a SSH-reachable Hermes host for ScarfGo).
4. Read [Build & Run](Build-and-Run) for the codebase tour, [Architecture Overview](Architecture-Overview) for the layering, and [Design System](Design-System) for the rust palette + token usage.

## Code conventions

The full list is in [`CONTRIBUTING.md`](https://github.com/awizemann/scarf/blob/main/CONTRIBUTING.md). The non-negotiables:

- **MVVM-F.** Features never import sibling features. Cross-feature concerns go through services or `AppCoordinator`.
- **No commented-out code, no TODOs, no deferred functionality** in PRs.
- **Zero warnings** on build.
- **Read-only DB access.** Never write to `~/.hermes/state.db`.
- **Swift 6 strict concurrency.** `@MainActor` default isolation; `nonisolated` for service methods.
- **Conventional commits.** `feat:`, `fix:`, `chore:`, `refactor:`, `docs:`, etc.

## What's good to work on

- Anything in the [Roadmap](Roadmap) or [ScarfGo Roadmap](ScarfGo-Roadmap).
- iOS-specific gaps — Cron editor, Settings full-YAML editor, Insights / Activity views, iPad layout polish, push notifications wiring once Hermes ships a sender. See [Platform Differences](Platform-Differences).
- Test coverage — see [Testing](Testing) for the highest-value remaining gaps (UI tests, log streaming).
- iOS localization — strings are extracted; translations welcome. See [Localization](Localization).
- Templates for the public catalog — see [Project Templates](Project-Templates) and the catalog at [awizemann.github.io/scarf/templates/](https://awizemann.github.io/scarf/templates/).
- Wiki content — every stub on the wiki is a pull request opportunity. See [Wiki Maintenance](Wiki-Maintenance) for the workflow.
- Bug reports with reproducible steps.

## Pull request flow

1. Open an issue first describing the change. This avoids rework if the maintainer has constraints in mind.
2. One feature or fix per PR — keeps reviews tight.
3. Include a clear description of what changed and why.
4. Ensure both schemes build clean:
   - `xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Debug build`
   - `xcodebuild -project scarf/scarf.xcodeproj -scheme "scarf mobile" -configuration Debug -destination "generic/platform=iOS Simulator" build`
5. Run the ScarfCore test suite if you touched anything in `Packages/ScarfCore`: `swift test --package-path scarf/Packages/ScarfCore`.

## Reporting issues

Open an issue at <https://github.com/awizemann/scarf/issues> with:

- What you expected to happen.
- What actually happened.
- macOS version and Hermes version.
- Steps to reproduce.
- The relevant log snippet from `~/.hermes/logs/errors.log` if applicable (redact secrets first).

## Documentation contributions

Two paths:

- **Small wiki edits** (typos, clarifications) — click **Edit** on any wiki page in the GitHub UI. Editing requires push access to the main repo.
- **Larger wiki changes** — clone the wiki directly (`git clone git@github.com:awizemann/scarf.wiki.git`) or open an issue describing what needs adding. See [Wiki Maintenance](Wiki-Maintenance) for the full workflow including the secret-scan policy.
- **Internal dev docs** (PRD, Hermes API discovery, raw architecture notes) live in `scarf/docs/` in the main repo and follow the normal PR flow.

## Repo memory (Memophant)

As of v2.10.1 Scarf's repo-resident memory for AI coding sessions is managed by **Memophant** — a memory manager I built for exactly this. You'll see it in three places:

- A managed block at the bottom of `CLAUDE.md` describing the layered memory system (`.memory/` for atomic facts via the `basic-memory` CLI, `wiki/` for long-form reference, `design/` for design system docs, `TASKS.md` for the work kanban).
- Commits on `main` titled "via Memophant" (memory migrations, consolidations, wiki/design syncs) — those are repo-memory housekeeping, not Scarf app changes; you can ignore them when reading history for app work.
- A `wiki/` working directory + a `TASKS.md` kanban file at the repo root.

Memophant will be open-sourced shortly. Until then, nothing in Scarf the app depends on it; it's a workflow tool for the repo. PRs don't need to touch any Memophant artifact — keep doing the normal `feat:` / `fix:` commits and the maintainer handles memory updates on the side.

## Code of conduct

Be kind, be specific, assume good faith. Disagreements about technical direction are welcome; personal attacks aren't.

---
_Last updated: 2026-05-29 — Scarf v2.10.1 (Memophant memory system note)_