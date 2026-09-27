---
id: t-32eabb16
title: R19 Final leftovers + i18n for R18 strings
status: done
added: 2026-09-27
priority: high
---

## Description

From R18a/R18c reports: (1) menu-bar gateway Restart silently does nothing for a hand-run gateway — disable it with an explanatory label/tooltip (e.g. "Restart (running manually)") or open the Gateway view with the explanation; (2) v0.21.4+ --external-supervisor restart can exceed the 30 s timeout on Platforms/MCP (HermesFileService.restartGateway) → use the Gateway view's budget or report "still restarting" honestly; (3) parked named profile with no host gateway still falls through to the foreground run on restart — route it through the restart guard; (4) Restore publishes databases an older archive's database list places inside now-excluded trees (e.g. backups/*.db) — skip them with a note; (5) Fetch preset description should say it needs uv/uvx on the Hermes host; (6) then localize every new/changed user-facing string since 4a3e09d1 (R18a/b/c + this phase) into the catalog + tools/translations per the method in `git show 93617417`, removing dead keys (e.g. Honcho Eager Init, old Nous subscription strings) after verifying no references.

## Plan

Worktree /Users/awizemann/Developer/Scarf-wt/r19, branch fix/hermes-v0215-audit-r19 (from 8aa1ed7d).
1. Menu-bar Restart for a hand-run gateway: ServerLiveStatus remembers the guard's verdict (probed once when Hermes is seen starting, and after a refused click); the menu relabels to "Restart Hermes (running manually)" and disables, or "(status unknown)" when status can't be read. Blast: Mac only (scarfApp.swift). Tests: pure label/state mapping in scarfTests.
2. --external-supervisor restart past the timeout: guard exposes a decision that says the restart is the supervised hand-back; HermesFileService.restartGateway uses the Gateway view's 60 s budget; judge() gains a success marker for "Gateway relaunched by its supervisor" and an unconfirmed "still restarting" arm when a supervised restart times out. Gateway view uses the same. Blast: Platforms, MCP, Gateway view (Mac). Tests: ScarfCore verdict tests.
3. Parked named profile: guard mode .parked (status's early-return line alone) refuses `gateway restart` with a note (Start unparks it); stop+start unaffected. Tests: guard suite.
4. Restore: databases an older archive lists inside trees hermes backup excludes (backups/, checkpoints/, hermes-agent/, models/, cache/<non-kept>…) are skipped (not probed, not published) and listed in the result sheet. Mirror of backup.py _should_exclude/_in_excluded_root_dir. Tests: ScarfCore restore scope suite.
5. Fetch preset description names the uv/uvx requirement (verbatim, not catalogued).
6. i18n: every new/changed user-facing string since 4a3e09d1 (R18a/b/c + R19) into Localizable.xcstrings + tools/translations/*.json per 93617417/60c53214; remove dead keys (Honcho Eager Init, old Nous subscription strings, …) after verifying no references; validate with tools/validate-catalog.py and LocalizationCatalogTests.
Memory/wiki: review gateway restart guard, backup/restore scope, MCP presets notes.

## Artifacts

Merged as c26ad8f9. Anchored backup excludes (-C <home> ., ./… members; bsdtar ^ anchor; old leaf-layout archives rewritten on restore) verified on GNU 1.26/1.29/1.35, BusyBox, bsdtar; menu-bar Restart guarded; supervised restart 60 s + "still restarting"; parked profile refused; restore skips excluded-tree dbs; Fetch uv note; i18n +23 −4 keys. ScarfCore 4086, scarfTests 1795 (1 stale citation fixed + suite rerun). Low follow-up filed: t-55229e05.

