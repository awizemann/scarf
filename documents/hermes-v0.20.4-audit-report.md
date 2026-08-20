# Hermes v0.20.4 (v2026.8.18) audit report

Audited 2026-08-20 against Scarf's current target v0.20.0 (v2026.8.3). Range: v2026.8.3..v2026.8.18 (~3,016 commits; patch tags v0.20.1–v0.20.4). Eight surface agents, source-verified per file:line. Installed host binary is still v0.20.0 — nothing is broken today; this is upgrade preparation.

## Verdict on the two deciding questions

- **state.db schema changed?** Effectively no. `messages`, `messages_fts`, `session_model_usage` DDL byte-identical. `sessions` gained 4 additive columns (`git_metadata_generation`, `title_source`, `hidden`, `last_read_at`). SCHEMA_VERSION 25→26, declarative/additive. No Scarf query breaks. (hermes_state_common.py:288–315)
- **Anything new reach the ACP client unhandled?** No. `_ADVERTISED_COMMANDS` untouched, no new discriminators, no shape changes. `session_info_update` now fires mid-turn (same payload) — Scarf handles identically.

So: **light-to-medium additive cycle**, but with three genuine breaks-on-upgrade and a cluster of pre-existing bugs found in passing.

## Tier 1 — the upgrade forces this (breaks at v0.20.4)

