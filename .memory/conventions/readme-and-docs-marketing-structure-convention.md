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
- [todo] **REGRESSION PERSISTENT** — wiki/Home.md stacks Latest (v3.4.0) + Previous (v3.3.0) + Earlier (v3.2.0) all inline; README.md has four "What's New" sections (v3.4.0 through v3.1.0; regression still present as of v3.4.0 / 2026-09-26). Restore compliance: (1) README keeps 3.4.0 only, move 3.3.0–3.1.0 to Release-Notes-Index; (2) wiki/Home.md keeps v3.4.0 only, move Previous/Earlier to Release-Notes-Index link. #releases
- [positioning] Canonical one-liner has minor alignment drift (2026-08-13 baseline): README.md line 8 correct: "The native Mac & iOS app for your Hermes AI agent." Wiki/Home.md line 11 says "for **the**" (missing "your"); site/landing/index.html omits "The". All three should align to README's canonical form.
- [structure] README order: hero → Why Scarf (5 value-prop bullets) → ScarfGo → Privacy → What's New (latest only, but currently stacked)... → Features (matching real sidebar order: Projects first, then Monitor/Interact/Configure/Manage, ⚙ marks capability-gated) → multi-server → requirements/compat → install → dashboards → architecture → releases → contributing → support → license.
- [fact] Canonical Hermes upstream repo (confirmed by Alan 2026-08-13): github.com/hermes-ai/hermes-agent. README, wiki/Home, and site/landing all link correctly (verified 2026-09-26).

## Relations
- relates_to [[Release Distribution and Updates]]
- relates_to [[Hermes Version Targeting Strategy]]
