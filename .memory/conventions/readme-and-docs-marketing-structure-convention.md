---
title: README and docs marketing structure convention
type: note
permalink: scarf/conventions/readme-and-docs-marketing-structure-convention
source_paths: [README.md, wiki/Home.md, site/landing/index.html]
source_paths_inferred: false
source_sha: 0efaac8432c1f749c3e6e28427375e9c22e4ff00
created: 2026-08-13
updated: 2026-08-13
reviewed: 2026-09-21
reviewed_by: audit:claude-code (background)
---

## Observations
- [convention] README.md carries ONLY the latest release's "What's New" section (4-6 bullets + link). All older versions live exclusively in the wiki Release-Notes-Index. Release prep must REPLACE the What's New section, never stack a new one on top. #readme #releases
- [convention] Same rule for wiki/Home.md: one "Latest release" paragraph + Release-Notes-Index link — no Previous/Earlier release stack.
- [todo] **REGRESSION PERSISTENT** — wiki/Home.md stacks Latest (v3.2.0) + Previous (v3.1.0) + Earlier (v3.0.1) all inline in one paragraph; README.md has both "What's New in 3.2.0" and "What's New in 3.1.0" sections (3.2.0 released 2026-09-14 but stacking remains). Restore compliance: (1) README keeps 3.2.0 only, move 3.1.0 to Release-Notes-Index; (2) wiki/Home.md keeps v3.2.0 only, move Previous/Earlier to Release-Notes-Index link. #releases
- [positioning] Canonical one-liner (README, wiki Home, landing page all aligned 2026-08-13): "The native Mac & iOS app for your Hermes AI agent." ScarfGo is co-equal in positioning, not a footnote — it appears prominently in a top-of-README section with App Store badge and download card (as of v3.2.0 release), and is mentioned in wiki/Home's opening paragraph. TestFlight beta link is secondary (under App Store CTA).
- [structure] README order: hero → Why Scarf (5 value-prop bullets) → ScarfGo → Privacy → What's New (latest only, but currently stacked)... → Features (matching real sidebar order: Projects first, then Monitor/Interact/Configure/Manage, ⚙ marks capability-gated) → multi-server → requirements/compat → install → dashboards → architecture → releases → contributing → support → license.
- [fact] Canonical Hermes upstream repo (confirmed by Alan 2026-08-13): github.com/hermes-ai/hermes-agent. The stray awizemann/hermes-agent links in wiki/Privacy-Policy.md and wiki/ScarfGo.md were corrected the same day.

## Relations
- relates_to [[Release Distribution and Updates]]
- relates_to [[Hermes Version Targeting Strategy]]
