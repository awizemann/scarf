---
title: Roadmap
type: note
permalink: scarf-wiki/roadmap
created: 2026-05-29
updated: 2026-05-29
---

# Roadmap

What's next for Scarf. Public, opinionated, subject to change. The internal version of this lives in [`scarf/docs/ROADMAP.md`](https://github.com/awizemann/scarf/blob/main/scarf/docs/ROADMAP.md) — the public wiki version is a distillation.

## Now (2.5)

- **[ScarfGo](ScarfGo) public TestFlight.** First public iPhone companion build. Pulse the beta tester pool; iterate on feedback over 2.5.x patches.
- **Mac Sessions parity.** Project filter + badges shipped in 2.5 alongside the iOS work. Watch for follow-up on per-project Insights views.
- **Documentation pass.** Wiki reorganized to surface ScarfGo as a first-class section. [Platform Differences](Platform-Differences) is the new canonical reference for "what's different on iOS".

## Near-term (2.6 candidates)

- **iOS cron editor.** Add / remove / toggle cron jobs from the phone. Data model is already shared; just needs the editor sheet.
- ~~**iOS scoped Settings editor.**~~ ✅ Shipped in v2.5 — Quick Edits sheet covers 7 commonly-changed keys via `hermes config set`. Arbitrary-key editing is the v2.6+ stretch.
- **iOS push notifications, lit up.** Three things need to happen together: enable the Push Notifications capability in the Xcode target, ship a Hermes-side push sender, flip `NotificationRouter.apnsEnabled = true`. Skeleton + lock-screen "Approve / Deny" action category are already in place.
- **iPad layout pass.** v2.5 ships iPhone-only (`TARGETED_DEVICE_FAMILY = 1`, Catalyst + Designed-for-iPad disabled). `.tabViewStyle(.sidebarAdaptable)` is wired in the view layer; flipping the target flag and verifying is the bulk of the work.
- **More MCP presets.** The curated list grows as MCP ecosystem matures.
- **Mermaid diagrams in the wiki.** Architecture pages get a lot of value from one good diagram.
- **Per-project FSEvents on remote.** Remote currently has one global mtime-poll loop ([HermesFileWatcher](Core-Services) has a TODO); per-project paths would reduce remote chattiness.

## Medium-term

- **iOS localization.** Translate the strings the Mac app already has; reuse the `.strings` files. 7 languages on Mac; iOS is English-only in v1.
- **iOS Health summary card.** Reduced version of the Mac Health view — gateway / DB / agent crash status. Read-mostly, doesn't need a full editor.
- **Custom commands palette.** A ⌘K-style palette for quick actions across all sidebar sections (Mac).
- **Better Insights.** Rolling heatmaps, drill-downs from any chart, exportable summaries.
- **Voice mode polish.** Speaker selection, partial-results display, better handling of long-form dictation.
- **In-app log filtering by structured fields.** Currently text-search; a typed query (level=error AND component=gateway AND session=...) would help.

## Long-term / speculative

- **Versioned docs.** GitHub wikis don't support `/v1.0/` paths natively; could mirror to GitHub Pages with a static-site generator (deferred — see [Wiki Maintenance](Wiki-Maintenance) "Out of scope").
- **DocC → wiki bridge** for auto-generated API reference.
- **Translated wiki pages** if there's demand.

## What we're NOT doing

- **A web version of Scarf.** The whole point is being native — macOS app on the desktop, iPhone app on mobile, both close to the metal.
- **Background sync.** Scarf is a viewer; Hermes runs the agent. Pull happens when you open a tab, not in the background. (Push notifications, when Hermes ships a sender, are an *event* surface — they alert; they don't sync.)
- **Bundled Hermes installer.** Hermes installation belongs in Hermes-land.
- **Closed-source / paid tier.** MIT-licensed, free, will stay that way.
- **Local Hermes runtime on iOS.** Hermes is Python; iOS doesn't sandbox Python runtimes practically. ScarfGo will always be a thin client over SSH.

## Suggesting features

Open an issue at <https://github.com/awizemann/scarf/issues> with what you want and why. Star the repo if you'd use it (signal helps prioritization).

---
_Last updated: 2026-04-25 — Scarf v2.5.0 + ScarfGo public TestFlight_