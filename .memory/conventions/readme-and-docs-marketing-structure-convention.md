---
title: README and docs marketing structure convention
type: note
permalink: scarf/conventions/readme-and-docs-marketing-structure-convention
source_paths: [README.md, wiki/Home.md, site/landing/index.html]
source_paths_inferred: false
source_sha: 0efaac8432c1f749c3e6e28427375e9c22e4ff00
created: 2026-08-13
updated: 2026-10-05
reviewed: 2026-09-21
reviewed_by: audit:claude-code (background)
---

## Observations
- [convention] README.md carries ONLY the latest release's "What's New" section (4-6 bullets + link). All older versions live exclusively in the wiki Release-Notes-Index. Release prep must REPLACE the What's New section, never stack a new one on top. #readme #releases
- [convention] Same rule for wiki/Home.md: one "Latest release" paragraph + Release-Notes-Index link — no Previous/Earlier release stack.
- [done] 2026-09-26: README and wiki/Home.md trimmed to v3.4.0 only. Root cause of the repeated regression: the `scarf-release-prep` skill itself said to insert above the previous section and to roll Latest→Previous→Earlier; both steps now state the latest-only rule (Alan made it a standing rule in the release runbook) #releases
- [positioning] Canonical one-liner has minor alignment drift (2026-08-13 baseline, still present 2026-09-26): README.md line 8 correct: "The native Mac & iOS app for your Hermes AI agent." Wiki/Home.md line 11 says "for **the**" (missing "your"); site/landing/index.html line 69 starts "Native" (missing "The"). All three should align to README's canonical form.
- [structure] README order: hero → Why Scarf (5 value-prop bullets) → ScarfGo → Privacy → What's New (latest only, but currently stacked)... → Features (matching real sidebar order: Projects first, then Monitor/Interact/Configure/Manage, ⚙ marks capability-gated) → multi-server → requirements/compat → install → dashboards → architecture → releases → contributing → support → license.
- [fact] Canonical Hermes upstream repo (Alan, 2026-10-05): github.com/NousResearch/hermes-agent. The earlier "hermes-ai/hermes-agent" claim was wrong — that URL 404s — and awizemann/hermes-agent is Alan's personal fork, never a user-facing link. Install anchor is #quick-install (upstream README "## Quick Install"); there is no #installation. In-app docs links use hermes-agent.nousresearch.com/docs/…; verify each with curl before shipping (the Nous Portal link 404'd until 2026-10-05). #links
- [gotcha] Marketing facts drift because they're hand-copied into five places: site/landing/index.html (visible FAQ AND its JSON-LD copy), site/landing/llms.txt, README.md, the wiki, and the hand-rendered gh-pages privacy page. Check claims against the source (project.pbxproj, ScarfBrand.xcassets, analytics code), not against each other. #site

## Relations
- relates_to [[Release Distribution and Updates]]
- relates_to [[Hermes Version Targeting Strategy]]
