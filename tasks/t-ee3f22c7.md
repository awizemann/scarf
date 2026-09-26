---
id: t-ee3f22c7
title: P7e Gateway/profiles/health/skills: allowlist warning, doctor/audit/update-check honesty, sticky notes
status: done
added: 2026-09-26
---

## Description

Source: documents/plans/2026-09-26-p6-surface-audit-findings-and-fix-plan.md §P7e. (1) MED Profile Routes allowlist warning (ProfileRoutesSection.swift:131, SettingsViewModel.swift:1138-1142) fires on ≥0.21.3 where Hermes no longer reads gateway.multiplex_profile_allowlist (only migration 43 deletes it, config_migrations.py:640-649@v2026.9.14; reader present at v2026.9.11) → gate on a new hasMultiplexProfileAllowlist (≥0.20.4 floor — verify — and <0.21.3); consider noting the key is obsolete on newer hosts. (2) MED Skills "Check for updates" (SkillsViewModel.swift:762-773,1018-1022) ignores exit code → only report "no updates" on exit 0 + Hermes's closing line (skills_hub.py:837 / :844@v2026.9.24); otherwise "check failed" with the tail, and don't wipe the existing list. (3) MED Health Doctor (HealthViewModel.swift:221,262, parseOutputStatic :653-713): keep exit code + timeout; when no ◆ section parsed or the run timed out, show a "doctor did not complete" row with output tail; stray `Key: value` lines like tracebacks must not count as passing; consider raising the 60 s cap (~120 s). (4) LOW-MED security audit: take the "Advisories found" arm only when a finding count parses (security_audit.py:257,309); otherwise failed(1). Related t-c9895ecb. (5) LOW Bots settlement-pending note auto-clears after 3 s (BotsViewModel.swift:1254) → persistent warning; Profiles (ProfilesViewModel.swift:300-307) earlier timers can wipe a later note → clear only if the message is unchanged. (6) LOW remote optimize refusal naming Scarf's own transient sqlite3 reader → "Scarf's own read was in progress — retry". (7) MED (found live on Alan's host 2026-09-26): from v0.21.5 `hermes gateway status` prints a boxed "⚠ This gateway is STANDALONE: it serves only its own profile. / Profiles NOT served (their bots stay silent): … / Why: … / Fix: hermes gateway migrate --multiplex" (hermes_cli/gateway_multiplex_mode.py @v2026.9.24; absent at v2026.9.21 — verify exact text/line). Scarf's Profile Routes/Gateway panes say multiplexing is "on unless the host's startup check blocks it" but never show that it IS blocked and why. Parse that box (gated ≥0.21.5; box-drawing borders, possibly very wide lines) and show: standalone, which profiles are not served, the reason, and the fix command (as copyable text, not a button that runs `migrate`). Live example on Alan's host: blocked by duplicate TELEGRAM_BOT_TOKEN in 'gateway' and 'scarfbox-test' profiles.

## Plan



## Artifacts

Commit 224d93f3. Flags: hasMultiplexProfileAllowlist (window 0.20.1 ≤ v < 0.21.3 — audit's 0.20.4 guess was wrong; also fixed a pre-existing over-gate at 0.20.4), hasGatewayStandaloneStatusBox (0.21.5). Skills check needs exit 0 + closing line, keeps list on failure; Doctor keeps exit code, 120 s, "did not complete/timed out" row, traceback lines no longer "passing"; security audit "Advisories" only with parsed count; Bots/Profiles notes persist; remote optimize names Scarf's own sqlite3 read; Gateway pane shows the v0.21.5 STANDALONE box (fix command as selectable text). ScarfCore 3742 pass; 22 app tests. Follow-up: standalone box not surfaced in ProfileRoutesSection. New strings need localization.