1. **[FIX] Personality pickers go empty.** Hermes removed the 14 inline built-ins from config.yaml (`agent.personalities: {}`); canon moved to `hermes_cli/personality.py:43` `BUILTIN_PERSONALITIES`. Both Scarf pickers scrape the YAML block (SettingsViewModel.swift:747, PersonalitiesViewModel.swift:51). Fix: hardcode/union the built-in list with user entries. Related pre-existing bugs (Tier 3 #1–2) mean the Personalities list was likely already broken.
2. **[FIX] iOS cron enable can't resume a paused job.** New `is_job_runnable()` gate: `state=="paused"` or `paused_at` set blocks firing regardless of `enabled` (cron/jobs.py:571–582, claim gate :2862). Scarf's `withEnabled(true)` (HermesCronJob.swift:172–198) flips only `enabled`, forwarding `state`/`paused_at` verbatim → job never fires again. Fix: enable = force `state="scheduled"` + strip `paused_at`/`paused_reason`; disable = set `state="paused"` + `paused_at`. Gate `hasCronPauseMarkerGate` (>=0.20.4). macOS CLI path (`hermes cron pause|resume`) unaffected.
3. **[FIX] `skills update` silently skips locally-edited skills, exits 0.** Prints `N skill(s) kept your local edits:` + hints `--force` (skills_hub.py:1133–1163). Scarf's updateAll gates on exit code only (SkillsViewModel.swift:513–524) → over-reports success. Parse the skipped list / surface a "kept local edits" affordance; do NOT blindly add `--force` (discards edits).
4. **[FIX] Provider tables drift (check-hermes-tables.py: 2 FAILs).** New overlay-only provider `actual` ("Actual Computer", codex_responses transport, ACTUAL_API_KEY, https://api.actual.inc/v1; providers.py:208) needs an overlay entry + aliases `actual-computer`/`actualcomputer`/`aci` (providers.py:393–395) + display name. Also `openai-codex` label renamed → "ChatGPT or Codex Subscription" (ModelCatalogService.swift:746, 1045). aggregators/modelAliases/imageGen all in sync.
5. **[GATE] `sessions.hidden` not filtered.** Hermes-hidden sessions would still appear in Scarf lists. Add `AND hidden = 0` behind a column probe (HermesDataService.swift:249,260,1109,1194).

## Tier 2 — worth adopting (additive; all need patch-level `atLeastSemver(0,20,4)` gates, NOT the existing `isV020OrLater`)

- **sessions.last_read_at** — free unread indicator for the session list (column probe alongside existing ones).
- **Reset-child sessions**: Hermes now lists reset children (`_LISTABLE_CHILD_SQL`, hermes_state_common.py:157–175); Scarf lists roots only → post-reset conversations invisible. Mirror the reset-child predicate.
- **Curator**: `curator ledger [--skill N]`, `curator purge [--days] [-y]` (purge = permanent delete, distinct from prune=archive), `rollback <entry_id>`. New config keys `curator.archive_ttl_days`, `skills.ledger`.
- **Skills**: `skills trust/untrust` + repo-local project skills (`./.hermes/skills`) — SkillsScanner only scans `~/.hermes/skills`; largest functional gap on that surface. `skills update --force`.
- **CLI**: `approvals test -- <cmd> --json` (dry-run verdict), `peer`, `verify`, `pause`/`resume`, `plugins search/doctor/capabilities/export/pack/show` (community plugin index).
- **Cron editor fields**: `--continuity`, `--monitor-script`, `--monitor-url` (fields round-trip via `extra` already; parsing safe).
- **MCP**: catalog grew 6→20 (blender removed); per-server `identity_header`, `strict_redirect_headers`, stdio `cwd`; probe JSON gained additive `schema_chars`. Scarf's YAML round-trip preserves unknown nested blocks (verified) — add a regression test.
- **Config keys** (ranked by relevance): `wake_word.capture` (client-mic mode), `stt.local.unload_after_idle_seconds`, `stt.cloud_trim_*`, `agent.background_review.enabled` (on by default, costs tokens — kill switch), `auxiliary.*.max_concurrency`, `compression.codex_responses_native`, `agent.cron_drain_timeout` / `gateway_turn_lease_timeout`, `security.approval.transport`.
- **`multiplex_profile_allowlist`** (gateway/config.py:973): malformed value fails safe to serving only `default` — parse it and warn in ProfileRoutesSection when a configured profile isn't allowlisted.
- **Delegation display defaults stale**: `delegation.max_iterations` default 50→250 (migration 36), `max_concurrent_children` 3→10 (migration 37, no Scarf field). HermesConfig+YAML.swift:229 shows 50 for unset configs.
- Cron state display: new derived `effective_job_state()`; also map `"error"` in `stateIcon` (HermesCronJob.swift:231–239).

## Tier 3 — pre-existing bugs found in passing (broken before v0.20.4 too)

1. **PersonalitiesViewModel prefix wrong**: filters `personalities.` but parser emits `agent.personalities.` — list always empty (PersonalitiesViewModel.swift:55,77).
2. **Personality sub-key wrong**: reads `.prompt`; Hermes uses `.system_prompt` (+ tone/style, or bare string) (PersonalitiesViewModel.swift:64,86).
3. **Cron decode fragility**: `null` prompt/name/state in a hand-edited jobs.json fails the whole-file decode; use `decodeIfPresent ?? ""` (HermesCronJob.swift:131).
4. **Stale docs**: GatewayPlatformSettings.swift:21–29 claims `gateway.platforms.<p>.*` path + wrong allowlist-kind mapping (comment-only); HermesDataService.swift:630 FTS parity comment now false (Scarf's phrase-quoting sanitizer is fine, arguably better).
5. **Backlog**: Discord has a real `allowed_channels` allowlist (discord/adapter.py:9977, enforced :7683) — `GatewayAllowlistKind.kind(for:)` returns nil for it; one-line add.

## Deliberate NO-OPs (don't re-litigate next audit)

- ACP: `_POLISHED_TOOLS` kanban additions (title-only); copilot_acp_client (Hermes-as-client, opposite direction); stderr RedactingFormatter; realpath cwd fix (silent benefit — fixes /var vs /private/var session filtering).
- Schema: new `gateway_hygiene_state` + `session_turn_leases` tables (gateway internals, never read); FTS_STORAGE_VERSION unchanged; corruption-rebuild paths.
- CLI: **no argparse in cli.py** — the real verb roster is `_BUILTIN_SUBCOMMANDS` in `hermes_cli/main.py:11413`; diff that next cycle. All four historic argv bugs confirmed fixed.
- Gateway: platform roster unchanged (22 plugins / 25 enum); `gateway list` output byte-identical; allowlist top-level location confirmed (with pre-existing nested fallback); LINE allowed_rooms is env-only (correctly excluded).
- Managed scope: `managed_scope.py` zero diff. All security commits (redaction, lockfile CVEs, plugin scanning, PYTHONHOME) server-side no-ops.
- `jobs.json` envelope unchanged; `cron runs` output unchanged; there is no `cron attach` subcommand (jobs.json field only).
- config: no key Scarf writes was renamed/moved (all 149 write keys + 3 unset keys verified against migrations 34–37, which are value rewrites only). Migration 34 force-resets everyone's personality selection once on upgrade (UX note, not a bug).

## Gating plan

New `// MARK: v0.20.4 (v2026.8.18) flags` group in HermesCapabilities.swift with `isV0204OrLater` = `atLeastSemver(0,20,4)` — patch-level, since v0.20.0 hosts lack all of this. Flags: `hasCronPauseMarkerGate`, `hasBuiltinPersonalitiesInCode`, `hasCuratorLedger`, `hasCuratorPurge`, `hasCuratorEntryRollback`, `hasSkillsProjectTrust`, `hasSkillsUpdateForce`, `hasPluginsSearch`, `hasApprovalsTest`, `hasPeerAndVerify`, `hasMCPIdentityHeader`. Schema items (`hidden`, `last_read_at`) use column probes, not version flags, per convention. HermesCapabilitiesTests cluster: version-line parse, all-flags-on at 0.20.4, hidden at 0.20.0/0.20.3, still-on at hypothetical 0.20.5/0.21.
