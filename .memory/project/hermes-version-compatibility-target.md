---
title: Hermes Version Compatibility Target
type: note
permalink: scarf/project/hermes-version-compatibility-target
tags: [hermes, compatibility, versioning]
source_paths: [README.md, scarf/scarf.xcodeproj/project.pbxproj, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift, scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesDataService.swift, documents/hermes-v0.21.1-audit-report.md, wiki/Hermes-Version-Compatibility.md]
source_paths_inferred: false
source_sha: 834467ab2ab1d5523097d023b965211259223f3d
created: 2026-05-29
updated: 2026-09-14
reviewed: 2026-09-18
reviewed_by: audit:claude-code (background)
---

## Observations
- [target] **Scarf's current Hermes target is v0.21.2 (v2026.9.11)** — bumped 2026-09-14 on `main` after a targeted compatibility check (not a full parity cycle): SCHEMA_VERSION 30 unchanged, no table removed, every probed column present, `check-hermes-tables.py --tag v2026.9.11` `lanes=5/5`, ACP wire clean, no argv removed, every judged output marker identical, Smoke + Live UI plans green against a live 0.21.2 host. One behaviour change answered: `hermes backup` defaults to `--keep 3` from v2026.9.11 and prunes `~/hermes-backup-*.zip`, so `HermesBackupVerdict.argv(capabilities:)` passes `--keep 0` behind `hasBackupKeep` (the v0.21.2 MARK group's only flag). The v0.21.1 parity itself landed on `feat/hermes-v0211-parity` (2026-09-08); the Scarf version shipping both is set at release prep. v0.6.0+ remain supported. See [[Hermes v0.21.1 Audit Findings]] and [[Hermes v0.21.1 Compatibility Decisions]]. #current
- [target] Latest shipped Scarf is **v3.2.0** (2026-09-14, tag `v3.2.0`; targets Hermes v0.21.2 / v2026.9.11 and carries the v0.21.1 parity, the six-round whole-surface audit, the UI release gate, and analytics `.identity`). Before it, **v3.1.0** — the Hermes v0.21.0 line release (Hermes v0.21.0 v2026.8.31 parity merged to main 2026-09-01 as commit a7f013b0, shipped in v2.23.0, subsequently released through v2.24.0, v3.0.0, v3.0.1, and v3.1.0). The last SHIPPED release targets Hermes v0.21.0 (v2026.8.31); v0.6.0+ remain fully supported, minimum v0.6.0. The Hermes catch-up trail: v2.11.0 → Hermes v0.16.0; v2.12.0 → v0.17.0; v2.13.0/v2.15.0 Scarf-internal; v2.15.1 aggregator-mismatch patch; v2.16.0 → v0.18 line; v2.18.0 → v0.20.0; v2.20.0 → v0.20.4; v2.21.0 → v0.20.5; v2.23.0 → v0.21.0. See [[Hermes v0.21.0 Audit Findings]], [[Hermes v0.20.0 Audit Findings]], and the Hermes Version Compatibility wiki page for detailed per-version audit results. #current
- [compatibility] Minimum supported Hermes: v0.6.0 (2026-03-30). All versions v0.6.0 through v0.21.2 are verified; older Hermes versions degrade gracefully — new behavior is capability-gated. #minimum
- [schema] Scarf reads Hermes's SQLite state.db and parses CLI output from `hermes status`, `hermes doctor`, `hermes tools`, `hermes sessions`, `hermes gateway`, `hermes pairing`. Automatic schema detection provides backward compatibility: v0.16 added the `messages.active` soft-delete column (first schema change since v0.11; detected via `hasMessagesActiveColumn`); v0.17 introduced no further schema change; v0.18 adds `messages.compacted` (in-place compaction soft-archive; detected via `HermesQueryBackend.hasCompactedColumn` — SEARCH widens to `(active = 1 OR compacted = 1)` while transcript/activity queries stay active-only); v0.21 adds `messages._compressed_summary` and lazy `gateway_heartbeats` / `hosted_room_*` tables (all PRAGMA/sqlite_master-detected, never version-probed). #schema
- [parsing] Log lines may carry an optional `[session_id]` tag between level and logger name; `HermesLogService.parseLine` treats the session tag as an optional capture group so older untagged lines still parse. #logs
- [sync-checklist] On each Hermes bump, keep in sync: `overlayOnlyProviders` / `modelAliases` / `demotedProviders` / `imageGenModels` (vs hermes_cli/providers.py + models.py + xai_retirement.py), the platform roster (vs plugins/platforms/ + gateway/platforms/), and the search/TTS backend lists. Added in the v0.21.1 cycle: the **web backend roster** (`WebToolsBackendRoster` vs `plugins/web/`, and re-check every previously-modelled REMOVAL — a patch tag can re-add one), the **plugin-provider lane 4** in `scripts/check-hermes-tables.py` (providers auto-appended to CANONICAL_PROVIDERS vs `overlayOnlyProviders`, resolved through BOTH alias tables), the **gateway multiplexer branch** of `gateway status` / `gateway list`, and the **cron dispatch rows** (`Dispatch:` / `⚠ Delivery UNVERIFIED:`). #maintenance

## Relations
- implements [[Hermes Capability Gating Pattern]]
- relates_to [[hermes-version-targeting-strategy]]
- documented_in [[scarf-wiki/hermes-version-compatibility]]

- [runbook] **The provider-table gate, exact command:** `./scripts/check-hermes-tables.py --tag v2026.9.11` from the repo root — it must exit 0 AND the verdict must read `lanes=5/5`. It reads Hermes at the TAG via `git show`, never the checkout's working tree, and it FAILS CLOSED: a `SKIPPED lane N` line exits 2, so a plain exit-0 check is not enough — read `lanes=5/5`. `--tag` defaults to `HERMES_TARGET_TAG` in the script, which is the one place the repo records the target tag (bump it with the capability floors); `--worktree` reads the working tree for local work; `--allow-skip` accepts a partial run and must not be used to clear the gate. The script's own tests: `python3 -m unittest discover -s scripts/tests -t .`. #maintenance
