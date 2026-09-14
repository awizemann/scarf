---
title: UI release gate: XCUITest is the gate, Harness is exploratory, fixture home built by the hermes CLI
type: note
permalink: scarf/decisions/ui-release-gate-xcuitest-is-the-gate-harness-is-exploratory
tags: [testing, release, harness, xcuitest]
source_paths: [scarf/scarfUITests/UITestIsolation.swift, scarf/scarfUITests/TemplateInstallUITests.swift, scarf/scarf/Navigation/AppCoordinator.swift, scripts/release.sh]
source_paths_inferred: false
source_sha: 96089feb0abaf78cf728e1ead67c4aa47f21cd11
created: 2026-09-08
updated: 2026-09-08
reviewed: 2026-09-12
reviewed_by: audit:claude-code (background)
---

Decided 2026-09-08 with Alan. Full plan: documents/testing/ui-release-gate-plan-2026-09-08.md. Harness "replay" is a viewer of a finished run's events.jsonl, not a re-executor, and its autonomous runs are LLM-driven and non-deterministic, so it cannot be a pass/fail gate.

## Observations
- [decision] The pre-release UI gate is XCUITest (scarfUITests on ScarfUITestCase isolation): a per-section sweep plus journeys, three test plans Smoke / Full / Live, run from release.sh with a loud --skip-ui-tests escape hatch; 10-15+ minutes is acceptable #testing #release
- [decision] Harness is OUT of the release-test story (Alan, 2026-09-08: drop it if it adds complexity, and it does — a second framework, LLM cost, weaker AX-label selectors); its replay is a viewer, not a re-executor, so it could never be a gate anyway #testing #harness
- [decision] Every UI test runs against a fresh throwaway Hermes home seeded by the installed hermes CLI (sessions, memories, paused cron, kanban, a skill, a project) so the state.db schema matches the real Hermes and Scarf itself never writes state.db (C3); no state.db is ever checked in #testing #fixture
- [decision] Credentials for the fixture home come from the developer's own real ~/.hermes (config.yaml / auth.json / .env copied by ScarfUITestCase); other contributors need their own Hermes install and keys, and the Live plan skips cleanly when hermes or credentials are absent #testing #secrets
- [convention] Every AppSection root view carries a <section>.root accessibility identifier and a scan test enforces it, so new sections cannot ship without being sweepable #testing #a11y

## Relations
- relates_to [[Fast test-iteration commands (swift test vs xcodebuild)]]
- relates_to [[ScarfCore tests inject a temp Hermes home via ServerContext.local(home:)]]
- relates_to [[Harness demo project surface for marketing screenshots]]
