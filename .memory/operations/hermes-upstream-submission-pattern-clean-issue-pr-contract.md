---
title: Hermes upstream submission pattern — clean issue/PR contract
type: note
permalink: scarf/operations/hermes-upstream-submission-pattern-clean-issue-pr-contract
created: 2026-07-13
updated: 2026-07-14
---

How to submit to NousResearch/hermes-agent without getting lost/closed (assembled 2026-07-13 from their CONTRIBUTING.md + AGENTS.md at main; a prior submission was lost for not following the provider/auth pattern — this note is the antidote).

## Observations
- [constraint] DUPLICATE SEARCH FIRST, open AND merged: `gh search issues --repo NousResearch/hermes-agent "<terms>"` + `gh search prs --state all`. Their tracker lags the code — also grep the source for the capability before proposing. If an open PR covers it, review/improve that one instead of competing. #before
- [constraint] PROVIDER/AUTH PATTERN (the one that burned us): provider work must follow the established resolution pattern — PROVIDER_REGISTRY / resolve_api_key_provider_credentials / plugins/model-providers/ on current main. Never ad-hoc env reads or bypass wiring. When 3+ PRs integrate the same category they design an ABC and turn PRs into plugins — check whether your area has been plugin-ized on MAIN before building. Memory providers + third-party product integrations are CLOSED in-repo (standalone plugin repos only). #pattern
- [constraint] Mechanics: branch `fix/description`; Conventional Commit with scope (`fix(agent): ...` — scopes: cli/gateway/tools/skills/agent/install/security); NO Co-Authored-By trailers (not their style); `scripts/run_tests.sh` before submitting (CI parity); manual test evidence; declare platforms tested; ONE logical change per PR; fill .github/PULL_REQUEST_TEMPLATE.md (What/Fixes #/Type/Changes/How to Test/Checklist). #mechanics
- [fact] What lands: `fix(...)` against a reported symptom that reproduces on current main, points at the exact line, and fixes the whole bug class including sibling call paths. Issues need OS + Python version + hermes version + traceback + repro. Security issues: private report. #what-lands
- [fact] Their core-vs-edges philosophy: expansive at the edges (platforms/providers/models/UI), conservative at the waist (core agent + model tool schema). Frame contributions accordingly. #philosophy

## Relations
- relates_to [[Local provider config keys — Hermes reader-verified (v0.17.0)]]
- relates_to [[Hermes Version Compatibility Target]]


## THE authentication pattern (solved 2026-07-14 — this is what lost the earlier submission)
- [gotcha] hermes-agent CI has a REQUIRED `Check contributors / check-attribution` job (.github/workflows/contributor-check.yml): every commit author email in the PR must be either a GitHub noreply address matching `+...@users.noreply.github.com` OR a key in `AUTHOR_MAP` in scripts/release.py. A raw personal email (e.g. gmail) fails the required check and the PR sits red until fixed — the likely fate of the lost submission. #root-cause
- [convention] FIX/PREVENT: author upstream commits as `Alan Wizemann <319078+awizemann@users.noreply.github.com>` (amend + force-push repairs an existing PR; `git config user.email` in the working clone prevents it). Alternative sanctioned path: add the mapping to AUTHOR_MAP inside the PR (the check's error text instructs this) — noreply is preferred (no extra diff, privacy-preserving). Applied to PR #64146 (2f52a04). #fix
