---
title: README and docs marketing structure convention
type: note
permalink: scarf/conventions/readme-and-docs-marketing-structure-convention
source_paths: [README.md, wiki/Home.md, site/landing/index.html]
source_paths_inferred: false
source_sha: 951ac39575c173950a1b989b29d5d689b19616ae
created: 2026-08-13
updated: 2026-08-13
---

## Observations
- [convention] README.md carries ONLY the latest release's "What's New" section (4-6 bullets + link). All older versions live exclusively in the wiki Release-Notes-Index. Release prep must REPLACE the What's New section, never stack a new one on top. #readme #releases
- [convention] Same rule for wiki/Home.md: one "Latest release" paragraph + Release-Notes-Index link — no Previous/Earlier release stack.
- [positioning] Canonical one-liner (README, wiki Home, landing page all aligned 2026-08-13): "The native Mac & iOS app for your Hermes AI agent." ScarfGo is co-equal in positioning, not a footnote — it appears in the first sentence and gets a top-of-README section with TestFlight link.
- [structure] README order: hero → Why Scarf (5 value-prop bullets) → ScarfGo → What's New (latest only) → Features (matching real sidebar order: Projects first, then Monitor/Interact/Configure/Manage, ⚙ marks capability-gated) → multi-server → requirements/compat → install → dashboards → architecture → releases → contributing → support.
- [fact] Canonical Hermes upstream repo (confirmed by Alan 2026-08-13): github.com/hermes-ai/hermes-agent. The stray awizemann/hermes-agent links in wiki/Privacy-Policy.md and wiki/ScarfGo.md were corrected the same day.

## Relations
- relates_to [[Release Distribution and Updates]]
- relates_to [[Hermes Version Compatibility Target]]
