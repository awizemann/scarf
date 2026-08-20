---
title: Support
type: note
permalink: scarf-wiki/support
created: 2026-05-29
updated: 2026-05-29
---

# Support

How to get help with Scarf (macOS) or ScarfGo (iOS), report a bug, request a feature, or disclose a security issue. This page is the **Support URL** Apple's App Store reviewer follows — it's intentionally simple and link-heavy so anyone landing here from the App Store finds what they need without scrolling.

## I'm having trouble using the app

Start with the troubleshooting docs — most issues match a known cause.

| Symptom | Page to check |
|---|---|
| ScarfGo can't connect to my Hermes host | [ScarfGo Onboarding](ScarfGo-Onboarding) → Troubleshooting |
| Mac Scarf can't reach a remote server | [Servers & Remote](Servers-and-Remote) |
| Chat hangs or shows "Spinning forever" | [Chat](Chat) → Troubleshooting + [Slow Chat Startup](Troubleshooting-Slow-Chat-Startup) |
| Skills hub Browse is empty | [Hermes Version Compatibility](Hermes-Version-Compatibility) — usually a v2.5+ Citadel exec channel issue, fixed in 2.5 |
| TestFlight says "this beta isn't accepting any new testers" | Apple's Beta Review queue is processing the latest build. See [ScarfGo](ScarfGo) — bookmark the page and try again in 24–48h. |
| Hermes "command not found" over iOS SSH | [ScarfGo Onboarding](ScarfGo-Onboarding) — set the **Hermes binary hint** in the server-edit screen |

## Bug reports

GitHub Issues is the canonical bug tracker:

**[github.com/awizemann/scarf/issues](https://github.com/awizemann/scarf/issues)**

Tag your issue with the right component so it gets routed:

- `component: scarf` — Mac app bugs.
- `component: scarfgo` — iOS app bugs.
- `component: scarfcore` — shared package bugs (services, models, transport).
- `component: design-system` — ScarfDesign tokens / components.
- `component: templates` — `.scarftemplate` install / uninstall / catalog issues.
- `component: docs` — wiki / README / release-notes corrections.

Include in every report:

- Scarf version: **Settings → General → About** (Mac) / **System tab → Server section** (iOS).
- Hermes version: `hermes --version` on the host.
- macOS / iOS version.
- Steps to reproduce.
- Relevant log snippet from `~/.hermes/logs/errors.log` (filter sensitive content first).

## Feature requests

Same place, different tag:

- `feature: scarf` / `feature: scarfgo` / etc.

Include the use case ("I want to do X because Y") and ⭐ the issue if you'd use the proposed feature — star count is a real input to prioritization.

## TestFlight feedback (ScarfGo only)

Open ScarfGo → take a screenshot → use the **Send Beta Feedback** button TestFlight overlays on your screenshot. The screenshot + your text go straight to the developer along with device + iOS version metadata. This is the right channel for TestFlight build issues (crashes, layout glitches on a specific device, missing strings).

For non-TestFlight-build issues (architectural feature requests, Mac↔iOS parity gaps), GitHub Issues is still the right place.

## Security issues

**Do not** open public GitHub issues for security disclosures. Instead:

- Email **[alan@wizemann.com](mailto:alan@wizemann.com)** with `[security]` in the subject line.
- Or use GitHub's private security advisories: <https://github.com/awizemann/scarf/security/advisories/new>.

I'll acknowledge within 48 hours and coordinate disclosure timing. Standard 90-day disclosure window applies for non-critical issues; immediate coordination for anything affecting credential storage or remote-code-execution surfaces.

## Privacy

See **[Privacy Policy](Privacy-Policy)** for what data the apps access and what they do not collect. Short version: your content never leaves your device or your Hermes hosts. Scarf for macOS sends anonymous, content-free usage statistics to guide development — one toggle in Settings → Advanced turns them off. ScarfGo on iOS sends nothing.

## License

Both Scarf and ScarfGo are MIT-licensed. Source: <https://github.com/awizemann/scarf>.

## Direct contact

Email: **[alan@wizemann.com](mailto:alan@wizemann.com)**

Email is for security disclosures, press / partnership inquiries, and "I tried GitHub Issues and the issue was closed but I think you missed something" situations. For everything else, the Issues tracker has more eyes on it and a better chance of someone else hitting the same problem and helping.

## Related pages

- [ScarfGo](ScarfGo) — feature tour, FAQs.
- [ScarfGo Onboarding](ScarfGo-Onboarding) — SSH key setup walkthrough.
- [Servers & Remote](Servers-and-Remote) — Mac remote-server setup.
- [Privacy Policy](Privacy-Policy) — data handling.

---
_Last updated: 2026-04-25 — Scarf v2.5.0 (initial publication)_