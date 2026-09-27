---
id: t-3ac6b3be
title: R18a R15 fixes: gateway restart, backup scope/tar, health, templates
status: done
added: 2026-09-27
priority: urgent
---

## Description

From R15 (documents/audits/hermes-v0.21.5-full-app-audit/r15-touched-surface-audit/, incl. P1-verification.md): T5-F1 (P1) Restart on a gateway running manually (no service) kills it — probe `gateway status` first; never run `gateway restart` in that state; use what Hermes itself does for a detached start at the tag (verify `gateway start` semantics) or explain + offer `gateway install`; cover Gateway view, Platforms and MCP restart buttons. T7-F1 (P1) GNU tar exit 1 on "file changed as we read it" fails Server Backup on Linux — accept exit 1, fail on >=2, both home and project stages. T7-F2 (P1) mirror hermes_cli/backup.py:46-81,108 exclusion sets (hermes-agent/, venvs, node(_modules), runtimes, models, backups, state-snapshots, checkpoints, browser-profile(s) [credential store — always excluded], caches, .git …, root- and profiles/<name>/-scoped as Hermes scopes them) in RemoteBackupService.hermesExcludes, the snapshot find prunes, and RemoteRestoreService.hermesExtractCommand; verify on Linux (docker/OrbStack) with GNU and BusyBox tar. T5-F2 pairing parser turns "No approved users." into a fake pending pairing (GatewayViewModel.swift:440-474). T5-F3 ScarfGo webhook "not enabled" copy says `hermes setup` (Scarf iOS/Webhooks/WebhooksView.swift:42). T7-F3 Health doctor numbered fix lines with a colon show as passing (HealthViewModel.swift:747-768). T7-F4 Backup/Restore sheets store the six-line `hermes --version` banner as the version (RemoteBackupService.swift:152-162, RemoteRestoreService.swift:259-265). T8-F1 exported template cron jobs keep `category/name` skill refs but the installer places skills under skills/templates/<slug>/<name>/ → Hermes can't find the skill (ProjectTemplateExporter.swift:483-496, ProjectTemplateInstaller.swift:318-331).

## Plan

R18a plan (worktree Scarf-wt/r18a, branch fix/hermes-v0215-audit-r18a)
- T5-F1: before `gateway restart`, probe `gateway status` (short timeout). If it prints the no-service branch (`(Running manually, not as a system service)` or the stopped `# Run in foreground` hint — both since the v0.6 floor, `_cmd_status` gateway.py:5049-5069 @ v2026.9.24) do NOT run restart (its no-service arm = stop + in-process foreground run_gateway, :4977-4981, killed by Scarf's timeout); return a refusal explaining how to restart where it runs / `hermes gateway install`. Exception: v0.21.4+ host whose gateway_state.json argv carries `--external-supervisor` (gateway_supervised_restart.py, v2026.9.21) — Hermes hands that back to its supervisor, so restart proceeds. Status probe that times out/fails → refuse (can't prove safe). Shared ScarfCore helper; callers GatewayViewModel.restartGateway, HermesFileService.restartGateway (Platforms + MCP). Tests: guard parse (manual/stopped/service/multiplexer/parked/older-format/supervised), VM uses fake runner to prove restart argv never runs.
- T7-F1: tar stages wrapped so GNU tar exit 1 (file changed) is success; exit>=2, and any non-zero from bsdtar/BusyBox, still fail. Home + projects (+ db) stages. Verify in debian (GNU) + alpine (BusyBox) with a rewriting file during tar.
- T7-F2: mirror hermes_cli/backup.py:46-81,108 in hermesExcludes (any-depth dir names, root-only hermes-agent, root+profiles/<name>/ models/runtimes/node/browser_profiles, cache/* except kept subdirs, names, suffixes, prefixes), snapshot find prunes, and hermesExtractCommand (BusyBox extract excludes are start-anchored → depth-enumerated patterns). Verify both tars.
- T5-F2: pairing parser ignores `No approved users.` / `No pending…` lines. Test pending-present+approved-empty.
- T5-F3: iOS webhook not-enabled copy → Mac wording.
- T7-F3: doctor parse stops at summary head (`Found N issue(s)`, `All checks passed`, rule).
- T7-F4: first line of `hermes --version` in backup/restore.
- T8-F1: exporter rewrites bundled job skill refs to `templates/<slug>/<name>`?? decide after reading installer; tests round-trip.
Blast radius: Mac Gateway/Platforms/MCP views, remote backup/restore (Linux GNU/BusyBox, Mac bsdtar), Health, iOS webhooks, template export/install.
Memory to review: gateway restart decisions (hermes-v0-21-1-compatibility-decisions), backup/restore architecture notes, templates note.

## Artifacts

Merged into integration (9 commits). Agent: ScarfCore 4037, scarfTests 1774 serial green, Mac+iOS builds; backup scope and tar exit verified in GNU + BusyBox containers; mutation-checked scope test. Leftovers → R19: menu-bar Restart silent on hand-run gateway; external-supervisor restart can exceed 30 s on Platforms/MCP; parked named profile with no host gateway still falls to foreground run; restore publishes dbs an old archive lists under now-excluded trees (backups/*.db).

