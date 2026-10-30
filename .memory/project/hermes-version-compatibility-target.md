---
title: Hermes Version Compatibility Target
type: note
permalink: scarf/project/hermes-version-compatibility-target
tags: [hermes, compatibility, versioning]
source_paths: [README.md, scarf/scarf.xcodeproj/project.pbxproj, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift, documents/hermes-v0.21.1-audit-report.md, wiki/Hermes-Version-Compatibility.md]
source_paths_inferred: false
source_sha: e9c088bdcbf280bdbe34fe7d16b1b2ff3c08eaeb
created: 2026-05-29
updated: 2026-10-25
reviewed: 2026-10-29
reviewed_by: audit:claude-code (background)
---

## Observations

- [gotcha] Bumping `HERMES_TARGET_TAG` reds `scripts/tests/test_readme_hermes_target.py` until release-prep updates the README's "Current target" line (and reds `check-hermes-tables.py` until the provider tables are reconciled) — expected on a working parity branch, not a regression; fix at release-prep, not in the bump commit #maintenance
- [target] **Hermes v0.22.5 (tag `v0.22.5`) is the current main target.** Merged to main via v3.7.0 (2026-10-26, tag `v3.7.0`) and carried through v3.7.1; both releases ship full parity from v0.21.6–v0.22.5. `HERMES_TARGET_TAG = "v0.22.5"`; `check-hermes-tables.py` lanes=8/8. Branch `feat/hermes-v0225-parity` was the development branch (active 2026-10-25); it is now merged. See [[Hermes v0.22 Compatibility Decisions]] and [[Hermes v0.22 Wire Verification]]. #current
- [target] **Branch `feat/hermes-v0215-parity` (2026-09-26) was merged to main; v0.21.5 parity (v2026.9.24) merged as of commit 9454726b, release-prep landed as commit a79ebfb7.** This target shipped through Scarf v3.4.0 (2026-09-26), v3.5.0 (2026-09-29), and v3.6.0 (2026-10-06) before advancing to v0.22.5 in v3.7.0. v0.21.5 (Hermes v2026.9.24) — SCHEMA_VERSION 30, every probed column present, `check-hermes-tables.py --tag v2026.9.24` lanes=5/5, ACP wire clean. Earlier: Scarf v3.3.0 (2026-09-22) targets Hermes v0.21.2 (v2026.9.11); v3.2.0 (2026-09-14) targets v0.21.2; v3.1.0 targets the Hermes v0.21.0 line. Earlier trail: v2.11.0 → Hermes v0.16.0; v2.12.0 → v0.17.0; v2.18.0 → v0.20.0; v2.21.0 → v0.20.5; v2.23.0 → v0.21.0. See [[Hermes v0.21.1 Audit Findings]] and [[Hermes v0.21.1 Compatibility Decisions]]. #current
- [compatibility] Minimum supported Hermes: v0.6.0 (2026-03-30). All versions v0.6.0 through v0.22.5 are verified; older Hermes versions degrade gracefully — new behavior is capability-gated. #minimum
- [schema] Scarf reads Hermes's SQLite state.db and parses CLI output from `hermes status`, `hermes doctor`, `hermes tools`, `hermes sessions`, `hermes gateway`, `hermes pairing`. Automatic schema detection provides backward compatibility: v0.16 added the `messages.active` soft-delete column (first schema change since v0.11; detected via `hasMessagesActiveColumn`); v0.17 introduced no further schema change; v0.18 adds `messages.compacted` (in-place compaction soft-archive; detected via `HermesQueryBackend.hasCompactedColumn` — SEARCH and TRANSCRIPT reads use `(active = 1 OR compacted = 1)` — transcripts add Hermes's generation dedupe — while activity feeds stay active-only); v0.21 adds `messages._compressed_summary` and lazy `gateway_heartbeats` / `hosted_room_*` tables (all PRAGMA/sqlite_master-detected, never version-probed). #schema
- [parsing] Log lines may carry an optional `[session_id]` tag between level and logger name; `HermesLogService.parseLine` treats the session tag as an optional capture group so older untagged lines still parse. #logs
- [sync-checklist] On each Hermes bump, keep in sync: `overlayOnlyProviders` / `modelAliases` / `demotedProviders` / `imageGenModels` (vs hermes_cli/providers.py + models.py + xai_retirement.py), the platform roster (vs plugins/platforms/ + gateway/platforms/), and the search/TTS backend lists. Added in the v0.21.1 cycle: the **web backend roster** (`WebToolsBackendRoster` vs `plugins/web/`, and re-check every previously-modelled REMOVAL — a patch tag can re-add one), the **plugin-provider lane 4** in `scripts/check-hermes-tables.py` (providers auto-appended to CANONICAL_PROVIDERS vs `overlayOnlyProviders`, resolved through BOTH alias tables), the **gateway multiplexer branch** of `gateway status` / `gateway list`, and the **cron dispatch rows** (`Dispatch:` / `⚠ Delivery UNVERIFIED:`). #maintenance

## Relations
- implements [[Hermes Capability Gating Pattern]]
- relates_to [[hermes-version-targeting-strategy]]
- documented_in [[scarf-wiki/hermes-version-compatibility]]

- [runbook] **The provider-table gate, exact command:** `./scripts/check-hermes-tables.py --tag v0.22.5` from the repo root — it must exit 0 AND the verdict must read `lanes=8/8`. It reads Hermes at the TAG via `git show`, never the checkout's working tree, and it FAILS CLOSED: a `SKIPPED lane N` line exits 2, so a plain exit-0 check is not enough — read `lanes=8/8`. `--tag` defaults to `HERMES_TARGET_TAG` in the script, which is the one place the repo records the target tag (bump it with the capability floors); `--worktree` reads the working tree for local work; `--allow-skip` accepts a partial run and must not be used to clear the gate. The script's own tests: `python3 -m unittest discover -s scripts/tests -t .`. #maintenance
